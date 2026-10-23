import 'dart:io';

import 'package:args/args.dart';

import 'src/github_api.dart';
import 'src/unit_test_runner.dart';
import 'src/unit_test_trace.dart';

/// CI's "Unit tests" step with its trace (ticket 15 of slice 1d.7).
///
/// It runs the commands the step ran before, in the same order and with
/// the same output: `dart test test` at the repo root, then `dart test` in
/// each package under `packages/` by name, stopping at the first that fails
/// (exit 1). Each command also gets `--file-reporter json:<file>`, and
/// every 30 s the commit status `CI trace / <job>` says which test file
/// has run longest without finishing, so a runner that is lost leaves its
/// last report on GitHub.
///
/// The token comes from `APPSTEIN_TRACE_TOKEN`; the tests are started
/// without it. With no token the tests run untraced, as on a developer's
/// machine. A status that can't be written never fails or holds up the
/// tests.
///
/// Usage, from the repo root:
///   dart run tool/ci_unit_tests.dart --job NAME --sha SHA --run-url URL
///       --attempt N --repo OWNER/NAME
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('job', help: 'The job, for example "test (ubuntu-latest)".')
    ..addOption('sha', help: 'The commit the trace is written on.')
    ..addOption('run-url', help: "The page of the run's attempt.")
    ..addOption('attempt', help: "The run's attempt.")
    ..addOption('repo', help: 'The repository, OWNER/NAME.');
  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (error) {
    _usage(parser, error.message);
    return;
  }
  final attempt = int.tryParse(options.option('attempt') ?? '');
  final missing = [
    for (final name in ['job', 'sha', 'run-url', 'attempt', 'repo'])
      if (options.option(name) == null) '--$name',
  ];
  if (missing.isNotEmpty || attempt == null || options.rest.isNotEmpty) {
    _usage(
      parser,
      missing.isNotEmpty
          ? 'Missing: ${missing.join(', ')}.'
          : 'Bad --attempt or extra arguments.',
    );
    return;
  }
  final sha = options.option('sha')!;
  final job = options.option('job')!;
  final runUrl = options.option('run-url')!;

  final token = Platform.environment[traceTokenVariable] ?? '';
  final api = token.isEmpty
      ? null
      : HttpGitHubApi(
          repo: options.option('repo')!,
          token: token,
          timeout: const Duration(seconds: 10),
        );
  final trace = api == null
      ? null
      : TraceWriter(
          (state, description) => api.postStatus(
            sha,
            state: state,
            context: traceContext(job),
            description: description,
            targetUrl: runUrl,
          ),
          out: stdout,
        );

  final temp = Platform.environment['RUNNER_TEMP'];
  final reports = Directory(
    '${temp == null || temp.isEmpty ? Directory.systemTemp.path : temp}'
    '${Platform.pathSeparator}unit-test-trace',
  )..createSync(recursive: true);
  try {
    exitCode = await runUnitTests(
      commands: unitTestCommands(packageFolders(Directory('packages'))),
      reportFolder: reports.path,
      attempt: attempt,
      out: stdout,
      trace: trace,
      start: (command, reportFile) => startDartTest(
        dart: Platform.resolvedExecutable,
        command: command,
        reportFile: reportFile,
        parentEnvironment: Platform.environment,
      ),
    );
  } finally {
    api?.close();
  }
}

void _usage(ArgParser parser, String problem) {
  stderr
    ..writeln(problem)
    ..writeln(
      'Usage: dart run tool/ci_unit_tests.dart --job NAME --sha SHA '
      '--run-url URL --attempt N --repo OWNER/NAME',
    )
    ..writeln(parser.usage);
  exitCode = 2;
}
