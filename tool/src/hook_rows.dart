import 'command_run.dart';
import 'hook_measurement.dart';
import 'mcp_session.dart';
import 'process_memory.dart';
import 'sharing_check.dart';

/// What the hook measurement found.
final class HookResults {
  /// The hook with no host running and a warm analysis cache, once it ran.
  NoHostHookRow? noHost;

  /// The hook with the host ready, once it ran.
  WarmHookRow? hostReady;

  /// The sharing check, once it ran.
  SharingResult? sharing;

  /// Why the measurement can't be trusted or failed, or null. When it is
  /// null, [hostReady] is set.
  String? problem;
}

/// The hook where an agent meets it (spec §9.1, §15), in order, on the
/// project at [project] where [file] is a Dart file (a path with `/`):
///
/// 1. the hook with **no host running and a warm analysis cache**, once
///    ([measureNoHostHook]): it starts a host and waits, with no limit but the
///    cap. Not a cold-cache start: the cache is the one the earlier rows
///    warmed, the everyday case of a new session or a host's idle stop;
/// 2. the host is waited for until a hook run on the clean project is not cut
///    by the cap ([waitUntilHostReady]), then three hook runs with the host
///    ready ([measureWarmHook]);
/// 3. the host is ended with [endHosts] (which says why it could not), and
///    the sharing check runs ([measureSharing]), which ends its own host too.
///
/// [run] runs the hook for a session ID, [startSession] starts an
/// `appstein mcp`, [hostIds] gives the IDs of the hosts with an address
/// file, and [lister] lists the processes. A run that can't be trusted ends
/// the measurement with [HookResults.problem], after the host it started is
/// ended; the sharing check does not run after a problem, or when the host
/// could not be ended. [pause] is how long the wait for the host sleeps
/// between its runs, and [clock] gives the time for the sharing check
/// ([measureSharing]).
Future<HookResults> measureHookRows({
  required Future<CommandRun> Function(String sessionId) run,
  required Future<McpSession> Function() startSession,
  required List<int> Function() hostIds,
  required Future<String?> Function() endHosts,
  required String project,
  required String file,
  ProcessLister lister = listProcesses,
  Duration pause = const Duration(seconds: 1),
  int Function() clock = nowMilliseconds,
}) async {
  final results = HookResults();
  String? ended;
  try {
    if (hostIds().isNotEmpty) {
      return results
        ..problem = 'an analysis host was running before the hook with no host';
    }
    final noHost = results.noHost = await measureNoHostHook(
      run: run,
      project: project,
      file: file,
    );
    if (noHost.problem case final problem?) {
      return results..problem = 'the hook with no host running: $problem';
    }
    if (await waitUntilHostReady(run: run, pause: pause) case final problem?) {
      return results..problem = problem;
    }
    final ready = results.hostReady = await measureWarmHook(
      run: run,
      project: project,
      file: file,
    );
    if (ready.problem case final problem?) {
      return results..problem = 'the hook with the host ready, $problem';
    }
  } on Object catch (error) {
    // A StateError carries its own message; anything else (a process that
    // cannot be started, a file that cannot be written) fails the row too,
    // so the tables still print.
    return results..problem = reasonOf(error);
  } finally {
    ended = await endHosts();
    if (ended != null) {
      results.problem = [?results.problem, ended].join('; ');
    }
  }
  if (ended != null) return results;
  final sharing = results.sharing = await measureSharing(
    startSession: startSession,
    runHook: run,
    hostIds: hostIds,
    endHosts: endHosts,
    lister: lister,
    clock: clock,
  );
  if (sharing.problem case final problem?) {
    results.problem = 'the sharing check: $problem';
  }
  return results;
}
