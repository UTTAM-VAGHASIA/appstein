import 'package:appstein_protocol/appstein_protocol.dart';

import '../deprecation_ignores.dart';
import '../test_run.dart';
import '../verify_check.dart';

/// `test.failed`: the project's tests, run once in a full run with
/// `flutter test` of the project's Flutter (slice 1d.2, spec §9.2).
///
/// - **Each failing test** is an error on the test's file and line, with the
///   test's full name (its groups included) and the first lines of the
///   failure. A test that threw is reported as one whose expectation failed.
/// - **A test file that can't be loaded** is one error on that file, with
///   the loader's message.
/// - **A test file that reports an error after it loaded** is one error on
///   that file, worded as such, not as a file that could not be loaded. The
///   cause is not told: it was seen once, on Linux CI, with its text not
///   recorded. The likely cause, from Flutter's source, is the shutdown
///   error of the `flutter_tester` process, which Flutter adds to a suite
///   that has finished, and fails the run for; an error from the file's own
///   code after it loaded is possible too.
/// - **A run that does not finish** keeps what it told: its failures are
///   reported as above, and one more error on the project says the run did
///   not finish, naming the tests that were running when it stopped. That is
///   a run still going at `verify.test_timeout_seconds`, which is stopped,
///   and a run whose output ends without the end of the run.
/// - **A run that ends with a failing exit code and names no failing test**
///   is one error on the project, with Flutter's last lines.
/// - **While the run's reading of the code has an analyzer error**, the
///   tests are not run: they would not compile. The check then names itself
///   among the checks that did not run. It is the reading that counts, so an
///   error that `verify.severity` lowered or a suppression hid still stops
///   the tests. When none of those errors is left as an error in the
///   result, the tests that were not run are one error on the project too
///   ([following]), so hidden errors never give a green run. Each error is
///   looked for among the findings of the check that reports it:
///   `dart.error`, or `dart.deprecated` for a deprecated use that
///   `analysis_options.yaml` raised to an error. The fix hint names those
///   checks.
/// - **A project with no test file** gives nothing, and is not named, also
///   while the code has analyzer errors, hidden or not: no test was kept
///   from running. That is `verify.test_required`'s finding.
///
/// The tests run while gathering, before the knowledge lock is taken, since
/// they can take minutes (`VerifyGathering.tests`). Tests that can't be run
/// at all (no Flutter SDK, `flutter test` not started) are Appstein failing
/// (`TestRunException`), not a finding.
final class TestFailedCheck implements GatheringCheck, FollowingCheck {
  /// Creates the check.
  const TestFailedCheck();

  static const _id = 'test.failed';

  /// How many running tests a finding names.
  static const _namedRunning = 5;

  @override
  List<String> get ids => const [_id];

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  bool get needsMap => false;

  static int _errors(CodeReading reading) => _errorDiagnostics(reading).length;

  static Iterable<CodeDiagnostic> _errorDiagnostics(CodeReading reading) =>
      reading.diagnostics.where(
        (diagnostic) => diagnostic.level == DiagnosticLevel.error,
      );

  /// The check that reports the analyzer error [diagnostic]: `dart.error`,
  /// or `dart.deprecated` for a deprecated use raised to an error, which
  /// `dart.error` leaves to it.
  static String _owner(CodeDiagnostic diagnostic) =>
      isDeprecatedUseCode(diagnostic.code) ? 'dart.deprecated' : 'dart.error';

  /// Whether [diagnostic] is among [kept] as an error of the check that
  /// reports it, with the place and message that check gives it.
  static bool _shown(CodeDiagnostic diagnostic, List<Finding> kept) {
    final id = _owner(diagnostic);
    final message = '${diagnostic.message} (`${diagnostic.code}`)';
    return kept.any(
      (finding) =>
          finding.id == id &&
          finding.severity == Severity.error &&
          finding.file == diagnostic.file &&
          finding.line == diagnostic.line &&
          finding.message == message,
    );
  }

  @override
  Future<void> gather(VerifyGathering gathering) async {
    if (_errors(await gathering.code()) > 0) return;
    await gathering.tests();
  }

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    if (_errors(context.code) > 0) {
      // With nothing to test, nothing was kept from running.
      if (!hasTestFiles(context.projectRoot)) return const [];
      context.notRun(_id, 'the code has analyzer errors');
      return const [];
    }
    final tests = context.tests;
    return [
      for (final failure in tests.failures)
        Finding(
          id: _id,
          severity: Severity.error,
          file: failure.file,
          line: failure.line,
          message: switch ((failure.test, failure.afterLoading)) {
            (final name?, _) => 'The test `$name` failed: ${failure.details}',
            (null, true) =>
              'This test file reported an error after it loaded: '
                  '${failure.details}',
            (null, false) =>
              'The test file could not be loaded: ${failure.details}',
          },
          fixHint:
              'Run `flutter test ${_argument(failure.file)}` to see the '
              'whole failure.',
        ),
      if (tests.timedOut)
        Finding(
          id: _id,
          severity: Severity.error,
          message:
              'The tests were still running after '
              '${context.config.verify.testTimeoutSeconds} s and were '
              'stopped. The limit is `verify.test_timeout_seconds` in '
              '`appstein.yaml`.${_runningSentence(tests.running)}',
          fixHint:
              'Run `flutter test` to find the test that does not end, or '
              'raise `verify.test_timeout_seconds`.',
        )
      else if (tests.cutShort)
        Finding(
          id: _id,
          severity: Severity.error,
          message:
              'The tests did not finish: `flutter test` ended with exit code '
              '${tests.exitCode} before it told the end of the run, so only '
              'the failures it had told are listed.'
              '${_runningSentence(tests.running)}',
          fixHint: 'Run `flutter test` in the project to see why it stopped.',
        )
      else if (tests.unexplained)
        Finding(
          id: _id,
          severity: Severity.error,
          message:
              'The tests gave no result: `flutter test` ended with exit code '
              '${tests.exitCode} and named no failing test'
              '${tests.said.isEmpty ? '' : ' (${tests.said})'}.',
          fixHint: 'Run `flutter test` in the project to see the full output.',
        ),
    ];
  }

  @override
  List<Finding> following(VerifyContext context, List<Finding> kept) {
    final diagnostics = _errorDiagnostics(context.code).toList();
    final errors = diagnostics.length;
    if (errors == 0 || !hasTestFiles(context.projectRoot)) return const [];
    // The reading's errors are `dart.error` findings, and `dart.deprecated`
    // ones for a deprecated use raised to an error: while one is still an
    // error, the result is not green. Otherwise every one was lowered or
    // suppressed (or its check is not in the run), and the tests that were
    // not run must not look like passed.
    if (diagnostics.any((diagnostic) => _shown(diagnostic, kept))) {
      return const [];
    }
    final owners = [
      for (final id in const ['dart.error', 'dart.deprecated'])
        if (diagnostics.any((diagnostic) => _owner(diagnostic) == id)) id,
    ];
    final both = owners.length > 1;
    return [
      Finding(
        id: _id,
        severity: Severity.error,
        message:
            'The tests were not run, because the code has $errors analyzer '
            '${errors == 1 ? 'error' : 'errors'} and none is reported as an '
            'error: a suppression or `verify.severity` hides '
            '${errors == 1 ? 'it' : 'them'}.',
        fixHint:
            'Remove the ${both ? 'suppressions' : 'suppression'} or the '
            '`verify.severity` ${both ? 'entries' : 'entry'} for '
            '${owners.map((id) => '`$id`').join(' and ')}, fix the errors, '
            'then run `appstein verify` again.',
      ),
    ];
  }

  /// " Running when it stopped: …" for the tests in [running], at most
  /// [_namedRunning] of them; empty when none was.
  static String _runningSentence(List<RunningTest> running) {
    if (running.isEmpty) return '';
    final named = [
      for (final test in running.take(_namedRunning))
        switch (test.test) {
          final name? => '`$name` in ${test.file}',
          null => '${test.file} (being loaded)',
        },
    ];
    final more = running.length - named.length;
    return ' Running when it stopped: ${named.join(', ')}'
        '${more > 0 ? ' and $more more' : ''}.';
  }

  /// [path] as one argument of a command line.
  static String _argument(String path) => path.contains(' ') ? '"$path"' : path;
}
