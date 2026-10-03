import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:args/command_runner.dart';

import 'exit_codes.dart';
import 'packs.dart';
import 'project_option.dart';
import 'version.dart';

/// `appstein mcp`: serves Appstein's MCP tools over stdio until the agent
/// closes the connection (spec §5.3, §8).
///
/// Before each answer the server syncs like `sync --detect`. It re-reads
/// `appstein.yaml` for every call, so a changed config takes effect at
/// once, and an invalid one marks replies stale instead of stopping the
/// server. Package skills are left to `appstein sync`, and the analyzer
/// cache stays in memory between calls.
final class McpCommand extends Command<int> {
  /// Creates the command. [channel] gives the connection to serve: stdin
  /// and stdout, or a test's channel.
  McpCommand({
    required this.err,
    required this.environment,
    required this.channel,
  });

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
    final server = AppsteinMcpServer(
      channel(),
      projectRoot: projectRoot,
      syncFor: mcpSyncFactory(
        projectRoot: projectRoot,
        environment: environment,
        held: HeldAnalyzerCache(),
      ),
      appsteinVersion: appsteinVersion,
    );
    await server.done;
    return ExitCodes.ok;
  }
}

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
