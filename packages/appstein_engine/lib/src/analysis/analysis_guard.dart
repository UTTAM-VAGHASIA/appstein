import 'dart:async';
import 'dart:io';

import '../host/host_environment.dart';
import 'analysis_cache.dart';
import 'process_identity.dart';

/// How the line starts with which the guard names its processes on stderr:
/// `guarding <the guard's process ID> <the server's process ID>`.
const analysisGuardSign = 'guarding ';

/// The line the guard writes on stderr when it ends in order: the server
/// has ended, or the guard has just killed it. A guard that ends without
/// this line was killed itself, and its server is still running. The guard
/// writes a line end before it, so it never continues the server's last
/// words; a reader accepts it at the end of a line all the same.
const analysisGuardEnded = 'guard ended';

/// How long the guard waits, counted from the moment it starts to end its
/// server, for the server to be **shown to be gone**: first for the system
/// to say it has ended (`exitCode`), then for the process to have ended
/// completely ([processHasEnded]). One wait for both. When it runs out, the
/// guard deletes nothing and ends.
const _serverEndWait = Duration(seconds: 2);

/// The most time the guard takes to end its server and clean up after it,
/// counted from the same moment as [_serverEndWait]: what is left of it
/// after the wait is the deletion's, which is given up at the end of it.
///
/// **It must stay below [analysisStopWait]**, the time the process that
/// started the guard waits for it to end before it kills it: a guard that is
/// killed in the middle of its clean-up leaves the files. A test checks it.
const analysisGuardEndBudget = Duration(seconds: 3);

/// How long `AnalysisServer.stop` waits, after it closed the guard's input,
/// for the guard to end before it kills the guard and the server by their
/// process IDs. The guard ends within [analysisGuardEndBudget] of that, so
/// this is a margin of two seconds for the system.
const analysisStopWait = Duration(seconds: 5);

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
///   process that started the guard ends in any way, and ends once the
///   system says the server has ended (at most 2 s later);
/// - **deletes the server's half-written cache files** every time it has
///   ended the server, or found it ended: the files named
///   `-temp-<the server's process ID>` directly in the cache's analysis
///   driver folder ([removeHalfWrittenFiles]), once nothing runs under that
///   ID any more ([removeServerFilesWhenGone]). A kill leaves such files
///   when it catches a write in the middle. The guard does it, not the
///   process that started it, since that process may be the one that was
///   killed. It ends within [analysisGuardEndBudget] of starting to end the
///   server, the clean-up included. A guard that is killed itself, with its
///   server at the same moment, leaves them, and so does one whose server
///   is not shown to be gone within its wait (known limits);
/// - says [analysisGuardEnded] on stderr after that, as the last thing
///   before it ends, so a process that waits for the guard's end waits for
///   the clean-up too.
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
  // Whether the system has said the server has ended: only then are its
  // half-written files deleted.
  var serverEnded = false;
  unawaited(server.exitCode.then((_) => serverEnded = true));
  // Counts the guard's end ([_serverEndWait], [analysisGuardEndBudget]) from
  // the moment it starts to end the server.
  final ending = Stopwatch();
  final errorLines = server.stderr.listen(stderr.add, onError: (Object _) {});
  void inputClosed() {
    if (!ending.isRunning) ending.start();
    server.kill(ProcessSignal.sigkill);
    // Ended once the system says the server has ended, not when it was
    // told to: on Windows a killed process already has its exit code while
    // a file it was creating is still being created, and that file is the
    // half-written cache file a stop deletes (ticket 13 of slice 1d.2).
    // The wait has a limit, so a server that never ends can't hold the
    // guard; the stop then kills it by its ID.
    unawaited(
      server.exitCode
          .timeout(_serverEndWait, onTimeout: () => -1)
          .then((_) => end(0)),
    );
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
        .then<void>((_) async {
          if (!ending.isRunning) ending.start();
          end(await server.exitCode);
        })
        .catchError((Object _) => inputClosed()),
  );
  final code = await ended.future;
  await incoming.cancel();
  await errorLines.cancel();
  await removeServerFilesWhenGone(
    server.pid,
    serverEnded: serverEnded,
    sinceEnding: ending,
  );
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

/// The cache folder of the server the guard started: by the environment the
/// guard inherited, which the server inherited too ([analysisCacheFolder]).
String? _inheritedCacheFolder() =>
    analysisCacheFolder(HostEnvironment.current());

/// Deletes the files the server with the process ID [serverId] left
/// half-written in its cache, once the server is **shown to be gone**, and
/// returns how many it deleted. It is the guard's whole clean-up
/// ([runAnalysisGuard]); the other parameters are a seam for the tests.
///
/// - [serverEnded] is whether the system said the server has ended. When it
///   did not, nothing is deleted: the server may still be writing.
/// - [sinceEnding] has run since the guard started to end the server. Until
///   it reaches [serverEndWait], the process is asked every 10 ms whether it
///   has ended completely ([hasEnded], [processHasEnded]): on Windows a
///   killed process has its exit code before it has finished ending, and a
///   file it was creating can still appear. **When the wait runs out, or
///   [hasEnded] throws, nothing is deleted**; so when another process has
///   the ID by then (it may be another analysis server, writing files with
///   that ID), its files are left.
/// - The deletion ([removeHalfWrittenFiles], or [remove]) gets what is left
///   of [budget] ([analysisGuardEndBudget]) and is given up at its end, so
///   the guard's end never waits for a very large folder.
/// - [cacheFolder] says the server's cache folder; null means it keeps none.
///
/// It never throws: what it could not do leaves the files, and the guard
/// still ends.
Future<int> removeServerFilesWhenGone(
  int serverId, {
  required bool serverEnded,
  required Stopwatch sinceEnding,
  bool Function(int id) hasEnded = processHasEnded,
  String? Function() cacheFolder = _inheritedCacheFolder,
  Future<int> Function(String cacheFolder, int serverId) remove =
      removeHalfWrittenFiles,
  Duration serverEndWait = _serverEndWait,
  Duration budget = analysisGuardEndBudget,
}) async {
  if (!serverEnded) return 0;
  try {
    final folder = cacheFolder();
    if (folder == null) return 0;
    while (!hasEnded(serverId)) {
      if (sinceEnding.elapsed >= serverEndWait) return 0;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final left = budget - sinceEnding.elapsed;
    if (left <= Duration.zero) return 0;
    return await remove(folder, serverId).timeout(left, onTimeout: () => 0);
  } on Object {
    // A clean-up that fails leaves the files; the guard still ends.
    return 0;
  }
}
