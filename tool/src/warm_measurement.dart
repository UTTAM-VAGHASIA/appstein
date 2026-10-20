import 'edited_file.dart';
import 'mcp_session.dart';
import 'process_memory.dart';
import 'warm_verify.dart';

List<int> _noHosts() => const [];

/// What the warm `verify` measurement found.
final class WarmResult {
  /// Why the measurement can't be trusted, or null.
  String? problem;

  /// The first `verify` call, which starts the analysis server and waits
  /// for it before it reads.
  Duration startUp = Duration.zero;

  /// The memory of `appstein mcp` and the processes under it (the guard and
  /// the analysis server) after the first call, and after the last.
  int memoryReady = 0;

  /// See [memoryReady].
  int memoryAfter = 0;

  /// Three calls of `verify` with the fast scope, each straight after an
  /// edit that adds an error.
  final fast = <Duration>[];

  /// Three calls straight after the error is fixed.
  final fixed = <Duration>[];

  /// Three more edits, each followed by an `overview` call (which refreshes
  /// the knowledge, as every tool does) and then by a `verify` call that has
  /// nothing left to refresh: where the time of the call above goes.
  final refresh = <Duration>[];

  /// See [refresh].
  final afterRefresh = <Duration>[];
}

/// Measures the warm `verify` tool of the `appstein mcp` that [session] talks
/// to, on the project at [project]. [file] is a Dart file of it, as a path
/// from the root with `/`.
///
/// 1. The first `verify` call (fast scope) starts the analysis server and
///    waits for it. It is the start-up time, and the project has no error.
/// 2. Three times: add a real error to [file] ([editWithError]), call
///    `verify` and time it, and require a `dart.error` on [file] at the line
///    written; restore the file, call `verify` again, and require that the
///    error is gone.
/// 3. Three times more: the same edit, then an `overview` call (the
///    knowledge refresh) and a `verify` call timed apart, the error required
///    again; restore the file, call `verify`, and require the error gone
///    again. So a reply left over from an earlier edit fails in either loop.
///
/// Then it closes the session and checks that it ended by itself and that no
/// process of its tree ([processTree]) is left, by ID and by start so that
/// another program given a process's ID doesn't count ([survivors]),
/// looking up to [goneAttempts] times, [goneDelay] apart. [closePatience] is
/// how long the session may take to end ([McpSession.close]). Nothing is
/// ended here but the session's own process: a leftover is a bug to find.
///
/// The session's `verify` calls go through the project's analysis host, a
/// detached process that outlives the session by design (decision record
/// 0002). [hostProcesses] gives the IDs of the hosts the session started,
/// whose trees (the host, its guard and the server) count with the session's
/// for the memory and for the check that nothing is left, and [endHosts]
/// ends them after the session is closed and returns why it could not, or
/// null: the one process this function lets the caller end besides the
/// session's own. Without them the session has no host.
///
/// The file is put back as it was. A failed check, a reply that is wrong or
/// a call that gets no answer is [WarmResult.problem], never an exception.
Future<WarmResult> measureWarm(
  McpSession session, {
  required String project,
  required String file,
  ProcessLister lister = listProcesses,
  int goneAttempts = 20,
  Duration goneDelay = const Duration(milliseconds: 500),
  Duration? closePatience,
  List<int> Function() hostProcesses = _noHosts,
  Future<String?> Function()? endHosts,
}) async {
  final warm = WarmResult();
  final edited = EditedFile(project, file);
  // Every process seen under the session, with the start it had when first
  // seen: what the check that nothing is left running compares with.
  final tree = <int, int?>{};
  void note(List<ProcessRow> rows) {
    for (final MapEntry(:key, :value) in treesStarts(rows, [
      session.pid,
      ...hostProcesses(),
    ]).entries) {
      tree.putIfAbsent(key, () => value);
    }
  }

  int addError(int n) => edited.addError(n);

  void fixError() => edited.restore();

  Future<McpCall> verify() => session.call('verify', const {'scope': 'fast'});

  /// Fixes edit [n], calls `verify` and returns why the reply is wrong, or
  /// null when it reports no error on the file. The time is recorded only
  /// for [timed] calls.
  Future<String?> checkFixed(int n, {required bool timed}) async {
    fixError();
    final fixed = await verify();
    if (timed) warm.fixed.add(fixed.elapsed);
    if (unexpectedError(fixed.result, file: file) case final problem?) {
      return 'after fixing edit $n: $problem';
    }
    return null;
  }

  try {
    // The first call starts the server and waits until it is ready; the
    // project has no error yet.
    final first = await session.call('verify', const {'scope': 'fast'});
    warm.startUp = first.elapsed;
    if (unexpectedError(first.result) case final problem?) {
      return warm..problem = 'the first verify call: $problem';
    }
    final ready = await lister();
    warm.memoryReady = treesMemory(ready, [session.pid, ...hostProcesses()]);
    note(ready);

    for (var n = 0; n < 3; n++) {
      final line = addError(n);
      final call = await verify();
      warm.fast.add(call.elapsed);
      if (missedError(call.result, file: file, line: line)
          case final problem?) {
        return warm..problem = 'edit $n: $problem';
      }
      if (await checkFixed(n, timed: true) case final problem?) {
        return warm..problem = problem;
      }
    }
    for (var n = 3; n < 6; n++) {
      final line = addError(n);
      final refresh = await session.call('overview', const {});
      if (refresh.isError) {
        return warm..problem = 'overview after edit $n answered with an error';
      }
      warm.refresh.add(refresh.elapsed);
      final call = await verify();
      warm.afterRefresh.add(call.elapsed);
      if (missedError(call.result, file: file, line: line)
          case final problem?) {
        return warm..problem = 'edit $n: $problem';
      }
      if (await checkFixed(n, timed: false) case final problem?) {
        return warm..problem = problem;
      }
    }
    final after = await lister();
    warm.memoryAfter = treesMemory(after, [session.pid, ...hostProcesses()]);
    note(after);
    return warm;
  } on StateError catch (error) {
    return warm..problem = error.message;
  } finally {
    fixError();
    // However the measurement ended (a first call that hangs or fails is
    // when a guard and a server are most likely left behind), the tree is
    // listed once more before the session is closed.
    String? listingProblem;
    try {
      note(await lister());
    } on StateError catch (error) {
      listingProblem =
          'could not list the processes of appstein mcp before closing it: '
          '${error.message}';
    }
    final byItself = closePatience == null
        ? await session.close()
        : await session.close(patience: closePatience);
    // The analysis host outlives the session by design, so the tool ends it
    // itself; its guard and server follow it.
    final hostsProblem = endHosts == null ? null : await endHosts();
    // Everything that was under it must be gone, which takes the guard a
    // moment after `appstein mcp` ends.
    final gone = await waitUntilGone(
      tree,
      lister,
      attempts: goneAttempts,
      delay: goneDelay,
    );
    final problems = [
      ?warm.problem,
      if (!byItself)
        'appstein mcp did not end when its input closed, and was killed',
      ?hostsProblem,
      ?listingProblem,
      ?gone.listingProblem,
      if (gone.listingProblem == null && gone.left.isNotEmpty)
        stillRunningProblem('appstein mcp', gone.left),
    ];
    warm.problem = problems.isEmpty ? null : problems.join('; ');
  }
}
