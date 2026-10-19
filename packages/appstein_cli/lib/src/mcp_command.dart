import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'analysis_guard_command.dart';
import 'analysis_host_command.dart';
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
///
/// The `verify` tool answers from **warm analysis**: from the project's
/// analysis host ([hostCodeAnalysis], decision record 0002), which owns the
/// project's one analysis server for every session and hook. Starting the
/// command starts nothing; the first `verify` call that needs the code
/// analysis starts a host when none answers. The host outlives this
/// command, and ends itself after ten minutes with no client.
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

  /// Gives each `verify` call its code analysis. When null, each call asks
  /// the project's analysis host ([hostCodeAnalysis]). Only tests set it.
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
    // Nothing is started here: the first `verify` call that asks starts a
    // host when none answers. The host is not this command's to stop: it
    // serves every session of the project, and ends itself when idle.
    final server = AppsteinMcpServer(
      channel(),
      projectRoot: projectRoot,
      syncFor: mcpSyncFactory(
        projectRoot: projectRoot,
        environment: environment,
        held: HeldAnalyzerCache(),
      ),
      codeAnalysis:
          codeAnalysis ??
          hostCodeAnalysis(
            projectRoot: projectRoot,
            environment: environment,
            dartSdkPath: dartSdkPath,
            // Stdout is the MCP channel: the notices go to the log.
            onLeft: (notices) => notices.forEach(err.writeln),
          ),
      appsteinVersion: appsteinVersion,
      dartSdkPath: dartSdkPath,
    );
    await server.done;
    return ExitCodes.ok;
  }
}

/// The code analysis of the `verify` tool of `appstein mcp` for the project
/// at [projectRoot]: the project's analysis host
/// (`analysisHostCodeAnalysis`), started when none answers
/// ([analysisHostCommand]), in the folder [environment] names
/// (`analysisHostFolder`). The host is given the analysis cache folder
/// [environment] names (`analysisServerEnvironment`), as a full path, since
/// the host runs in another folder. When the host runs a newer Appstein,
/// the call is answered by an analysis server of its own instead, as a
/// terminal run is (`terminalCodeAnalysis`), and says the session should
/// be restarted.
///
/// [dartSdkPath] replaces the Flutter SDK's own Dart SDK, for tests.
///
/// [onLeft] is told, after a call that used a server of its own was
/// answered and the server stopped, a line for each process the stop could
/// not end because it could not be shown to be the server's own
/// (`AnalysisServer.leftProcesses`); `appstein mcp` writes them to stderr.
CodeAnalysisScope hostCodeAnalysis({
  required String projectRoot,
  required HostEnvironment environment,
  String? dartSdkPath,
  void Function(List<String> notices)? onLeft,
}) {
  final folder = analysisHostFolder(environment);
  final own = <AnalysisServer>[];
  final scope = analysisHostCodeAnalysis(
    projectRoot: projectRoot,
    hostCommand: analysisHostCommand(
      addressFolder: folder,
      dartSdkPath: dartSdkPath,
    ),
    addressFolder: folder,
    appsteinVersion: appsteinVersion,
    // A host of a newer Appstein is left alone: the run starts the server
    // a terminal run would.
    ownServer: () {
      final server = AnalysisServer(
        projectRoot: projectRoot,
        guardCommand: analysisGuardCommand(),
        dartExecutable: () => projectDartExecutable(
          environment,
          projectRoot,
          dartSdkPath: dartSdkPath,
        ),
        environment: analysisServerEnvironment(environment),
      );
      own.add(server);
      return server;
    },
    os: environment.os,
    environment: {
      for (final MapEntry(:key, :value) in analysisServerEnvironment(
        environment,
      ).entries)
        key: value.isEmpty || p.isAbsolute(value)
            ? value
            : p.join(environment.workingDirectory, value),
    },
  );
  return <T>(body) async {
    try {
      return await scope(body);
    } finally {
      // The scope has closed its own server, if it used one.
      final servers = [...own];
      own.clear();
      for (final server in servers) {
        final left = server.leftProcesses();
        if (left.isNotEmpty) onLeft?.call(left);
      }
    }
  };
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
