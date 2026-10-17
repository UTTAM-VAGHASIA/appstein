import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import 'analysis_guard_command.dart';
import 'analysis_host_command.dart';
import 'docs_command.dart';
import 'doctor_command.dart';
import 'exit_codes.dart';
import 'failure.dart';
import 'mcp_command.dart';
import 'sync_command.dart';
import 'verify_command.dart';
import 'verify_hook.dart';
import 'version.dart';

/// Runs the `appstein` command line and returns the process exit code
/// (spec §9.5).
///
/// [out] and [err] default to stdout and stderr, and [environment] and
/// [processRunner] default to the real machine. [doctorChecks] and
/// [extraCommands] exist only for tests: they replace the doctor's checks
/// and add commands, such as one that crashes on purpose. [environmentFactory]
/// (also for tests) builds the environment when [environment] is null.
/// [mcpChannel] (also for tests) gives the connection `appstein mcp` serves;
/// by default stdin and stdout. [verifyChecks] (also for tests) replaces the
/// checks `appstein verify` runs, and [dartSdkPath] (also for tests) is the
/// Dart SDK `appstein verify` and `appstein mcp` read `dart:` libraries
/// from and run the analysis server with, where a fake Flutter SDK has
/// none. [codeAnalysis] (also for tests) replaces the analysis server that
/// `appstein verify` and the `verify` tool of `appstein mcp` would start.
/// [hookInput] (also for tests) gives what `appstein verify --hook` reads on
/// stdin.
Future<int> runAppstein(
  List<String> arguments, {
  StringSink? out,
  StringSink? err,
  HostEnvironment? environment,
  ProcessRunner? processRunner,
  List<DoctorCheck>? doctorChecks,
  List<Command<int>> extraCommands = const [],
  HostEnvironment Function()? environmentFactory,
  McpChannel Function()? mcpChannel,
  VerifyChecks? verifyChecks,
  CodeAnalysisScope? codeAnalysis,
  String? dartSdkPath,
  Future<String> Function()? hookInput,
}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;
  // The one answer a hook run may give: the process's own when `runGuarded`
  // made one, so its failure handler and this run never both answer.
  final answer = HookAnswer.current ?? HookAnswer();
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
      ..addCommand(SyncCommand(out: output, err: errors, environment: machine))
      ..addCommand(DocsCommand(out: output, err: errors, environment: machine))
      ..addCommand(
        VerifyCommand(
          out: output,
          err: errors,
          environment: machine,
          checks: verifyChecks ?? checksFor,
          codeAnalysis: codeAnalysis,
          dartSdkPath: dartSdkPath,
          hookInput: hookInput,
          hookAnswer: answer,
        ),
      )
      ..addCommand(
        McpCommand(
          out: output,
          err: errors,
          environment: machine,
          channel: mcpChannel ?? () => stdioMcpChannel(stdin, stdout),
          codeAnalysis: codeAnalysis,
          dartSdkPath: dartSdkPath,
        ),
      )
      ..addCommand(AnalysisGuardCommand())
      ..addCommand(AnalysisHostCommand());
    extraCommands.forEach(runner.addCommand);
    return await runner.run(arguments) ?? ExitCodes.ok;
  } on UsageException catch (error) {
    errors
      ..writeln(error.message)
      ..writeln()
      ..writeln(error.usage);
    return ExitCodes.appsteinFailed;
  } catch (error, stackTrace) {
    // Everything else is Appstein's failure, told in one set of words for the
    // terminal and for a hook (`describeFailure`): an analysis server that
    // could not answer or tests that could not be run are a broken setup,
    // never "no errors" (spec §9.5), and a crash comes with its trace.
    final failure = describeFailure(error, stackTrace);
    // In a hook a failure never blocks the agent, wherever it happened.
    if (isClaudeHookRun(arguments)) {
      return answerHookFailure(output, errors, failure, answer);
    }
    failure.writeTo(errors);
    return ExitCodes.appsteinFailed;
  }
}

/// Prints the message for an unexpected failure of Appstein itself, with
/// the details a bug report needs. The exit code for it is
/// [ExitCodes.appsteinFailed].
void reportCrash(StringSink errors, Object error, StackTrace stackTrace) =>
    unexpectedFailure(error, stackTrace).writeTo(errors);

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
