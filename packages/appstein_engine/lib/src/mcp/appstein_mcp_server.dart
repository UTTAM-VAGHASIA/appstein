import 'dart:async';
import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:stream_channel/stream_channel.dart';

import '../config/config_loader.dart';
import '../knowledge/knowledge_lock.dart';
import '../knowledge/knowledge_refresh.dart';
import '../knowledge/knowledge_sync.dart';
import '../knowledge/knowledge_write_exception.dart';
import '../knowledge/platform_sync.dart';
import '../decisions/decision_store.dart';
import 'check_api.dart';
import 'decisions_query.dart';
import 'feature_query.dart';
import 'knowledge_snapshot.dart';
import 'memory_tools.dart';
import 'record_decision.dart';
import 'route_query.dart';
import 'tool_answer.dart';
import '../verify/engine_checks.dart';
import '../verify/verify_check.dart';
import '../verify/verify_run.dart';
import 'toolchain_report.dart';
import 'verify_tool.dart';
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

const _doctor = 'Run `appstein doctor` to see what is wrong.';

/// Appstein's MCP server (spec §8): read tools over the project's
/// knowledge, each answered from fresh knowledge, the two tools that write
/// its decisions and memory, and `verify`. [clock] gives the date those
/// writes record; the machine's clock when it is left out.
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
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       super.fromStreamChannel(
         implementation: Implementation(
           name: 'appstein',
           version: appsteinVersion,
         ),
         instructions:
             'Appstein knows this Flutter project: its SDK, the version '
             'delta, the native toolchain and the project map. Call '
             '`overview` first. Ask `where_is` before searching files, '
             '`check_api` before using an API you are unsure of, and '
             '`toolchain` before changing native versions. Read '
             '`memory_read` when you resume work, and record a choice that '
             'binds later work with `record_decision`. Run `verify` with '
             '`scope: full` before you say a task is done.',
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
          'feature, parent, nested routes, and where it redirects to (or '
          'the line to read when the map cannot tell).',
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
          'many deprecated, removed, changed and moved APIs each library '
          'has. '
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
    _tool(
      'decisions',
      "The project's recorded decisions (architecture, state management, "
          'conventions) with the reason for each. Without a topic: every '
          'decision in force. With words, such as "state management": the '
          'decisions that mention them. With a file path, such as '
          '`lib/ui/home/widgets/home_screen.dart`: the decisions that cover '
          'that file. Check it before a change that a decision may already '
          'settle. Only an accepted decision binds.',
      input: ToolSchemas.decisionsInput,
      result: ToolSchemas.decisionsResult,
      answer: (_, arguments) => decisionsInfo(
        readDecisions(projectRoot),
        topic: arguments['topic'] as String?,
        projectRoot: projectRoot,
      ),
    );
    _writeTool(
      'record_decision',
      'Record a choice that binds later work, with its reason. Pass `title` '
          'and `why` (and `paths`, the patterns it applies to); it is saved '
          'as proposed. Pass `status: accepted` only when the user agreed to '
          'this decision in this conversation. To replace an older decision, '
          'add `supersedes` with its number. To accept a proposed decision '
          'once the user agrees, pass only `accept` with its number. The '
          'text of an existing decision is never rewritten. The file is '
          'committed: never put secrets in it.',
      input: ToolSchemas.recordDecisionInput,
      result: ToolSchemas.recordDecisionResult,
      write: (arguments) =>
          recordDecision(projectRoot, arguments, today: _today()),
    );
    _tool(
      'memory_read',
      'The task in progress (goal, plan, status, open questions) and the '
          'lessons recorded so far. Read it when you start or resume work.',
      input: ToolSchemas.noInput,
      result: ToolSchemas.memoryReadResult,
      answer: (_, _) => memoryRead(projectRoot),
    );
    _writeTool(
      'memory_write',
      "Keep the project's memory. `kind: current` replaces the task in "
          'progress with `text` (goal, plan, status, open questions). '
          '`kind: lesson` appends `text` to the lessons as one dated line. '
          '`kind: complete` finishes the task: `text` is your one-paragraph '
          'summary, which is saved as a lesson, and the task in progress is '
          'cleared. The files are committed: never put secrets in them.',
      input: ToolSchemas.memoryWriteInput,
      result: ToolSchemas.memoryWriteResult,
      write: (arguments) =>
          memoryWrite(projectRoot, arguments, today: _today()),
    );
    registerTool(
      Tool(
        name: 'verify',
        description:
            'Check the project against its knowledge and get findings, each '
            'with its file, line and a fix hint. `scope: fast` after a '
            'change; `scope: full` before you say the task is done. An '
            'error blocks "done"; warnings and info are reported only.',
        inputSchema: ObjectSchema.fromMap(ToolSchemas.verifyInput),
        outputSchema: ObjectSchema.fromMap(
          toolOutputSchema(ToolSchemas.verifyResult),
        ),
      ),
      (request) => _oneAtATime(() => _verify(request.arguments ?? const {})),
    );
  }

  /// The project's folder.
  final String projectRoot;

  /// The sync to run before each answer; called once per answer.
  final KnowledgeSync Function() syncFor;

  /// Where `dart:` libraries are read from; null for the Flutter SDK's.
  final String? dartSdkPath;

  final DateTime Function() _clock;

  Future<void> _last = Future.value();

  /// Today's date on this machine, as decision records and lessons write
  /// it: `2026-10-06`.
  String _today() {
    final now = _clock();
    String two(int number) => '$number'.padLeft(2, '0');
    return '${'${now.year}'.padLeft(4, '0')}-${two(now.month)}-${two(now.day)}';
  }

  /// Registers a tool that changes files the project commits (spec §8,
  /// Writes). After a write that worked, the freshness check runs again, so
  /// `INDEX.md` shows the new decision or task when the reply arrives, and
  /// the reply states that second freshness.
  void _writeTool(
    String name,
    String description, {
    required Map<String, Object?> input,
    required Map<String, Object?> result,
    required Future<ToolAnswer> Function(Map<String, Object?> arguments) write,
  }) => registerTool(
    Tool(
      name: name,
      description: description,
      inputSchema: ObjectSchema.fromMap(input),
      outputSchema: ObjectSchema.fromMap(toolOutputSchema(result)),
    ),
    (request) => _oneAtATime(() async {
      final before = await _freshen();
      try {
        return switch (await write(request.arguments ?? const {})) {
          ToolReply(:final result, :final summary) => _reply(
            result,
            summary,
            await _freshen(),
          ),
          ToolRefusal(:final message) => _refuse(message, before),
        };
      } on Object catch (error) {
        return _refuse(
          'Appstein failed to write: $error. $_doctor If this keeps '
          'happening, please report it.',
          before,
        );
      }
    }),
  );

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

  /// Answers `verify` (spec §8, §9). The freshness check every call runs is
  /// the refresh `verify` needs, so the knowledge is refreshed once: stale
  /// knowledge is the finding `knowledge.stale` in a normal reply, not an
  /// error reply. `appstein.yaml` is read for every call, as the sync's is.
  Future<CallToolResult> _verify(Map<String, Object?> arguments) async {
    KnowledgeSync? sync;
    final freshness = await _freshen(built: (built) => sync = built);
    try {
      final using = sync;
      // Without a sync there are no packs, so no list of checks.
      if (using == null) return _refuse('The checks could not run.', freshness);
      final AppsteinConfig config;
      try {
        config = loadConfig(projectRoot) ?? const AppsteinConfig();
      } on ConfigException catch (error) {
        final problem = '$error'.replaceFirst(RegExp(r'\.$'), '');
        return _refuse(
          'The checks could not run: appstein.yaml is invalid: $problem. '
          'Fix it, then call `verify` again.',
          freshness,
        );
      }
      final mode = arguments['scope'] == 'fast'
          ? VerifyMode.fast
          : VerifyMode.full;
      final result = await runVerify(
        projectRoot: projectRoot,
        config: config,
        packs: using.packs,
        sync: using,
        mode: mode,
        checks: checksFor(using.packs),
        refreshed: KnowledgeRefresh.fromFreshness(freshness),
        dartSdkPath: dartSdkPath,
      );
      return switch (verifyAnswer(result, mode: mode)) {
        ToolReply(result: final json, :final summary) => _reply(
          json,
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
  /// [built] gets the sync it ran, when one could be built.
  Future<FreshnessReport> _freshen({
    void Function(KnowledgeSync sync)? built,
  }) async {
    try {
      final sync = syncFor();
      built?.call(sync);
      final report = await sync.detect(projectRoot, dartSdkPath: dartSdkPath);
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
    // A result with a `summary` of its own keeps it (`toolOutputSchema`);
    // the sentence is in the text either way.
    final structured =
        withoutNulls({
              ...result,
              if (!result.containsKey('summary')) 'summary': summary,
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

  /// An error has no structured content, so its text carries the freshness
  /// every reply states (spec §8).
  CallToolResult _refuse(String message, FreshnessReport freshness) =>
      CallToolResult(
        isError: true,
        content: [TextContent(text: '$message ${freshness.sentence}')],
      );
}
