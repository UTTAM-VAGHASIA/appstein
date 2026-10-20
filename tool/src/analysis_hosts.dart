import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart'
    show readAnalysisHostAddress;
import 'package:path/path.dart' as p;

import 'process_memory.dart';

/// An analysis host as its address file names it: its process ID, and when
/// the file was written (a host writes it a moment after it starts, so the
/// host started before that).
typedef HostRecord = ({int processId, DateTime written});

/// The hosts that have an address file in [folder] (`host-<hash>.json`, the
/// engine's `analysisHostAddressFile`), whether or not they still run. A file
/// that can't be read as an address is left out. Empty when the folder does
/// not exist.
List<HostRecord> hostRecords(String folder) {
  final directory = Directory(folder);
  if (!directory.existsSync()) return const [];
  return [
    for (final file in directory.listSync().whereType<File>())
      if (_isAddressFile(file.path))
        if (readAnalysisHostAddress(file.path) case final address?)
          (processId: address.processId, written: file.lastModifiedSync()),
  ];
}

/// The process IDs of the hosts of [hostRecords].
List<int> hostProcessIds(String folder) => [
  for (final host in hostRecords(folder)) host.processId,
];

bool _isAddressFile(String path) {
  final name = p.basename(path);
  return name.startsWith('host-') && name.endsWith('.json');
}

/// Ends the process [pid]. Returns false when it could not be ended.
bool killProcess(int pid) => Process.killPid(pid);

/// How far a process's start, as a listing gives it (to the second), may lie
/// after the time its address file was written and still be the host.
const _hostStartTolerance = Duration(seconds: 2);

/// Ends every analysis host that has an address file in [folder], and checks
/// that nothing of it is left. A host outlives the session that started it by
/// design (it ends itself after 10 minutes with no question), so a measuring
/// tool that started one ends it itself: it kills the host with [kill], and
/// the host's end closes its guard's input, so the guard ends the analysis
/// server and cleans up after it (decision record 0002).
///
/// **A process ID is killed only while it still belongs to the host.** The
/// system gives the ID of an ended process to a new program (Windows within
/// seconds), and a host that died leaves its address file. The host started
/// before it wrote the file, so a process listed with [lister] that started
/// more than two seconds (the precision of a listing) after the file was
/// written is not the host and is not killed; neither is a process whose
/// start the listing does not give, which cannot be shown to be the host.
/// Both are reported. A listing that fails kills nothing. A host that is not
/// running needs no kill.
///
/// The tree of each host that is ended (its guard and the server under it,
/// found by ID and start together as the rest of the tool does:
/// [treeStarts]) is looked for up to [goneAttempts] times, [goneDelay] apart,
/// afterwards ([survivors]). The address files are then deleted, so the next
/// client does not take them for a host that died. Returns null when there
/// was nothing to end or everything ended, else why not: a process left
/// running, a process not killed, or a listing that failed, with the command
/// to end a process by hand.
Future<String?> stopHosts(
  String folder, {
  ProcessLister lister = listProcesses,
  bool Function(int pid) kill = killProcess,
  int goneAttempts = 20,
  Duration goneDelay = const Duration(milliseconds: 500),
}) async {
  final hosts = hostRecords(folder);
  if (hosts.isEmpty) return null;
  final problems = <String>[];
  // The hosts that are running and are shown to be the hosts, and the hosts
  // that have ended (whose guard and server may still be on their way out).
  final ending = <int>[];
  var tree = <int, int?>{};
  try {
    final rows = await lister();
    for (final host in hosts) {
      final row = rows.where((row) => row.id == host.processId).firstOrNull;
      if (row == null) {
        ending.add(host.processId);
      } else if (row.start == null) {
        problems.add(
          'process ${host.processId} cannot be shown to be the analysis host '
          '(the process list gives no start for it), so it was not ended',
        );
      } else if (row.start! >
          host.written.millisecondsSinceEpoch +
              _hostStartTolerance.inMilliseconds) {
        problems.add(
          'process ${host.processId} is not the analysis host any more (it '
          'started after the address file was written, so the ID of a host '
          'that ended was given to another program), so it was not ended',
        );
      } else {
        ending.add(host.processId);
        kill(host.processId);
      }
    }
    tree = treesStarts(rows, ending);
  } on StateError catch (error) {
    problems.add(
      'could not list the processes of the analysis host before ending it, '
      'so nothing was ended: ${error.message}',
    );
  }
  final gone = await waitUntilGone(
    tree,
    lister,
    attempts: goneAttempts,
    delay: goneDelay,
  );
  if (gone.listingProblem case final problem?) {
    problems.add(problem);
  } else if (gone.left.isNotEmpty) {
    problems.add(stillRunningProblem('the analysis host', gone.left));
  }
  for (final file in Directory(folder).listSync().whereType<File>()) {
    if (!_isAddressFile(file.path)) continue;
    try {
      file.deleteSync();
    } on FileSystemException {
      // The folder goes with the tool's work folder.
    }
  }
  return problems.isEmpty ? null : problems.join('; ');
}
