import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../sdk/sdk_detector.dart';

/// The outcome of one doctor check.
enum CheckStatus {
  /// Everything is fine.
  ok,

  /// Worth knowing, nothing to fix.
  info,

  /// Something may cause trouble later.
  warning,

  /// Something Appstein or Flutter needs is broken or missing.
  error,

  /// The check doesn't apply here.
  skipped,
}

/// What a doctor check found.
final class CheckResult {
  /// A result with any [status].
  const CheckResult(
    this.status,
    this.summary, {
    this.details = const [],
    this.fixHint,
  });

  /// Everything is fine.
  const CheckResult.ok(this.summary, {this.details = const []})
    : status = CheckStatus.ok,
      fixHint = null;

  /// Worth knowing, nothing to fix.
  const CheckResult.info(this.summary, {this.details = const []})
    : status = CheckStatus.info,
      fixHint = null;

  /// Something may cause trouble later.
  const CheckResult.warning(
    this.summary, {
    this.details = const [],
    this.fixHint,
  }) : status = CheckStatus.warning;

  /// Something is broken or missing.
  const CheckResult.error(this.summary, {this.details = const [], this.fixHint})
    : status = CheckStatus.error;

  /// The check doesn't apply here.
  const CheckResult.skipped(this.summary)
    : status = CheckStatus.skipped,
      details = const [],
      fixHint = null;

  /// The outcome.
  final CheckStatus status;

  /// One line saying what was found.
  final String summary;

  /// Extra lines, such as paths, that help explain the summary.
  final List<String> details;

  /// What to do about a warning or error.
  final String? fixHint;
}

/// Everything a check may look at. It is built once per doctor run.
final class DoctorContext {
  /// Creates a context.
  const DoctorContext({
    required this.environment,
    required this.runner,
    required this.projectRoot,
    required this.sdk,
  });

  /// The machine being checked.
  final HostEnvironment environment;

  /// Runs external tools.
  final ProcessRunner runner;

  /// The project being checked, or null outside a project.
  final String? projectRoot;

  /// The Flutter SDK detection, shared by every check.
  final SdkDetection sdk;
}

/// One thing `appstein doctor` checks.
abstract interface class DoctorCheck {
  /// A stable ID, such as `doctor.flutter`.
  String get id;

  /// A short name shown to people, such as `Flutter SDK`.
  String get title;

  /// Runs the check.
  Future<CheckResult> run(DoctorContext context);
}
