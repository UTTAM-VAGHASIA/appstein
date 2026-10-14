import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../knowledge/support/sync_harness.dart';
import '../support/fake_process_runner.dart';
import '../support/flutter_test_output.dart';
import '../support/temp.dart';

// `runProjectTests` with a scripted process runner (slice 1d.2, seam 3).
// The scripted output is what Flutter 3.47.5 really printed; see
// `flutterTestOutput`.
void main() {
  late String sdk;
  late String app;
  late FakeProcessRunner runner;

  void writeFile(String relative, [String content = '']) =>
      File(p.joinAll([app, ...relative.split('/')]))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);

  setUp(() {
    sdk = fakeFlutter();
    app = p.join(tempDir().path, 'tests app');
    writeFile('pubspec.yaml', 'name: tests_app\n');
    writeFile('test/passing_test.dart', 'void main() {}\n');
    runner = FakeProcessRunner();
  });

  Future<TestRun> run({
    String? flutterRoot,
    Duration timeout = const Duration(seconds: 600),
  }) => runProjectTests(
    projectRoot: app,
    environment: fakeEnvironment({'FLUTTER_ROOT': flutterRoot ?? sdk}),
    runner: runner,
    timeout: timeout,
  );

  List<(String?, int?, String?, String)> told(TestRun tests) => [
    for (final failure in tests.failures)
      (failure.file, failure.line, failure.test, failure.details),
  ];

  test('a passing run: no failure, from one `flutter test` of the '
      'project\'s Flutter, in the project, with the time limit', () async {
    scriptFlutterTest(
      runner,
      sdk,
      RunResult(exitCode: 0, stdout: flutterTestOutput('passing', app)),
    );
    final tests = await run(timeout: const Duration(seconds: 45));
    expect((tests.ran, tests.timedOut), (true, false));
    expect(tests.failures, isEmpty);
    expect(runner.calls, ['${flutterCommand(sdk)} test --machine --no-pub']);
    expect(runner.workingDirectories, [app]);
    expect(runner.timeouts, [const Duration(seconds: 45)]);
  });

  group('a failing run', () {
    late TestRun tests;

    setUp(() async {
      scriptFlutterTest(
        runner,
        sdk,
        RunResult(exitCode: 1, stdout: flutterTestOutput('failing', app)),
      );
      tests = await run();
    });

    test('names each failing test once, and no passing or skipped '
        'one', () {
      expect((tests.ran, tests.timedOut), (true, false));
      expect(
        [for (final failure in tests.failures) failure.test],
        [
          null,
          'in a folder with a space',
          'counter next adds two',
          'counter next throws',
          'shows other text',
          'a widget in a folder with a space',
          'widget throws',
        ],
      );
    });

    test('a failing expectation: the file, the line of the test, its full '
        'name with its groups, and what was expected', () {
      expect(
        told(tests),
        contains((
          'test/widgets/failing_test.dart',
          8,
          'counter next adds two',
          'Expected: <3> Actual: <2>',
        )),
      );
    });

    test('a thrown error is told the same way', () {
      expect(
        told(tests),
        contains((
          'test/widgets/failing_test.dart',
          12,
          'counter next throws',
          'Bad state: the counter broke',
        )),
      );
    });

    test('a widget test: the line in the test file, not the one inside '
        'flutter_test, and what Flutter printed about the failure', () {
      expect(
        told(tests),
        containsAll([
          (
            'test/widgets/failing_test.dart',
            18,
            'shows other text',
            'The following TestFailure was thrown running a test: '
                'Expected: exactly one matching candidate '
                'Actual: _TextWidgetFinder:<Found 0 widgets with text '
                '"goodbye": []> '
                'Which: means none were found but one was expected',
          ),
          (
            'test/widgets/failing_test.dart',
            28,
            'widget throws',
            'The following ArgumentError was thrown running a test: '
                'Invalid argument(s): bad widget',
          ),
        ]),
      );
    });

    test('a file that can\'t load: on the file, with the loader\'s '
        'message and no test name', () {
      expect(told(tests).first, (
        'test/broken_test.dart',
        null,
        null,
        'Compilation failed for testPath=test/broken_test.dart: '
            'test/broken_test.dart:6:12: Error: Method not found: '
            '\'nextt\'. expect(nextt(1), 2);',
      ));
    });

    // Flutter 3.47.5 gives no line for a test whose path from the project
    // has a space: its own stack trace reader stops at the space.
    test('a test file in a folder with a space: the file, and no line '
        'where Flutter gives none', () {
      expect(
        told(tests),
        containsAll([
          (
            'test/my folder/spaced_test.dart',
            null,
            'in a folder with a space',
            'Expected: <6> Actual: <5>',
          ),
          (
            'test/my folder/spaced_test.dart',
            null,
            'a widget in a folder with a space',
            'The following TestFailure was thrown running a test: '
                'Expected: no matching candidates '
                'Actual: _TextWidgetFinder:<Found 1 widget with text '
                '"hello": [ Text("hello", dependencies: [MediaQuery]), ]> '
                'Which: means one was found but none were expected',
          ),
        ]),
      );
    });
  });

  // A real run of a file whose `main()` throws: Flutter prints the reason on
  // the same line as `Failed to load "<path>":` (for a compile error it comes
  // on the lines after it).
  test('a test file whose main throws: the exception, with no test '
      'name', () async {
    scriptFlutterTest(
      runner,
      sdk,
      RunResult(exitCode: 1, stdout: flutterTestOutput('load_throw', app)),
    );
    expect(told(await run()), [
      (
        'test/top_level_throw_test.dart',
        null,
        null,
        'Bad state: main threw before declaring',
      ),
    ]);
  });

  // A real run of two widget tests of one file: one fails with an exception
  // the test framework caught, one with a RenderFlex overflow, which the
  // rendering library caught.
  group('a widget test that fails with an exception', () {
    String overflowRun() => flutterTestOutput('overflow', app);

    final frameworkMessage =
        'The following TestFailure was thrown running a test: '
        'Expected: exactly one matching candidate '
        'Actual: _TextWidgetFinder:<Found 0 widgets with text "x": []> '
        'Which: means none were found but one was expected';
    const overflowMessage =
        'The following assertion was thrown during layout: '
        'A RenderFlex overflowed by 490 pixels on the right.';

    Future<List<(String?, int?, String?, String)>> readRun(
      String stdout,
    ) async {
      scriptFlutterTest(runner, sdk, RunResult(exitCode: 1, stdout: stdout));
      return told(await run());
    }

    test('that a library other than the test framework caught: what '
        'that library printed', () async {
      expect(await readRun(overflowRun()), [
        (
          'test/sub dir/deep/space path_test.dart',
          null,
          'widget in spaced',
          frameworkMessage,
        ),
        (
          'test/sub dir/deep/space path_test.dart',
          null,
          'g layout overflow',
          overflowMessage,
        ),
      ]);
    });

    test('and what one test printed is never told of another, even when '
        'their events are mixed', () async {
      // Suites run at the same time, so the events of two tests alternate:
      // here the second test prints before the first one's error.
      final lines = overflowRun().split('\n');
      final firstError = lines.indexWhere(
        (line) => line.contains('"testID":26,"error"'),
      );
      final secondPrint = lines.indexWhere(
        (line) => line.contains('"testID":37,"messageType":"print"'),
      );
      final moved = lines.removeAt(firstError);
      lines.insert(secondPrint, moved);
      expect(
        [
          for (final (_, _, test, details) in await readRun(lines.join('\n')))
            (test, details),
        ],
        [
          ('widget in spaced', frameworkMessage),
          ('g layout overflow', overflowMessage),
        ],
      );
    });
  });

  group('a run that does not finish keeps what it told', () {
    List<String?> names(TestRun tests) => [
      for (final failure in tests.failures) failure.test,
    ];

    test('a run that never ends: stopped at the limit, with the failures it '
        'had told and the tests that were open', () async {
      scriptFlutterTest(
        runner,
        sdk,
        RunResult.timedOut(
          // Half of a failing run had been printed when it was stopped.
          stdout: flutterTestOutput(
            'failing',
            app,
          ).split('\n').take(40).join('\n'),
          stderr: 'Timed out after 2 s: flutter test',
        ),
      );
      final tests = await run(timeout: const Duration(seconds: 2));
      expect((tests.ran, tests.timedOut), (true, true));
      expect((tests.cutShort, tests.unexplained), (false, false));
      expect(names(tests), [
        null,
        'counter next adds two',
        'counter next throws',
      ]);
      // Two suites ran at the same time, and each had a test open.
      expect(tests.running, [
        (
          file: 'test/my folder/spaced_test.dart',
          test: 'in a folder with a space',
        ),
        (file: 'test/widgets/failing_test.dart', test: 'shows other text'),
      ]);
      expect(runner.timeouts, [const Duration(seconds: 2)]);
    });

    test('the first 300 KB of a real run of 22 failures, whose output '
        'ends in the middle of a line: the 16 failures it had told, the '
        'test that was open, and not a finished run', () async {
      scriptFlutterTest(
        runner,
        sdk,
        RunResult(exitCode: 1, stdout: flutterTestOutput('truncated', app)),
      );
      final tests = await run();
      expect(
        (tests.ran, tests.timedOut, tests.cutShort, tests.unexplained),
        (true, false, true, false),
      );
      expect(tests.exitCode, 1);
      expect(tests.failures, hasLength(16));
      expect(names(tests).take(4), [
        null,
        null,
        'outer (setUpAll)',
        'plain in spaced',
      ]);
      expect(names(tests).last, 'm6 fails');
      expect(tests.running, [
        (file: 'test/unit/nested_test.dart', test: 'prints a lot then fails'),
      ]);
    });

    test('a run with no failure whose output ends before the end of the '
        'run is not a passed run', () async {
      final lines = flutterTestOutput('passing', app).trimRight().split('\n')
        ..removeLast();
      scriptFlutterTest(
        runner,
        sdk,
        RunResult(exitCode: 1, stdout: lines.join('\n')),
      );
      final tests = await run();
      expect((tests.cutShort, tests.exitCode), (true, 1));
      expect(tests.failures, isEmpty);
      expect(tests.running, isEmpty);
    });

    test(
      'a file being loaded when the run stops is told by its file',
      () async {
        final lines = flutterTestOutput('passing', app).split('\n').take(3);
        scriptFlutterTest(
          runner,
          sdk,
          RunResult.timedOut(stdout: lines.join('\n'), stderr: ''),
        );
        final tests = await run();
        expect(tests.timedOut, isTrue);
        expect(tests.running, [(file: 'test/passing_test.dart', test: null)]);
      },
    );
  });

  group('nothing to run, so `flutter test` is not started', () {
    test('no test folder', () async {
      Directory(p.join(app, 'test')).deleteSync(recursive: true);
      final tests = await run();
      expect((tests.ran, tests.timedOut), (false, false));
      expect(tests.failures, isEmpty);
      expect(runner.calls, isEmpty);
    });

    // `flutter test` exits 1 there with "does not appear to contain any
    // test files", and prints no event.
    test('a test folder without a file that ends in _test.dart', () async {
      File(p.join(app, 'test', 'passing_test.dart')).deleteSync();
      writeFile('test/support/helper.dart');
      writeFile('test/notes_test.txt');
      final tests = await run();
      expect(tests.ran, isFalse);
      expect(runner.calls, isEmpty);
    });

    test('a test file in a folder below is found', () async {
      File(p.join(app, 'test', 'passing_test.dart')).deleteSync();
      writeFile('test/ui/home/home_test.dart');
      scriptFlutterTest(runner, sdk);
      expect((await run()).ran, isTrue);
      expect(runner.calls, hasLength(1));
    });
  });

  group('Appstein fails, and never reads it as "no test failed"', () {
    Matcher cannotRun(Object reason) => throwsA(
      isA<TestRunException>()
          .having((error) => error.reason, 'reason', reason)
          .having(
            (error) => '$error',
            'text',
            startsWith('The project\'s tests could not be run: '),
          ),
    );

    test('`flutter test` can\'t be started', () async {
      // Nothing is scripted: the runner says it could not start it.
      await expectLater(
        run(),
        cannotRun(
          allOf(
            startsWith('`flutter test` could not be started with '),
            contains(flutterCommand(sdk)),
            contains('not faked'),
          ),
        ),
      );
    });

    test('the project has no usable Flutter SDK', () async {
      await expectLater(
        run(flutterRoot: p.join(app, 'no such sdk')),
        cannotRun(startsWith('the project has no usable Flutter SDK (')),
      );
      expect(runner.calls, isEmpty);
    });
  });

  // A run that was started and gave no result is a result of its own, a
  // finding of the project: not Appstein failing.
  group('`flutter test` ran and named no failing test', () {
    test('it fails: its exit code and last words', () async {
      scriptFlutterTest(
        runner,
        sdk,
        const RunResult(
          exitCode: 1,
          stdout: '{"protocolVersion":"0.1.1","type":"start","time":0}\n',
          stderr:
              'Error: cannot run without a dependency on '
              '"package:flutter_test".\nAdd it to pubspec.yaml.\n',
        ),
      );
      final tests = await run();
      expect((tests.unexplained, tests.exitCode), (true, 1));
      expect(
        tests.said,
        'Error: cannot run without a dependency on '
        '"package:flutter_test". Add it to pubspec.yaml',
      );
      expect(tests.failures, isEmpty);
    });

    test('it ends with exit code 0 but never says the run is done', () async {
      scriptFlutterTest(
        runner,
        sdk,
        const RunResult(exitCode: 0, stdout: 'Downloading the engine\n'),
      );
      final tests = await run();
      expect((tests.unexplained, tests.exitCode), (true, 0));
      expect(tests.said, 'Downloading the engine');
    });
  });

  test('lines that are no events are passed over, and an error after a '
      'test was done still counts', () async {
    final root = app.replaceAll(r'\', '/');
    scriptFlutterTest(
      runner,
      sdk,
      RunResult(
        exitCode: 1,
        stdout: [
          'Spawning version "3.47.5"...',
          '',
          '[{"event":"test.startedProcess","params":{"vmServiceUri":null}}]',
          '{"suite":{"id":0,"platform":"vm","path":"$root/test/a_test.dart"},'
              '"type":"suite","time":0}',
          '{"test":{"id":1,"name":"late","suiteID":0,"groupIDs":[],'
              '"line":3,"column":3,'
              '"url":"${Uri.file(p.join(app, 'test', 'a_test.dart'))}"},'
              '"type":"testStart","time":1}',
          '{"testID":1,"result":"success","skipped":false,"hidden":false,'
              '"type":"testDone","time":2}',
          '{"testID":1,"error":"late error","stackTrace":"",'
              '"isFailure":false,"type":"error","time":3}',
          '{"broken json',
          '{"success":false,"type":"done","time":4}',
        ].join('\r\n'),
      ),
    );
    expect(told(await run()), [('test/a_test.dart', 3, 'late', 'late error')]);
  });
}
