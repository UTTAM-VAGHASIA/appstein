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
String flutterTestOutput(String name, String project) =>
    File(p.join(p.dirname(fixtureAppsDir), 'flutter_test', '$name.jsonl'))
        .readAsStringSync()
        // The file URI first: Flutter prints both forms.
        .replaceAll('{rootUri}', Uri.file(project).toString())
        .replaceAll('{root}', project.replaceAll(r'\', '/'));

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
