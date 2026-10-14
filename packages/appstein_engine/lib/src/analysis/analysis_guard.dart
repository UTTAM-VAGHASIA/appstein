import 'dart:async';
import 'dart:io';

/// How the line starts with which the guard names its processes on stderr:
/// `guarding <the guard's process ID> <the server's process ID>`.
const analysisGuardSign = 'guarding ';

/// The line the guard writes on stderr when it ends in order: the server
/// has ended, or the guard has just killed it. A guard that ends without
/// this line was killed itself, and its server is still running. The guard
/// writes a line end before it, so it never continues the server's last
/// words; a reader accepts it at the end of a line all the same.
const analysisGuardEnded = 'guard ended';

/// The guard of a Dart analysis server (decision record 0001).
///
/// A server that speaks the legacy analyzer protocol keeps running when the
/// process that started it is killed. So Appstein never starts one directly:
/// it starts this guard, which
/// - starts the server with [dartExecutable], the real `dart` of an SDK
///   (`dart language-server --protocol=analyzer`);
/// - names both processes on stderr in one line ([analysisGuardSign]);
/// - passes its stdin to the server and the server's output to its stdout,
///   byte for byte, and the server's stderr to its own;
/// - kills the server when its stdin closes, which is what happens when the
///   process that started the guard ends in any way;
/// - says [analysisGuardEnded] on stderr before it ends.
///
/// It returns the guard's exit code: 0 after its input closed, the server's
/// own exit code when the server ended first (it was asked to stop, or it
/// crashed), and 1 when the server could not be started.
///
/// **Whoever calls it must then end the process with `exit`**, not by
/// setting `exitCode` and returning. A guard that had passed a request on
/// to a server that had just been killed said [analysisGuardEnded] and
/// returned, and its process then never ended by itself (Windows, about 1
/// run in 5 of a test that kills the server and asks at once). What kept
/// the Dart VM running was not found; the request written to the dead
/// server is the suspect. A guard that says it ended and stays is the one
/// thing a guard must not do, so its end doesn't depend on that.
Future<int> runAnalysisGuard(String dartExecutable) async {
  final Process server;
  try {
    server = await Process.start(dartExecutable, const [
      'language-server',
      '--protocol=analyzer',
    ]);
  } on ProcessException catch (error) {
    stderr.writeln('$dartExecutable could not be started: ${error.message}');
    return 1;
  }
  stderr.writeln('$analysisGuardSign$pid ${server.pid}');
  final ended = Completer<int>();
  void end(int code) {
    if (!ended.isCompleted) ended.complete(code);
  }

  // Writing to a server that has just ended fails; the server's exit says
  // what happened.
  server.stdin.done.ignore();
  final errorLines = server.stderr.listen(stderr.add, onError: (Object _) {});
  void inputClosed() {
    server.kill(ProcessSignal.sigkill);
    end(0);
  }

  final incoming = stdin.listen(
    (bytes) {
      try {
        server.stdin.add(bytes);
      } on Object {
        // The server has ended.
      }
    },
    onDone: inputClosed,
    onError: (Object _) => inputClosed(),
    cancelOnError: true,
  );
  // The server ended by itself: pass on what it still said, then end with
  // its exit code. A broken output means nobody is listening any more.
  unawaited(
    stdout
        .addStream(server.stdout)
        .then((_) => stdout.flush())
        .then<void>((_) async => end(await server.exitCode))
        .catchError((Object _) => inputClosed()),
  );
  final code = await ended.future;
  await incoming.cancel();
  await errorLines.cancel();
  try {
    // On a line of its own, whatever the server wrote last: its last words
    // may have had no line end.
    stderr.writeln('\n$analysisGuardEnded');
    await stderr.flush();
  } on Object {
    // Nobody is listening any more.
  }
  return code;
}
