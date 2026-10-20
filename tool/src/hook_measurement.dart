import 'dart:convert';

import 'package:path/path.dart' as p;

import 'command_run.dart';
import 'edited_file.dart';
import 'warm_verify.dart';

/// Claude Code's PostToolUse input for an edit of [file] (a path from the
/// root with `/`) in the project at [project], from the session [sessionId]:
/// the fields Claude Code sends that `appstein verify --hook claude` reads
/// (`session_id`, `hook_event_name`), and the others it sends for a tool use,
/// so the run reads what a real one does.
String hookInput(
  String sessionId, {
  required String project,
  required String file,
}) => jsonEncode({
  'session_id': sessionId,
  'transcript_path': p.join(project, '.measure-transcript.jsonl'),
  'cwd': project,
  'hook_event_name': 'PostToolUse',
  'tool_name': 'Edit',
  'tool_input': {'file_path': projectFile(project, file).path},
  'tool_response': {'success': true},
});

/// Words that the text of a hook run cut by the cap holds: the reason of a
/// check that did not run because the cap cut the code analysis (the engine's
/// `capReason` ends with them).
const hookCutWords = 'still pending';

/// Words of the agent's context when `verify` could not run at all
/// (`claudeFailureReply`).
const _couldNotRun = 'could not run';

/// Whether [run] says its code checks were cut by the cap (spec: "The cap"):
/// a hook run keeps its own answer then, exit 0 or 2 with the errors the
/// other checks found, and tells the agent its code checks are pending.
bool hookCutByCap(CommandRun run) =>
    run.stdout.contains(hookCutWords) || run.stderr.contains(hookCutWords);

/// Why [run] is not the hook's answer to the error written to [file] at
/// [line], or null when it is: it must exit 2, and its stderr, which Claude
/// Code shows the agent, must name the file and report a `dart.error` on that
/// line. A fast hook that missed the change must fail the measurement,
/// however fast it was.
String? hookRunProblem(
  CommandRun run, {
  required String file,
  required int line,
}) {
  if (run.exitCode != 2) {
    return 'exit code ${run.exitCode}, expected 2 (the hook blocks on an '
        'error):\n${run.stdout}${run.stderr}';
  }
  final lines = run.stderr.split(RegExp(r'\r?\n'));
  if (!lines.any((text) => text.trim() == file)) {
    return 'its stderr does not name $file:\n${run.stderr}';
  }
  if (!lines.any((text) => text.contains('error dart.error (line $line)'))) {
    return 'its stderr does not report an error dart.error on line $line of '
        '$file:\n${run.stderr}';
  }
  return null;
}

/// Why [run], a hook run on a project with no error, does not show a host
/// that is ready, or null when it does: the code checks must not be cut by
/// the cap (the host is still starting), Appstein must not have failed, and
/// the run must exit 0.
String? hookNotReady(CommandRun run) {
  if (hookCutByCap(run)) {
    return 'the host is not ready: the run\'s code checks were cut by the '
        'cap:\n${run.stdout}${run.stderr}';
  }
  if (run.stdout.contains(_couldNotRun) || run.stderr.contains(_couldNotRun)) {
    return 'Appstein verify could not run:\n${run.stdout}${run.stderr}';
  }
  if (run.exitCode != 0) {
    return 'exit code ${run.exitCode}, expected 0 on a project with no '
        'error:\n${run.stdout}${run.stderr}';
  }
  return null;
}

/// The host-ready hook row: three runs of the hook with the project's
/// analysis host ready, each after an edit that adds an error.
final class WarmHookRow {
  /// The time of each run, in order; a run that failed is the last.
  final times = <Duration>[];

  /// Why the row can't be trusted, or null.
  String? problem;

  /// The middle time of [times] (the median of three once all ran).
  Duration get median => medianOf(times);
}

/// Measures the host-ready hook row: [count] times, add the error of edit
/// `firstEdit + i` to [file] of the project at [project] ([editWithError]:
/// a size and a line of its own each time), then run the hook with [run] and
/// time it. Each run has a session of its own, so the hook's "nothing
/// changed" rule (ticket 06) never makes a run silent, and each follows an
/// edit of its own, so it has something to check. Every run must exit 2 and
/// name the error ([hookRunProblem]); the first that does not ends the row
/// with [WarmHookRow.problem], whatever its time. The file is put back, also
/// when [run] throws.
Future<WarmHookRow> measureWarmHook({
  required Future<CommandRun> Function(String sessionId) run,
  required String project,
  required String file,
  int firstEdit = 6,
  int count = 3,
}) async {
  final row = WarmHookRow();
  final edited = EditedFile(project, file);
  try {
    for (var i = 0; i < count; i++) {
      final line = edited.addError(firstEdit + i);
      final result = await run('measure-hook-$i');
      row.times.add(result.elapsed);
      if (hookRunProblem(result, file: file, line: line) case final problem?) {
        return row..problem = 'run ${i + 1}: $problem';
      }
      edited.restore();
    }
    return row;
  } finally {
    edited.restore();
  }
}

/// The no-host row: the hook with no analysis host running and a warm
/// analysis cache (a new session, or after a host's idle stop), which is not
/// a cold-cache start.
final class NoHostHookRow {
  /// The run, once it ran.
  CommandRun? run;

  /// Whether the cap cut the run's code checks: the host was still starting
  /// when the time was up ([hookCutByCap]).
  bool reachedCap = false;

  /// Why the row can't be trusted, or null.
  String? problem;
}

/// Measures the no-host hook: one run of the hook with [run], after the error of
/// edit [edit] was added to [file], with no host running, so the run starts
/// one and waits for it. There is no limit but the cap: a run cut by it is a
/// result ([NoHostHookRow.reachedCap]), not a failure. A run that was not cut
/// must exit 2 and name the error ([hookRunProblem]), and one that was cut
/// must exit 0 or 2. The file is put back.
Future<NoHostHookRow> measureNoHostHook({
  required Future<CommandRun> Function(String sessionId) run,
  required String project,
  required String file,
  int edit = 9,
}) async {
  final row = NoHostHookRow();
  final edited = EditedFile(project, file);
  try {
    final line = edited.addError(edit);
    final result = row.run = await run('measure-hook-no-host');
    row.reachedCap = hookCutByCap(result);
    if (!row.reachedCap) {
      row.problem = hookRunProblem(result, file: file, line: line);
    } else if (result.exitCode != 0 && result.exitCode != 2) {
      row.problem =
          'a run cut by the cap exited ${result.exitCode}, expected 0 or '
          '2:\n${result.stdout}${result.stderr}';
    }
    return row;
  } finally {
    edited.restore();
  }
}

/// Waits until the analysis host a hook started is ready: runs the hook with
/// [run] on a project with no error, up to [attempts] times with [pause]
/// between, each with a session of its own so every run checks, until one is
/// not cut by the cap and Appstein did not fail ([hookNotReady]). Returns
/// null when the host is ready, else why the last run was not.
Future<String?> waitUntilHostReady({
  required Future<CommandRun> Function(String sessionId) run,
  int attempts = 6,
  Duration pause = const Duration(seconds: 1),
}) async {
  String? last;
  for (var i = 0; i < attempts; i++) {
    last = hookNotReady(await run('measure-hook-ready-$i'));
    if (last == null) return null;
    if (i + 1 < attempts) await Future<void>.delayed(pause);
  }
  return 'the analysis host was not ready after $attempts hook runs; the '
      'last: $last';
}
