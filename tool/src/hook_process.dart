import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'command_run.dart';
import 'measure_context.dart';

/// How long a hook run may take before it is killed and the row fails.
const hookRunLimit = Duration(seconds: 120);

/// How long a hook's output may stay open after the process ended before the
/// row fails.
const hookOutputPatience = Duration(seconds: 10);

/// The arguments of the hook Claude Code runs after an edit.
const hookArguments = ['verify', '--fast', '--hook', 'claude'];

/// Runs the compiled `appstein verify --fast --hook claude` once, the way
/// Claude Code's PostToolUse hook does: from the project's folder, with
/// [input] (an edit's input, `hookInput`) on stdin, and the analysis server's
/// disk cache in [cache].
///
/// **The time** runs from before the process starts until the process has
/// exited **and** its stdout and stderr have both closed, whichever is later
/// (owner decision, 2026-10-21): that is what Claude Code waits for, and a
/// process the hook started that holds its output open (the analysis host is
/// started detached) would hold Claude Code up.
///
/// Throws a [StateError], which the row reports, when:
/// - the process cannot be started;
/// - its output fails to be read;
/// - the process has not exited after [limit]: it is killed;
/// - its output is still open [outputPatience] after it exited.
Future<CommandRun> runHook(
  MeasureContext context, {
  required String cache,
  required String input,
  Duration limit = hookRunLimit,
  Duration outputPatience = hookOutputPatience,
}) async {
  final watch = Stopwatch()..start();
  final Process process;
  try {
    process = await context.start(
      context.executable,
      hookArguments,
      workingDirectory: context.project,
      environment: context.environment(cache),
    );
  } on ProcessException catch (error) {
    throw StateError(
      'could not start the hook ${context.executable}: ${error.message}',
    );
  }
  final output = Future.wait([
    process.stdout.transform(utf8.decoder).join(),
    process.stderr.transform(utf8.decoder).join(),
  ]);
  // A pipe that breaks after the hook was killed (or after this function
  // threw for another reason) must not be an error nobody listens to.
  output.ignore();
  try {
    process.stdin.write(input);
    await process.stdin.close();
  } on Object {
    // A hook that ended before it read its input: its exit code says why.
  }
  final int code;
  try {
    code = await process.exitCode.timeout(limit);
  } on TimeoutException {
    process.kill();
    throw StateError(
      'the hook had not ended after ${limit.inSeconds} s, and was killed',
    );
  }
  final exited = watch.elapsed;
  final List<String> texts;
  try {
    texts = await output.timeout(outputPatience);
  } on TimeoutException {
    throw StateError(
      'the hook ended after ${exited.inMilliseconds} ms, but its output '
      'stayed open for ${outputPatience.inSeconds} s more: a process it '
      'started holds its pipe, and Claude Code would wait for it',
    );
  } on Object catch (error) {
    throw StateError('could not read the output of the hook: $error');
  }
  watch.stop();
  return (
    exitCode: code,
    stdout: texts[0],
    stderr: texts[1],
    elapsed: watch.elapsed,
  );
}
