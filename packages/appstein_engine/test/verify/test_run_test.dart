import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../knowledge/support/sync_harness.dart';
import '../support/fake_process_runner.dart';
import '../support/flutter_test_output.dart';
import '../support/temp.dart';

/// The details of a test whose test process ended before it finished.
const _ended =
    'Its test process ended before the test finished (a crash or `exit`).';

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

  // macOS's temp folder `/var/…` is a link to `/private/var/…`, and Flutter
  // names each test file by its real path. A link to the project (a junction
  // on Windows) stands in for it here.
  test('a project reached through a link: its test files are named from the '
      'project root all the same', () async {
    final linked = p.join(tempDir().path, 'linked app');
    Link(linked).createSync(app);
    // A tool that follows links names files by the fully resolved location.
    // The temp folder itself may not be in that form: on macOS it is under
    // the `/var` link, and on a Windows runner it can be a short 8.3 name
    // (`RUNNER~1`), so the scripted output takes the resolved one.
    final real = Directory(app).resolveSymbolicLinksSync();
    scriptFlutterTest(
      runner,
      sdk,
      RunResult(exitCode: 1, stdout: flutterTestOutput('failing', real)),
    );
    final tests = await runProjectTests(
      projectRoot: linked,
      environment: fakeEnvironment({'FLUTTER_ROOT': sdk}),
      runner: runner,
      timeout: const Duration(seconds: 600),
    );
    expect(
      [for (final failure in tests.failures) failure.file],
      [
        'test/broken_test.dart',
        'test/my folder/spaced_test.dart',
        'test/widgets/failing_test.dart',
        'test/widgets/failing_test.dart',
        'test/widgets/failing_test.dart',
        'test/my folder/spaced_test.dart',
        'test/widgets/failing_test.dart',
      ],
    );
    expect(
      told(tests),
      contains((
        'test/widgets/failing_test.dart',
        8,
        'counter next adds two',
        'Expected: <3> Actual: <2>',
      )),
    );
    final slashed = real.replaceAll(r'\', '/');
    for (final failure in tests.failures) {
      expect(failure.details, isNot(contains(slashed)));
    }
  });

  // On macOS the link's path is the end of the real one: `/var/…/app` is
  // `/private/var/…/app`. Taking the root out of the details before its real
  // form left `/private` behind.
  test('a link whose path is a part of the project\'s real path: the files '
      'and the details lose the whole path', () async {
    final tmp = Directory(tempDir().path).resolveSymbolicLinksSync();
    final linked = p.join(tmp, 'a', 'app');
    final real = '${p.join(tmp, 'p')}$linked';
    Directory(p.dirname(real)).createSync(recursive: true);
    Directory(app).renameSync(real);
    Directory(p.dirname(linked)).createSync(recursive: true);
    Link(linked).createSync(real);
    scriptFlutterTest(
      runner,
      sdk,
      RunResult(exitCode: 1, stdout: flutterTestOutput('failing', real)),
    );
    final tests = await runProjectTests(
      projectRoot: linked,
      environment: fakeEnvironment({'FLUTTER_ROOT': sdk}),
      runner: runner,
      timeout: const Duration(seconds: 600),
    );
    expect(told(tests).first, (
      'test/broken_test.dart',
      null,
      null,
      'Compilation failed for testPath=test/broken_test.dart: '
          'test/broken_test.dart:6:12: Error: Method not found: '
          '\'nextt\'. expect(nextt(1), 2);',
    ));
    for (final failure in tests.failures) {
      expect(failure.file, startsWith('test/'));
      expect(failure.details, isNot(contains(tmp)));
    }
  }, testOn: '!windows');

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

    // On Linux and macOS the stop is a SIGTERM, which `flutter test` handles:
    // `package:test` closes the tests still running, and its JSON reporter
    // tells each one it closed as done with `error`, with no error event
    // before it (test_core 0.6.18, `JsonReporter._normalizeTestResult`: "if
    // test is still active, it was probably cancelled"). The end of the run
    // may follow, as a failure, or never be printed: the tool's own SIGTERM
    // handler exits at the same time. These lines are written from that
    // source, not copied from a run: no Linux run has been recorded.
    String stoppedOnPosix(
      String printed, {
      List<int> closed = const [9, 19],
      String before = '',
      bool done = true,
    }) => [
      printed,
      if (before.isNotEmpty) before,
      for (final id in closed)
        '{"testID":$id,"result":"error","skipped":false,"hidden":false,'
            '"type":"testDone","time":75012}',
      if (done) '{"success":false,"type":"done","time":75020}',
      '',
    ].join('\n');

    /// The first [count] lines of the real run of the whole fixture app.
    String failingRun([int count = 40]) =>
        flutterTestOutput('failing', app).split('\n').take(count).join('\n');

    test('a run stopped by a signal it handles: the tests the stop closed '
        'are told as running, never as failing tests', () async {
      scriptFlutterTest(
        runner,
        sdk,
        RunResult.timedOut(stdout: stoppedOnPosix(failingRun()), stderr: ''),
      );
      final tests = await run(timeout: const Duration(seconds: 2));
      expect((tests.ran, tests.timedOut), (true, true));
      expect(names(tests), [
        null,
        'counter next adds two',
        'counter next throws',
      ]);
      // `counter next throws` was done with `error` before the stop, and
      // other tests started after it: it is a failure, not running.
      expect(tests.running, [
        (
          file: 'test/my folder/spaced_test.dart',
          test: 'in a folder with a space',
        ),
        (file: 'test/widgets/failing_test.dart', test: 'shows other text'),
      ]);
    });

    test('a test that had told an error and was still running at the stop '
        'is a failing test, and is named as running too', () async {
      scriptFlutterTest(
        runner,
        sdk,
        RunResult.timedOut(
          stdout: stoppedOnPosix(
            failingRun(),
            before:
                '{"testID":19,"error":"Bad state: broke, then hung",'
                '"stackTrace":"","isFailure":false,"type":"error",'
                '"time":40000}',
            done: false,
          ),
          stderr: '',
        ),
      );
      final tests = await run(timeout: const Duration(seconds: 2));
      expect(tests.timedOut, isTrue);
      expect(told(tests).last, (
        'test/widgets/failing_test.dart',
        18,
        'shows other text',
        'Bad state: broke, then hung',
      ));
      expect(names(tests), [
        null,
        'counter next adds two',
        'counter next throws',
        'shows other text',
      ]);
      expect(tests.running, [
        (
          file: 'test/my folder/spaced_test.dart',
          test: 'in a folder with a space',
        ),
        (file: 'test/widgets/failing_test.dart', test: 'shows other text'),
      ]);
    });

    test('stopped on Windows, a test that had told an error and was still '
        'running is a failing test, and is named as running too', () async {
      scriptFlutterTest(
        runner,
        sdk,
        RunResult.timedOut(
          stdout:
              '${failingRun()}\n'
              '{"testID":19,"error":"Bad state: broke, then hung",'
              '"stackTrace":"","isFailure":false,"type":"error",'
              '"time":40000}\n',
          stderr: '',
        ),
      );
      final tests = await run(timeout: const Duration(seconds: 2));
      expect(names(tests).last, 'shows other text');
      expect(tests.running.last, (
        file: 'test/widgets/failing_test.dart',
        test: 'shows other text',
      ));
    });

    /// A test done with `error` by the stop, as the reporter tells it.
    String closedByStop(int id) =>
        '{"testID":$id,"result":"error","skipped":false,"hidden":false,'
        '"type":"testDone","time":75012}';

    /// The end of the run after a stop.
    const doneAfterStop = '{"success":false,"type":"done","time":75020}';

    List<RunningTest> bothOpen() => [
      (
        file: 'test/my folder/spaced_test.dart',
        test: 'in a folder with a space',
      ),
      (file: 'test/widgets/failing_test.dart', test: 'shows other text'),
    ];

    test(
      'the stop runs the tearDownAll of a file whose test it closed: '
      'that hidden test is passed over, and never named as running',
      () async {
        // test_core runs a group's tearDownAll even after the engine is
        // closed (engine.dart, `_runGroup`). A file has one when its author
        // wrote one, or when flutter_test's leak tracking is turned on. The
        // stop closes it too.
        scriptFlutterTest(
          runner,
          sdk,
          RunResult.timedOut(
            stdout: [
              failingRun(),
              closedByStop(19),
              '{"test":{"id":20,"name":"(tearDownAll)","suiteID":6,'
                  '"groupIDs":[14],"metadata":{"skip":false,"skipReason":null},'
                  '"line":null,"column":null,"url":null},"type":"testStart",'
                  '"time":75013}',
              closedByStop(20),
              '{"test":{"id":21,"name":"counter (setUpAll)","suiteID":6,'
                  '"groupIDs":[14,15],"metadata":{"skip":false,'
                  '"skipReason":null},"line":null,"column":null,"url":null},'
                  '"type":"testStart","time":75014}',
              '{"testID":21,"result":"success","skipped":false,"hidden":true,'
                  '"type":"testDone","time":75014}',
              closedByStop(9),
              doneAfterStop,
            ].join('\n'),
            stderr: '',
          ),
        );
        final tests = await run(timeout: const Duration(seconds: 2));
        expect(names(tests), [
          null,
          'counter next adds two',
          'counter next throws',
        ]);
        expect(tests.running, bothOpen());
      },
    );

    test('a print from a test still running in another file, between the '
        'stop\'s lines, is passed over', () async {
      scriptFlutterTest(
        runner,
        sdk,
        RunResult.timedOut(
          stdout: [
            failingRun(),
            closedByStop(19),
            '{"testID":9,"messageType":"print","message":"still going",'
                '"type":"print","time":75013}',
            closedByStop(9),
            doneAfterStop,
          ].join('\n'),
          stderr: '',
        ),
      );
      final tests = await run(timeout: const Duration(seconds: 2));
      expect(names(tests), [
        null,
        'counter next adds two',
        'counter next throws',
      ]);
      expect(tests.running, bothOpen());
    });

    /// The error the stop gave the loading test [id] on macOS (CI run
    /// 38885267342, the integration test's reason line).
    String stopErrorOn(int id) =>
        '{"testID":$id,"error":"Bad state: Cannot close sink while adding '
        'stream.","stackTrace":"","isFailure":false,"type":"error",'
        '"time":75015}';

    test('macOS: an error the stop gives a loading test that was done is '
        'part of the stop, not a failure', () async {
      scriptFlutterTest(
        runner,
        sdk,
        RunResult.timedOut(
          stdout: [
            failingRun(),
            closedByStop(19),
            closedByStop(9),
            // `loading …/failing_test.dart` and `loading …/spaced_test.dart`,
            // each told as done (hidden) before.
            stopErrorOn(7),
            stopErrorOn(3),
            doneAfterStop,
          ].join('\n'),
          stderr: '',
        ),
      );
      final tests = await run(timeout: const Duration(seconds: 2));
      expect(tests.timedOut, isTrue);
      expect(names(tests), [
        null,
        'counter next adds two',
        'counter next throws',
      ]);
      expect(tests.running, bothOpen());
    });

    test('the same error on a loading test whose end the output never told '
        'is a failure of its file, in a stopped run', () async {
      // Up to before `loading …/spaced_test.dart` (3) was told as done.
      scriptFlutterTest(
        runner,
        sdk,
        RunResult.timedOut(
          stdout: [failingRun(19), stopErrorOn(3), doneAfterStop].join('\n'),
          stderr: '',
        ),
      );
      final tests = await run(timeout: const Duration(seconds: 2));
      expect(tests.timedOut, isTrue);
      expect(told(tests).last, (
        'test/my folder/spaced_test.dart',
        null,
        null,
        'Bad state: Cannot close sink while adding stream.',
      ));
    });

    test('the same error before its loading test was told as done is a '
        'failure of its file, in a stopped run', () async {
      scriptFlutterTest(
        runner,
        sdk,
        RunResult.timedOut(
          stdout: [
            failingRun(19),
            stopErrorOn(3),
            '{"testID":3,"result":"success","skipped":false,"hidden":true,'
                '"type":"testDone","time":75013}',
            doneAfterStop,
          ].join('\n'),
          stderr: '',
        ),
      );
      final tests = await run(timeout: const Duration(seconds: 2));
      expect(tests.timedOut, isTrue);
      expect(told(tests).last, (
        'test/my folder/spaced_test.dart',
        null,
        null,
        'Bad state: Cannot close sink while adding stream.',
      ));
    });

    test('a file that failed to load, printed last before the stop, is a '
        'failure and is not named as running', () async {
      // The real output's load failure: an error, `testDone` with `error`
      // and `"hidden":false`, then a second error, all on `loading
      // …/broken_test.dart` (1).
      scriptFlutterTest(
        runner,
        sdk,
        RunResult.timedOut(stdout: failingRun(13), stderr: ''),
      );
      final tests = await run(timeout: const Duration(seconds: 2));
      expect(tests.timedOut, isTrue);
      expect([
        for (final failure in told(tests)) failure.$1,
      ], contains('test/broken_test.dart'));
      expect([
        for (final running in tests.running) running.file,
      ], isNot(contains('test/broken_test.dart')));
    });

    test('the same error on a done loading test is a failure of its file in '
        'a run that was not stopped', () async {
      final lines = flutterTestOutput('passing', app).trimRight().split('\n');
      scriptFlutterTest(
        runner,
        sdk,
        RunResult(
          exitCode: 1,
          stdout: [
            ...lines.take(lines.length - 1),
            stopErrorOn(1),
            '{"success":false,"type":"done","time":2754}',
          ].join('\n'),
        ),
      );
      final tests = await run();
      expect(tests.timedOut, isFalse);
      expect(told(tests), [
        (
          'test/passing_test.dart',
          null,
          null,
          'Bad state: Cannot close sink while adding stream.',
        ),
      ]);
    });

    test('a test that starts after a test was done with `error` ends the '
        'stop\'s lines: that one is a test whose process ended', () async {
      scriptFlutterTest(
        runner,
        sdk,
        RunResult.timedOut(
          stdout: [
            failingRun(),
            closedByStop(19),
            '{"test":{"id":20,"name":"shows yet more text","suiteID":6,'
                '"groupIDs":[14],"metadata":{"skip":false,"skipReason":null},'
                '"line":null,"column":null,"url":null},"type":"testStart",'
                '"time":75013}',
          ].join('\n'),
          stderr: '',
        ),
      );
      final tests = await run(timeout: const Duration(seconds: 2));
      expect(names(tests).last, 'shows other text');
      expect(tests.running.last, (
        file: 'test/widgets/failing_test.dart',
        test: 'shows yet more text',
      ));
    });

    test('a test whose process ended well before the stop is still a '
        'failing test in a stopped run', () async {
      // The real run with a test that calls `exit`, up to the start of the
      // last test, which then never ends.
      final printed = flutterTestOutput(
        'crash',
        app,
      ).split('\n').take(21).join('\n');
      scriptFlutterTest(
        runner,
        sdk,
        RunResult.timedOut(
          stdout: stoppedOnPosix(printed, closed: [9]),
          stderr: '',
        ),
      );
      final tests = await run(timeout: const Duration(seconds: 2));
      expect(tests.timedOut, isTrue);
      expect(told(tests), [
        ('test/crash_test.dart', 9, 'ends its process', _ended),
        ('test/crash_test.dart', 12, 'after the crash', _ended),
      ]);
      expect(tests.running, [
        (file: 'test/real_failure_test.dart', test: 'fails for real'),
      ]);
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

  // A real run of Flutter 3.47.5 on Windows: a test calls `exit(0)`. Its
  // test process ends, and `package:test` tells that test, and every later
  // test of the same file, as done with `error` and no error event before.
  group('a test whose process ends before it finishes', () {
    test('alone: each such test is a failing test that says its process '
        'ended, in a finished run', () async {
      final crash = flutterTestOutput('crash', app)
          .split('\n')
          .where(
            (line) => !line.contains('"testID":9') && !line.contains('"id":9,'),
          )
          .join('\n');
      scriptFlutterTest(runner, sdk, RunResult(exitCode: 1, stdout: crash));
      final tests = await run();
      expect(
        (tests.timedOut, tests.cutShort, tests.unexplained),
        (false, false, false),
      );
      expect(told(tests), [
        ('test/crash_test.dart', 9, 'ends its process', _ended),
        ('test/crash_test.dart', 12, 'after the crash', _ended),
      ]);
      expect(tests.running, isEmpty);
    });

    test('with a real failure in another file: both are told', () async {
      scriptFlutterTest(
        runner,
        sdk,
        RunResult(exitCode: 1, stdout: flutterTestOutput('crash', app)),
      );
      final tests = await run();
      expect(
        (tests.timedOut, tests.cutShort, tests.unexplained),
        (false, false, false),
      );
      expect(told(tests), [
        ('test/crash_test.dart', 9, 'ends its process', _ended),
        ('test/crash_test.dart', 12, 'after the crash', _ended),
        (
          'test/real_failure_test.dart',
          4,
          'fails for real',
          'Expected: <2> Actual: <1>',
        ),
      ]);
    });
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

    test('its last words leave out the lines Flutter prints for each test '
        'process it starts', () async {
      scriptFlutterTest(
        runner,
        sdk,
        const RunResult(
          exitCode: 1,
          stdout:
              'Something went wrong.\n'
              '[{"event":"test.startedProcess","params":'
              '{"vmServiceUri":null}}]\n',
        ),
      );
      final tests = await run();
      expect(tests.said, 'Something went wrong');
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
