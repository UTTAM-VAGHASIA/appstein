import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../host/host_environment.dart';
import 'analysis_host.dart';
import 'analysis_server.dart';
import 'code_analysis.dart';
import 'process_identity.dart';

/// How long a client waits for an analysis host it started to write its
/// address and welcome it. A compiled host does so in well under a second;
/// one run from source (Appstein's own tests) compiles first, which takes
/// seconds. The analysis server is not started yet then: its own start
/// limit (`analysisReadyTimeout`) counts in the first reading.
const analysisHostStartLimit = Duration(seconds: 60);

/// How much longer than the question's own limit a client waits for the
/// host's answer before it takes the host for one that does not answer: the
/// time the answer takes to cross, and a host busy ending an earlier
/// question.
const analysisHostAnswerGrace = Duration(seconds: 30);

/// How long a client waits for its question's turn in the host's queue
/// before it takes the host for one that hangs. The wait is the questions
/// ahead's, each with its own limit (a reading up to 2 × 180 s while the
/// server starts), so this is far above any real queue; it is there so that
/// a host stuck before it begins a question can't hold a tool call or a hook
/// forever.
const analysisHostTurnLimit = Duration(minutes: 15);

/// The code analysis of the project at [projectRoot], answered by the
/// project's **analysis host** (decision record 0002): the `verify` tool of
/// `appstein mcp` uses it. It is one more implementation of [CodeAnalysis],
/// so the checks ask it as they ask an analysis server of their own.
///
/// - **Nothing happens until the body asks.** The first question reads the
///   address file ([analysisHostAddressFile] in [addressFolder]) and
///   connects to `127.0.0.1` at its port with its secret. When no host
///   answers there, it starts one, as a detached process ([hostCommand] with
///   [projectRoot] added as its last argument, and [environment] added to
///   this process's own), and waits up to [startLimit] for it to answer.
/// - **An address file it doesn't own is never trusted** (off Windows): the
///   folder must be the user's own with mode 700, and the file the user's
///   own with mode 600 ([untrustedAddress]); otherwise the question fails
///   with the reason.
/// - **One connection serves the whole body**, and is closed when the body
///   ends; the host is left running for the next client. The host takes the
///   server for each question alone, so between two questions of this body
///   another client's may be answered.
/// - **A host that can't be started, ends, or doesn't answer in time** is
///   Appstein failing, as an analysis server that can't answer is: the
///   question throws a [CodeAnalysisException] that says so. A host that
///   could not start says why in [analysisHostFailureFile], and the
///   exception carries that.
/// - [CodeAnalysis.applyFixesAndFormat]'s `leaveUnformatted` is asked here,
///   for each file of the last reading, before the question is sent: the
///   host can't ask it back.
///
/// [readyTimeout] and [answerGrace] set how long an answer is waited for
/// (a reading: twice [readyTimeout], since the server may start again
/// within one, plus [answerGrace]; any other question: its own limit plus
/// [answerGrace]); only tests change them. [os] is the system's, for tests.
CodeAnalysisScope analysisHostCodeAnalysis({
  required String projectRoot,
  required List<String> hostCommand,
  required String addressFolder,
  required String appsteinVersion,
  Map<String, String> environment = const {},
  Duration startLimit = analysisHostStartLimit,
  Duration readyTimeout = analysisReadyTimeout,
  Duration answerGrace = analysisHostAnswerGrace,
  HostOs? os,
}) => <T>(body) async {
  final client = _HostClient(
    projectRoot: projectRoot,
    hostCommand: hostCommand,
    addressFile: analysisHostAddressFile(addressFolder, projectRoot, os: os),
    appsteinVersion: appsteinVersion,
    environment: environment,
    startLimit: startLimit,
    readyTimeout: readyTimeout,
    answerGrace: answerGrace,
    os: os ?? HostOs.current,
  );
  try {
    return await body(client);
  } finally {
    client.close();
  }
};

/// One connection to the host, made by the first question.
final class _Connection {
  _Connection(this.socket)
    : lines = StreamIterator(
        utf8.decoder.bind(socket).transform(const LineSplitter()),
      ) {
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
  }

  final Socket socket;
  final StreamIterator<String> lines;

  /// The next line; null with `late` false when the host closed the
  /// connection, null with `late` true when none came within [limit] (with
  /// no [limit], it waits until one comes or the connection closes).
  Future<({String? line, bool late})> next(Duration? limit) async {
    try {
      final more = limit == null
          ? await lines.moveNext()
          : await lines.moveNext().timeout(limit);
      return (line: more ? lines.current : null, late: false);
    } on TimeoutException {
      return (line: null, late: true);
    } on Object {
      // The connection broke.
      return (line: null, late: false);
    }
  }

  void close() {
    socket.destroy();
    unawaited(lines.cancel());
  }
}

final class _HostClient implements CodeAnalysis {
  _HostClient({
    required this.projectRoot,
    required this.hostCommand,
    required this.addressFile,
    required this.appsteinVersion,
    required this.environment,
    required this.startLimit,
    required this.readyTimeout,
    required this.answerGrace,
    required this.os,
  });

  final String projectRoot;
  final List<String> hostCommand;
  final String addressFile;
  final String appsteinVersion;
  final Map<String, String> environment;
  final Duration startLimit;
  final Duration readyTimeout;
  final Duration answerGrace;
  final HostOs os;

  _Connection? _connection;
  var _closed = false;
  var _broken = false;
  var _nextId = 0;

  /// The files of the last reading, for `leaveUnformatted`.
  var _analyzedFiles = const <String>[];

  void close() {
    _closed = true;
    _connection?.close();
    _connection = null;
  }

  /// The connection, made by the first question.
  Future<_Connection> _connect() async {
    if (_closed) {
      throw const CodeAnalysisException(
        'it was asked after the run that used it had ended',
      );
    }
    if (_connection case final open?) return open;
    if (_broken) {
      // Another connection would be another client: the server may have
      // been replaced, and the last reading's offsets and files with it.
      throw const CodeAnalysisException(
        'the analysis host stopped answering during this run',
      );
    }
    final found = await _reach();
    if (found != null) return _connection = found;
    // A reason left by an earlier host is not this one's.
    final failure = File(analysisHostFailureFile(addressFile));
    try {
      await failure.delete();
    } on FileSystemException {
      // None was left.
    }
    final started = await _start();
    final watch = Stopwatch()..start();
    while (watch.elapsed < startLimit) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (await _reach() case final reached?) return _connection = reached;
      if (lookUpProcess(started) is ProcessGone) {
        // It may have written its address in its last moment.
        if (await _reach() case final reached?) return _connection = reached;
        String? why;
        try {
          why = (await failure.readAsString()).trim();
          await failure.delete();
        } on FileSystemException {
          // It left none: it ended before it could say why, or it could not
          // write there, as in a folder that is a link (it refuses to write
          // through one), which the look below names.
        }
        if (why == null || why.isEmpty) {
          if (await untrustedAddress(addressFile, os: os) case final bad?) {
            why = 'the analysis host could not start: $bad';
          }
        }
        throw CodeAnalysisException(
          why == null || why.isEmpty
              ? 'the analysis host Appstein started ended before it answered'
              : why,
        );
      }
    }
    throw CodeAnalysisException(
      'the analysis host Appstein started did not answer within '
      '${secondsText(startLimit)}',
    );
  }

  /// Starts a host, detached, and returns its process ID.
  Future<int> _start() async {
    try {
      final process = await Process.start(
        hostCommand.first,
        [...hostCommand.skip(1), projectRoot],
        environment: environment,
        // A folder the host holds open can't be deleted on Windows: not the
        // project's, nor the folder a caller happens to be in.
        workingDirectory: Directory.systemTemp.path,
        mode: ProcessStartMode.detached,
      );
      return process.pid;
    } on ProcessException catch (error) {
      throw CodeAnalysisException(
        'the analysis host could not be started (${error.message})',
      );
    }
  }

  /// A connection to the host the address file names, welcomed; null when
  /// there is no address file or nothing there welcomes this client.
  ///
  /// Throws a [CodeAnalysisException] when the address file or its folder
  /// may not be trusted ([untrustedAddress]).
  Future<_Connection?> _reach() async {
    if (await untrustedAddress(addressFile, os: os) case final why?) {
      throw CodeAnalysisException(
        'Appstein will not use the analysis host address file: $why',
      );
    }
    final address = readAnalysisHostAddress(addressFile);
    if (address == null) return null;
    final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        address.port,
        timeout: const Duration(seconds: 5),
      );
    } on SocketException {
      return null;
    }
    final connection = _Connection(socket);
    socket.writeln(
      jsonEncode(
        AnalysisHostHello(
          secret: address.secret,
          appsteinVersion: appsteinVersion,
        ).toJson(),
      ),
    );
    final (:line, late: _) = await connection.next(const Duration(seconds: 10));
    try {
      final json = line == null ? null : jsonDecode(line);
      if (json is Map<String, Object?>) {
        AnalysisHostWelcome.fromJson(json);
        return connection;
      }
    } on FormatException {
      // Not a welcome: not a host this client can use.
    }
    connection.close();
    return null;
  }

  /// Asks the host [question] and returns its answer's value; it waits at
  /// most [limit] for the answer.
  Future<Object> _ask(
    AnalysisHostQuestion Function(int id) question,
    Duration limit,
  ) async {
    final connection = await _connect();
    final asked = question(_nextId++);
    connection.socket.writeln(jsonEncode(asked.toJson()));
    // First the turn: the wait in the host's queue is the questions ahead's,
    // each with its own limit, so only [analysisHostTurnLimit], far above any
    // real queue, bounds it. The question's own limit starts when the server
    // begins on it.
    // A host that is ending answers at once with a failure, without a turn.
    var got = await connection.next(analysisHostTurnLimit);
    final waitedForTurn = got.late;
    if (_isTurn(got.line, asked.id)) got = await connection.next(limit);
    final (:line, :late) = got;
    if (line == null) {
      // The answers of this connection can no longer be told apart: a later
      // question of the body fails too, and the next body connects anew.
      _drop();
      throw CodeAnalysisException(switch ((late, waitedForTurn)) {
        (true, true) =>
          'the analysis host did not begin the question within '
              '${secondsText(analysisHostTurnLimit)}',
        (true, false) =>
          'the analysis host did not answer within ${secondsText(limit)}',
        _ =>
          'the analysis host ended, or closed the connection, before it '
              'answered',
      });
    }
    final AnalysisHostAnswer answer;
    try {
      answer = AnalysisHostAnswer.fromJson(
        jsonDecode(line) as Map<String, Object?>,
      );
    } on Object catch (error) {
      _drop();
      throw CodeAnalysisException(
        'the analysis host sent an answer that could not be read ($error)',
      );
    }
    if (answer.failure case final failure?) {
      throw CodeAnalysisException(failure, refusalCode: answer.refusalCode);
    }
    if (answer.timedOut) throw TimeoutException(null, asked.within);
    return answer.value!;
  }

  /// Whether [line] is the turn of the question [id].
  static bool _isTurn(String? line, int id) {
    if (line == null) return false;
    try {
      final json = jsonDecode(line);
      return json is Map<String, Object?> &&
          AnalysisHostTurn.isTurn(json) &&
          json['id'] == id;
    } on FormatException {
      return false;
    }
  }

  /// Closes the connection for good, after it failed.
  void _drop() {
    _broken = true;
    _connection?.close();
    _connection = null;
  }

  @override
  Future<CodeReading> read() async {
    final value = await _ask(
      (id) => AnalysisHostQuestion(id: id, kind: AnalysisHostQuestionKind.read),
      // The host's server may start several times within one reading (a
      // change to the analysis options while it starts).
      readyTimeout * 2 + answerGrace,
    );
    final reading = CodeReading.fromJson(value as Map<String, Object?>);
    _analyzedFiles = reading.analyzedFiles;
    return reading;
  }

  @override
  Future<bool> canDartFix(
    CodeDiagnostic diagnostic, {
    required Duration within,
  }) async =>
      await _ask(
            (id) => AnalysisHostQuestion(
              id: id,
              kind: AnalysisHostQuestionKind.canDartFix,
              within: within,
              diagnostic: diagnostic,
            ),
            within + answerGrace,
          )
          as bool;

  @override
  Future<FormatAnswers> formatChanges(
    List<String> files, {
    required Duration within,
  }) async => FormatAnswers.fromJson(
    await _ask(
          (id) => AnalysisHostQuestion(
            id: id,
            kind: AnalysisHostQuestionKind.formatChanges,
            within: within,
            files: files,
          ),
          within + questionGrace + answerGrace,
        )
        as Map<String, Object?>,
  );

  @override
  Future<PendingFixes> pendingFixes({required Duration within}) async =>
      PendingFixes.fromJson(
        await _ask(
              (id) => AnalysisHostQuestion(
                id: id,
                kind: AnalysisHostQuestionKind.pendingFixes,
                within: within,
              ),
              fixQuestionLimit(within) + answerGrace,
            )
            as Map<String, Object?>,
      );

  @override
  Future<AppliedChanges> applyFixesAndFormat({
    required Future<bool> Function(String file) leaveUnformatted,
    required Duration within,
  }) async {
    final leave = [
      for (final file in _analyzedFiles)
        if (await leaveUnformatted(file)) file,
    ];
    return AppliedChanges.fromJson(
      await _ask(
            (id) => AnalysisHostQuestion(
              id: id,
              kind: AnalysisHostQuestionKind.applyFixesAndFormat,
              within: within,
              leaveUnformatted: leave,
            ),
            fixQuestionLimit(within) + answerGrace,
          )
          as Map<String, Object?>,
    );
  }
}
