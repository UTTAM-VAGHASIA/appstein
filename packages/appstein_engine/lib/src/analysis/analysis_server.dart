import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/host_environment.dart';
import '../knowledge/input_hash.dart';
import '../sdk/sdk_detector.dart';
import 'analysis_guard.dart';
import 'code_analysis.dart';
import 'disk_look.dart';
import 'process_identity.dart';

/// How long an analysis server may take until its analysis is done, before
/// the run fails (slice 1d.2). The slowest start measured was 71 s.
const analysisReadyTimeout = Duration(seconds: 180);

/// The ID the analysis server gives a data-driven fix (a migration a
/// package's `fix_data.yaml` describes), the kind `dart fix` applies to the
/// use of a deprecated API. Measured in ticket 02 of slice 1d.2.
const dataDrivenFixId = 'dart.fix.dataDriven';

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
/// The arguments are [AnalysisServer.new]'s, and [onLeft]: called after the
/// server was stopped, with a line for each process the stop could not end
/// because it could not be shown to be the server's own
/// ([AnalysisServer.leftProcesses]). A terminal run has no later run to
/// tell it in, so it prints them.
CodeAnalysisScope ownAnalysisServer({
  required String projectRoot,
  required List<String> guardCommand,
  required String Function() dartExecutable,
  Duration readyTimeout = analysisReadyTimeout,
  ProcessLookup processLookup = lookUpProcess,
  void Function(List<String> notices)? onLeft,
}) => <T>(body) async {
  final server = AnalysisServer(
    projectRoot: projectRoot,
    guardCommand: guardCommand,
    dartExecutable: dartExecutable,
    readyTimeout: readyTimeout,
    processLookup: processLookup,
  );
  try {
    return await body(server);
  } finally {
    await server.close();
    // What the stop could not end and could not show to be its own. The
    // body's result was made before the stop, so it can't hold this.
    final left = server.leftProcesses();
    if (left.isNotEmpty) onLeft?.call(left);
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
/// - **It may be kept between questions** (`KeptAnalysisServer`). Every
///   question then makes the server take in what changed on disk since the
///   last one, before it reads ([read]).
///
/// A server that can't be started, reports a fatal error, ends by itself,
/// loses its guard, or isn't done within [readyTimeout] makes the question
/// throw a [CodeAnalysisException]. Its processes are ended before the
/// exception is thrown, and the next question starts a new server. One
/// case is not an error: a server that answered an earlier question and is
/// found dead by this one is replaced, and this question is answered by the
/// new server.
final class AnalysisServer implements StoppableCodeAnalysis {
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
    this.processLookup = lookUpProcess,
    this.afterLook,
  }) : projectRoot = p.normalize(p.absolute(projectRoot));

  /// **Test-only**, like [processLookup]: called in each reading after the
  /// look at the disk and the reading of the changed files, before the
  /// server is told of them, so a test can change a file at that moment.
  /// Production code leaves it null; `ownAnalysisServer` and the CLI never
  /// pass it.
  final Future<void> Function()? afterLook;

  /// Asks the system which process runs under an ID: how a process is
  /// shown to be one this object started before it is ended by its ID.
  /// Only tests replace it.
  final ProcessLookup processLookup;

  /// Processes that were to be ended by their ID and may still be there, by
  /// ID: `seen` is the process that had the ID then (null when it couldn't
  /// be told who it was), and `shown` says whether it was shown to be one
  /// this object started (it was then killed) or not (it was left alone).
  /// One ID is one entry, however often a stop met it.
  final _left = <int, ({ProcessIdentity? seen, bool shown})>{};

  /// Notes the process with the ID [id] as left; an ID noted already keeps
  /// its first note.
  void _leave(int id, ProcessIdentity? seen, {required bool shown}) =>
      _left.putIfAbsent(id, () => (seen: seen, shown: shown));

  /// Looks again at each process an earlier stop may have left, and
  /// returns one line for each that is still there and could not be ended:
  /// its ID, that Appstein could not confirm it is its own analysis server
  /// and so did not end it, and the command to end it by hand.
  ///
  /// - A process that is gone, or whose ID another process has now, is
  ///   forgotten.
  /// - One that was shown to be this object's own and is still there is
  ///   killed again.
  /// - One that can't be told about at all is reported, never dropped.
  ///
  /// Every reading does this first and carries the lines
  /// (`CodeReading.notices`); the owner of a server that is closed for
  /// good asks once more afterwards.
  List<String> leftProcesses() {
    final lines = <String>[];
    for (final id in [..._left.keys]) {
      final left = _left[id]!;
      switch (processLookup(id)) {
        case ProcessGone():
          _left.remove(id);
        case ProcessRunning(identity: final now)
            when left.seen != null && now != left.seen:
          // Another process has the ID: the one that was left has ended.
          _left.remove(id);
        case ProcessRunning(identity: final now) when left.shown:
          Process.killPid(now.id, ProcessSignal.sigkill);
        case ProcessRunning(identity: final now):
          lines.add(_leftLine(id, now.image, 'confirm that it is its own'));
        case ProcessUnknown():
          lines.add(
            _leftLine(id, left.seen?.image, 'tell what the process is'),
          );
      }
    }
    return lines;
  }

  static String _leftLine(int id, String? image, String couldNot) =>
      'Process $id${image == null ? '' : ' ($image)'} may be an analysis '
      'server that Appstein started and could not stop. Appstein could not '
      '$couldNot, so it did not end it. To end it by hand: '
      '`${endByHandCommand(id, image: image)}`';

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
  /// is running. Questions asked at the same time share one server, and are
  /// answered one after the other.
  ///
  /// **The reading is never older than the files on disk** as they were
  /// when it was asked for. A running server learns of a changed file from
  /// its own file watcher, some time later, so a question does not rely on
  /// that. Before each reading it
  /// 1. looks at the project's files itself and compares them with its last
  ///    look: every Dart file's time and size, and the text of the files
  ///    that set how the project is analyzed (`analysis_options.yaml`,
  ///    `pubspec.yaml` and `.dart_tool/package_config.json`). Folders whose
  ///    name starts with a dot are left out, as the server leaves them out;
  /// 2. tells the server each Dart file that changed, appeared or is gone
  ///    (`analysis.updateContent`, which makes it read the file again at
  ///    once), and asks it for one of those files' errors: the answer comes
  ///    only after the server has taken the changes in and started on them;
  /// 3. waits until the server says its analysis is done.
  ///
  /// With no change it still sends one request and waits for the answer, so
  /// **a reading is never taken from a server that has died**: a dead
  /// server answers nothing. A server that answered an earlier question and
  /// is found dead here is replaced by a new one, which answers this
  /// question.
  ///
  /// **When one of the files that set how the project is analyzed changed,
  /// the server is started again** and the new one answers. The server
  /// takes such a change in by itself, but later, and nothing it sends says
  /// when it has. A new server has read the files as they are, and it tells
  /// a plugin that still can't be loaded again, so `pluginFailures` holds a
  /// failure only while it holds.
  @override
  Future<CodeReading> read() async {
    if (_closed) {
      throw StateError(
        'The analysis server of $projectRoot was asked after its owner '
        'closed it.',
      );
    }
    var replacedDead = false;
    for (var starts = 0; ; starts++) {
      if (_closed) throw const CodeAnalysisException('it was stopped');
      final session = _session ??= _Session(this);
      // A server that answered before may have died since: that is found
      // here, and is no reason to fail this question.
      final kept = session.answered;
      var late = false;
      try {
        return await session.read().timeout(
          readyTimeout,
          onTimeout: () {
            late = true;
            throw CodeAnalysisException(
              'its analysis was not done within ${readyTimeout.inSeconds} s',
            );
          },
        );
      } on _SettingsChanged {
        await _replace(session);
        if (starts >= _mostStarts) {
          throw const CodeAnalysisException(
            'the files that set how the project is analyzed kept changing '
            'while it started',
          );
        }
      } on CodeAnalysisException {
        // Another question on the same server already replaced it.
        final replaced = session.replaced;
        // Nothing is left running, and the next question starts again.
        if (identical(_session, session)) _session = null;
        await session.stop();
        if (replaced && starts < _mostStarts) continue;
        if (!kept || late || replacedDead || session.stoppedByOwner) rethrow;
        replacedDead = true;
      }
    }
  }

  /// Asks the running server, which answered the last [read], whether it
  /// offers a data-driven fix for [diagnostic] (`edit.getFixes` at the
  /// diagnostic's offset): a migration the package that deprecated the API
  /// describes in its `fix_data.yaml`. Nothing is changed, on disk or in the
  /// server.
  ///
  /// The answer is kept by the file's path, the hash of the text the server
  /// analyzed (the text a reading gave it), the offset and the code, for as
  /// long as the server runs: a use in an unchanged file is asked about
  /// once. Where that text isn't known the answer is not kept.
  ///
  /// Throws a [CodeAnalysisException] when no reading was taken from the
  /// running server (another caller replaced it, or it died: the offset
  /// belongs to that reading), and when the server fails meanwhile. A
  /// caller falls back to saying nothing.
  @override
  Future<bool> canDartFix(
    CodeDiagnostic diagnostic, {
    required Duration within,
  }) async {
    final session = _session;
    if (session == null || !session.answered) {
      throw const CodeAnalysisException(
        'it was asked about a fix with no reading taken from it',
      );
    }
    // The time is the server's own: an earlier question of the same run
    // that it is still busy with counts, nothing of the caller's does.
    return session.canDartFix(diagnostic).timeout(within);
  }

  /// Asks the running server, which answered the last [read], which of
  /// [files] its formatter would change (`edit.format`, which the server
  /// answers with the edits `dart format` of its SDK would make, the project's
  /// `formatter:` settings in `analysis_options.yaml` included). Nothing is
  /// changed, on disk or in the server.
  ///
  /// - **The questions are sent together**, at most 32 at a time (the most
  ///   files the look keeps open): a question costs the server about 15 ms
  ///   when it is the only one in flight, and next to nothing when many are,
  ///   so 100 files cost 30 to 125 ms, not 1.5 s.
  /// - **At most [within] is spent**, counted from when the server is asked
  ///   (and, past that, [questionGrace] for a server stuck on an earlier
  ///   question). A question still unanswered then is given up and its file
  ///   is in neither map of the result; its answer, when it comes, is kept
  ///   for the next question.
  /// - **The answer is kept** by the file's path and the hash of the text
  ///   the server analyzed (the text a reading gave it), for as long as the
  ///   server runs, so a file that did not change is asked about once. A new
  ///   server (a change to a file that sets how the project is analyzed, such
  ///   as `analysis_options.yaml`, which can change the format) starts with
  ///   none. Where that text isn't known the answer is not kept.
  /// - **The server answers from its own copy of the file**, which its file
  ///   watcher may have updated after the reading. So when an answer arrives,
  ///   the file is read again; if it is no longer the text of the reading
  ///   (changed, deleted, locked), the answer is neither kept nor used: the
  ///   file is in `refused`, as one not checked. The re-read compares the
  ///   text, so it also finds an edit that keeps the file's size and puts its
  ///   time back, which the reading's look (sizes and times) never sees; such
  ///   a file is "not checked" for that question, and the next reading tells
  ///   the server about it again, so the question after it is answered. The
  ///   same re-read comes before a syntax-error answer is used or kept.
  /// - **A file with a syntax error** is answered false: the server refuses
  ///   to format it (`FORMAT_WITH_ERRORS`). Any other refusal is that file's
  ///   alone: it is in `refused` with the server's words, and the other
  ///   answers are kept.
  ///
  /// Throws a [CodeAnalysisException] when no reading was taken from the
  /// running server (another caller replaced it, or it died: the kept answers
  /// belong to that reading), and when the server fails meanwhile.
  @override
  Future<FormatAnswers> formatChanges(
    List<String> files, {
    required Duration within,
  }) async {
    final session = _session;
    if (session == null || !session.answered) {
      throw const CodeAnalysisException(
        'it was asked about formatting with no reading taken from it',
      );
    }
    return session
        .formatChanges(files, within)
        .timeout(
          within + questionGrace,
          onTimeout: () => const FormatAnswers(),
        );
  }

  /// How often one question starts a server again before it gives up.
  static const _mostStarts = 5;

  /// Ends [session] because a new server must answer in its place.
  Future<void> _replace(_Session session) async {
    session.replaced = true;
    if (identical(_session, session)) _session = null;
    await session.stop();
  }

  /// Stops the server and its guard, and returns when both have ended. It
  /// does nothing when no server is running, and never throws. A question
  /// asked afterwards starts a new server; a question that is waiting fails
  /// with a [CodeAnalysisException].
  @override
  Future<void> stop() async {
    final session = _session;
    _session = null;
    session?.stoppedByOwner = true;
    await session?.stop();
  }

  /// Stops the server as [stop] does, for good: a question asked afterwards
  /// throws a [StateError] instead of starting a server nobody would stop.
  @override
  Future<void> close() {
    _closed = true;
    return stop();
  }
}

/// A file that set how the project is analyzed has changed: the session
/// that found it can't answer, and a new one must.
final class _SettingsChanged implements Exception {
  const _SettingsChanged();
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

  /// The files as the server knows them: the look taken before the server
  /// was started, then the look of each reading.
  late DiskLook _seen;

  /// The folders whose packages the look leaves out ([unchangingFolders]).
  late final List<String> _unchanging;

  /// The Dart files of the project the server read for the reading under
  /// way, which are read whole before and after it.
  var _told = const <String>[];

  /// The hash of the text the server analyzes for each Dart file of the
  /// project, by absolute path, where it is known: read the same whole
  /// before and after the reading in which the server read it. What
  /// [canDartFix]'s kept answers are keyed by.
  final _textHashes = <String, String>{};

  void _noteText(String file, String? text) {
    if (text == null) {
      _textHashes.remove(file);
    } else {
      _textHashes[file] = sha256Hex(utf8.encode(text));
    }
  }

  /// Whether no reading has been taken from this session yet.
  var _firstReading = true;

  /// What [canDartFix] answered, by file, the hash of its text, offset and
  /// code: an unchanged file is never asked about again while this session
  /// runs. A new session (a settings change, which can change the fixes)
  /// starts empty.
  final _fixAnswers = <String, bool>{};

  /// The reading before the one that is asked for now: readings are taken
  /// one after the other.
  Future<void> _turn = Future.value();

  /// Whether it has answered a reading.
  var answered = false;

  /// Whether a new server took its place ([AnalysisServer.read]).
  var replaced = false;

  /// Whether its owner stopped it ([AnalysisServer.stop]).
  var stoppedByOwner = false;

  Process? _process;
  final _listening = <StreamSubscription<String>>[];
  ({int guard, int server})? processes;

  /// The requests the server hasn't answered, by ID.
  final _pending = <String, Completer<Object?>>{};
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
    // Before the server reads anything: what changes from here on is told.
    _unchanging = unchangingFolders(dart, Platform.environment);
    _seen = await DiskLook.of(_root, unchanging: _unchanging);
    if (_stopping) throw _failure!;
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

  /// What the server says about the project as its files are now: the
  /// diagnostics `dart analyze` would show for the files inside the
  /// project, and the plugins that failed. Readings asked for at the same
  /// time are taken one after the other.
  ///
  /// Throws a [_SettingsChanged] when this server can't answer for the
  /// files as they are and a new one must.
  Future<CodeReading> read() {
    final reading = _turn.then((_) => _read());
    _turn = reading.then<void>((_) {}, onError: (Object _) {});
    return reading;
  }

  /// Makes the server take in what changed on disk since the last look, and
  /// returns when it has answered a request sent after that look.
  Future<void> _takeIn() async {
    final now = await DiskLook.of(_root, unchanging: _unchanging);
    if (_failure case final failure?) throw failure;
    if (!now.sameSettingsAs(_seen)) throw const _SettingsChanged();
    // Besides what the look sees change: the files a formatting question
    // found different from the text of the last reading, which the look may
    // never see (a same-size edit whose time was put back). Without them such
    // a file would be named "not checked" by every run until the look saw it
    // change, and a partial run lets no file leave the unverified files.
    final changed = <String>{
      ...now.dartChangedSince(_seen),
      for (final path in _renew)
        if (now.dart.containsKey(path)) path,
    }.toList()..sort();
    _renew.clear();
    _seen = now;
    // The files of the project the server reads for this reading: those
    // told below, and at a session's first reading every file, which it
    // read when it started. Each is read whole here and again after the
    // reading (the look reads only a file's first byte, which a lock
    // further in doesn't stop): a lock taken in between that is still held
    // is found by the second read. The server is not given the text as an
    // overlay: an overlay keeps its own file watcher off that file for good,
    // and the watcher is what sees a change the look can't (a same-size
    // edit whose time is put back), shown by the engine's tests.
    _told = [
      for (final file in _firstReading ? now.dart.keys : changed)
        if (p.isWithin(_root, file)) file,
    ];
    _firstReading = false;
    await now.readWhole(_told);
    await _owner.afterLook?.call();
    if (changed.isEmpty) {
      await _request('server.getVersion');
      return;
    }
    // Taking an overlay away, also where there is none, makes the server
    // read the file from disk again, add it when it is new, and drop it
    // when it is gone. It works for a file outside the project folder that
    // the project imports, which the server never notices by itself.
    await _request('analysis.updateContent', {
      'files': {
        for (final file in changed) file: {'type': 'remove'},
      },
    });
    // The answer to this comes after the server has taken those changes in
    // and has said that it is analyzing; a request that needs no analysis
    // is answered in order too, but only as the server happens to work. It
    // is asked about a file of the project: one of the changed ones, or
    // any when the changes are all outside or all deletions.
    final probe = now.dartFileInProject(changed);
    if (probe == null) {
      await _request('server.getVersion');
      return;
    }
    try {
      await _request('analysis.getErrors', {'file': probe});
    } on CodeAnalysisException {
      // Refused: a file the project's analysis options leave out. The
      // refusal is an answer all the same.
      if (_failure case final failure?) throw failure;
    }
  }

  Future<CodeReading> _read() async {
    await _opened;
    // A guard that has exited is being looked at (did it end in order?):
    // what its server sent is not answered from in the meantime.
    if (_exiting case final exiting?) await exiting;
    if (_failure case final failure?) throw failure;
    await _takeIn();
    if (_failure case final failure?) throw failure;
    if (!_analyzed || _analyzing) {
      final done = Completer<void>();
      _waiting.add(done);
      await done.future;
    }
    // A file locked after the look, before the server read it, was read as
    // empty: still unreadable now, it is reported so. The text the server
    // analyzed is known when both reads gave the same text (the server read
    // the file between them); otherwise it is not, and no fix answer is
    // kept for that file.
    final before = {for (final file in _told) file: _seen.texts[file]};
    await _seen.readWhole(_told);
    for (final file in _told) {
      final text = _seen.texts[file];
      _noteText(file, text == before[file] ? text : null);
    }
    answered = true;
    final found = <CodeDiagnostic>[];
    // The server sends `analysis.errors` for every file it analyzes, with
    // an empty list for a file without a diagnostic.
    final analyzed = <String>[];
    for (final MapEntry(key: file, value: errors) in _errors.entries) {
      if (!p.isWithin(_root, file)) continue;
      final relative = p.split(p.relative(file, from: _root)).join('/');
      analyzed.add(relative);
      for (final error in errors) {
        if (error case {
          'severity': final String severity,
          'type': final String type,
          'location': {'startLine': final int line, 'offset': final int offset},
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
              offset: offset,
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
    // The files this reading's look could not read, among those the server
    // analyzed: it lists such a file with no diagnostic. One the project's
    // options exclude is not the analysis's, and is left out.
    final covered = analyzed.toSet();
    final unreadable = <String, String>{
      for (final MapEntry(key: file, value: reason) in _seen.unreadable.entries)
        if (p.isWithin(_root, file) &&
            covered.contains(p.split(p.relative(file, from: _root)).join('/')))
          p.split(p.relative(file, from: _root)).join('/'): reason,
    };
    return CodeReading(
      diagnostics: found,
      pluginFailures: List.unmodifiable(_pluginFailures),
      notices: _owner.leftProcesses(),
      analyzedFiles: List.unmodifiable(analyzed..sort()),
      unreadableFiles: Map.unmodifiable(
        Map.fromEntries(
          unreadable.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
        ),
      ),
    );
  }

  /// Whether the server offers a data-driven fix for [diagnostic], which
  /// `dart fix` applies by itself. Asked after a reading, in turn with the
  /// readings, of the files as that reading saw them.
  Future<bool> canDartFix(CodeDiagnostic diagnostic) {
    final asked = _turn.then((_) => _canDartFix(diagnostic));
    _turn = asked.then<void>((_) {}, onError: (Object _) {});
    return asked;
  }

  Future<bool> _canDartFix(CodeDiagnostic diagnostic) async {
    final offset = diagnostic.offset;
    if (offset == null) return false;
    await _opened;
    if (_failure case final failure?) throw failure;
    final file = p.joinAll([_root, ...diagnostic.file.split('/')]);
    // The text the reading was taken from, not the file as it is now: an
    // edit since then must not file an answer under the wrong text.
    final text = _textHashes[file];
    final key = '${diagnostic.file}|$text|$offset|${diagnostic.code}';
    if (text != null) {
      if (_fixAnswers[key] case final known?) return known;
    }
    final found = await _askDartFix(file, offset, diagnostic.code);
    // Kept only when the text the server analyzed is known.
    if (text != null) _fixAnswers[key] = found;
    return found;
  }

  Future<bool> _askDartFix(String file, int offset, String asked) async {
    final Object? answer;
    try {
      answer = await _request('edit.getFixes', {
        'file': file,
        'offset': offset,
      });
    } on CodeAnalysisException {
      // A refusal (a file the options leave out) offers no fix; a server
      // that failed fails the question.
      if (_failure case final failure?) throw failure;
      return false;
    }
    if (answer case {'fixes': final List<Object?> entries}) {
      for (final entry in entries) {
        if (entry case {
          'error': {
            'code': final String code,
            'location': {'offset': final int at},
          },
          'fixes': final List<Object?> fixes,
        } when code == asked && at == offset) {
          for (final fix in fixes) {
            if (fix case {'id': dataDrivenFixId}) return true;
          }
        }
      }
    }
    return false;
  }

  /// What [formatChanges] answered, by file and the hash of its text: an
  /// unchanged file is never asked about again while this session runs.
  final _formatAnswers = <String, bool>{};

  /// How many formatting questions are in flight at once: each re-reads its
  /// file when it is answered, and the look keeps at most this many files
  /// open at once ([openFilesAtOnce]).
  static const _formatInFlight = openFilesAtOnce;

  /// Which of [files] the server's formatter would change, within [within].
  /// Asked after a reading, in turn with the readings, of the files as that
  /// reading saw them.
  Future<FormatAnswers> formatChanges(List<String> files, Duration within) {
    final asked = _turn.then((_) => _formatChanges(files, within));
    _turn = asked.then<void>((_) {}, onError: (Object _) {});
    return asked;
  }

  Future<FormatAnswers> _formatChanges(
    List<String> files,
    Duration within,
  ) async {
    await _opened;
    if (_failure case final failure?) throw failure;
    final spent = Stopwatch()..start();
    final answers = <String, bool>{};
    final refused = <String, String>{};
    final toAsk = <({String file, String path, String? text})>[];
    for (final file in files) {
      final path = p.joinAll([_root, ...file.split('/')]);
      // The text the reading was taken from, not the file as it is now: an
      // edit since then must not file an answer under the wrong text.
      final text = _textHashes[path];
      final known = text == null ? null : _formatAnswers['$file|$text'];
      if (known != null) {
        answers[file] = known;
      } else {
        toAsk.add((file: file, path: path, text: text));
      }
    }
    // A question still unanswered when the time is up is dropped from the
    // result, but its answer is still kept when it comes.
    var open = true;
    try {
      for (var from = 0; from < toAsk.length; from += _formatInFlight) {
        final left = within - spent.elapsed;
        if (left <= Duration.zero) break;
        final window = toAsk.skip(from).take(_formatInFlight);
        final asking = [
          for (final question in window)
            _askFormat(question.path, question.text).then((answer) {
              switch (answer) {
                case (changed: final changed?, why: _):
                  if (question.text case final text?) {
                    _formatAnswers['${question.file}|$text'] = changed;
                  }
                  if (open) answers[question.file] = changed;
                case (changed: _, why: final why?):
                  if (open) refused[question.file] = why;
                case _:
                  break;
              }
            }),
        ];
        try {
          await Future.wait(asking).timeout(left);
        } on TimeoutException {
          break;
        }
      }
    } finally {
      open = false;
    }
    return FormatAnswers(
      changed: Map.unmodifiable(answers),
      refused: Map.unmodifiable(refused),
    );
  }

  /// Whether the server's formatter would change the file at [path]
  /// (`changed`), or why that can't be said for this file (`why`): the
  /// server refused the question, or the file is not [text] (the hash of the
  /// text the reading saw) by the time it was answered. A server that failed
  /// fails the question.
  Future<({bool? changed, String? why})> _askFormat(
    String path,
    String? text,
  ) async {
    Object? answer;
    var syntaxError = false;
    try {
      answer = await _request('edit.format', {
        'file': path,
        'selectionOffset': 0,
        'selectionLength': 0,
      });
    } on CodeAnalysisException catch (error) {
      if (_failure case final failure?) throw failure;
      // Any other refusal is about this file; the others are still asked.
      if (error.refusalCode != 'FORMAT_WITH_ERRORS') {
        return (changed: null, why: error.reason);
      }
      // A file with a syntax error has no format to ask for: "would not
      // change", once the check below has shown it is the reading's text.
      syntaxError = true;
      answer = null;
    }
    // The server answered from its own copy of the file, which its watcher
    // may have updated since the reading: the answer is about the reading's
    // text only if the file still is that text. That holds for a refusal for
    // a syntax error too: it is no more true of the reading's text than any
    // other answer, and a later reading of that text must not be served it.
    if (text != null && await _textHashOnDisk(path) != text) {
      // Not what the look saw, and the look may never see it (a same-size
      // edit whose time was put back): the next reading tells the server
      // about the file again, and takes its text anew.
      _renew.add(path);
      return (
        changed: null,
        why:
            'the file changed, or could not be read again, while its '
            'formatting was being checked',
      );
    }
    if (syntaxError) return (changed: false, why: null);
    if (answer case {'edits': final List<Object?> edits}) {
      return (changed: edits.isNotEmpty, why: null);
    }
    return (
      changed: null,
      why: 'it answered a formatting question in a form Appstein does not know',
    );
  }

  /// The files [formatChanges] found different from the text of the reading,
  /// by absolute path: the next reading tells the server about them again
  /// (`_takeIn`), whether or not the look sees them change.
  final _renew = <String>{};

  /// The hash of the text of the file at [path] as the look reads it (UTF-8,
  /// malformed bytes replaced); null when it can't be read.
  static Future<String?> _textHashOnDisk(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      return sha256Hex(
        utf8.encode(const Utf8Decoder(allowMalformed: true).convert(bytes)),
      );
    } on FileSystemException {
      return null;
    }
  }

  /// Sends a request, and completes with the server's `result` when it
  /// answers.
  Future<Object?> _request(String method, [Map<String, Object?>? params]) {
    if (_failure case final failure?) throw failure;
    final id = '${++_nextId}';
    final answered = _pending[id] = Completer<Object?>();
    _send({'id': id, 'method': method, 'params': ?params});
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
              refusalCode: switch (error['code']) {
                final String code => code,
                _ => null,
              },
            ),
          );
        } else {
          answered.complete(message['result']);
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
        // At once, while both run: what a later kill by ID is checked
        // against.
        _guardIdentity = _identityOf(guard);
        _serverIdentity = _identityOf(server);
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

  /// The guard and the server as they were when the guard named them; null
  /// when that could not be told.
  ProcessIdentity? _guardIdentity;
  ProcessIdentity? _serverIdentity;

  ProcessIdentity? _identityOf(int id) => switch (_owner.processLookup(id)) {
    ProcessRunning(:final identity) => identity,
    _ => null,
  };

  /// Ends the process with the ID [id] that this session started, when it
  /// can be shown to be that process still: the process that has the ID now
  /// is the one [recorded] when the guard named it, by its start and its
  /// program. An ID alone is no proof: the system gives an ended process's
  /// ID to a new one.
  ///
  /// - Nothing has the ID: it has ended, nothing to do.
  /// - Another process has it: this session's has ended, nothing to do.
  /// - It was never recorded and something has the ID, or who has the ID
  ///   can't be told: nothing is ended, and the owner notes it as left
  ///   ([AnalysisServer.leftProcesses]), once.
  void _endById(int id, ProcessIdentity? recorded) {
    switch (_owner.processLookup(id)) {
      case ProcessGone():
        return;
      case ProcessUnknown():
        _owner._leave(id, recorded, shown: false);
      case ProcessRunning(identity: final now) when recorded == null:
        _owner._leave(id, now, shown: false);
      case ProcessRunning(identity: final now) when now == recorded:
        Process.killPid(id, ProcessSignal.sigkill);
        // Looked at again by the next question: a kill may not take.
        _owner._leave(id, now, shown: true);
      case ProcessRunning():
        // Another process has the ID now.
        return;
    }
  }

  /// After the guard has exited: ends the server when the guard did not
  /// end in order, which means the guard was killed and left its server
  /// running. The process ID is the one the guard named for the server it
  /// started, and the process is ended only when it is shown to be that
  /// server still ([_endById]). A guard that ended in order has a server
  /// that has ended, and then nothing is looked at.
  late final Future<void> _orphanEnded = () async {
    // The guard's last words may arrive after its exit.
    await _saidAll.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    if (_guardEndedInOrder) return;
    if (processes case (guard: _, :final server)) {
      _endById(server, _serverIdentity);
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

  /// Ends the server and the guard. It closes the guard's input, which
  /// makes the guard kill the server at once and end. It does not ask the
  /// server to stop first: in 60 of 60 stops measured in review, the server
  /// had not answered `server.shutdown` within 250 ms, and it took about 4 s
  /// to end by itself, so the request only made every stop slower. A kill
  /// is no harder on the server's cache on disk than the end of every `dart
  /// analyze` (which asks, then kills) or than Appstein being killed. When
  /// both are still there 5 s later, they are killed: the process this
  /// session holds directly, and the guard and the server by their IDs when
  /// each is shown to be the one it started ([_endById]).
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

    process.stdin.close().ignore();
    {
      if (!await ended()) {
        process.kill(ProcessSignal.sigkill);
        if (processes case (:final guard, :final server)) {
          _endById(guard, _guardIdentity);
          _endById(server, _serverIdentity);
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
