import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';

import 'child_processes.dart';

/// Who runs under the process ID [id] now, as the product asks it
/// (`lookUpProcess`); null when nothing does or it can't be told.
ProcessIdentity? _identityOf(int id) => switch (lookUpProcess(id)) {
  ProcessRunning(:final identity) => identity,
  _ => null,
};

/// The host each address file named when a test first looked, by the file:
/// who ran under its process ID then. A host that dies hard leaves its file,
/// and its ID can be given to another program, so [killHost] kills only a
/// process that still is the one seen.
final _seenHosts = <String, ProcessIdentity>{};

/// The process ID of the analysis host the address file of [project] in
/// [folder] names; null when there is no address file. The first time it
/// finds a host running it notes who that is, for [killHost].
int? hostProcess(String folder, String project) {
  final file = analysisHostAddressFile(folder, project);
  final id = readAnalysisHostAddress(file)?.processId;
  if (id != null) {
    final seen = _identityOf(id);
    if (seen != null) _seenHosts.putIfAbsent(file, () => seen);
  }
  return id;
}

/// Kills the analysis host the address file of [project] in [folder] names,
/// and what runs under it (its guard and analysis server), and waits until
/// they have ended: a test leaves no host running. A host that has ended
/// already is left alone.
///
/// It kills only what it can show this test started: the process under the
/// host's ID must be the one [hostProcess] saw (or, when the test never
/// looked, a program of the same kind as the host's: `dart` or `appstein`),
/// and what runs under it is killed later only while each process still is
/// the one seen under it.
Future<void> killHost(String folder, String project) async {
  final file = analysisHostAddressFile(folder, project);
  final host = hostProcess(folder, project);
  final known = _seenHosts.remove(file);
  if (host == null) return;
  final now = _identityOf(host);
  if (now == null || (known != null && now != known)) return;
  if (known == null && !_isOurKind(now.image)) return;
  final under = {
    for (final child in await processesUnder(host)) child: _identityOf(child),
  };
  await recordProcesses(under.keys);
  Process.killPid(host, ProcessSignal.sigkill);
  if (await goneWithin([host, ...under.keys], const Duration(seconds: 20)) ==
      null) {
    for (final MapEntry(key: child, value: who) in under.entries) {
      if (who != null && _identityOf(child) == who) {
        Process.killPid(child, ProcessSignal.sigkill);
      }
    }
  }
}

/// Whether [image] (a program's path or name) is `dart` or `appstein`.
bool _isOurKind(String image) {
  final name = image.split(RegExp(r'[\\/]')).last.toLowerCase();
  return name.startsWith('dart') || name.startsWith('appstein');
}
