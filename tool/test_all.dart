import 'dart:io';

import 'src/suite_run.dart';

/// Runs every check this repo has before a commit, and exits 1 when any
/// of them failed. A step passes only when its exit code and its output
/// agree (`judgeTestRun`), so a failure can never read as green.
///
/// The steps, in order: the format check, the analyzer with infos fatal,
/// the generated docs (`gen_docs --check`), the developer guide check
/// against `main`, then the test suites of every package (the engine's
/// [engineRuns] times, since a failure that depends on load shows in one
/// run of several) and the repo tools' tests.
///
/// `APPSTEIN_REQUIRE_GRAPHIFY=1` is set for the tests, as CI does, so the
/// graph check's tests fail instead of skipping when graphify is missing:
/// a skipped test proves nothing.
///
/// Usage, from the repo root:
///   fvm dart run tool/test_all.dart [--engine-runs N] [--since REV]
///       [--only NAME]
///
/// `--only` runs just the steps whose name contains NAME (for example
/// `appstein_cli`), to run one suite again; it is never the check before
/// a commit.
Future<void> main(List<String> arguments) async {
  var engineRuns = 2;
  var since = 'main';
  String? only;
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    final value = i + 1 < arguments.length ? arguments[i + 1] : null;
    if (argument == '--engine-runs' && int.tryParse(value ?? '') != null) {
      engineRuns = int.parse(value!);
      i++;
    } else if (argument == '--since' && value != null) {
      since = value;
      i++;
    } else if (argument == '--only' && value != null) {
      only = value;
      i++;
    } else {
      stderr.writeln(
        'Usage: fvm dart run tool/test_all.dart '
        '[--engine-runs N] [--since REV] [--only NAME]',
      );
      exitCode = 2;
      return;
    }
  }
  if (!File('pubspec.yaml').existsSync() ||
      !Directory('packages').existsSync()) {
    stderr.writeln('Run it from the repo root.');
    exitCode = 2;
    return;
  }
  // The `dart` that runs this tool: under `fvm dart run`, the pinned SDK's.
  final dart = Platform.resolvedExecutable;
  final environment = {'APPSTEIN_REQUIRE_GRAPHIFY': '1'};

  final steps = <({String name, String folder, List<String> args, bool tests})>[
    (
      name: 'format',
      folder: '.',
      args: ['format', '--output=none', '--set-exit-if-changed', '.'],
      tests: false,
    ),
    (
      name: 'analyze',
      folder: '.',
      args: ['analyze', '--fatal-infos'],
      tests: false,
    ),
    (
      name: 'gen_docs --check',
      folder: '.',
      args: ['run', 'tool/gen_docs.dart', '--check'],
      tests: false,
    ),
    (
      name: 'check_guide --since $since',
      folder: '.',
      args: ['run', 'tool/check_guide.dart', '--since', since],
      tests: false,
    ),
    (
      name: 'appstein_protocol',
      folder: 'packages/appstein_protocol',
      args: ['test'],
      tests: true,
    ),
    for (var run = 1; run <= engineRuns; run++)
      (
        name: 'appstein_engine (run $run of $engineRuns)',
        folder: 'packages/appstein_engine',
        args: ['test'],
        tests: true,
      ),
    (
      name: 'appstein_cli',
      folder: 'packages/appstein_cli',
      args: ['test'],
      tests: true,
    ),
    (
      name: 'appstein_lints',
      folder: 'packages/appstein_lints',
      args: ['test'],
      tests: true,
    ),
    (name: 'repo tools', folder: '.', args: ['test', 'test'], tests: true),
  ];

  final chosen = [
    for (final step in steps)
      if (only == null || step.name.contains(only)) step,
  ];
  if (chosen.isEmpty) {
    stderr.writeln('No step has `$only` in its name.');
    exitCode = 2;
    return;
  }
  // Each step's whole output, one file per step, replaced on each run.
  final logs = Directory('.dart_tool/test_all')..createSync(recursive: true);
  for (final old in logs.listSync().whereType<File>()) {
    old.deleteSync();
  }
  var stepNumber = 0;
  final failed = <String>[];
  for (final step in chosen) {
    stdout.writeln('== ${step.name} ...');
    final watch = Stopwatch()..start();
    final result = await Process.run(
      dart,
      step.args,
      workingDirectory: step.folder,
      environment: environment,
    );
    final output = '${result.stdout}\n${result.stderr}';
    // The whole output is kept, so a failure can be read afterwards even
    // when the lines shown here don't say enough.
    final log = File(
      '${logs.path}${Platform.pathSeparator}'
      '${(++stepNumber).toString().padLeft(2, '0')}-'
      '${step.name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}.log',
    )..writeAsStringSync(output);
    final verdict = step.tests
        ? judgeTestRun(result.exitCode, output)
        : judgeTool(result.exitCode, output);
    final seconds = (watch.elapsedMilliseconds / 1000).toStringAsFixed(0);
    stdout.writeln(
      '== ${step.name}: ${verdict.passed ? 'passed' : 'FAILED'} '
      '(${verdict.reason}) in $seconds s',
    );
    if (!verdict.passed) {
      failed.add(step.name);
      for (final line in failureLines(output)) {
        stdout.writeln('   $line');
      }
      stdout.writeln('   The whole output: ${log.path}');
    }
  }
  if (failed.isEmpty) {
    stdout.writeln('ALL GREEN');
  } else {
    stdout.writeln('FAILED: ${failed.join(', ')}');
    exitCode = 1;
  }
}
