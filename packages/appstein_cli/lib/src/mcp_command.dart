import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:args/command_runner.dart';

import 'analysis_guard_command.dart';
import 'exit_codes.dart';
import 'packs.dart';
import 'project_option.dart';
import 'verify_command.dart';
import 'version.dart';

/// `appstein mcp`: serves Appstein's MCP tools over stdio until the agent
/// closes the connection (spec §5.3, §8).
///
/// Before each answer the server syncs like `sync --detect`. It re-reads
/// `appstein.yaml` for every call, so a changed config takes effect at
/// once, and an invalid one marks replies stale instead of stopping the
/// server. Package skills are left to `appstein sync`, and the analyzer
/// cache stays in memory between calls.
///
/// The `verify` tool answers from **warm analysis** ([keptCodeAnalysis]):
/// the first `verify` call starts the project's analysis server, which then
/// stays between calls, is stopped after ten minutes without one, and is
/// stopped when this command ends. Starting the command starts none.
final class McpCommand extends Command<int> {
  /// Creates the command. [channel] gives the connection to serve: stdin
  /// and stdout, or a test's channel.
  McpCommand({
    required this.out,
    required this.err,
    required this.environment,
    required this.channel,
    this.codeAnalysis,
    this.dartSdkPath,
  });

  /// Gives each `verify` call its code analysis. When null, the command
  /// keeps one analysis server for the project ([keptCodeAnalysis]) and
  /// stops it when it ends. Only tests set it.
  final CodeAnalysisScope? codeAnalysis;

  /// Where the analysis reads `dart:` libraries from, and whose `dart` runs
  /// the analysis server, instead of the Flutter SDK's own Dart SDK. Only
  /// tests set it.
  final String? dartSdkPath;

  /// Where `appstein help mcp` writes its usage. A user-invoked help request
  /// only: while serving, stdout belongs to the protocol and nothing else is
  /// written to it.
  final StringSink out;

  /// Where startup problems go. stdout belongs to the protocol.
  final StringSink err;

  /// The machine, used to find the project and the Flutter SDK.
  final HostEnvironment environment;

  /// Gives the connection to serve.
  final McpChannel Function() channel;

  @override
  String get name => 'mcp';

  @override
  String get description =>
      "Serve Appstein's MCP tools over stdio (started by agents).";

  @override
  void printUsage() => out.writeln(usage);

  @override
  Future<int> run() async {
    final projectRoot = resolveProjectRoot(globalResults, environment);
    if (projectRoot == null) {
      err
        ..writeln(
          'appstein mcp needs a Flutter project, but there is no pubspec.yaml '
          'in ${environment.workingDirectory} or any folder above it.',
        )
        ..writeln(
          'Start it inside the project, or pass --project <path> (in the '
          "agent's MCP config).",
        );
      return ExitCodes.appsteinFailed;
    }
    // Nothing is started here: the first `verify` call starts the server.
    final kept = codeAnalysis == null
        ? keptCodeAnalysis(
            projectRoot: projectRoot,
            environment: environment,
            dartSdkPath: dartSdkPath,
          )
        : null;
    try {
      final server = AppsteinMcpServer(
        channel(),
        projectRoot: projectRoot,
        syncFor: mcpSyncFactory(
          projectRoot: projectRoot,
          environment: environment,
          held: HeldAnalyzerCache(),
        ),
        codeAnalysis: codeAnalysis ?? kept!.use,
        appsteinVersion: appsteinVersion,
        dartSdkPath: dartSdkPath,
      );
      await server.done;
    } finally {
      // The orderly end. When this process is killed instead, the guard
      // ends the analysis server (decision record 0001).
      await kept?.close();
      // No call is left to tell it in: what the stop could not end, and
      // could not show to be its own, is said on stderr.
      kept?.server.leftProcesses().forEach(err.writeln);
    }
    return ExitCodes.ok;
  }
}

/// The code analysis of `appstein mcp`: one analysis server for the project
/// at [projectRoot], of the SDK the project uses and behind the guard
/// ([analysisGuardCommand]), kept between `verify` calls. Nothing is
/// started until a call asks, and the server is stopped when it was idle
/// for `analysisIdleStop`. The caller passes its `use` as the server's code
/// analysis and closes it when the MCP server is done.
///
/// A terminal run uses [terminalCodeAnalysis] instead, which gives each run
/// a server of its own. Both ask the same `AnalysisServer`, so the tool and
/// a terminal run give the same findings.
///
/// [dartSdkPath] replaces the Flutter SDK's own Dart SDK, for tests.
KeptAnalysisServer<AnalysisServer> keptCodeAnalysis({
  required String projectRoot,
  required HostEnvironment environment,
  String? dartSdkPath,
}) => KeptAnalysisServer(
  AnalysisServer(
    projectRoot: projectRoot,
    guardCommand: analysisGuardCommand(),
    dartExecutable: () => projectDartExecutable(
      environment,
      projectRoot,
      dartSdkPath: dartSdkPath,
    ),
  ),
);

/// The factory `appstein mcp` gives its server: each call builds a
/// [KnowledgeSync] from the `appstein.yaml` as it is now (an invalid file
/// throws a `ConfigException`, which the server turns into a stale reply),
/// with package skills off and every sync sharing [held].
///
/// Package skills never run from the server: they start a `skills` process
/// and write agent folders, which belongs to `appstein sync`.
KnowledgeSync Function() mcpSyncFactory({
  required String projectRoot,
  required HostEnvironment environment,
  required HeldAnalyzerCache held,
}) => () {
  final config = loadConfig(projectRoot) ?? const AppsteinConfig();
  return KnowledgeSync(
    environment: environment,
    appsteinVersion: appsteinVersion,
    packs: packsFor(config),
    baseline: config.delta.baseline,
    agents: config.integrations.agents,
    packageSkills: false,
    heldCache: held,
  );
};
