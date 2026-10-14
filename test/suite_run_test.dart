import 'package:test/test.dart';

import '../tool/src/suite_run.dart';

void main() {
  group('judgeTestRun', () {
    test('exit 0 and "All tests passed!" pass, with the counts', () {
      final verdict = judgeTestRun(
        0,
        '00:01 +5: some test\n00:02 +238 ~1: All tests passed!\n',
      );
      expect(verdict.passed, isTrue);
      expect(verdict.tests, 238);
      expect(verdict.skipped, 1);
      expect(verdict.failed, 0);
      expect(verdict.reason, '238 passed, 1 skipped');
    });

    test('a failing test fails even when the exit code is 0, as a script '
        'that only prints would give', () {
      final verdict = judgeTestRun(
        0,
        '02:08 +1023 ~8 -1: test\\a_test.dart: a test [E]\n'
        '  Expected: not true\n'
        '02:10 +1528 ~8 -1: Some tests failed.\n',
      );
      expect(verdict.passed, isFalse);
      expect(verdict.failed, 1);
      expect(verdict.reason, 'exit code 0: 1528 passed, 8 skipped, 1 failed');
    });

    test('a non-zero exit fails even when the last line says every test '
        'passed', () {
      expect(judgeTestRun(1, '00:02 +3: All tests passed!').passed, isFalse);
    });

    test('a run cut short, with no last line of results, fails', () {
      final verdict = judgeTestRun(0, '00:01 +3: a test that was running\n');
      expect(verdict.passed, isFalse);
      expect(judgeTestRun(0, '').passed, isFalse);
      expect(judgeTestRun(0, '').reason, 'exit code 0: ');
    });

    test('Windows line ends and trailing blank lines are read', () {
      final verdict = judgeTestRun(0, '00:00 +79: All tests passed!\r\n\r\n');
      expect(verdict.passed, isTrue);
      expect(verdict.tests, 79);
      expect(verdict.skipped, 0);
    });
  });

  group('judgeTool', () {
    test('passes on exit 0 and says its last line', () {
      final verdict = judgeTool(0, 'Guide check passed.\n');
      expect(verdict.passed, isTrue);
      expect(verdict.reason, 'Guide check passed.');
    });

    test('fails on any other exit code', () {
      final verdict = judgeTool(1, 'docs/guide/verify.md: out of date\n');
      expect(verdict.passed, isFalse);
      expect(verdict.reason, 'exit code 1: docs/guide/verify.md: out of date');
    });
  });

  test('failureLines keeps the failing tests and what they expected', () {
    final lines = failureLines(
      '00:01 +1: fine\n'
      '00:02 +1 -1: broken [E]\n'
      '  Expected: <1>\n'
      '    Actual: <2>\n'
      '00:03 +2 -1: also fine\n',
    );
    expect(lines, [
      '00:02 +1 -1: broken [E]',
      '  Expected: <1>',
      '    Actual: <2>',
    ]);
  });
}
