import 'dart:async';
import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:stream_channel/stream_channel.dart';

import '../config/config_loader.dart';
import '../knowledge/knowledge_lock.dart';
import '../knowledge/knowledge_sync.dart';
import '../knowledge/knowledge_write_exception.dart';
import '../knowledge/platform_sync.dart';
import 'check_api.dart';
import 'feature_query.dart';
import 'knowledge_snapshot.dart';
import 'route_query.dart';
import 'tool_answer.dart';
import 'toolchain_report.dart';
import 'what_changed.dart';
import 'where_is.dart';

/// A channel an MCP server talks over: one JSON-RPC message per string.
typedef McpChannel = StreamChannel<String>;

/// The MCP channel over [input] and [output] (stdin and stdout for
/// `appstein mcp`, spec §8): one message per line.
McpChannel stdioMcpChannel(
  Stream<List<int>> input,
  StreamSink<List<int>> output,
) => stdioChannel(input: input, output: output);

/// The tools `appstein mcp` serves in slice 1c.1, in the order it lists
/// them (spec §8). `verify` and `package_check` come with slice 1d.
const mcpToolNames = [
  'overview',
  'where_is',
  'feature',
  'route',
  'check_api',
  'what_changed',
  'toolchain',
];

const _doctor = 'Run `appstein doctor` to see what is wrong.';

/// Appstein's MCP server (spec §8): read tools over the project's
/// knowledge, each answered from fresh knowledge.
///
/// Before each answer it syncs as `appstein sync --detect` does, with
/// [syncFor]'s `KnowledgeSync` (the CLI builds one from `appstein.yaml` on
/// every call, with package skills off and a held analyzer cache). Calls
/// are answered one at a time. A sync that fails leaves the reply marked
/// `stale`, from the files on disk; with no file to answer from, the reply
/// is an error. Nothing is ever written to stdout but protocol messages.
final class AppsteinMcpServer extends MCPServer with ToolsSupport {
  /// Serves the project at [projectRoot] over [channel]. [dartSdkPath]
  /// overrides where `dart:` libraries are read from, for tests.
  AppsteinMcpServer(
    super.channel, {
    required this.projectRoot,
    required this.syncFor,
    required String appsteinVersion,
    this.dartSdkPath,
  }) : super.fromStreamChannel(
         implementation: Implementation(
           name: 'appstein',
           version: appsteinVersion,
         ),
         instructions:
             'Appstein knows this Flutter project: its SDK, the version '
             'delta, the native toolchain and the project map. Call '
             '`overview` first. Ask `where_is` before searching files, '
             '`check_api` before using an API you are unsure of, and '
             '`toolchain` before changing native versions.',
       ) {
    _tool(
      'overview',
      "The project's INDEX.md: what the app is, the rules that matter most, "
          'its features, where things live, version notes, decisions and '
          'current work, plus whether the knowledge is fresh. Call it first.',
      input: ToolSchemas.noInput,
      result: ToolSchemas.overviewResult,
      answer: (knowledge, _) =>
          knowledge.refusalFor([knowledge.index]) ??
          ToolReply(
            {
              'index': knowledge.index.value!.body,
              'generatedAt': knowledge.index.value!.generatedAt,
            },
            "Read `index` first: it is the project's INDEX.md, generated "
            '${knowledge.index.value!.generatedAt}.',
          ),
    );
    _tool(
      'where_is',
      'Find files and symbols for free text, such as "login screen" or '
          '"booking repository", ranked by symbol names, routes and '
          'screens, features, then file paths, with the reason for each '
          'match. Use it before searching files.',
      input: ToolSchemas.whereIsInput,
      result: ToolSchemas.whereIsResult,
      answer: (knowledge, arguments) =>
          knowledge.refusalFor([
            knowledge.symbols,
            knowledge.routes,
            knowledge.features,
            knowledge.layers,
          ]) ??
          whereIs(
            arguments['query']! as String,
            symbols: knowledge.symbols.value!,
            routes: knowledge.routes.value!,
            features: knowledge.features.value!,
            layers: knowledge.layers.value!,
          ),
    );
    _tool(
      'feature',
      'Everything in one feature (a folder under lib/ui/, such as '
          '`auth/login`): screens, view models, repositories, services, '
          'models, routes, tests and files.',
      input: ToolSchemas.featureInput,
      result: ToolSchemas.featureResult,
      answer: (knowledge, arguments) =>
          knowledge.refusalFor([knowledge.features, knowledge.routes]) ??
          featureInfo(
            arguments['name']! as String,
            features: knowledge.features.value!,
            routes: knowledge.routes.value!,
          ),
    );
    _tool(
      'route',
      'The go_router route for a path, such as `/booking/42`: its screen, '
          'feature, parent, nested routes and whether it redirects.',
      input: ToolSchemas.routeInput,
      result: ToolSchemas.routeResult,
      answer: (knowledge, arguments) =>
          knowledge.refusalFor([knowledge.routes, knowledge.features]) ??
          routeInfo(
            arguments['path']! as String,
            routes: knowledge.routes.value!,
            features: knowledge.features.value!,
          ),
    );
    _tool(
      'check_api',
      "Is an API deprecated or removed for this project's Flutter, Dart and "
          'packages? Give a name such as `WillPopScope`, `withOpacity` or '
          "`Color.withOpacity`. Returns the library's own deprecation text, "
          'the migration and the curated notes that mention it.',
      input: ToolSchemas.checkApiInput,
      result: ToolSchemas.checkApiResult,
      answer: (knowledge, arguments) =>
          knowledge.refusalFor([knowledge.delta]) ??
          checkApi(arguments['name']! as String, knowledge.delta.value!),
    );
    _tool(
      'what_changed',
      'The curated notes about what changed in Flutter and Dart, and how '
          'many deprecated, removed and moved APIs each library has. '
          '`since` (a Flutter version such as `3.27`) narrows the notes; '
          "`library` (such as `package:go_router`) lists that library's "
          'APIs.',
      input: ToolSchemas.whatChangedInput,
      result: ToolSchemas.whatChangedResult,
      answer: (knowledge, arguments) =>
          knowledge.refusalFor([knowledge.delta]) ??
          whatChanged(
            knowledge.delta.value!,
            since: arguments['since'] as String?,
            library: arguments['library'] as String?,
          ),
    );
    _tool(
      'toolchain',
      'The native versions that work with this Flutter (Gradle, AGP, KGP, '
          "SDK levels, NDK, iOS deployment target), the project's current "
          'values, and every mismatch. Check it before changing native '
          'versions.',
      input: ToolSchemas.noInput,
      result: ToolSchemas.toolchainResult,
      answer: (knowledge, _) =>
          knowledge.refusalFor([knowledge.toolchain]) ??
          toolchainInfo(knowledge.toolchain.value!, knowledge.native.value),
    );
  }

  /// The project's folder.
  final String projectRoot;

  /// The sync to run before each answer; called once per answer.
  final KnowledgeSync Function() syncFor;

  /// Where `dart:` libraries are read from; null for the Flutter SDK's.
  final String? dartSdkPath;

  Future<void> _last = Future.value();

  void _tool(
    String name,
    String description, {
    required Map<String, Object?> input,
    required Map<String, Object?> result,
    required ToolAnswer Function(
      KnowledgeSnapshot knowledge,
      Map<String, Object?> arguments,
    )
    answer,
  }) => registerTool(
    Tool(
      name: name,
      description: description,
      inputSchema: ObjectSchema.fromMap(input),
      outputSchema: ObjectSchema.fromMap(toolOutputSchema(result)),
    ),
    (request) => _oneAtATime(() => _call(request, answer)),
  );

  /// Runs [action] after every call before it finished.
  Future<T> _oneAtATime<T>(Future<T> Function() action) {
    final result = _last.then((_) => action());
    _last = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<CallToolResult> _call(
    CallToolRequest request,
    ToolAnswer Function(KnowledgeSnapshot, Map<String, Object?>) answer,
  ) async {
    final freshness = await _freshen();
    try {
      return switch (answer(
        KnowledgeSnapshot(projectRoot),
        request.arguments ?? const {},
      )) {
        ToolReply(:final result, :final summary) => _reply(
          result,
          summary,
          freshness,
        ),
        ToolRefusal(:final message) => _refuse(message, freshness),
      };
    } on Object catch (error) {
      return _refuse(
        'Appstein failed to answer: $error. $_doctor If this keeps '
        'happening, please report it.',
        freshness,
      );
    }
  }

  /// Syncs as `sync --detect` does and says how fresh the knowledge is.
  Future<FreshnessReport> _freshen() async {
    try {
      final report = await syncFor().detect(
        projectRoot,
        dartSdkPath: dartSdkPath,
      );
      if (report.current) return const FreshnessReport.current();
      // Input names: a project file's is `project:<path>`; the agent wants
      // the path, as `appstein sync --detect` prints it.
      const project = 'project:';
      return FreshnessReport.rebuilt(
        because: report.rebuiltBecause,
        changed: [
          for (final name in report.changed)
            name.startsWith(project) ? name.substring(project.length) : name,
        ],
        mapSkipped: report.map?.skipped,
      );
    } on KnowledgeLockTimeout {
      return const FreshnessReport.stale(
        problem: 'another sync is running and holds the lock',
      );
    } on SyncException catch (error) {
      return FreshnessReport.stale(
        problem: error.problem,
        fixHint: error.fixHint,
      );
    } on ConfigException catch (error) {
      return FreshnessReport.stale(
        problem: 'appstein.yaml is invalid: $error',
        fixHint: 'Fix appstein.yaml; the next call syncs again.',
      );
    } on KnowledgeWriteException catch (error) {
      return FreshnessReport.stale(problem: '$error', fixHint: _doctor);
    } on Object catch (error) {
      return FreshnessReport.stale(
        problem: 'the sync failed unexpectedly: $error',
        fixHint: _doctor,
      );
    }
  }

  CallToolResult _reply(
    Map<String, Object?> result,
    String summary,
    FreshnessReport freshness,
  ) {
    final structured =
        withoutNulls({
              ...result,
              'summary': summary,
              'freshness': freshness.toJson(),
            })!
            as Map<String, Object?>;
    return CallToolResult(
      content: [
        TextContent(text: '$summary ${freshness.sentence}'),
        TextContent(text: jsonEncode(structured)),
      ],
      structuredContent: structured,
    );
  }

  CallToolResult _refuse(String message, FreshnessReport freshness) =>
      CallToolResult(
        isError: true,
        content: [
          TextContent(
            text: freshness.state == FreshnessState.stale
                ? '$message ${freshness.sentence}'
                : message,
          ),
        ],
      );
}
