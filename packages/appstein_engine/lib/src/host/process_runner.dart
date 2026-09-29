import 'dart:convert';
import 'dart:io';

/// The outcome of running a tool.
final class RunResult {
  /// A tool that ran to completion with [exitCode].
  const RunResult({required this.exitCode, this.stdout = '', this.stderr = ''})
    : started = true,
      timedOut = false;

  /// A tool that could not be started, for example because it isn't
  /// installed. [reason] says why.
  const RunResult.notStarted(String reason)
    : exitCode = -1,
      stdout = '',
      stderr = reason,
      started = false,
      timedOut = false;

  /// A tool that was killed because it ran past its time limit.
  const RunResult.timedOut({required this.stdout, required this.stderr})
    : exitCode = -1,
      started = true,
      timedOut = true;

  /// The exit code, or -1 when the tool didn't start or timed out.
  final int exitCode;

  /// Everything the tool printed to standard output.
  final String stdout;

  /// Everything the tool printed to standard error, or why it failed.
  final String stderr;

  /// Whether the tool started at all.
  final bool started;

  /// Whether the tool was killed for running too long.
  final bool timedOut;

  /// Whether the tool ran and exited with code 0.
  bool get ok => started && !timedOut && exitCode == 0;
}

/// Runs external tools, such as `java -version` or `git --version`.
abstract interface class ProcessRunner {
  /// Runs [executable] with [arguments] and waits for it, killing it after
  /// [timeout]. Never throws for a missing or failing tool; see [RunResult].
  ///
  /// On Windows, pass a `.bat` or `.cmd` tool (such as `fvm`) as the full path
  /// that `findExecutable` returns. A bare name only finds `.exe` files, so
  /// `run('fvm', ...)` reports "not started" even when `fvm.bat` is on PATH.
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? environment,
  });
}

/// Runs tools as real processes.
///
/// On Windows, a `.bat` or `.cmd` tool must be given as a full path (see
/// [ProcessRunner.run]); a bare name only finds `.exe` files.
final class SystemProcessRunner implements ProcessRunner {
  /// Creates a runner.
  const SystemProcessRunner();

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? environment,
  }) async {
    final Process process;
    try {
      // Not runInShell: on Windows, Dart's shell wrapper doesn't quote a
      // path with spaces (cmd.exe then tries to run `C:\Users\John`).
      // Starting a .bat or .cmd file directly works, because Windows runs
      // batch files through cmd.exe itself and Dart quotes the arguments.
      process = await Process.start(
        executable,
        arguments,
        environment: environment,
      );
    } on ProcessException catch (error) {
      return RunResult.notStarted(error.message);
    }
    // Tools can print bytes that aren't valid UTF-8 (for example a JDK in
    // another locale). Replace them instead of crashing.
    const decoder = Utf8Decoder(allowMalformed: true);
    final stdoutText = process.stdout.transform(decoder).join();
    final stderrText = process.stderr.transform(decoder).join();
    var timedOut = false;
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        process.kill();
        return -1;
      },
    );
    // Killing a .bat or .cmd file kills only the implicit cmd.exe, not the
    // programs it started, and those can keep the pipes open. So the wait
    // for output is bounded.
    const drain = Duration(seconds: 2);
    final out = await stdoutText.timeout(drain, onTimeout: () => '');
    final err = await stderrText.timeout(drain, onTimeout: () => '');
    if (timedOut) {
      return RunResult.timedOut(
        stdout: out,
        stderr:
            'Timed out after ${timeout.inSeconds} s: '
            '$executable ${arguments.join(' ')}\n$err',
      );
    }
    return RunResult(exitCode: exitCode, stdout: out, stderr: err);
  }
}
