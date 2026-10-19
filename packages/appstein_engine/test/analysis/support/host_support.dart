import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/temp.dart';
import 'analysis_support.dart';

/// An analysis host for the project at [app], as the engine's tests start
/// it (`host_main.dart`): its own address-file folder and analysis cache,
/// and [idle] as its idle time. Every host it starts is killed after the
/// test, with what runs under it: every host the test's clients started
/// (one that lost a race, one of another version), which each note their
/// process ID and start in [startedHosts].
///
/// [folder] is the address-file folder when given; [readyTimeout] and
/// [answerGrace] shorten how long the client waits for an answer.
/// [version] is the Appstein version of the client and of the hosts it
/// starts. [dartFrom] is a file that holds the path of the `dart` that runs
/// the server (`host_main.dart`'s `--dart-from`). A run whose host is newer
/// asks a real analysis server of its own, with the tests' SDK. [connect]
/// replaces the connection to the host's port.
({CodeAnalysisScope scope, String folder}) testHost(
  String app, {
  Duration idle = const Duration(minutes: 10),
  List<String>? hostCommand,
  String? folder,
  Duration readyTimeout = analysisReadyTimeout,
  Duration answerGrace = analysisHostAnswerGrace,
  Duration turnLimit = analysisHostTurnLimit,
  String version = 'test',
  String? dartFrom,
  Future<Socket> Function(int port)? connect,
}) {
  folder ??= p.join(tempDir().path, 'host folder');
  final environment = testAnalysisEnvironment();
  addTearDown(() => killHosts(folder!));
  return (
    scope: analysisHostCodeAnalysis(
      projectRoot: app,
      readyTimeout: readyTimeout,
      answerGrace: answerGrace,
      turnLimit: turnLimit,
      connect: connect,
      hostCommand:
          hostCommand ??
          [
            Platform.resolvedExecutable,
            analysisSupportFile('host_main.dart'),
            folder,
            testDart,
            '${idle.inMilliseconds}',
            version,
            startedHosts(folder),
            if (dartFrom != null) '--dart-from=$dartFrom',
          ],
      addressFolder: folder,
      appsteinVersion: version,
      ownServer: () => AnalysisServer(
        projectRoot: app,
        guardCommand: testGuardCommand,
        dartExecutable: () => testDart,
        environment: environment,
      ),
      environment: environment,
    ),
    folder: folder,
  );
}

/// The file the hosts started for the address-file folder [folder] note
/// their process IDs and starts in, one host a line (`<id>\t<start>`):
/// beside the folder, so the folder holds only what the hosts write.
String startedHosts(String folder) => '$folder.started';

/// The hosts started for [folder], in the order they started: each one's
/// process ID, and its start as `lookUpProcess` told it then.
List<({int id, String start})> _startedHosts(String folder) {
  final file = File(startedHosts(folder));
  if (!file.existsSync()) return const [];
  return [
    for (final line in file.readAsLinesSync())
      if (line.split('\t') case [
        final id,
        final start,
      ] when int.tryParse(id) != null)
        (id: int.parse(id), start: start),
  ];
}

/// The process IDs of the hosts started for [folder], in the order they
/// started.
List<int> startedHostProcesses(String folder) => [
  for (final host in _startedHosts(folder)) host.id,
];

/// The process ID of the host the address file of [app] in [folder] names;
/// null when there is no address file.
int? hostProcess(String folder, String app) =>
    readAnalysisHostAddress(analysisHostAddressFile(folder, app))?.processId;

/// Kills the hosts started for [folder] ([startedHosts]) and what runs under
/// them, and waits until they have ended: a test leaves nothing running.
///
/// It kills only what it can show this test started. By the end of a test
/// a host that ended (one that lost a race) may have had its ID given to
/// another program, so a host is killed only while the process under its
/// ID has the start the host noted itself; and what runs under it is
/// killed later only while each process still is the one seen under it
/// (`lookUpProcess`: its ID, start and program).
Future<void> killHosts(String folder) async {
  for (final (:id, :start) in _startedHosts(folder)) {
    // A stand-in host in the test's own process is never killed.
    if (id == pid) continue;
    final seen = identityOf(id);
    if (seen == null || seen.start != start) continue;
    final under = {
      for (final child in await processesUnder(id)) child: ?identityOf(child),
    };
    await recordProcesses(under.keys);
    Process.killPid(id, ProcessSignal.sigkill);
    if (await goneWithin([id, ...under.keys], const Duration(seconds: 20)) ==
        null) {
      for (final MapEntry(key: child, value: who) in under.entries) {
        if (identityOf(child) == who) {
          Process.killPid(child, ProcessSignal.sigkill);
        }
      }
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
