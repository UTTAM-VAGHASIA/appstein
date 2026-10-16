import 'package:appstein_engine/appstein_engine.dart';

/// What the terminal tells a person whose setup is the problem.
const doctorAdvice = 'Run `appstein doctor` to check your setup.';

/// What the terminal tells a person after a crash, which is a bug to report.
const crashAdvice =
    'Run `appstein doctor` to check your setup. If this keeps '
    'happening, please report it with the details below.';

/// A command that could not start for a reason the person can fix: the
/// [problem] and what to do about it, [advice]. `runAppstein` reports it.
final class CannotStart implements Exception {
  /// Creates the exception.
  const CannotStart(this.problem, this.advice);

  /// What is wrong, as a sentence.
  final String problem;

  /// What to do about it.
  final String advice;
}

/// How Appstein tells that it failed (spec §9.5), in one place so the
/// terminal and a hook use the same words: the [reason], what to do about it
/// ([advice]) and, for a bug, where it happened ([trace]).
final class FailureDescription {
  /// Creates the description.
  const FailureDescription({required this.reason, this.advice, this.trace});

  /// What failed.
  final String reason;

  /// What to do about it; null when [reason] says enough.
  final String? advice;

  /// Where a crash happened; null for a failure that is no bug.
  final StackTrace? trace;

  /// Writes the failure the way the terminal shows it, one line each.
  void writeTo(StringSink sink) {
    sink.writeln(reason);
    if (advice case final advice?) sink.writeln(advice);
    if (trace case final trace?) sink.writeln(trace);
  }

  /// [writeTo] as a string.
  String get text {
    final buffer = StringBuffer();
    writeTo(buffer);
    return buffer.toString();
  }
}

/// The failure of a crash: a bug, with its [trace].
FailureDescription unexpectedFailure(Object error, StackTrace trace) =>
    FailureDescription(
      reason: 'Appstein failed unexpectedly: $error',
      advice: crashAdvice,
      trace: trace,
    );

/// How [error], which stopped a run at [trace], is told (spec §9.5):
/// - [CannotStart]: its problem and what to do;
/// - [ConfigException]: the file is invalid;
/// - [CodeAnalysisException] and [TestRunException]: its reason and
///   `appstein doctor`, with no trace, since it is a broken setup and not a
///   bug;
/// - anything else, a check that threw included: a crash, with the trace of
///   where it happened (a check's own trace for a [VerifyCheckError]).
FailureDescription describeFailure(Object error, StackTrace trace) =>
    switch (error) {
      CannotStart() => FailureDescription(
        reason: error.problem,
        advice: error.advice,
      ),
      ConfigException() => FailureDescription(
        reason: 'Invalid appstein.yaml: $error',
      ),
      CodeAnalysisException() || TestRunException() => FailureDescription(
        reason: '$error',
        advice: doctorAdvice,
      ),
      VerifyCheckError() => unexpectedFailure(error, error.stackTrace),
      _ => unexpectedFailure(error, trace),
    };
