import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../host/host_environment.dart';
import 'analysis_host_lock.dart';
import 'analysis_server.dart';
import 'code_analysis.dart';
import 'kept_analysis_server.dart';

/// The environment variable that moves the folder of the analysis hosts'
/// address files ([analysisHostFolder]), as `analysisCacheVariable` moves the
/// analysis server's cache. Tests set it, so their hosts never meet the
/// hosts of the developer's own sessions.
const analysisHostFolderVariable = 'APPSTEIN_ANALYSIS_HOST_FOLDER';

/// How long an analysis host may go without a question before it ends
/// itself, with its analysis server (decision record 0002). The time is
/// counted from the end of the last question, and never runs while one is
/// answered, so a question is never cut off. A connection that asks nothing
/// for this long is closed too, so a client that stays connected doesn't
/// keep the host. A test shortens it.
const analysisHostIdleStop = analysisIdleStop;

/// The folder of the analysis hosts' address files on the machine
/// [environment], outside every project and readable by its user only:
/// - [analysisHostFolderVariable], when it is set and not empty;
/// - on Windows, `appstein` in `%LOCALAPPDATA%`, the user's own;
/// - elsewhere, `appstein` in `$XDG_RUNTIME_DIR` (`/run/user/<uid>` on
///   Linux, the user's own);
/// - otherwise `appstein-<uid>` in the system's temporary folder: on Linux
///   that folder is shared by every user, so the name is the user's own and
///   another user can't make it first under the name this user looks for.
///   Where the user ID can't be read, `appstein-<user name>`.
///
/// The host makes the folder, and off Windows gives it mode 700
/// ([writeAnalysisHostAddress]); a client refuses one that isn't so
/// ([untrustedAddress]).
String analysisHostFolder(HostEnvironment environment) {
  String? set(String name) => switch (environment.variable(name)) {
    final value? when value.isNotEmpty => value,
    _ => null,
  };
  if (set(analysisHostFolderVariable) case final folder?) {
    return p.normalize(p.absolute(folder));
  }
  if (environment.os == HostOs.windows) {
    return p.join(set('LOCALAPPDATA') ?? Directory.systemTemp.path, 'appstein');
  }
  if (set('XDG_RUNTIME_DIR') case final runtime?) {
    return p.join(runtime, 'appstein');
  }
  return p.join(Directory.systemTemp.path, 'appstein-${_userId(environment)}');
}

/// The user's ID (`id -u`); the user's name when it can't be read.
String _userId(HostEnvironment environment) {
  try {
    final result = Process.runSync('id', ['-u']);
    final id = '${result.stdout}'.trim();
    if (result.exitCode == 0 && int.tryParse(id) != null) return id;
  } on ProcessException {
    // No `id`: the name below.
  }
  return environment.variable('USER') ?? 'unknown';
}

/// The address file, in [folder], of the analysis host of the project at
/// [projectRoot]: named by a hash of the project's full path, so a path with
/// spaces or any length gives a short plain name. On Windows ([os]), where a
/// path's letter case doesn't matter, the path is hashed in lower case, so
/// two spellings of one folder share one host.
String analysisHostAddressFile(
  String folder,
  String projectRoot, {
  HostOs? os,
}) {
  var path = p.normalize(p.absolute(projectRoot));
  if ((os ?? HostOs.current) == HostOs.windows) path = path.toLowerCase();
  final hash = sha256.convert(utf8.encode(path)).toString().substring(0, 32);
  return p.join(folder, 'host-$hash.json');
}

/// The file beside the address file [addressFile] where a host that could
/// not start leaves why, for the client that started it
/// ([analysisHostAddressFile] with `.failed` for `.json`).
String analysisHostFailureFile(String addressFile) =>
    '${p.withoutExtension(addressFile)}.failed';

/// Deletes the address file [addressFile] when it still holds the address
/// with [secret], under the lock ([withAnalysisHostLock]), and says whether
/// it did. A client calls it for a host it found dead, and a host for its
/// own address as it ends: an address another starter has written meanwhile
/// is left. Returns false when the lock can't be had.
Future<bool> removeAnalysisHostAddress(
  String addressFile,
  String secret,
) async {
  if (!await Directory(p.dirname(addressFile)).exists()) return false;
  try {
    return await withAnalysisHostLock(addressFile, () async {
      if (readAnalysisHostAddress(addressFile)?.secret != secret) return false;
      try {
        await File(addressFile).delete();
        return true;
      } on FileSystemException {
        return false;
      }
    });
  } on FileSystemException {
    return false;
  }
}

/// Writes [address] to the file [path], whole or not at all: to a new file
/// beside it first, which then takes its place (a rename), so a client never
/// reads half an address. The rename replaces a file that is there: the
/// host calls this under the address file's lock, after it has found none
/// ([withAnalysisHostLock]). Off Windows ([os]) the folder is given mode 700
/// and the file mode 600 before the address is in it, so only the user can
/// read the secret; `chmod` fails on a folder that isn't the user's, so a
/// folder another user made is never written to. On Windows the folder is
/// the user's own (`%LOCALAPPDATA%`). Off Windows a folder path that is a
/// link is refused before anything is made or changed: a link planted where
/// the folder goes (`/tmp/appstein-<uid>`) would otherwise make the host
/// `chmod` one of the user's own folders and write the secret there.
///
/// Throws a [FileSystemException] when it can't be written.
Future<void> writeAnalysisHostAddress(
  String path,
  AnalysisHostAddress address, {
  HostOs? os,
}) => _writeUserOnly(path, jsonEncode(address.toJson()), os ?? HostOs.current);

/// Writes [text] to [path] as [writeAnalysisHostAddress] says.
Future<void> _writeUserOnly(String path, String text, HostOs os) async {
  await _userFolder(path, os);
  final beside = File('$path.$pid.tmp');
  try {
    await beside.writeAsString('');
    await _userOnly('600', beside.path, os);
    await beside.writeAsString(text, flush: true);
    await beside.rename(path);
  } on Object {
    try {
      await beside.delete();
    } on FileSystemException {
      // Never made, or gone already.
    }
    rethrow;
  }
}

/// Makes the folder of the file [path], user-only, as
/// [writeAnalysisHostAddress] says.
Future<void> _userFolder(String path, HostOs os) async {
  final folder = Directory(p.dirname(path));
  if (os != HostOs.windows && await FileSystemEntity.isLink(folder.path)) {
    throw FileSystemException(
      'the folder of the address file is a link, not a plain folder',
      folder.path,
    );
  }
  await folder.create(recursive: true);
  await _userOnly('700', folder.path, os);
}

/// Gives [path] the permissions [mode] off Windows ([setFileMode]), and does
/// nothing on Windows. Throws a [FileSystemException] when that fails.
Future<void> _userOnly(String mode, String path, HostOs os) async {
  if (os == HostOs.windows) return;
  if (!await setFileMode(mode, path)) {
    throw FileSystemException(
      'its permissions could not be set to $mode (is it the user\'s own?)',
      path,
    );
  }
}

/// Why the address file [path] must not be trusted; null when it may be
/// read. On Windows ([os]) the folder is the user's own (`%LOCALAPPDATA%`),
/// so nothing is checked. Elsewhere, when the folder exists:
/// - it must be a folder, not a link, with mode 700, and the user's own
///   (`chmod` to the same mode works only for its owner);
/// - the file, when there is one, must be a file, not a link, with mode 600,
///   and the user's own.
///
/// Every local program can reach a loopback port, so a client that took
/// another user's address file would send that user's host its questions,
/// and that host could answer anything.
Future<String?> untrustedAddress(String path, {HostOs? os}) async {
  if ((os ?? HostOs.current) == HostOs.windows) return null;
  Future<String?> check(
    String what,
    String target,
    int mode,
    bool folder,
  ) async {
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    final wanted = folder
        ? FileSystemEntityType.directory
        : FileSystemEntityType.file;
    if (type != wanted) {
      return '$what $target is not a plain ${folder ? 'folder' : 'file'}';
    }
    final actual = (await FileStat.stat(target)).mode & 0x1FF;
    final octal = mode.toRadixString(8);
    if (actual != mode) {
      return '$what $target has mode ${actual.toRadixString(8)}, not $octal';
    }
    if (!await setFileMode(octal, target)) {
      return '$what $target is not the user\'s own';
    }
    return null;
  }

  return await check('the folder', p.dirname(path), 0x1C0, true) ??
      await check('the address file', path, 0x180, false);
}

/// The address in the file [path]; null when there is none, or it can't be
/// read as one.
AnalysisHostAddress? readAnalysisHostAddress(String path) {
  try {
    final json = jsonDecode(File(path).readAsStringSync());
    if (json is! Map<String, Object?>) return null;
    return AnalysisHostAddress.fromJson(json);
  } on Object {
    return null;
  }
}

/// How long a new connection may take to send its hello before the host
/// closes it.
const _helloLimit = Duration(seconds: 10);

/// Runs the **analysis host** of the project at [projectRoot] (decision
/// record 0002), and returns when it has ended. It is what the hidden
/// `appstein analysis-host` mode runs.
///
/// - **It owns [analysis]**, the project's analysis server behind its
///   guard, with all its rules (`AnalysisServer`), and keeps it between
///   questions (`KeptAnalysisServer`). Nothing is started until a client
///   asks.
/// - **It listens on loopback TCP only**: `127.0.0.1`, on a port the system
///   picks. It then writes its address file ([analysisHostAddressFile] in
///   [addressFolder]): the port, a random secret, its process ID and
///   [appsteinVersion]. When it can't (the folder can't be made or isn't the
///   user's, the port can't be bound, the file can't be written), it leaves
///   why in [analysisHostFailureFile] for the client that started it, and
///   throws.
/// - **Taking the project is exclusive**: the address is written under the
///   address file's lock ([withAnalysisHostLock]), and only when no other
///   host's address is there. A host that finds one has lost a race with
///   another starter: it returns at once, having started nothing, and its
///   client connects to the winner. An address a dead host left is deleted
///   by the client that finds it dead, before it starts a host.
/// - **A client of a newer Appstein version asks it to stop**
///   (`AnalysisHostStop`): it deletes its address file and closes its port
///   at once, so that client can start a host of its own version, then
///   closes that connection, answers the questions it already has (being
///   answered or waiting in its queue), and ends. It takes no new question:
///   one that comes on a connection still open is answered with an
///   `AnalysisHostEnding` and the connection is closed, so its client asks
///   the host that took the project, and an `--apply` sent then never
///   writes.
/// - **A connection must send the secret first** (an `AnalysisHostHello`):
///   every local program can reach a loopback port, so one whose first line
///   isn't the hello with the secret, or that sends none within 10 s, is
///   closed.
/// - **Each question is one use of the server**: questions are answered one
///   at a time, in the order they arrive, from every connection, and a
///   connection holds the server only while its question is answered. A
///   question that changes the server's state for a while (the pending-fix
///   passes and the rewrite of `--apply`, whose overlays no other client may
///   see) is one question, so no other client's question comes in between.
/// - **A question's turn is told** (`AnalysisHostTurn`) when it leaves the
///   queue, so a client counts its time limit from there, not from the wait
///   behind other clients' questions.
/// - **A question whose client has gone is never begun**: one whose
///   connection closed while it waited is dropped. A rewrite
///   (`applyFixesAndFormat`) whose client goes away while the server works
///   writes nothing: [analysis] is made with an [AnalysisHostWrites], whose
///   `replaceText` looks once, at the first write, whether the client is
///   still there (as `AnalysisServer` gives up a rewrite whose caller stopped
///   waiting).
/// - **It ends itself after [idleStop] with no question**, never while one
///   is answered: it closes its port and its connections, deletes its
///   address file (when it is still its own) and stops the server and its
///   guard. A connection that asks nothing for [idleStop] is closed. A host
///   that is killed instead takes its guard and server with it: the guard
///   ends the server when the host's end closes its input.
Future<void> runAnalysisHost({
  required String projectRoot,
  required StoppableCodeAnalysis Function(AnalysisHostWrites writes) analysis,
  required String addressFolder,
  required String appsteinVersion,
  Duration idleStop = analysisHostIdleStop,
  HostOs? os,
}) async {
  final system = os ?? HostOs.current;
  final writes = AnalysisHostWrites._();
  final kept = KeptAnalysisServer(analysis(writes), idleStop: idleStop * 2);
  final addressFile = analysisHostAddressFile(
    addressFolder,
    projectRoot,
    os: system,
  );
  final failureFile = analysisHostFailureFile(addressFile);
  final random = Random.secure();
  final secret = [
    for (var i = 0; i < 32; i++) random.nextInt(256).toRadixString(16),
  ].map((byte) => byte.padLeft(2, '0')).join();
  final ServerSocket listening;
  try {
    listening = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final bool claimed;
    try {
      await _userFolder(addressFile, system);
      // Exclusive: only when no other host's address is there. A dead
      // host's was deleted by the client that found it dead.
      claimed = await withAnalysisHostLock(addressFile, () async {
        if (readAnalysisHostAddress(addressFile) != null) return false;
        await writeAnalysisHostAddress(
          addressFile,
          AnalysisHostAddress(
            port: listening.port,
            secret: secret,
            processId: pid,
            appsteinVersion: appsteinVersion,
          ),
          os: system,
        );
        return true;
      });
    } on Object {
      await listening.close();
      rethrow;
    }
    if (!claimed) {
      // Another host took the project first: its clients, the one that
      // started this one too, use that one.
      await listening.close();
      await kept.close();
      return;
    }
  } on Object catch (error) {
    await kept.close();
    try {
      await _writeUserOnly(
        failureFile,
        'the analysis host could not start: ${_plain(error)}',
        system,
      );
    } on Object {
      // Not even that: the client says the host ended as it started.
    }
    rethrow;
  }
  try {
    await File(failureFile).delete();
  } on FileSystemException {
    // None was left.
  }

  final ended = Completer<void>();
  final connections = <Socket>{};
  var asking = 0;
  var ending = false;
  var askedToStop = false;
  Timer? idle;
  Future<void>? gaveUp;

  // Gives the project up: the port is closed and the address file deleted,
  // when it is still its own (another host may have written it since).
  Future<void> giveUp() => gaveUp ??= () async {
    await listening.close();
    await removeAnalysisHostAddress(addressFile, secret);
  }();

  Future<void> end() async {
    if (ending) return;
    ending = true;
    idle?.cancel();
    await giveUp();
    // An answer written a moment ago still reaches its client.
    await Future.wait([...connections].map(_closeWritten));
    await kept.close();
    if (!ended.isCompleted) ended.complete();
  }

  void countIdle() {
    idle?.cancel();
    idle = Timer(idleStop, () {
      if (asking == 0) unawaited(end());
    });
  }

  // When no question is being answered: a host asked to stop ends, any
  // other counts its idle time again.
  void afterQuestions() {
    if (asking > 0 || ending) return;
    if (askedToStop) {
      unawaited(end());
    } else {
      countIdle();
    }
  }

  // Asked by a client of a newer version: the project is given up at once,
  // so that client can start a host of its own, and this one ends when the
  // questions it already has are answered. It takes no new one.
  Future<void> stop() async {
    if (askedToStop) return;
    askedToStop = true;
    idle?.cancel();
    await giveUp();
    afterQuestions();
  }

  countIdle();
  listening.listen((socket) async {
    connections.add(socket);
    // Read apart from the answering, so a client that goes away is seen
    // while its question waits or is answered.
    var open = true;
    final incoming = StreamController<String>();
    utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(
          incoming.add,
          onDone: () {
            open = false;
            unawaited(incoming.close());
          },
          onError: (Object _) {
            open = false;
            unawaited(incoming.close());
          },
        );
    final lines = StreamIterator(incoming.stream);
    // A write to a client that has gone away fails here, not in the host.
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
    try {
      if (!await _helloWith(lines, secret)) return;
      socket.writeln(
        jsonEncode(
          AnalysisHostWelcome(
            appsteinVersion: appsteinVersion,
            processId: pid,
          ).toJson(),
        ),
      );
      // A connection that asks nothing for the idle time is closed.
      while (await lines.moveNext().timeout(idleStop)) {
        final json = jsonDecode(lines.current);
        if (json is! Map<String, Object?>) return;
        if (AnalysisHostStop.isStop(json)) {
          // Its address file is gone before the connection closes.
          await stop();
          return;
        }
        final question = AnalysisHostQuestion.fromJson(json);
        if (askedToStop || ending) {
          // A question that came after the stop, or while the host ends
          // (its server is being closed), is not taken, so the old
          // host and server don't run on beside the new ones: its client
          // asks the host that took the project.
          socket.writeln(jsonEncode(AnalysisHostEnding(question.id).toJson()));
          return;
        }
        asking++;
        idle?.cancel();
        final AnalysisHostAnswer? answer;
        try {
          answer = await kept.use((analysis) async {
            // Its client went away while it waited: it is not begun.
            if (!open) return null;
            socket.writeln(jsonEncode(AnalysisHostTurn(question.id).toJson()));
            writes._current = _Asked(() => open);
            try {
              return await _answer(question, analysis);
            } finally {
              writes._current = null;
            }
          });
        } on CodeAnalysisException catch (error) {
          // The host is ending: the server is closed.
          socket.writeln(
            jsonEncode(
              AnalysisHostAnswer.failed(question.id, error.reason).toJson(),
            ),
          );
          return;
        } finally {
          asking--;
          afterQuestions();
        }
        if (answer == null) return;
        socket.writeln(jsonEncode(answer.toJson()));
      }
    } on Object {
      // A client that broke its connection, sent what is no question, or
      // asked nothing for the idle time: the connection is closed below.
    } finally {
      connections.remove(socket);
      // The last line written (an answer, an ending) still reaches it.
      await _closeWritten(socket);
      await lines.cancel();
    }
  });
  await ended.future;
}

/// Closes [socket] once what was written to it has gone out, or after 1 s
/// when its client doesn't take it: `destroy` alone drops what is still
/// waiting to be sent.
Future<void> _closeWritten(Socket socket) async {
  try {
    await socket.flush().timeout(const Duration(seconds: 1));
  } on Object {
    // Gone already, or not taking what was written: closed below anyway.
  }
  socket.destroy();
}

/// How the analysis host's server writes the files of a rewrite
/// (`applyFixesAndFormat`): the host gives it to the code analysis it owns
/// ([runAnalysisHost]), which passes [replaceText] to `AnalysisServer` as
/// its `replaceText`.
///
/// At the first write of a question it looks whether the client that asked
/// is still connected. When it isn't, that write and every other of the
/// question fail, so nothing is written: the client has already been told
/// the question failed, and a rewrite must only ever fail before anything
/// is written. Once the first write is made, the others follow, as in
/// `AnalysisServer`.
final class AnalysisHostWrites {
  AnalysisHostWrites._();

  /// The question being answered; null between questions.
  _Asked? _current;

  /// Writes [text] to [path] as `replaceFileText` does, unless the client
  /// whose question this is has gone away (above).
  ///
  /// Throws a [FileSystemException] for a write that is not made.
  Future<void> replaceText(String path, String text) =>
      gate(replaceFileText)(path, text);

  /// [write], under the rule above: [replaceText] is `gate(replaceFileText)`.
  /// A test's stand-in for the server passes its own [write].
  Future<void> Function(String path, String text) gate(
    Future<void> Function(String path, String text) write,
  ) => (path, text) async {
    final asked = _current;
    if (asked != null && !asked.began) {
      asked
        ..began = true
        ..abandoned = !asked.wanted();
    }
    if (asked != null && asked.abandoned) {
      throw FileSystemException(
        'the client that asked for the rewrite has gone away, so nothing is '
        'written',
        path,
      );
    }
    await write(path, text);
  };
}

/// One question as [AnalysisHostWrites] sees it.
final class _Asked {
  _Asked(this.wanted);

  /// Whether its client is still connected.
  final bool Function() wanted;

  /// Whether its first write was looked at.
  var began = false;

  /// Whether its writes are not made.
  var abandoned = false;
}

/// [error] in one line, without Dart's class name in front.
String _plain(Object error) => switch (error) {
  FileSystemException(:final message, :final path, :final osError) =>
    '$message${path == null ? '' : ' ($path)'}'
        '${osError == null ? '' : ': ${osError.message}'}',
  SocketException(:final message, :final osError) =>
    '$message${osError == null ? '' : ': ${osError.message}'}',
  _ => '$error',
}.replaceAll(RegExp(r'\s*\n\s*'), ' ');

/// Whether the first line of [lines] is a hello with [secret], sent within
/// [_helloLimit].
Future<bool> _helloWith(StreamIterator<String> lines, String secret) async {
  try {
    if (!await lines.moveNext().timeout(_helloLimit)) return false;
    final json = jsonDecode(lines.current);
    if (json is! Map<String, Object?>) return false;
    final hello = AnalysisHostHello.fromJson(json);
    return _same(hello.secret, secret);
  } on Object {
    return false;
  }
}

/// Whether [a] and [b] are the same text, in a time that doesn't tell how
/// much of them agrees.
bool _same(String a, String b) {
  if (a.length != b.length) return false;
  var differ = 0;
  for (var i = 0; i < a.length; i++) {
    differ |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return differ == 0;
}

/// [analysis]'s answer to [question].
Future<AnalysisHostAnswer> _answer(
  AnalysisHostQuestion question,
  CodeAnalysis analysis,
) async {
  final id = question.id;
  final within = question.within ?? Duration.zero;
  try {
    return AnalysisHostAnswer.answered(id, switch (question.kind) {
      AnalysisHostQuestionKind.read => (await analysis.read()).toJson(),
      AnalysisHostQuestionKind.canDartFix => await analysis.canDartFix(
        question.diagnostic!,
        within: within,
      ),
      AnalysisHostQuestionKind.formatChanges => (await analysis.formatChanges(
        question.files,
        within: within,
      )).toJson(),
      AnalysisHostQuestionKind.pendingFixes => (await analysis.pendingFixes(
        within: within,
      )).toJson(),
      AnalysisHostQuestionKind.applyFixesAndFormat =>
        (await analysis.applyFixesAndFormat(
          leaveUnformatted: (file) async =>
              question.leaveUnformatted.contains(file),
          within: within,
        )).toJson(),
    });
  } on TimeoutException {
    return AnalysisHostAnswer.timedOut(id);
  } on CodeAnalysisException catch (error) {
    return AnalysisHostAnswer.failed(
      id,
      error.reason,
      refusalCode: error.refusalCode,
    );
  } on Object catch (error) {
    return AnalysisHostAnswer.failed(id, 'the analysis host failed: $error');
  }
}
