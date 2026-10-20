import 'command_run.dart';
import 'hook_measurement.dart';
import 'mcp_session.dart';
import 'process_memory.dart';
import 'warm_verify.dart';

/// The analysis servers in [rows], found by their place in the process tree
/// and not by anyone's name (the Dart VM may name the compiled binary after
/// its script, `dart:<script>`, so the host, the guard and the server can all
/// read as Dart programs): the Dart programs ([dartPrograms]) that
/// - started at or after [since] (milliseconds since the epoch, to within two
///   seconds, the precision of a listing; a process whose start the listing
///   did not give counts), so servers that other programs on the machine run
///   don't count; and
/// - are inside the process tree of one of the **roots**: [roots] (the
///   analysis hosts and the sessions of the check), and every **orphan** that
///   started since the check began, that is, a process whose parent is not
///   running or is process 1. An orphan is what a process of this check leaves
///   when it ends (the hook), or a host nobody knows an address of; its tree
///   is looked into, so a second host's server is seen; and
/// - are not one of [roots], and are not under another Dart program (a Dart
///   program that hands its script to a VM child is one server), **unless
///   that program is one of [roots]**: when the VM names the host and the
///   guard alike, the guard is a Dart program under a Dart program that is
///   the host, and is the top one of its tree.
List<ProcessRow> analysisServerRows(
  List<ProcessRow> rows, {
  required int since,
  required Iterable<int> roots,
}) {
  final byId = {for (final row in rows) row.id: row};
  final rootIds = roots.toSet();
  bool isDart(ProcessRow? row) =>
      row != null && dartPrograms.contains(programOf(row));
  bool recent(ProcessRow row) =>
      row.start == null || row.start! >= since - 2000;
  bool orphan(ProcessRow row) =>
      row.parent <= 1 || !byId.containsKey(row.parent);
  final searched = <int>{
    ...rootIds,
    for (final row in rows)
      if (orphan(row) && recent(row)) row.id,
  };
  final inTrees = <int>{
    for (final root in searched) ...processTree(rows, root),
  };
  return [
    for (final row in rows)
      if (isDart(row) &&
          !rootIds.contains(row.id) &&
          recent(row) &&
          inTrees.contains(row.id) &&
          (!isDart(byId[row.parent]) || rootIds.contains(row.parent)))
        row,
  ];
}

/// Why [rows] do not show exactly one analysis server for the project, kept
/// by exactly one host, or null when they do: the host IDs [hostIds] (from
/// the address files) must be one, that process must be running, exactly one
/// analysis server must be running that started at or after [since]
/// ([analysisServerRows], looking in the trees of the host, of the
/// [sessionIds] and of the orphans that started since), and it must be under
/// the host.
String? sharingProblem(
  List<ProcessRow> rows, {
  required List<int> hostIds,
  List<int> sessionIds = const [],
  required int since,
}) {
  final problems = <String>[];
  if (hostIds.length != 1) {
    problems.add(
      '${hostIds.length} analysis hosts have an address file, expected '
      'exactly 1${hostIds.isEmpty ? '' : ' (${hostIds.join(', ')})'}',
    );
  } else if (!rows.any((row) => row.id == hostIds.single)) {
    problems.add(
      'the analysis host (process ${hostIds.single}) is not running',
    );
  }
  final servers = analysisServerRows(
    rows,
    since: since,
    roots: [...hostIds, ...sessionIds],
  );
  if (servers.length != 1) {
    problems.add(
      '${servers.length} analysis servers are running'
      '${servers.isEmpty ? '' : ' (${servers.map((row) => row.id).join(', ')})'}'
      ', expected exactly 1',
    );
  } else if (hostIds.length == 1 &&
      !processTree(rows, hostIds.single).contains(servers.single.id)) {
    problems.add(
      'the analysis server (process ${servers.single.id}) is not under the '
      'analysis host (process ${hostIds.single}): a session runs a server of '
      'its own',
    );
  }
  return problems.isEmpty ? null : problems.join('; ');
}

/// What the sharing check found.
final class SharingResult {
  /// Why the check failed or can't be trusted, or null.
  String? problem;

  /// The memory of one `appstein mcp` after its `verify` call, with the
  /// analysis host and the server under it: the processes of the session and
  /// the host, each once.
  int memoryOne = 0;

  /// The memory of two `appstein mcp` sessions and the host, after both
  /// called `verify` and a hook ran.
  int memoryTwo = 0;

  /// The analysis servers running at the end, when the check got that far.
  int servers = 0;

  /// The analysis hosts with an address file at the end.
  int hosts = 0;
}

/// Checks that sessions share one analysis server (spec: "Measuring"): with
/// no host running, [startSession] starts a first `appstein mcp`, which calls
/// `verify` (so a host is started); the memory of that session, the host and
/// the server is taken ([SharingResult.memoryOne]). A second session then
/// calls `verify`, and a hook runs with [runHook]; the memory of both
/// sessions and the host is taken again ([SharingResult.memoryTwo]).
///
/// After each step the processes are listed with [lister]. The check fails
/// ([SharingResult.problem]) unless exactly one analysis host has an address
/// ([hostIds]) and exactly one analysis server is running, under that host
/// ([sharingProblem]). A host that was running before the check fails it
/// too, since it could not show who started the server. Both sessions are
/// closed and the hosts are ended with [endHosts] (which returns why it
/// could not), whatever the outcome; a session that did not end by itself is
/// killed and fails the check. [clock] gives the time, in milliseconds since
/// the epoch.
Future<SharingResult> measureSharing({
  required Future<McpSession> Function() startSession,
  required Future<CommandRun> Function(String sessionId) runHook,
  required List<int> Function() hostIds,
  required Future<String?> Function() endHosts,
  ProcessLister lister = listProcesses,
  int Function() clock = nowMilliseconds,
}) async {
  final result = SharingResult();
  if (hostIds().isNotEmpty) {
    return result
      ..problem =
          'an analysis host was already running before the check, so it '
          'could not show which session started the server';
  }
  final since = clock();
  final sessions = <McpSession>[];
  var allEnded = true;
  Future<String?> verifyOn(McpSession session) async {
    final call = await session.call('verify', const {'scope': 'fast'});
    return unexpectedError(call.result);
  }

  String? problemWith(List<ProcessRow> rows) => sharingProblem(
    rows,
    hostIds: hostIds(),
    sessionIds: [for (final session in sessions) session.pid],
    since: since,
  );

  try {
    final first = await startSession();
    sessions.add(first);
    if (await verifyOn(first) case final problem?) {
      return result..problem = 'the first session\'s verify call: $problem';
    }
    var rows = await lister();
    if (problemWith(rows) case final problem?) {
      return result..problem = 'with one session: $problem';
    }
    result.memoryOne = treesMemory(rows, [first.pid, ...hostIds()]);

    final second = await startSession();
    sessions.add(second);
    if (await verifyOn(second) case final problem?) {
      return result..problem = 'the second session\'s verify call: $problem';
    }
    if (hookNotReady(await runHook('measure-hook-sharing'))
        case final problem?) {
      return result..problem = 'the hook of the sharing check: $problem';
    }
    rows = await lister();
    result
      ..hosts = hostIds().length
      ..servers = analysisServerRows(
        rows,
        since: since,
        roots: [...hostIds(), for (final session in sessions) session.pid],
      ).length;
    if (problemWith(rows) case final problem?) {
      return result..problem = 'with two sessions and a hook: $problem';
    }
    result.memoryTwo = treesMemory(rows, [first.pid, second.pid, ...hostIds()]);
    return result;
  } on Object catch (error) {
    return result..problem = reasonOf(error);
  } finally {
    for (final session in sessions) {
      if (!await session.close()) allEnded = false;
    }
    final stopped = await endHosts();
    final problems = [
      ?result.problem,
      if (!allEnded)
        'appstein mcp did not end when its input closed, and was killed',
      ?stopped,
    ];
    result.problem = problems.isEmpty ? null : problems.join('; ');
  }
}

/// The time now, in milliseconds since the epoch.
int nowMilliseconds() => DateTime.now().millisecondsSinceEpoch;
