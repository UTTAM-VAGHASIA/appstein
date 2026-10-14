/// How one step of `tool/test_all.dart` ended, judged from its exit code
/// and its output.
final class SuiteVerdict {
  /// Creates a verdict.
  const SuiteVerdict({
    required this.passed,
    required this.reason,
    this.tests,
    this.skipped,
    this.failed,
  });

  /// Whether the step passed: it exited 0 and, for a test suite, its last
  /// line says every test passed.
  final bool passed;

  /// One line that says why: the test counts, or what went wrong.
  final String reason;

  /// The number of tests that passed, when the output said it.
  final int? tests;

  /// The number of tests that were skipped, when the output said it.
  final int? skipped;

  /// The number of tests that failed, when the output said it.
  final int? failed;
}

/// The counts at the start of `dart test`'s progress lines:
/// `+12`, then optionally `~3` skipped and `-1` failed.
final _counts = RegExp(r'\+(\d+)(?: ~(\d+))?(?: -(\d+))?:');

/// Judges a `dart test` run that exited with [exitCode] and printed
/// [output]. It passes only when both agree: exit code 0 and a last line
/// that says `All tests passed!`. Either alone is not trusted, so a script
/// that only prints, or a run cut short, never reads as green.
SuiteVerdict judgeTestRun(int exitCode, String output) {
  final lines = output
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final last = lines.isEmpty ? '' : lines.last;
  final match = _counts.allMatches(last).lastOrNull;
  final tests = match == null ? null : int.parse(match.group(1)!);
  final skipped = match?.group(2) == null ? 0 : int.parse(match!.group(2)!);
  final failed = match?.group(3) == null ? 0 : int.parse(match!.group(3)!);
  final allPassed = last.contains('All tests passed!');
  if (exitCode == 0 && allPassed && failed == 0) {
    return SuiteVerdict(
      passed: true,
      reason: '$tests passed, $skipped skipped',
      tests: tests,
      skipped: skipped,
      failed: 0,
    );
  }
  return SuiteVerdict(
    passed: false,
    reason: match == null
        ? 'exit code $exitCode: $last'
        : 'exit code $exitCode: $tests passed, $skipped skipped, '
              '$failed failed',
    tests: tests,
    skipped: match == null ? null : skipped,
    failed: match == null ? null : failed,
  );
}

/// Judges a step that is not a test suite (a check or a generator): it
/// passes when it exited 0.
SuiteVerdict judgeTool(int exitCode, String output) {
  final lines = output
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final last = lines.isEmpty ? '(no output)' : lines.last;
  return SuiteVerdict(
    passed: exitCode == 0,
    reason: exitCode == 0 ? last : 'exit code $exitCode: $last',
  );
}

/// The lines of a failed run worth showing: the failing tests and what
/// they expected, at most [limit] of them.
List<String> failureLines(String output, {int limit = 40}) {
  final worth = RegExp(
    r'\[E\]|Expected|Actual|TimeoutException|Error|error|survivor|outliv',
  );
  return output
      .split(RegExp(r'\r?\n'))
      .where(worth.hasMatch)
      .take(limit)
      .toList();
}
