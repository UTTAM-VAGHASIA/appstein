import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  ///
  /// The tool runs in [workingDirectory], or in Appstein's own working folder
  /// when it is null.
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? environment,
    String? workingDirectory,
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
    String? workingDirectory,
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
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (error) {
      return RunResult.notStarted(error.message);
    }
    final stdoutReader = _PipeReader(process.stdout);
    final stderrReader = _PipeReader(process.stderr);
    var timedOut = false;
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () async {
        timedOut = true;
        await _killTree(process);
        return -1;
      },
    );
    // A .bat or .cmd file's child programs can keep the pipes open after the
    // shell is gone. So the wait for output is bounded, and the readers are
    // cancelled afterwards: an open pipe would keep appstein itself alive.
    await Future.wait([
      stdoutReader.done,
      stderrReader.done,
    ]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    final out = await stdoutReader.finish();
    final err = await stderrReader.finish();
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

/// Kills [process] and, on Windows, everything it started.
///
/// `Process.kill` on Windows ends only the process itself. For a `.bat` or
/// `.cmd` file that is the implicit cmd.exe, and the tool it started keeps
/// running. `taskkill /T` ends the whole tree. It is started by its full path
/// under SystemRoot, never by bare name.
Future<void> _killTree(Process process) async {
  if (Platform.isWindows) {
    final root = _systemRoot(Platform.environment) ?? r'C:\Windows';
    try {
      await Process.run('$root\\System32\\taskkill.exe', [
        '/PID',
        '${process.pid}',
        '/T',
        '/F',
      ]).timeout(const Duration(seconds: 5));
    } on Object {
      // Fall through to the plain kill below.
    }
  }
  process.kill();
}

/// SystemRoot from [environment], which Windows names case-insensitively.
String? _systemRoot(Map<String, String> environment) {
  for (final entry in environment.entries) {
    if (entry.key.toUpperCase() == 'SYSTEMROOT' && entry.value.isNotEmpty) {
      return entry.value;
    }
  }
  return null;
}

/// Collects a process's output bytes, so they can be decoded once at the end
/// and the pipe released even when a child program never closes it.
final class _PipeReader {
  _PipeReader(Stream<List<int>> stream) {
    _subscription = stream.listen(
      _bytes.add,
      onError: (Object _) => _finished.complete(),
      onDone: _finished.complete,
      cancelOnError: true,
    );
  }

  final _bytes = BytesBuilder(copy: false);
  final _finished = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;

  /// Completes when the pipe closes.
  Future<void> get done => _finished.future;

  /// Stops reading and returns the text so far. Tools can print bytes that
  /// aren't valid UTF-8 (for example a JDK in another locale); those are
  /// replaced instead of crashing.
  Future<String> finish() async {
    await _subscription.cancel();
    return const Utf8Decoder(allowMalformed: true).convert(_bytes.takeBytes());
  }
}
