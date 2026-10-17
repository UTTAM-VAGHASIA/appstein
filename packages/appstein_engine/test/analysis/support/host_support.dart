import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/temp.dart';
import 'analysis_support.dart';

/// An analysis host for the project at [app], as the engine's tests start
/// it (`host_main.dart`): its own address-file folder and analysis cache,
/// and [idle] as its idle time. Every host it starts is killed after the
/// test, with what runs under it.
///
/// [folder] is the address-file folder when given; [readyTimeout] and
/// [answerGrace] shorten how long the client waits for an answer.
({CodeAnalysisScope scope, String folder}) testHost(
  String app, {
  Duration idle = const Duration(minutes: 10),
  List<String>? hostCommand,
  String? folder,
  Duration readyTimeout = analysisReadyTimeout,
  Duration answerGrace = analysisHostAnswerGrace,
  Duration turnLimit = analysisHostTurnLimit,
}) {
  folder ??= p.join(tempDir().path, 'host folder');
  final environment = testAnalysisEnvironment();
  addTearDown(() => killHosts(folder!, app));
  return (
    scope: analysisHostCodeAnalysis(
      projectRoot: app,
      readyTimeout: readyTimeout,
      answerGrace: answerGrace,
      turnLimit: turnLimit,
      hostCommand:
          hostCommand ??
          [
            Platform.resolvedExecutable,
            analysisSupportFile('host_main.dart'),
            folder,
            testDart,
            '${idle.inMilliseconds}',
          ],
      addressFolder: folder,
      appsteinVersion: 'test',
      environment: environment,
    ),
    folder: folder,
  );
}

/// The process ID of the host the address file of [app] in [folder] names;
/// null when there is no address file.
int? hostProcess(String folder, String app) =>
    readAnalysisHostAddress(analysisHostAddressFile(folder, app))?.processId;

/// Kills the host the address file of [app] in [folder] names, and what
/// runs under it, and waits until they have ended: a test leaves nothing
/// running.
Future<void> killHosts(String folder, String app) async {
  final host = hostProcess(folder, app);
  // A stand-in host in the test's own process is never killed.
  if (host == null || host == pid || !await processAlive(host)) return;
  final under = await processesUnder(host);
  await recordProcesses(under);
  Process.killPid(host, ProcessSignal.sigkill);
  if (await goneWithin([host, ...under], const Duration(seconds: 20)) == null) {
    for (final id in under) {
      if (await processAlive(id)) Process.killPid(id, ProcessSignal.sigkill);
    }
  }
}

/// The running processes under [root]: its children, theirs and so on.
Future<Set<int>> processesUnder(int root) async {
  final ProcessResult list;
  if (Platform.isWindows) {
    list = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Get-CimInstance Win32_Process | '
          r'ForEach-Object { "$($_.ProcessId) $($_.ParentProcessId)" }',
    ]);
  } else {
    list = await Process.run('ps', ['-A', '-o', 'pid=,ppid=']);
  }
  final byParent = <int, List<int>>{};
  for (final line in '${list.stdout}'.split('\n')) {
    final words = line.trim().split(RegExp(r'\s+'));
    if (words.length != 2) continue;
    final id = int.tryParse(words[0]);
    final parent = int.tryParse(words[1]);
    if (id == null || parent == null || id == list.pid) continue;
    (byParent[parent] ??= []).add(id);
  }
  final under = <int>{};
  final queue = [root];
  while (queue.isNotEmpty) {
    for (final child in byParent[queue.removeLast()] ?? const <int>[]) {
      if (child != root && under.add(child)) queue.add(child);
    }
  }
  return under;
}
