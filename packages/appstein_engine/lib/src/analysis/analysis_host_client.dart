import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:pub_semver/pub_semver.dart';

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

/// How long a client waits for the host to take its connection.
const _connectLimit = Duration(seconds: 5);

/// The code analysis of the project at [projectRoot], answered by the
/// project's **analysis host** (decision record 0002): the `verify` tool of
/// `appstein mcp`, the hooks (with [startHost] true) and a terminal `appstein
/// verify` (with it false) use it. It is one more implementation of [CodeAnalysis],
/// so the checks ask it as they ask an analysis server of their own.
///
/// - **Nothing happens until the body asks** (or calls `warmUp`, as a hook
///   does at its start). The first question reads the
///   address file ([analysisHostAddressFile] in [addressFolder]) and
///   connects to `127.0.0.1` at its port with its secret. When no host
///   answers there, it starts one, as a detached process ([hostCommand] with
///   [projectRoot] added as its last argument, and [environment] added to
///   this process's own), and waits up to [startLimit] for it to answer.
/// - **Every client of a project shares one host.** Clients that start a
///   host at the same moment end with one: a host writes its address only
///   when no other's is there (`runAnalysisHost`), and the client whose host
///   lost connects to the winner's.
/// - **An address whose host has ended** (its port refuses the connection,
///   or its process is gone) is deleted, unless another client has replaced
///   it meanwhile ([removeAnalysisHostAddress]), and a host is started. A
///   connection that is not taken in 5 s while the host's process runs is
///   no proof of that: the question fails, and the address is left.
/// - **The versions are compared as semantic versions** (the welcome's with
///   [appsteinVersion]):
///   - a host of an older Appstein is asked to stop (`AnalysisHostStop`);
///     it gives up its address at once, and a host of [appsteinVersion] is
///     started and answers;
///   - a host of a newer Appstein is left alone: this run asks an analysis
///     server of its own ([ownServer], stopped when the body ends), as a
///     terminal run without a host does, and its reading's notices say that
///     the session runs an older Appstein and should be restarted;
///   - a version that can't be read as one counts as newer than this
///     client's, so nothing is stopped.
/// - **A host that was asked to stop by another client** answers a question
///   that came after the stop with an `AnalysisHostEnding`. The question is
///   then asked again of the host found through the address file, when that
///   is safe: it is a reading, or nothing was answered yet in this body.
///   Otherwise it fails, as a host that ended does.
/// - **An address file it doesn't own is never trusted** (off Windows): the
///   folder must be the user's own with mode 700, and the file the user's
///   own with mode 600 ([untrustedAddress]); otherwise the question fails
///   with the reason. (A client that starts no host uses a server of its own
///   instead, below.)
/// - **One connection serves the whole body**, and is closed when the body
///   ends; the host is left running for the next client. The host takes the
///   server for each question alone, so between two questions of this body
///   another client's may be answered.
/// - **A question that gets an `AnalysisHostEnding`, or whose connection
///   closes before the host's turn,** is asked again of the host found
///   through the address file, at most 3 times in all. It is asked again
///   only when it is a reading or nothing was answered yet in this body;
///   otherwise it fails.
/// - **A host that can't be started, ends after it took a question, or
///   doesn't answer in time** is
///   Appstein failing, as an analysis server that can't answer is: the
///   question throws a [CodeAnalysisException] that says so. A host that
///   could not start says why in [analysisHostFailureFile], and the
///   exception carries that.
/// - [CodeAnalysis.applyFixesAndFormat]'s `leaveUnformatted` is asked here,
///   for each file of the last reading, before the question is sent: the
///   host can't ask it back.
///
/// **With [startHost] false** (a terminal `appstein verify`), the client
/// only uses a host that is already there, and never starts one, stops one,
/// or deletes an address. [hostCommand] is never run. Until a host has
/// answered a question, a host that can't be used counts as no host:
/// - a host of this [appsteinVersion] that welcomes the client is asked, and
///   no server of this run's own is started;
/// - otherwise the run asks an analysis server of its own ([ownServer],
///   stopped when the body ends), as in 1d.2, and the address file is left as
///   it was, dead or not;
/// - a host of another version, older or newer, a host that refused the
///   connection or has ended, and no address file are quiet: no notice;
/// - an address file that may not be trusted, a live host that won't take the
///   connection within 5 s, and a live host that never welcomes the client
///   each add a notice that says why ([unusableHostNotice]) to the readings,
///   so a planted file shows in a log;
/// - a question that meets an ending host, or a closed connection, is asked
///   again as for the other client, and finds the next host, if it has this
///   version, or else the run's own server, with a notice that the host ended
///   or was replaced.
///
/// **From the first answer of a host on,** the run never changes its
/// analysis server: a host that then fails (ended, replaced by another
/// version, or closed the connection) is Appstein failing, a
/// [CodeAnalysisException] with the reason, like its own server failing.
///
/// [readyTimeout] and [answerGrace] set how long an answer is waited for
/// (a reading: twice [readyTimeout], since the server may start again
/// within one, plus [answerGrace]; any other question: its own limit plus
/// [answerGrace]); [turnLimit] is how long the host's turn is waited for
/// ([analysisHostTurnLimit]); only tests change them. [connect] replaces
/// the connection to the host's port, and [os] the system's, for tests
/// only.
CodeAnalysisScope analysisHostCodeAnalysis({
  required String projectRoot,
  required List<String> hostCommand,
  required String addressFolder,
  required String appsteinVersion,
  required StoppableCodeAnalysis Function() ownServer,
  bool startHost = true,
  Map<String, String> environment = const {},
  Duration startLimit = analysisHostStartLimit,
  Duration readyTimeout = analysisReadyTimeout,
  Duration answerGrace = analysisHostAnswerGrace,
  Duration turnLimit = analysisHostTurnLimit,
  Future<Socket> Function(int port)? connect,
  HostOs? os,
}) => <T>(body) async {
  final client = _HostClient(
    projectRoot: projectRoot,
    hostCommand: hostCommand,
    addressFile: analysisHostAddressFile(addressFolder, projectRoot, os: os),
    appsteinVersion: appsteinVersion,
    ownServer: ownServer,
    startHost: startHost,
    environment: environment,
    startLimit: startLimit,
    readyTimeout: readyTimeout,
    answerGrace: answerGrace,
    turnLimit: turnLimit,
    connect: connect,
    os: os ?? HostOs.current,
  );
  try {
    return await body(client);
  } finally {
    await client.close();
  }
};

/// How the Appstein version [client] compares with [host]: negative when
/// the client is older, zero when they are the same, positive when it is
/// newer. Both are read as semantic versions; when either can't be, the
/// client counts as older, so it stops nothing.
int compareAppsteinVersions(String client, String host) {
  if (client == host) return 0;
  try {
    return Version.parse(client).compareTo(Version.parse(host));
  } on FormatException {
    return -1;
  }
}

/// The notice of a run whose session runs Appstein [client], older than the
/// project's analysis host, which runs [host].
String olderThanHostNotice(String client, String host) =>
    'This session runs Appstein $client, older than the analysis host of the '
    'project (Appstein $host), so this run started an analysis server of its '
    'own, which is slower. Restart the session for fast answers.';

/// The notice of a terminal run that did not use the project's analysis host
/// because it could not: [reason] says why, as "it did not welcome the
/// client". The run used an analysis server of its own instead.
String unusableHostNotice(String reason) =>
    'This run did not use the analysis host of the project ($reason), so it '
    'started an analysis server of its own, which is slower.';

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

/// What a client finds at the address file ([_HostClient._tryAddress]).
sealed class _AddressOutcome {
  const _AddressOutcome();
}

/// No address file, or none that can be read.
final class _NoHost extends _AddressOutcome {
  const _NoHost();
}

/// The host welcomed the client.
final class _Reached extends _AddressOutcome {
  const _Reached(this.connection, this.welcome, this.address);

  final _Connection connection;
  final AnalysisHostWelcome welcome;
  final AnalysisHostAddress address;
}

/// The host of the address has ended: its port refuses the connection, or
/// its process is gone.
final class _Dead extends _AddressOutcome {
  const _Dead(this.address);

  final AnalysisHostAddress address;
}

/// The host's process is there, and it did not welcome the client.
final class _Silent extends _AddressOutcome {
  const _Silent();
}

/// The address file or its folder may not be trusted ([untrustedAddress]);
/// [why] is the reason it gave.
final class _Untrusted extends _AddressOutcome {
  const _Untrusted(this.why);

  final String why;
}

/// The host's process runs and its port did not take the connection within
/// 5 s: a slow host is not a dead one. [message] is the error's.
final class _Slow extends _AddressOutcome {
  const _Slow(this.message);

  final String message;
}

/// The error codes of a connection refused: Windows (Winsock's 10061, and
/// the 1225 a refused loopback connect reports), Linux, macOS.
const _refusedCodes = {10061, 1225, 111, 61};

/// [line] as a JSON object; null when it is none.
Map<String, Object?>? _object(String? line) {
  if (line == null) return null;
  try {
    return switch (jsonDecode(line)) {
      final Map<String, Object?> json => json,
      _ => null,
    };
  } on FormatException {
    return null;
  }
}

final class _HostClient implements CodeAnalysis, WarmableCodeAnalysis {
  _HostClient({
    required this.projectRoot,
    required this.hostCommand,
    required this.addressFile,
    required this.appsteinVersion,
    required this.ownServer,
    required this.startHost,
    required this.environment,
    required this.startLimit,
    required this.readyTimeout,
    required this.answerGrace,
    required this.turnLimit,
    required this.connect,
    required this.os,
  });

  final String projectRoot;
  final List<String> hostCommand;
  final String addressFile;
  final String appsteinVersion;
  final StoppableCodeAnalysis Function() ownServer;
  final bool startHost;
  final Map<String, String> environment;
  final Duration startLimit;
  final Duration readyTimeout;
  final Duration answerGrace;
  final Duration turnLimit;
  final Future<Socket> Function(int port)? connect;
  final HostOs os;

  _Connection? _connection;
  var _closed = false;
  var _broken = false;
  var _nextId = 0;

  /// Whether a question of this body was answered by a host.
  var _answered = false;

  /// Whether this client, which starts no host, has connected to one.
  var _reached = false;

  /// The run's own analysis server, once the host was found to run a newer
  /// Appstein, or, for a client that starts no host, to be none that can be
  /// used; null until then.
  StoppableCodeAnalysis? _own;

  /// The notice of [_own]'s readings ([olderThanHostNotice],
  /// [unusableHostNotice]); null for none.
  String? _ownNotice;

  /// The files of the last reading, for `leaveUnformatted`.
  var _analyzedFiles = const <String>[];

  /// The connection being made, or waited on to end, that [close] must close:
  /// a run that stopped waiting (a fast run at its cap) leaves no wait for a
  /// host that never answers.
  _Connection? _reaching;

  /// The look for the host, and the launch of one when none answers
  /// ([_connectLoop]). The first question joins it, so a run never launches
  /// two hosts. It is kept when it failed, for the rest of the run: the first
  /// question gets the same failure instead of looking, and launching, again.
  /// It is dropped once it succeeded, since a question asked again after its
  /// host ended needs a new look.
  Future<_Connection?>? _connecting;

  /// Cancels the connection being made to the host's port; null when none is.
  void Function()? _cancelDial;

  /// The pause of the look's poll, ended by [close].
  Timer? _pause;
  Completer<void>? _pausing;

  @override
  void warmUp() {
    if (!startHost || _closed || _connection != null || _own != null) return;
    unawaited(_connect().then<void>((_) {}, onError: (Object _) {}));
  }

  /// Ends the run's use of the host: nothing is waited for. A launch that was
  /// asked for has been made, since [warmUp] asks at the start of the run; a
  /// run that ends before its look has reached the launch leaves none.
  Future<void> close() async {
    _closed = true;
    _cancelDial?.call();
    _pause?.cancel();
    if (_pausing case final pausing? when !pausing.isCompleted) {
      pausing.complete();
    }
    _reaching?.close();
    _reaching = null;
    _connection?.close();
    _connection = null;
    final own = _own;
    _own = null;
    await own?.close();
  }

  /// The run's own server when this run uses one ([_own]); null when it asks
  /// the host. The first question decides.
  Future<CodeAnalysis?> _ownRoute() async {
    await _connect();
    return _own;
  }

  /// The connection, made by [warmUp] or by the first question; null when
  /// this run uses its own server instead ([_own]).
  Future<_Connection?> _connect() async {
    _checkOpen();
    if (_own != null) return null;
    if (_connection case final open?) return open;
    if (_broken) {
      // Another connection would be another client: the server may have
      // been replaced, and the last reading's offsets and files with it.
      throw const CodeAnalysisException(
        'the analysis host stopped answering during this run',
      );
    }
    if (!startHost) return _connectToExisting();
    if (_connecting case final looking?) return looking;
    final looking = _connecting = _connectLoop();
    unawaited(
      looking.then<void>((_) {
        if (identical(_connecting, looking)) _connecting = null;
      }, onError: (Object _) {}),
    );
    return looking;
  }

  Future<_Connection?> _connectLoop() async {
    final failure = File(analysisHostFailureFile(addressFile));
    // The secrets of the hosts of an older version this client asked to stop.
    final askedToStop = <String>{};
    int? started;
    var startedEnded = false;
    final watch = Stopwatch()..start();
    while (true) {
      _checkOpen();
      switch (await _tryAddressWhileOpen()) {
        case _Reached(:final connection, :final welcome, :final address):
          final compared = compareAppsteinVersions(
            appsteinVersion,
            welcome.appsteinVersion,
          );
          if (compared == 0) return _connection = connection;
          if (compared < 0) {
            // A newer host is left alone: this run asks a server of its own.
            connection.close();
            _ownNotice = olderThanHostNotice(
              appsteinVersion,
              welcome.appsteinVersion,
            );
            _own = ownServer();
            return null;
          }
          if (!askedToStop.add(address.secret)) {
            connection.close();
            throw CodeAnalysisException(
              'the analysis host of Appstein ${welcome.appsteinVersion} did '
              'not stop when asked',
            );
          }
          await _askToStop(connection);
          // Its address is gone: a host of this version is started next.
          continue;
        case _Untrusted(:final why):
          throw CodeAnalysisException(
            'Appstein will not use the analysis host address file: $why',
          );
        case _Slow(:final message):
          throw CodeAnalysisException(
            'the analysis host did not take the connection ($message)',
          );
        case _Dead(:final address):
          // Unless another client has replaced it meanwhile.
          await removeAnalysisHostAddress(
            addressFile,
            address.secret,
            cancelled: () => _closed,
          );
        case _NoHost() when started == null:
          // A reason left by an earlier host is not this one's.
          await _deleteIfThere(failure);
          started = await _start();
        case _NoHost() when startedEnded:
          throw CodeAnalysisException(await _whyItEnded(failure));
        case _NoHost() when lookUpProcess(started!) is ProcessGone:
          // It may have written its address in its last moment: one more
          // look.
          startedEnded = true;
          continue;
        case _Silent() || _NoHost():
          // A host that is starting or ending, or the one this client
          // started: asked again below.
          break;
      }
      _checkOpen();
      if (watch.elapsed >= startLimit) {
        final which = started == null
            ? 'the analysis host'
            : 'the analysis host Appstein started';
        throw CodeAnalysisException(
          '$which did not answer within ${secondsText(startLimit)}',
        );
      }
      await _wait(const Duration(milliseconds: 100));
    }
  }

  /// The connection of a client that starts no host ([startHost] false): to
  /// the host the address file names when it welcomes this client and runs
  /// this [appsteinVersion]; null when this run uses its own server instead
  /// ([_own]). It never starts a host, sends a stop or deletes an address:
  /// the address file and the host are left as they were.
  ///
  /// The line is drawn at the first answer ([_answered]):
  /// - **Nothing answered yet** (the first look, or a question asked again
  ///   after its host ended or was replaced): a host that can't be used
  ///   counts as no host, and the run uses its own server. A host of another
  ///   version is left alone, quietly. An address file that may not be
  ///   trusted, a host that won't take the connection and a host that never
  ///   welcomes the client come with a notice ([unusableHostNotice]) that
  ///   says why, so a planted file shows in a CI log. A host that refused
  ///   the connection or has ended, or no address file, is quiet: the stale
  ///   file is never deleted here, so a notice would print on every run.
  ///   A host that was connected and is gone (ended, or replaced by another
  ///   version) comes with a notice too.
  /// - **Something answered:** a later look must find a host of this version
  ///   again; anything else is Appstein failing, since the run would
  ///   otherwise change its analysis server in the middle.
  Future<_Connection?> _connectToExisting() async {
    final reach = await _tryAddressWhileOpen();
    if (reach case _Reached(:final connection, :final welcome)) {
      if (compareAppsteinVersions(appsteinVersion, welcome.appsteinVersion) ==
          0) {
        _reached = true;
        return _connection = connection;
      }
      connection.close();
    }
    if (_answered) {
      throw const CodeAnalysisException(
        'the analysis host stopped answering during this run',
      );
    }
    _ownNotice = _reached
        ? unusableHostNotice('it ended or was replaced before it answered')
        : switch (reach) {
            _Untrusted(:final why) => unusableHostNotice(
              'its address file may not be trusted: $why',
            ),
            _Slow(:final message) => unusableHostNotice(
              'it did not take the connection ($message)',
            ),
            _Silent() => unusableHostNotice('it did not welcome the client'),
            _ => null,
          };
    _own = ownServer();
    return null;
  }

  /// Why the host this client started ended before it answered: the reason
  /// it left in [failure] (which is then deleted), else what is wrong with
  /// the address file's folder, else that it ended.
  Future<String> _whyItEnded(File failure) async {
    try {
      final why = (await failure.readAsString()).trim();
      await failure.delete();
      if (why.isNotEmpty) return why;
    } on FileSystemException {
      // It left none: it ended before it could say why, or it could not
      // write there, as in a folder that is a link (it refuses to write
      // through one), which the look below names.
    }
    if (await untrustedAddress(addressFile, os: os) case final bad?) {
      return 'the analysis host could not start: $bad';
    }
    return 'the analysis host Appstein started ended before it answered';
  }

  /// Deletes [file] when it is there.
  static Future<void> _deleteIfThere(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // None was there.
    }
  }

  /// Asks the host of an older version at [connection] to stop, and waits
  /// until it has closed the connection: it has deleted its address file
  /// by then.
  Future<void> _askToStop(_Connection connection) async {
    // Tracked, so closing the client ends the wait for the host to answer.
    _reaching = connection;
    connection.socket.writeln(jsonEncode(const AnalysisHostStop().toJson()));
    await connection.next(const Duration(seconds: 10));
    connection.close();
    if (identical(_reaching, connection)) _reaching = null;
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

  /// Waits [time], or until [close] ends the wait: no timer outlives the run.
  Future<void> _wait(Duration time) {
    final pausing = _pausing = Completer<void>();
    _pause = Timer(time, () {
      if (!pausing.isCompleted) pausing.complete();
    });
    return pausing.future;
  }

  /// Connects to the host's port on this machine. A connection that is not
  /// made within [_connectLimit] fails, and one still being made when [close]
  /// is called is cancelled, so nothing keeps the process alive after the
  /// run: a refused connection to a closed port takes about 2 s to be
  /// refused on Windows.
  Future<Socket> _dial(int port) {
    if (connect case final replaced?) return replaced(port);
    final result = Completer<Socket>();
    ConnectionTask<Socket>? task;
    Timer? limit;
    var cancelled = false;
    void failWith(Object error, [StackTrace? stackTrace]) {
      if (!result.isCompleted) result.completeError(error, stackTrace);
    }

    void cancel() {
      cancelled = true;
      limit?.cancel();
      task?.cancel();
      failWith(const SocketException('The connection was cancelled'));
    }

    _cancelDial = cancel;
    Socket.startConnect(InternetAddress.loopbackIPv4, port).then<void>((made) {
      task = made;
      if (cancelled) {
        // Cancelled before the task was known: its failure is nobody's.
        unawaited(
          made.socket.then<void>(
            (socket) => socket.destroy(),
            onError: (Object _) {},
          ),
        );
        made.cancel();
        return;
      }
      limit = Timer(_connectLimit, () {
        made.cancel();
        failWith(
          SocketException('Connection timed out, host: 127.0.0.1, port: $port'),
        );
      });
      made.socket.then<void>(
        (socket) {
          limit?.cancel();
          if (result.isCompleted) {
            socket.destroy();
          } else {
            result.complete(socket);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          limit?.cancel();
          failWith(error, stackTrace);
        },
      );
    }, onError: failWith);
    return result.future.whenComplete(() {
      if (identical(_cancelDial, cancel)) _cancelDial = null;
    });
  }

  /// Throws when the run that uses this client has ended.
  void _checkOpen() {
    if (_closed) throw askedAfterRunEnded;
  }

  /// [_tryAddress], for a client that may be closed meanwhile: a connection
  /// that welcomed it after that is closed, and the question ends.
  Future<_AddressOutcome> _tryAddressWhileOpen() async {
    final outcome = await _tryAddress();
    if (_closed) {
      if (outcome case _Reached(:final connection)) connection.close();
      _checkOpen();
    }
    return outcome;
  }

  /// What the address file names now: no host, a host that welcomed this
  /// client, a dead host (the connection is refused, or its process has
  /// ended), or one that is there and did not welcome it (starting, or
  /// ending).
  ///
  /// It throws nothing about the host: an address file or folder that may
  /// not be trusted ([untrustedAddress]) is an [_Untrusted], and a
  /// connection that fails otherwise (it is not taken within 5 s) while the
  /// host's process runs is a [_Slow] (a slow host is not a dead one). The
  /// caller decides what each means: a client that starts a host fails the
  /// question, a terminal run uses a server of its own.
  Future<_AddressOutcome> _tryAddress() async {
    if (await untrustedAddress(addressFile, os: os) case final why?) {
      return _Untrusted(why);
    }
    final address = readAnalysisHostAddress(addressFile);
    if (address == null) return const _NoHost();
    // A host whose process has ended is dead, and nothing is dialed: a
    // refused connection to a closed port takes about 2 s on Windows, and a
    // stale address file would cost every hook that.
    if (lookUpProcess(address.processId) is ProcessGone) {
      return _Dead(address);
    }
    final Socket socket;
    try {
      socket = await _dial(address.port);
    } on SocketException catch (error) {
      final refused = _refusedCodes.contains(error.osError?.errorCode);
      if (refused || lookUpProcess(address.processId) is ProcessGone) {
        // Nothing listens there, or nothing runs: the host has ended.
        return _Dead(address);
      }
      return _Slow(error.message);
    }
    final connection = _Connection(socket);
    _reaching = connection;
    if (_closed) connection.close();
    socket.writeln(
      jsonEncode(
        AnalysisHostHello(
          secret: address.secret,
          appsteinVersion: appsteinVersion,
        ).toJson(),
      ),
    );
    final (:line, late: _) = await connection.next(const Duration(seconds: 10));
    if (identical(_reaching, connection)) _reaching = null;
    if (_object(line) case final json?) {
      try {
        return _Reached(
          connection,
          AnalysisHostWelcome.fromJson(json),
          address,
        );
      } on FormatException {
        // Not a welcome: not a host this client can use.
      }
    }
    connection.close();
    // Another program may have the port of a host that has ended.
    return lookUpProcess(address.processId) is ProcessGone
        ? _Dead(address)
        : const _Silent();
  }

  /// Asks the host [question] and returns its answer's value; it waits at
  /// most [limit] for the answer, from the question's turn.
  ///
  /// A host that was asked to stop by another client sends an ending for
  /// it instead: the question is asked again of the host found through the
  /// address file, when that is safe (a reading, or nothing answered yet
  /// in this body), a few times at most.
  Future<Object> _ask(
    AnalysisHostQuestion Function(int id) question,
    Duration limit,
  ) async {
    for (var tries = 1; ; tries++) {
      final connection = await _connect();
      if (connection == null) throw const _UseOwnServer();
      final asked = question(_nextId++);
      connection.socket.writeln(jsonEncode(asked.toJson()));
      // First the turn: the wait in the host's queue is the questions
      // ahead's, each with its own limit, so only [turnLimit], far above
      // any real queue, bounds it. The question's own limit starts when the
      // server begins on it.
      var got = await connection.next(turnLimit);
      final waitedForTurn = got.late;
      final first = _object(got.line);
      final ending = first != null && AnalysisHostEnding.isEnding(first);
      // Closed before the question's turn: the host ended without
      // beginning it (a host asked to stop ends once it has nothing left).
      final closed = got.line == null && !got.late;
      if (ending || closed) {
        final again = asked.kind == AnalysisHostQuestionKind.read || !_answered;
        if (again && tries < 3) {
          // Not this run's host any more: the next one is found anew.
          _connection?.close();
          _connection = null;
          continue;
        }
        if (ending) {
          _drop();
          throw const CodeAnalysisException(
            'the analysis host was replaced by a newer Appstein during this '
            'run',
          );
        }
      }
      if (first != null && AnalysisHostTurn.isTurn(first)) {
        got = await connection.next(limit);
      }
      return _answerOf(got, asked, limit, waitedForTurn: waitedForTurn);
    }
  }

  /// The value of the answer [got] to [asked].
  Object _answerOf(
    ({String? line, bool late}) got,
    AnalysisHostQuestion asked,
    Duration limit, {
    required bool waitedForTurn,
  }) {
    final (:line, :late) = got;
    if (line == null) {
      // The answers of this connection can no longer be told apart: a later
      // question of the body fails too, and the next body connects anew.
      _drop();
      throw CodeAnalysisException(switch ((late, waitedForTurn)) {
        (true, true) =>
          'the analysis host did not begin the question within '
              '${secondsText(turnLimit)}',
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
    _answered = true;
    if (answer.failure case final failure?) {
      throw CodeAnalysisException(failure, refusalCode: answer.refusalCode);
    }
    if (answer.timedOut) throw TimeoutException(null, asked.within);
    return answer.value!;
  }

  /// Closes the connection for good, after it failed.
  void _drop() {
    _broken = true;
    _connection?.close();
    _connection = null;
  }

  /// [ownAnswer] from the run's own server when this run uses one ([_own]),
  /// else [hostAnswer]. A question asked again after its host ended
  /// ([_ask]) may find a newer host, and so this run's own server: it is
  /// then answered by that.
  Future<T> _either<T>(
    Future<T> Function(CodeAnalysis own) ownAnswer,
    Future<T> Function() hostAnswer,
  ) async {
    if (await _ownRoute() case final own?) return ownAnswer(own);
    try {
      return await hostAnswer();
    } on _UseOwnServer {
      return ownAnswer(_own!);
    }
  }

  @override
  Future<CodeReading> read() => _either(
    (own) async {
      final reading = await own.read();
      return CodeReading(
        diagnostics: reading.diagnostics,
        pluginFailures: reading.pluginFailures,
        notices: [...reading.notices, ?_ownNotice],
        analyzedFiles: reading.analyzedFiles,
        unreadableFiles: reading.unreadableFiles,
      );
    },
    () async {
      final value = await _ask(
        (id) =>
            AnalysisHostQuestion(id: id, kind: AnalysisHostQuestionKind.read),
        // The host's server may start several times within one reading (a
        // change to the analysis options while it starts).
        readyTimeout * 2 + answerGrace,
      );
      final reading = CodeReading.fromJson(value as Map<String, Object?>);
      _analyzedFiles = reading.analyzedFiles;
      return reading;
    },
  );

  @override
  Future<bool> canDartFix(
    CodeDiagnostic diagnostic, {
    required Duration within,
  }) => _either(
    (own) => own.canDartFix(diagnostic, within: within),
    () async =>
        await _ask(
              (id) => AnalysisHostQuestion(
                id: id,
                kind: AnalysisHostQuestionKind.canDartFix,
                within: within,
                diagnostic: diagnostic,
              ),
              within + answerGrace,
            )
            as bool,
  );

  @override
  Future<FormatAnswers> formatChanges(
    List<String> files, {
    required Duration within,
  }) => _either(
    (own) => own.formatChanges(files, within: within),
    () async => FormatAnswers.fromJson(
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
    ),
  );

  @override
  Future<PendingFixes> pendingFixes({required Duration within}) => _either(
    (own) => own.pendingFixes(within: within),
    () async => PendingFixes.fromJson(
      await _ask(
            (id) => AnalysisHostQuestion(
              id: id,
              kind: AnalysisHostQuestionKind.pendingFixes,
              within: within,
            ),
            fixQuestionLimit(within) + answerGrace,
          )
          as Map<String, Object?>,
    ),
  );

  @override
  Future<AppliedChanges> applyFixesAndFormat({
    required Future<bool> Function(String file) leaveUnformatted,
    required Duration within,
  }) => _either(
    (own) => own.applyFixesAndFormat(
      leaveUnformatted: leaveUnformatted,
      within: within,
    ),
    () async {
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
    },
  );
}

/// Thrown by [_HostClient._ask] when a question asked again after its host
/// ended finds that this run must use its own server.
final class _UseOwnServer implements Exception {
  const _UseOwnServer();
}
