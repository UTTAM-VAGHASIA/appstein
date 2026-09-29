import 'package:appstein_engine/appstein_engine.dart';
import 'package:args/command_runner.dart';

import 'doctor_printer.dart';
import 'exit_codes.dart';
import 'project_option.dart';

/// `appstein doctor`: checks the environment and explains fixes.
final class DoctorCommand extends Command<int> {
  /// Creates the command.
  DoctorCommand({
    required this.out,
    required this.environment,
    required this.processRunner,
    this.checks,
  });

  /// Where the report goes.
  final StringSink out;

  /// The machine being checked.
  final HostEnvironment environment;

  /// Runs external tools.
  final ProcessRunner processRunner;

  /// The checks to run; null means the default checks.
  final List<DoctorCheck>? checks;

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check your environment and explain how to fix problems.';

  @override
  void printUsage() => out.writeln(usage);

  @override
  Future<int> run() async {
    final projectRoot = resolveProjectRoot(globalResults, environment);
    final report = await Doctor(
      environment: environment,
      runner: processRunner,
      checks: checks,
    ).run(projectRoot: projectRoot);
    out.write(formatDoctorReport(report, projectRoot: projectRoot));
    return report.hasErrors ? ExitCodes.errorsFound : ExitCodes.ok;
  }
}
