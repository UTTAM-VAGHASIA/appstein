import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';

import 'child_processes.dart';

/// The process ID of the analysis host the address file of [project] in
/// [folder] names; null when there is no address file.
int? hostProcess(String folder, String project) => readAnalysisHostAddress(
  analysisHostAddressFile(folder, project),
)?.processId;

/// Kills the analysis host the address file of [project] in [folder] names,
/// and what runs under it (its guard and analysis server), and waits until
/// they have ended: a test leaves no host running. A host that has ended
/// already is left alone.
Future<void> killHost(String folder, String project) async {
  final host = hostProcess(folder, project);
  if (host == null || !await processAlive(host)) return;
  final under = await processesUnder(host);
  await recordProcesses(under);
  Process.killPid(host, ProcessSignal.sigkill);
  if (await goneWithin([host, ...under], const Duration(seconds: 20)) == null) {
    for (final id in under) {
      if (await processAlive(id)) Process.killPid(id, ProcessSignal.sigkill);
    }
  }
}
