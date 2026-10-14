import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../knowledge/support/sync_harness.dart';
import '../../support/fake_process_runner.dart';
import '../../support/fixture_app.dart';
import '../../support/flutter_test_output.dart';
import '../../support/scripted_code_analysis.dart';

const _packs = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];

const _analyzerError = CodeDiagnostic(
  file: 'lib/main.dart',
  line: 3,
  code: 'undefined_identifier',
  message: 'Undefined name.',
  level: DiagnosticLevel.error,
);

// `test.failed` through `runVerify`, with the process runner scripted
// (slice 1d.2, seam 3). The fixture app has a `test/` folder.
void main() {
  late String sdk;
  late String app;
  late FakeProcessRunner runner;
  late ScriptedCodeAnalysis analysis;

  setUp(() {
    sdk = fakeFlutter();
    app = copyFixtureApp();
    runner = FakeProcessRunner();
    analysis = ScriptedCodeAnalysis();
  });

  Future<VerifyResult> verify({
    VerifyMode mode = VerifyMode.full,
    AppsteinConfig config = const AppsteinConfig(),
    List<VerifyCheck> checks = const [TestFailedCheck()],
    String? flutterRoot,
  }) => runVerify(
    projectRoot: app,
    config: config,
    packs: _packs,
    sync: knowledgeSync(
      flutterRoot: flutterRoot ?? sdk,
      runner: runner,
      packs: _packs,
      packageSkills: false,
    ),
    mode: mode,
    checks: [for (final check in checks) (check: check, pack: null)],
    codeAnalysis: analysis,
    dartSdkPath: testDartSdk,
  );

  int testRuns() =>
      runner.calls.where((call) => call.contains(' test ')).length;

  void scriptFailing() => scriptFlutterTest(
    runner,
    sdk,
    RunResult(exitCode: 1, stdout: flutterTestOutput('failing', app)),
  );

  test('the check is a full check that needs no map', () {
    const check = TestFailedCheck();
    expect(check.ids, ['test.failed']);
    expect(check.mode, VerifyMode.full);
    expect(check.needsMap, isFalse);
  });

  test('a passing run: no finding, nothing named as not run, and the '
      'tests ran once', () async {
    scriptFlutterTest(
      runner,
      sdk,
      RunResult(exitCode: 0, stdout: flutterTestOutput('passing', app)),
    );
    final result = await verify();
    expect(result.findings, isEmpty);
    expect(result.notRun, isEmpty);
    expect(testRuns(), 1);
    expect(runner.workingDirectories.last, app);
    // The default of `verify.test_timeout_seconds`.
    expect(runner.timeouts.last, const Duration(seconds: 600));
  });

  group('a failing run', () {
    late VerifyResult result;

    setUp(() async {
      scriptFailing();
      result = await verify();
    });

    Finding on(String file, int? line) => result.findings.singleWhere(
      (finding) => finding.file == file && finding.line == line,
    );

    test('each failing test is one test.failed error, in file and line '
        'order', () {
      expect(
        [
          for (final finding in result.findings)
            (finding.id, finding.severity, finding.file, finding.line),
        ],
        [
          ('test.failed', Severity.error, 'test/broken_test.dart', null),
          (
            'test.failed',
            Severity.error,
            'test/my folder/spaced_test.dart',
            null,
          ),
          (
            'test.failed',
            Severity.error,
            'test/my folder/spaced_test.dart',
            null,
          ),
          ('test.failed', Severity.error, 'test/widgets/failing_test.dart', 8),
          ('test.failed', Severity.error, 'test/widgets/failing_test.dart', 12),
          ('test.failed', Severity.error, 'test/widgets/failing_test.dart', 18),
          ('test.failed', Severity.error, 'test/widgets/failing_test.dart', 28),
        ],
      );
      expect(result.errors, 7);
      expect(result.notRun, isEmpty);
      expect(testRuns(), 1);
    });

    test('a failing expectation: the whole finding', () {
      final finding = on('test/widgets/failing_test.dart', 8);
      expect(
        finding.message,
        'The test `counter next adds two` failed: Expected: <3> Actual: <2>',
      );
      expect(
        finding.fixHint,
        'Run `flutter test test/widgets/failing_test.dart` to see the whole '
        'failure.',
      );
      expect(finding.pack, isNull);
      expect(finding.knowledgeRef, isNull);
    });

    test('a thrown error is reported the same way', () {
      final finding = on('test/widgets/failing_test.dart', 12);
      expect(
        finding.message,
        'The test `counter next throws` failed: Bad state: the counter broke',
      );
      expect(
        finding.fixHint,
        'Run `flutter test test/widgets/failing_test.dart` to see the whole '
        'failure.',
      );
    });

    test('a file that can\'t load: one finding on the file, with the '
        'loader\'s message', () {
      final finding = on('test/broken_test.dart', null);
      expect(
        finding.message,
        'The test file could not be loaded: Compilation failed for '
        'testPath=test/broken_test.dart: test/broken_test.dart:6:12: Error: '
        'Method not found: \'nextt\'. expect(nextt(1), 2);',
      );
      expect(
        finding.fixHint,
        'Run `flutter test test/broken_test.dart` to see the whole failure.',
      );
    });

    test('a path with a space is quoted in the fix hint', () {
      final spaced = result.findings
          .where((finding) => finding.file == 'test/my folder/spaced_test.dart')
          .toList();
      expect(
        spaced.first.message,
        'The test `a widget in a folder with a space` failed: The following '
        'TestFailure was thrown running a test: Expected: no matching '
        'candidates Actual: _TextWidgetFinder:<Found 1 widget with text '
        '"hello": [ Text("hello", dependencies: [MediaQuery]), ]> Which: '
        'means one was found but none were expected',
      );
      expect(
        spaced.last.message,
        'The test `in a folder with a space` failed: Expected: <6> '
        'Actual: <5>',
      );
      expect(
        {for (final finding in spaced) finding.fixHint},
        {
          'Run `flutter test "test/my folder/spaced_test.dart"` to see the '
              'whole failure.',
        },
      );
    });
  });

  test('verify.severity changes test.failed, and a suppression hides '
      'it', () async {
    scriptFailing();
    final result = await verify(
      config: const AppsteinConfig(
        verify: VerifyConfig(severity: {'test.failed': Severity.warning}),
        suppressions: [
          SuppressionEntry(
            id: 'test.failed',
            path: 'test/widgets',
            reason: 'Being rewritten.',
            line: 4,
          ),
        ],
      ),
    );
    expect(
      [for (final finding in result.findings) (finding.file, finding.severity)],
      [
        ('test/broken_test.dart', Severity.warning),
        ('test/my folder/spaced_test.dart', Severity.warning),
        ('test/my folder/spaced_test.dart', Severity.warning),
      ],
    );
    expect((result.suppressed, result.activeSuppressions), (4, 1));
    expect(result.errors, 0);
  });

  group('the reading has an analyzer error', () {
    setUp(() => analysis.found = const [_analyzerError]);

    test('the tests are not run, and the check is named with that '
        'reason', () async {
      final result = await verify(
        checks: const [DartErrorCheck(), TestFailedCheck()],
      );
      expect(testRuns(), 0);
      expect(
        [for (final finding in result.findings) finding.id],
        ['dart.error'],
      );
      expect(
        [for (final entry in result.notRun) '${entry.id}: ${entry.reason}'],
        ['test.failed: the code has analyzer errors'],
      );
    });

    const hidden = SuppressionEntry(
      id: 'dart.error',
      path: 'lib/main.dart',
      reason: 'Hidden on purpose.',
      line: 3,
    );

    test('a hidden error still stops the tests, and is one test.failed error '
        'on the project: it is the reading, before overrides and '
        'suppressions', () async {
      final result = await verify(
        checks: const [DartErrorCheck(), TestFailedCheck()],
        config: const AppsteinConfig(suppressions: [hidden]),
      );
      expect(testRuns(), 0);
      final finding = result.findings.single;
      expect(finding.id, 'test.failed');
      expect(finding.severity, Severity.error);
      expect(finding.file, isNull);
      expect(finding.line, isNull);
      expect(
        finding.message,
        'The tests were not run, because the code has 1 analyzer error and '
        'none is reported as an error: a suppression or `verify.severity` '
        'hides it.',
      );
      expect(
        finding.fixHint,
        'Remove the suppression or the `verify.severity` entry for '
        '`dart.error`, fix the errors, then run `appstein verify` again.',
      );
      expect(result.suppressed, 1);
      expect(result.errors, 1);
      expect([for (final entry in result.notRun) entry.id], ['test.failed']);
    });

    test('an error lowered by verify.severity hides it the same way, and '
        'the errors are counted', () async {
      analysis.found = const [
        _analyzerError,
        CodeDiagnostic(
          file: 'lib/other.dart',
          line: 9,
          code: 'undefined_method',
          message: 'Undefined method.',
          level: DiagnosticLevel.error,
        ),
      ];
      final result = await verify(
        checks: const [DartErrorCheck(), TestFailedCheck()],
        config: const AppsteinConfig(
          verify: VerifyConfig(severity: {'dart.error': Severity.warning}),
        ),
      );
      expect(testRuns(), 0);
      expect(
        [for (final finding in result.findings) (finding.id, finding.severity)],
        [
          ('test.failed', Severity.error),
          ('dart.error', Severity.warning),
          ('dart.error', Severity.warning),
        ],
      );
      expect(
        result.findings.first.message,
        'The tests were not run, because the code has 2 analyzer errors and '
        'none is reported as an error: a suppression or `verify.severity` '
        'hides them.',
      );
    });

    test('one error still reported as an error keeps the tests unrun and '
        'named, with no test.failed finding', () async {
      analysis.found = const [
        _analyzerError,
        CodeDiagnostic(
          file: 'lib/other.dart',
          line: 9,
          code: 'undefined_method',
          message: 'Undefined method.',
          level: DiagnosticLevel.error,
        ),
      ];
      final result = await verify(
        checks: const [DartErrorCheck(), TestFailedCheck()],
        config: const AppsteinConfig(suppressions: [hidden]),
      );
      expect(testRuns(), 0);
      expect(
        [for (final finding in result.findings) (finding.id, finding.file)],
        [('dart.error', 'lib/other.dart')],
      );
      expect(result.suppressed, 1);
      expect([for (final entry in result.notRun) entry.id], ['test.failed']);
    });

    test('that finding can be lowered with verify.severity, and a '
        'suppression does not reach it', () async {
      final result = await verify(
        checks: const [DartErrorCheck(), TestFailedCheck()],
        config: const AppsteinConfig(
          verify: VerifyConfig(severity: {'test.failed': Severity.warning}),
          suppressions: [
            hidden,
            SuppressionEntry(
              id: 'test.failed',
              path: '.',
              reason: 'Hide the hiding.',
              line: 5,
            ),
          ],
        ),
      );
      final finding = result.findings.firstWhere(
        (finding) => finding.id == 'test.failed',
      );
      expect(finding.severity, Severity.warning);
      expect(finding.file, isNull);
      expect(result.suppressed, 1);
    });

    test('it counts without the dart.error check in the run: no finding of '
        'the errors is left as an error', () async {
      final result = await verify();
      expect(testRuns(), 0);
      expect(result.findings.single.id, 'test.failed');
      expect(result.notRun.single.reason, 'the code has analyzer errors');
    });

    test('a suppression of test.failed is then not reported as '
        'unused', () async {
      final result = await verify(
        checks: const [DartErrorCheck(), TestFailedCheck()],
        config: const AppsteinConfig(
          suppressions: [
            SuppressionEntry(
              id: 'test.failed',
              path: 'test/widgets',
              reason: 'Being rewritten.',
              line: 4,
            ),
          ],
        ),
      );
      expect(
        [for (final finding in result.findings) finding.id],
        ['dart.error'],
      );
    });

    test('a warning and an info-level diagnostic do not stop the '
        'tests', () async {
      analysis.found = const [
        CodeDiagnostic(
          file: 'lib/main.dart',
          line: 1,
          code: 'unused_import',
          message: 'Unused import.',
          level: DiagnosticLevel.warning,
        ),
        CodeDiagnostic(
          file: 'lib/main.dart',
          line: 2,
          code: 'prefer_const',
          message: 'Prefer const.',
          level: DiagnosticLevel.info,
        ),
      ];
      scriptFlutterTest(runner, sdk);
      final result = await verify();
      expect(testRuns(), 1);
      expect(result.notRun, isEmpty);
    });
  });

  test('the tests run while gathering: after the knowledge refresh, while '
      'the knowledge lock is free, and before any check runs', () async {
    scriptFlutterTest(runner, sdk);
    final log = <String>[];
    Object? lockProblem;
    runner.onRun = (command) async {
      if (!command.contains(' test ')) return;
      log.add(
        'tests, index: '
        '${File(p.join(app, '.appstein', 'INDEX.md')).existsSync()}',
      );
      // A lock taken from here would wait if the run held it: on Windows a
      // second handle in one process can't share a file lock.
      try {
        await KnowledgeStore(
          app,
        ).locked(() async {}, timeout: const Duration(milliseconds: 300));
      } on Object catch (error) {
        lockProblem = error;
      }
    };
    await verify(checks: [_LoggingCheck(log), const TestFailedCheck()]);
    expect(lockProblem, isNull);
    expect(log, ['tests, index: true', 'run logging.check']);
  });

  test('a fast run never runs the tests and does not name the check, with '
      'an analyzer error too', () async {
    for (final found in [
      const <CodeDiagnostic>[],
      const [_analyzerError],
    ]) {
      analysis.found = found;
      final result = await verify(
        mode: VerifyMode.fast,
        checks: const [DartErrorCheck(), TestFailedCheck()],
      );
      expect(testRuns(), 0);
      expect(result.notRun, isEmpty);
      expect([
        for (final finding in result.findings) finding.id,
      ], found.isEmpty ? isEmpty : ['dart.error']);
    }
  });

  group('a project with nothing to test', () {
    test('no test folder: no finding, not named as not run, nothing '
        'started', () async {
      Directory(p.join(app, 'test')).deleteSync(recursive: true);
      final result = await verify();
      expect(result.findings, isEmpty);
      expect(result.notRun, isEmpty);
      expect(testRuns(), 0);
    });
  });

  group('a suite that is still running at the limit', () {
    test('is stopped at verify.test_timeout_seconds and reported as one '
        'test.failed on the project, naming the limit and the key', () async {
      scriptFlutterTest(
        runner,
        sdk,
        RunResult.timedOut(
          stdout: flutterTestOutput(
            'failing',
            app,
          ).split('\n').take(40).join('\n'),
          stderr: 'Timed out after 45 s',
        ),
      );
      final result = await verify(
        config: const AppsteinConfig(
          verify: VerifyConfig(testTimeoutSeconds: 45),
        ),
      );
      expect(runner.timeouts.last, const Duration(seconds: 45));
      // The failures it had told are kept.
      expect(
        [for (final finding in result.findings) (finding.file, finding.line)],
        [
          (null, null),
          ('test/broken_test.dart', null),
          ('test/widgets/failing_test.dart', 8),
          ('test/widgets/failing_test.dart', 12),
        ],
      );
      final finding = result.findings.firstWhere((f) => f.file == null);
      expect(finding.id, 'test.failed');
      expect(finding.severity, Severity.error);
      expect(
        finding.message,
        'The tests were still running after 45 s and were stopped. The limit '
        'is `verify.test_timeout_seconds` in `appstein.yaml`. Running when it '
        'stopped: `in a folder with a space` in test/my folder/spaced_test.dart, '
        '`shows other text` in test/widgets/failing_test.dart.',
      );
      expect(
        finding.fixHint,
        'Run `flutter test` to find the test that does not end, or raise '
        '`verify.test_timeout_seconds`.',
      );
      expect(result.notRun, isEmpty);
    });

    test('with nothing told, it is the one finding', () async {
      scriptFlutterTest(
        runner,
        sdk,
        const RunResult.timedOut(stdout: '', stderr: 'Timed out'),
      );
      final result = await verify();
      expect(result.findings.single.message, startsWith('The tests were'));
      expect(result.findings.single.message, endsWith('`appstein.yaml`.'));
    });

    test('names at most five of the tests that were running', () async {
      final root = app.replaceAll(r'\', '/');
      final events = [
        '{"suite":{"id":0,"platform":"vm","path":"$root/test/many_test.dart"},'
            '"type":"suite","time":0}',
        for (var id = 1; id <= 7; id++)
          '{"test":{"id":$id,"name":"t$id","suiteID":0,"groupIDs":[],'
              '"line":null,"column":null,"url":null},'
              '"type":"testStart","time":$id}',
      ];
      scriptFlutterTest(
        runner,
        sdk,
        RunResult.timedOut(stdout: events.join('\n'), stderr: ''),
      );
      final message = (await verify()).findings.single.message;
      expect(
        message,
        endsWith(
          'Running when it stopped: `t1` in test/many_test.dart, `t2` in '
          'test/many_test.dart, `t3` in test/many_test.dart, `t4` in '
          'test/many_test.dart, `t5` in test/many_test.dart and 2 more.',
        ),
      );
    });
  });

  group('a run whose output ends before the end of the run', () {
    test('is not a finished run: the failures it told, and one error on the '
        'project naming the test that was open', () async {
      scriptFlutterTest(
        runner,
        sdk,
        RunResult(exitCode: 1, stdout: flutterTestOutput('truncated', app)),
      );
      final result = await verify();
      expect(result.errors, 17);
      final finding = result.findings.singleWhere((f) => f.file == null);
      expect(finding.id, 'test.failed');
      expect(finding.severity, Severity.error);
      expect(
        finding.message,
        'The tests did not finish: `flutter test` ended with exit code 1 '
        'before it told the end of the run, so only the failures it had told '
        'are listed. Running when it stopped: `prints a lot then fails` in '
        'test/unit/nested_test.dart.',
      );
      expect(
        finding.fixHint,
        'Run `flutter test` in the project to see why it stopped.',
      );
    });
  });

  group('`flutter test` ran and named no failing test', () {
    test('it is one error on the project, with Flutter\'s last lines: not '
        'Appstein failing', () async {
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
      final result = await verify();
      final finding = result.findings.single;
      expect(finding.id, 'test.failed');
      expect(finding.severity, Severity.error);
      expect(finding.file, isNull);
      expect(
        finding.message,
        'The tests gave no result: `flutter test` ended with exit code 1 and '
        'named no failing test (Error: cannot run without a dependency on '
        '"package:flutter_test". Add it to pubspec.yaml).',
      );
      expect(
        finding.fixHint,
        'Run `flutter test` in the project to see the full output.',
      );
      expect(result.errors, 1);
    });

    test('without any words, the message ends after the exit code', () async {
      scriptFlutterTest(runner, sdk, const RunResult(exitCode: 2));
      expect(
        (await verify()).findings.single.message,
        'The tests gave no result: `flutter test` ended with exit code 2 and '
        'named no failing test.',
      );
    });
  });

  group('`flutter test` cannot be run: Appstein fails', () {
    test('it can\'t be started: a TestRunException, not a finding and not '
        'a check\'s error', () async {
      // Nothing is scripted for `flutter test`.
      await expectLater(
        verify(),
        throwsA(
          isA<TestRunException>().having(
            (error) => '$error',
            'text',
            allOf(
              startsWith(
                'The project\'s tests could not be run: `flutter test` could '
                'not be started with ',
              ),
              endsWith('.'),
            ),
          ),
        ),
      );
    });
  });

  // What a machine without a Flutter SDK gets, where the code analysis
  // answered all the same (a real one fails first, for the same reason).
  test('no usable Flutter SDK: the knowledge is stale, and the run fails '
      'with a TestRunException, not with a finding', () async {
    await expectLater(
      verify(flutterRoot: p.join(app, 'no such sdk')),
      throwsA(
        isA<TestRunException>().having(
          (error) => error.reason,
          'reason',
          startsWith('the project has no usable Flutter SDK ('),
        ),
      ),
    );
    expect(testRuns(), 0);
  });

  test('a check that reads the test run without gathering it fails the '
      'run by name', () async {
    scriptFlutterTest(runner, sdk);
    await expectLater(
      verify(checks: [const TestFailedCheck(), _ForgetfulCheck()]),
      throwsA(
        isA<VerifyCheckError>()
            .having((error) => error.checkId, 'check', 'forgetful.check')
            .having(
              (error) => '${error.error}',
              'error',
              contains('read the test run without gathering it'),
            ),
      ),
    );
  });
}

/// A check that writes to [log] when it runs.
final class _LoggingCheck implements VerifyCheck {
  _LoggingCheck(this.log);

  final List<String> log;

  @override
  List<String> get ids => const ['logging.check'];

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    log.add('run logging.check');
    return const [];
  }
}

/// A check that reads the test run without gathering it: a bug.
final class _ForgetfulCheck implements VerifyCheck {
  @override
  List<String> get ids => const ['forgetful.check'];

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    context.tests;
    return const [];
  }
}
