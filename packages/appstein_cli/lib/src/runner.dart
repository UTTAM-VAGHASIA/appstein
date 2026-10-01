import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import 'doctor_command.dart';
import 'exit_codes.dart';
import 'sync_command.dart';
import 'version.dart';

/// Runs the `appstein` command line and returns the process exit code
/// (spec §9.5).
///
/// [out] and [err] default to stdout and stderr, and [environment] and
/// [processRunner] default to the real machine. [doctorChecks] and
/// [extraCommands] exist only for tests: they replace the doctor's checks
/// and add commands, such as one that crashes on purpose. [environmentFactory]
/// (also for tests) builds the environment when [environment] is null.
Future<int> runAppstein(
  List<String> arguments, {
  StringSink? out,
  StringSink? err,
  HostEnvironment? environment,
  ProcessRunner? processRunner,
  List<DoctorCheck>? doctorChecks,
  List<Command<int>> extraCommands = const [],
  HostEnvironment Function()? environmentFactory,
}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;
  // Everything, including setup, runs inside the try, so no failure can
  // escape with the VM's own exit code.
  try {
    final machine =
        environment ?? (environmentFactory ?? HostEnvironment.current)();
    final runner = _AppsteinCommandRunner(output)
      ..addCommand(
        DoctorCommand(
          out: output,
          environment: machine,
          processRunner: processRunner ?? const SystemProcessRunner(),
          checks: doctorChecks,
        ),
      )
      ..addCommand(SyncCommand(out: output, err: errors, environment: machine));
    extraCommands.forEach(runner.addCommand);
    return await runner.run(arguments) ?? ExitCodes.ok;
  } on UsageException catch (error) {
    errors
      ..writeln(error.message)
      ..writeln()
      ..writeln(error.usage);
    return ExitCodes.appsteinFailed;
  } on ConfigException catch (error) {
    errors.writeln('Invalid appstein.yaml: $error');
    return ExitCodes.appsteinFailed;
  } catch (error, stackTrace) {
    reportCrash(errors, error, stackTrace);
    return ExitCodes.appsteinFailed;
  }
}

/// Prints the message for an unexpected failure of Appstein itself, with
/// the details a bug report needs. The exit code for it is
/// [ExitCodes.appsteinFailed].
void reportCrash(StringSink errors, Object error, StackTrace stackTrace) {
  errors
    ..writeln('Appstein failed unexpectedly: $error')
    ..writeln(
      'Run `appstein doctor` to check your setup. If this keeps '
      'happening, please report it with the details below.',
    )
    ..writeln(stackTrace);
}

final class _AppsteinCommandRunner extends CommandRunner<int> {
  _AppsteinCommandRunner(this._out)
    : super(
        'appstein',
        'A knowledge and verification layer for AI agents that build '
            'Flutter apps.',
      ) {
    argParser
      ..addFlag(
        'version',
        negatable: false,
        help: 'Print the Appstein, protocol and supported Flutter versions.',
      )
      ..addOption(
        'project',
        valueHelp: 'path',
        help:
            'The Flutter project to work on. Defaults to the nearest '
            'folder at or above the current one that contains pubspec.yaml.',
      );
  }

  final StringSink _out;

  @override
  void printUsage() => _out.writeln(usage);

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults.flag('version')) {
      _out.writeln(versionText());
      return ExitCodes.ok;
    }
    return super.runCommand(topLevelResults);
  }
}
