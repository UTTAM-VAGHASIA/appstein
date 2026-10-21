import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;

import '../knowledge/support/sync_harness.dart';
import 'fake_process_runner.dart';
import 'fixture_app.dart';

/// What a full `verify` passes to the project's `flutter`.
const flutterTestArguments = ['test', '--machine', '--no-pub'];

/// What `flutter test --machine` of Flutter 3.47.5 printed on Windows for
/// the `tests_app` fixture, as if it had run in [project]. The files are in
/// `test/fixtures/flutter_test/`, copied from real runs with the project's
/// path replaced by a placeholder: `passing` is the run of
/// `test/passing_test.dart` alone, and `failing` the run of the whole app.
/// `load_throw` and `overflow` hold the events of single tests from another
/// real run: a file whose `main()` throws, and two widget tests, one failing
/// in the test framework and one in the rendering library (a RenderFlex
/// overflow). `truncated` is the first 300 KB of a real run of 22 failures
/// in 12 files, which ends in the middle of a line, without the events of
/// the tests that passed and all but the first three lines one test printed.
/// `crash` is a run of two files of another project: in `crash_test.dart` a
/// test calls `exit(0)`, so it and the test after it end with its process,
/// and `real_failure_test.dart` has one failing expectation.
String flutterTestOutput(String name, String project) =>
    File(p.join(p.dirname(fixtureAppsDir), 'flutter_test', '$name.jsonl'))
        .readAsStringSync()
        // The file URI first: Flutter prints both forms.
        .replaceAll('{rootUri}', Uri.file(project).toString())
        .replaceAll('{root}', project.replaceAll(r'\', '/'));

/// A plausible text for an `error` event on a file's loading test after the
/// file loaded: Flutter's message for a `flutter_tester` that crashed. The
/// real text of the one occurrence (Linux CI, run 39565003192) was not
/// recorded, and the tests do not depend on its form.
const shutdownError = 'Shell subprocess crashed with segmentation fault.';

/// [flutterTestOutput] of [name] in [project], with an `error` event with
/// [message] on the loading test [id]. With [after] true it comes right
/// after the line that tells that test as done (hidden), as an error after
/// the file loaded does. With [after] false it comes right before, and that
/// line tells the test as done with `error` and not hidden, as a file that
/// could not be loaded does. Written from Flutter's source and the real load
/// failure in `failing.jsonl`, not copied from a run of an error after
/// loading.
String flutterTestOutputWithError(
  String name,
  String project, {
  required int id,
  required bool after,
  String message = shutdownError,
}) {
  final lines = flutterTestOutput(name, project).trimRight().split('\n');
  final doneAt = lines.indexWhere(
    (line) => line.contains('"testID":$id,') && line.contains('"testDone"'),
  );
  final error =
      '{"testID":$id,"error":"$message","stackTrace":"",'
      '"isFailure":false,"type":"error","time":31500}';
  return [
    ...lines.take(after ? doneAt + 1 : doneAt),
    error,
    if (!after)
      '{"testID":$id,"result":"error","skipped":false,"hidden":false,'
          '"type":"testDone","time":31501}',
    ...lines.skip(doneAt + 1),
  ].join('\n');
}

/// The last event of a run whose tests all passed.
const _allPassed = '{"success":true,"type":"done","time":1}\n';

/// Makes [runner] answer the `flutter test` a full `verify` runs with the
/// Flutter SDK at [sdk]: with [result], or as a run whose tests all pass.
void scriptFlutterTest(
  FakeProcessRunner runner,
  String sdk, [
  RunResult result = const RunResult(exitCode: 0, stdout: _allPassed),
]) => runner.when(flutterCommand(sdk), flutterTestArguments, result);

/// Makes the `flutter` of the fake SDK at [sdk] a real script, for a test
/// that starts it as a process: whatever it is asked, it prints [events]
/// (by default the end of a run whose tests all passed) and exits with
/// [exitCode].
void fakeFlutterPrints(
  String sdk, {
  String events = _allPassed,
  int exitCode = 0,
}) {
  File(p.join(sdk, 'bin', 'events.jsonl')).writeAsStringSync(events);
  File(flutterCommand(sdk)).writeAsStringSync(
    Platform.isWindows
        ? '@echo off\r\ntype "%~dp0events.jsonl"\r\nexit /b $exitCode\r\n'
        : '#!/bin/sh\ncat "\$(dirname "\$0")/events.jsonl"\nexit $exitCode\n',
  );
}
