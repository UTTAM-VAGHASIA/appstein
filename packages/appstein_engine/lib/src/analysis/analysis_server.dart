import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/host_environment.dart';
import '../sdk/sdk_detector.dart';
import 'analysis_guard.dart';
import 'code_analysis.dart';

/// How long an analysis server may take until its analysis is done, before
/// the run fails (slice 1d.2). The slowest start measured was 71 s.
const analysisReadyTimeout = Duration(seconds: 180);

/// The real `dart` executable of the Dart SDK at [dartSdkPath]: never the
/// `dart.bat` wrapper of a Flutter SDK or FVM's, which each cost a second
/// per start on Windows.
String dartExecutableIn(String dartSdkPath) =>
    p.join(dartSdkPath, 'bin', Platform.isWindows ? 'dart.exe' : 'dart');

/// The `dart` executable of the Flutter SDK the project at [projectRoot]
/// uses, found as every other part of Appstein finds the SDK, so `verify`
/// agrees with the developer's `dart analyze` and IDE. [dartSdkPath]
/// replaces the Flutter SDK's own Dart SDK, for tests.
///
/// Throws a [CodeAnalysisException] when the project has no usable SDK.
String projectDartExecutable(
  HostEnvironment environment,
  String projectRoot, {
  String? dartSdkPath,
}) {
  if (dartSdkPath != null) return dartExecutableIn(dartSdkPath);
  final detection = SdkDetector(environment).detect(projectRoot: projectRoot);
  final location = detection.location;
  if (detection.info == null || location == null) {
    final problem = detection.problem ?? 'no Flutter SDK was found';
    throw CodeAnalysisException(
      'the project has no usable Flutter SDK '
      '(${problem.replaceFirst(RegExp(r'\.$'), '')})',
    );
  }
  return dartExecutableIn(p.join(location.root, 'bin', 'cache', 'dart-sdk'));
}

/// A scope that gives each body an analysis server of its own for the
/// project at [projectRoot], and stops it when the body ends, normally or
/// with an error. This is what a terminal `appstein verify` does. The
/// server is started only when the body first asks something. A question
/// asked after the body has ended throws a [StateError]: it would start a
/// server nobody stops.
///
/// The arguments are [AnalysisServer.new]'s.
CodeAnalysisScope ownAnalysisServer({
  required String projectRoot,
  required List<String> guardCommand,
  required String Function() dartExecutable,
  Duration readyTimeout = analysisReadyTimeout,
}) => <T>(body) async {
  final server = AnalysisServer(
    projectRoot: projectRoot,
    guardCommand: guardCommand,
    dartExecutable: dartExecutable,
    readyTimeout: readyTimeout,
  );
  try {
    return await body(server);
  } finally {
    await server.close();
  }
};

/// The code analysis of one project, answered by a Dart analysis server
/// that runs as a child process behind a guard (decision record 0001).
///
/// - **The server** is `dart language-server --protocol=analyzer` of the
///   project's own SDK, spoken to over the legacy analyzer protocol: one
///   JSON object per line on its stdin and stdout.
/// - **It starts when it is first asked**, so an owner that never asks holds
///   no server. A question waits until the server says its analysis is done
///   (`server.status`), which over this protocol includes its plugins'.
/// - **Diagnostics** are kept from the `analysis.errors` notifications the
///   server sends for each file, since the request for one file's errors
///   leaves a plugin's diagnostics out. A file is dropped when the server
///   sends `analysis.flushResults` for it.
/// - **A plugin that could not be loaded** is told with `server.pluginError`,
///   after which the server reports its analysis done as usual. Those
///   messages are kept and returned with every reading.
/// - **Whoever creates it owns it** and must call [stop] or [close]. No
///   check does.
///
/// A server that can't be started, reports a fatal error, ends by itself,
/// loses its guard, or isn't done within [readyTimeout] makes the question
/// throw a [CodeAnalysisException]. Its processes are ended before the
/// exception is thrown, and the next question starts a new server.
final class AnalysisServer implements CodeAnalysis {
  /// Creates the analysis of the project at [projectRoot]. Nothing is
  /// started yet.
  ///
  /// [guardCommand] starts the guard: the `appstein` binary and the name of
  /// its guard mode, or where Appstein runs from source, `dart`, its entry
  /// script and that name. The server's `dart` is added as the last
  /// argument. [dartExecutable] gives that `dart` when the server is
  /// started; it may throw a [CodeAnalysisException] when the project has
  /// none (see [projectDartExecutable]).
  AnalysisServer({
    required String projectRoot,
    required this.guardCommand,
    required this.dartExecutable,
    this.readyTimeout = analysisReadyTimeout,
  }) : projectRoot = p.normalize(p.absolute(projectRoot));

  /// The project's folder, absolute.
  final String projectRoot;

  /// The command that starts the guard, without the server's `dart`.
  final List<String> guardCommand;

  /// Gives the `dart` executable that runs the server.
  final String Function() dartExecutable;

  /// How long a question waits for the server's analysis to be done.
  final Duration readyTimeout;

  _Session? _session;
  var _closed = false;

  /// The process IDs of the running guard and server; null when no server
  /// is running, or the guard hasn't named them yet.
  ({int guard, int server})? get processes => _session?.processes;

  /// One reading from the running server, which is started first when none
  /// is running. Questions asked at the same time share one server.
  ///
  /// The reading holds what the server has sent by the time it last said
  /// its analysis was done. A server that is kept between runs (slice 1d.2,
  /// ticket 04) needs one more thing here, before the reading is taken: a
  /// way to know the server has seen the latest edit on disk, which is not
  /// a wait. Every run takes its one reading through this method, so this
  /// is the place for it.
  @override
  Future<CodeReading> read() async {
    if (_closed) {
      throw StateError(
        'The analysis server of $projectRoot was asked after its owner '
        'closed it.',
      );
    }
    final session = _session ??= _Session(this);
    try {
      return await session.read().timeout(
        readyTimeout,
        onTimeout: () => throw CodeAnalysisException(
          'its analysis was not done within ${readyTimeout.inSeconds} s',
        ),
      );
    } on CodeAnalysisException {
      // Nothing is left running, and the next question starts again.
      if (identical(_session, session)) _session = null;
      await session.stop();
      rethrow;
    }
  }

  /// Stops the server and its guard, and returns when both have ended. It
  /// does nothing when no server is running, and never throws. A question
  /// asked afterwards starts a new server.
  Future<void> stop() async {
    final session = _session;
    _session = null;
    await session?.stop();
  }

  /// Stops the server as [stop] does, for good: a question asked afterwards
  /// throws a [StateError] instead of starting a server nobody would stop.
  Future<void> close() {
    _closed = true;
    return stop();
  }
}

/// One run of the server: its guard process and what the server has said.
final class _Session {
  _Session(this._owner) {
    _opened = _open();
    // A failure is reported to whoever asks next.
    _opened.ignore();
  }

  final AnalysisServer _owner;
  late final Future<void> _opened;

  Process? _process;
  final _listening = <StreamSubscription<String>>[];
  ({int guard, int server})? processes;

  /// The requests the server hasn't answered, by ID.
  final _pending = <String, Completer<void>>{};
  var _nextId = 0;

  /// The latest diagnostics the server sent for each file, as it sent them.
  final _errors = <String, List<Object?>>{};

  /// What the server said about each plugin it could not load or run.
  final _pluginFailures = <String>[];

  /// The last lines the guard and the server wrote to stderr.
  final _said = <String>[];

  /// Completes when the guard's stderr has closed.
  final _saidAll = Completer<void>();

  /// Whether the guard said it ended in order ([analysisGuardEnded]): its
  /// server has ended too.
  var _guardEndedInOrder = false;

  /// Whether the server said it is analyzing, and whether it has since said
  /// it is done.
  var _analyzing = false;
  var _analyzed = false;
  final _waiting = <Completer<void>>[];

  CodeAnalysisException? _failure;
  var _stopping = false;

  /// Set when the guard's process has exited: completes when its end has
  /// been judged and the session has failed.
  Future<void>? _exiting;

  String get _root => _owner.projectRoot;

  /// Starts the guard, and tells the server which notifications to send
  /// and where the project is.
  Future<void> _open() async {
    final dart = _owner.dartExecutable();
    if (!File(dart).existsSync()) {
      throw CodeAnalysisException('there is no Dart executable at $dart');
    }
    final command = [..._owner.guardCommand, dart];
    final Process process;
    try {
      process = await Process.start(command.first, command.sublist(1));
    } on ProcessException catch (error) {
      throw CodeAnalysisException(
        'its guard could not be started with ${command.first} '
        '(${error.message})',
      );
    }
    _process = process;
    // A write to a process that has ended fails; its exit says why.
    process.stdin.done.ignore();
    _listening
      ..add(_lines(process.stdout).listen(_onLine, onError: (Object _) {}))
      ..add(
        _lines(
          process.stderr,
        ).listen(_onSaid, onError: (Object _) {}, onDone: _saidAll.complete),
      );
    unawaited(process.exitCode.then((code) => _exiting = _onExit(code)));
    await _request('server.setSubscriptions', {
      'subscriptions': ['STATUS'],
    });
    await _request('analysis.setAnalysisRoots', {
      'included': [_root],
      'excluded': <String>[],
    });
  }

  static Stream<String> _lines(Stream<List<int>> bytes) => bytes
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  /// What the server has said about the project, once its analysis is done:
  /// the diagnostics `dart analyze` would show for the files inside the
  /// project, and the plugins that failed.
  Future<CodeReading> read() async {
    await _opened;
    // A guard that has exited is being looked at (did it end in order?):
    // what its server sent is not answered from in the meantime.
    if (_exiting case final exiting?) await exiting;
    if (_failure case final failure?) throw failure;
    if (!_analyzed || _analyzing) {
      final done = Completer<void>();
      _waiting.add(done);
      await done.future;
    }
    final found = <CodeDiagnostic>[];
    for (final MapEntry(key: file, value: errors) in _errors.entries) {
      if (!p.isWithin(_root, file)) continue;
      final relative = p.split(p.relative(file, from: _root)).join('/');
      for (final error in errors) {
        if (error case {
          'severity': final String severity,
          'type': final String type,
          'location': {'startLine': final int line},
          'code': final String code,
          'message': final String message,
        }) {
          // A `TODO` comment the project didn't raise above info level:
          // the server sends it for IDEs, and `dart analyze` hides it.
          if (type == 'TODO' && severity == 'INFO') continue;
          found.add(
            CodeDiagnostic(
              file: relative,
              line: line,
              code: code,
              message: message,
              level: switch (severity) {
                'ERROR' => DiagnosticLevel.error,
                'WARNING' => DiagnosticLevel.warning,
                _ => DiagnosticLevel.info,
              },
              correction: switch (error) {
                {'correction': final String correction} => correction,
                _ => null,
              },
            ),
          );
        } else {
          throw CodeAnalysisException(
            'it sent a diagnostic for $relative in a form Appstein does not '
            'know',
          );
        }
      }
    }
    found.sort((a, b) {
      final byFile = a.file.compareTo(b.file);
      if (byFile != 0) return byFile;
      final byLine = a.line.compareTo(b.line);
      return byLine != 0 ? byLine : a.code.compareTo(b.code);
    });
    return CodeReading(
      diagnostics: found,
      pluginFailures: List.unmodifiable(_pluginFailures),
    );
  }

  Future<void> _request(String method, Map<String, Object?> params) {
    if (_failure case final failure?) throw failure;
    final id = '${++_nextId}';
    final answered = _pending[id] = Completer<void>();
    _send({'id': id, 'method': method, 'params': params});
    return answered.future;
  }

  void _send(Map<String, Object?> message) {
    try {
      // Bytes, so a path keeps its non-ASCII characters on every system.
      _process?.stdin.add(utf8.encode('${jsonEncode(message)}\n'));
    } on Object {
      // The process has ended; `_onExit` reports it.
    }
  }

  void _onLine(String line) {
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (message is! Map<String, Object?>) return;
    final params = message['params'];
    switch (message['event']) {
      case null:
        final answered = _pending.remove('${message['id']}');
        if (answered == null) return;
        if (message['error'] case final Map<String, Object?> error) {
          answered.completeError(
            CodeAnalysisException(
              'it refused a request (${_plain('${error['message']}')})',
            ),
          );
        } else {
          answered.complete();
        }
      case 'server.status' when params is Map<String, Object?>:
        final analysis = params['analysis'];
        if (analysis is! Map<String, Object?>) return;
        if (analysis['isAnalyzing'] == true) {
          _analyzing = true;
        } else if (_analyzing) {
          _analyzing = false;
          _analyzed = true;
          for (final waiter in _waiting) {
            waiter.complete();
          }
          _waiting.clear();
        }
      case 'analysis.errors' when params is Map<String, Object?>:
        if ((params['file'], params['errors']) case (
          final String file,
          final List<Object?> errors,
        )) {
          _errors[file] = errors;
        }
      case 'analysis.flushResults' when params is Map<String, Object?>:
        if (params['files'] case final List<Object?> files) {
          files.forEach(_errors.remove);
        }
      case 'server.pluginError' when params is Map<String, Object?>:
        // The message ends with the server's own stack trace.
        final said = _plain('${params['message']}'.split('\n#0').first);
        if (!_pluginFailures.contains(said)) _pluginFailures.add(said);
      case 'server.error' when params is Map<String, Object?>:
        final said = _plain('${params['message']}');
        if (params['isFatal'] == true) {
          _fail(CodeAnalysisException('it reported a fatal error ($said)'));
        } else {
          _onSaid(said);
        }
    }
  }

  void _onSaid(String line) {
    if (processes == null && line.startsWith(analysisGuardSign)) {
      final ids = line
          .substring(analysisGuardSign.length)
          .split(' ')
          .map(int.tryParse)
          .toList();
      if (ids case [final guard?, final server?]) {
        processes = (guard: guard, server: server);
        return;
      }
    }
    // The guard starts this line on a line of its own, but a stream may
    // still deliver it after text that had no line end: what stands before
    // it is the server's last words.
    if (line.trimRight().endsWith(analysisGuardEnded)) {
      _guardEndedInOrder = true;
      line = line.trimRight();
      line = line.substring(0, line.length - analysisGuardEnded.length);
    }
    if (line.trim().isEmpty) return;
    _said.add(line.trim());
    if (_said.length > 5) _said.removeAt(0);
  }

  Future<void> _onExit(int code) async {
    await _endOrphan();
    if (_stopping) return;
    final said = _said.isEmpty ? '' : ': ${_plain(_said.join(' '))}';
    _fail(
      CodeAnalysisException(
        _guardEndedInOrder
            ? 'it ended by itself with exit code $code$said'
            : 'its guard ended without it, with exit code $code$said',
      ),
    );
  }

  /// After the guard has exited: ends the server when the guard did not
  /// end in order, which means the guard was killed and left its server
  /// running. The process ID is the one the guard named for the server it
  /// started. A guard that ended in order has a server that has ended, and
  /// then nothing is killed, since its ID may belong to another process by
  /// now.
  late final Future<void> _orphanEnded = () async {
    // The guard's last words may arrive after its exit.
    await _saidAll.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    if (_guardEndedInOrder) return;
    if (processes case (guard: _, :final server)) {
      Process.killPid(server, ProcessSignal.sigkill);
    }
  }();

  Future<void> _endOrphan() => _orphanEnded;

  /// [text] as part of a reason: one line, without a closing full stop.
  static String _plain(String text) => text
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(RegExp(r'\.$'), '');

  void _fail(CodeAnalysisException failure) {
    _failure ??= failure;
    for (final waiter in [..._pending.values, ..._waiting]) {
      if (!waiter.isCompleted) waiter.completeError(_failure!);
    }
    _pending.clear();
    _waiting.clear();
  }

  /// Ends the server and the guard: by asking the server to stop, then by
  /// closing the guard's input, then by killing both. A server whose guard
  /// was killed is ended by its process ID. Only processes this session
  /// started are ever ended.
  Future<void> stop() async {
    _stopping = true;
    _fail(const CodeAnalysisException('it was stopped'));
    try {
      await _opened;
    } on Object {
      // It failed to start, or was stopped while starting.
    }
    final process = _process;
    if (process == null) return;
    Future<bool> ended() => process.exitCode
        .then((_) => true)
        .timeout(const Duration(seconds: 5), onTimeout: () => false);

    _send({'id': 'stop', 'method': 'server.shutdown'});
    if (!await ended()) {
      process.stdin.close().ignore();
      if (!await ended()) {
        process.kill(ProcessSignal.sigkill);
        if (processes case (:final guard, :final server)) {
          Process.killPid(guard, ProcessSignal.sigkill);
          Process.killPid(server, ProcessSignal.sigkill);
        }
        await ended();
      }
    }
    process.stdin.close().ignore();
    await _endOrphan();
    for (final subscription in _listening) {
      await subscription.cancel();
    }
  }
}
