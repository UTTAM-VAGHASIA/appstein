import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../sdk/sdk_detector.dart';
import 'checks/agents_check.dart';
import 'checks/android_sdk_check.dart';
import 'checks/appstein_path_check.dart';
import 'checks/cocoapods_check.dart';
import 'checks/dart_check.dart';
import 'checks/flutter_check.dart';
import 'checks/fvm_check.dart';
import 'checks/java_check.dart';
import 'checks/project_check.dart';
import 'checks/tool_check.dart';
import 'checks/xcode_check.dart';
import 'doctor_check.dart';

/// One check and its result.
final class DoctorEntry {
  /// Pairs a check with its result.
  const DoctorEntry(this.check, this.result);

  /// The check that ran.
  final DoctorCheck check;

  /// What it found.
  final CheckResult result;
}

/// Everything one doctor run found, in check order.
final class DoctorReport {
  /// Creates a report.
  const DoctorReport(this.entries);

  /// One entry per check.
  final List<DoctorEntry> entries;

  /// Whether any check found an error.
  bool get hasErrors =>
      entries.any((entry) => entry.result.status == CheckStatus.error);
}

/// The checks `appstein doctor` runs, in the order they are shown.
List<DoctorCheck> defaultDoctorChecks() => const [
  FlutterCheck(),
  DartCheck(),
  FvmCheck(),
  JavaCheck(),
  AndroidSdkCheck(),
  XcodeCheck(),
  CocoaPodsCheck(),
  gitCheck,
  ripgrepCheck,
  AgentsCheck(),
  AppsteinPathCheck(),
  ProjectCheck(),
];

/// Checks the environment and explains how to fix problems (spec §5.3).
final class Doctor {
  /// Creates a doctor that runs [checks] (by default, [defaultDoctorChecks]).
  Doctor({
    required this.environment,
    required this.runner,
    List<DoctorCheck>? checks,
  }) : checks = checks ?? defaultDoctorChecks();

  /// The machine being checked.
  final HostEnvironment environment;

  /// Runs external tools.
  final ProcessRunner runner;

  /// The checks to run.
  final List<DoctorCheck> checks;

  /// Runs every check for [projectRoot] (or outside a project when it is
  /// null). Checks run in parallel, and results keep the check order.
  Future<DoctorReport> run({String? projectRoot}) async {
    final context = DoctorContext(
      environment: environment,
      runner: runner,
      projectRoot: projectRoot,
      sdk: SdkDetector(environment).detect(projectRoot: projectRoot),
    );
    final results = await Future.wait(
      checks.map((check) => _runSafely(check, context)),
    );
    return DoctorReport([
      for (var i = 0; i < checks.length; i++)
        DoctorEntry(checks[i], results[i]),
    ]);
  }

  Future<CheckResult> _runSafely(
    DoctorCheck check,
    DoctorContext context,
  ) async {
    try {
      return await check.run(context);
    } catch (error) {
      return CheckResult.error(
        'The check itself failed: $error',
        fixHint: 'This is a bug in Appstein. Please report it.',
      );
    }
  }
}
