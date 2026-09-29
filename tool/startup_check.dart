import 'dart:io';

/// Runs a compiled `appstein --version` several times and fails when the
/// median start-up exceeds the 200 ms budget (spec section 15).
///
/// Usage: fvm dart run tool/startup_check.dart [path to compiled appstein]
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/startup_check.dart <path to appstein>',
    );
    exitCode = 2;
    return;
  }
  const runs = 7;
  const budgetMs = 200;
  final times = <int>[];
  for (var i = 0; i < runs; i++) {
    final watch = Stopwatch()..start();
    final result = await Process.run(arguments.single, ['--version']);
    watch.stop();
    if (result.exitCode != 0) {
      stderr.writeln('appstein --version failed: ${result.stderr}');
      exitCode = 1;
      return;
    }
    times.add(watch.elapsedMilliseconds);
  }
  times.sort();
  final median = times[runs ~/ 2];
  stdout.writeln(
    'appstein --version start-up: median $median ms over $runs '
    'runs (budget $budgetMs ms). All runs: $times',
  );
  if (median > budgetMs) exitCode = 1;
}
