import 'dart:async';
import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:stream_channel/stream_channel.dart';

import '../analysis/code_analysis.dart';
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
import '../verify/apply.dart';
import '../verify/engine_checks.dart';
import '../verify/test_run.dart';
import '../verify/unverified_files.dart';
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

/// A turn that one caller holds at a time; the others wait in the order
/// they asked.
final class _Turn {
  Future<void> _last = Future.value();
  Completer<void>? _held;

  /// Completes when the turn is this caller's, after everyone who asked
  /// before. The caller must [give] it back.
  Future<void> take() {
    final before = _last;
    final mine = Completer<void>();
    _last = mine.future;
    return before.then<void>((_) {
      _held = mine;
    });
  }

  /// Gives the turn to the next caller. Only its holder calls this.
  void give() => _held!.complete();

  /// Runs [action] holding the turn, and gives it back when [action] ends,
  /// normally or with an error.
  Future<T> hold<T>(Future<T> Function() action) async {
    await take();
    try {
      return await action();
    } finally {
      give();
    }
  }
}

/// The code analysis of a `verify` call that holds [_turn]: it gives the
/// turn back while the analysis is asked, and takes it again before the
/// run goes on.
final class _OutOfTurn implements CodeAnalysis {
  _OutOfTurn(this._analysis, this._turn);

  final CodeAnalysis _analysis;
  final _Turn _turn;

  @override
  Future<CodeReading> read() => _outOfTurn(_analysis.read);

  // The time limit of a question is held on the question itself, inside the
  // out-of-turn part: the wait to take the turn back is another call's, may
  // be long, and is no part of what the analysis took. A limit around both
  // would give up on an answer the analysis had given, and let the run on
  // while another call still holds the turn.
  @override
  Future<bool> canDartFix(
    CodeDiagnostic diagnostic, {
    required Duration within,
  }) => _outOfTurn(
    () => _analysis.canDartFix(diagnostic, within: within).timeout(within),
  );

  @override
  Future<FormatAnswers> formatChanges(
    List<String> files, {
    required Duration within,
  }) => _outOfTurn(
    () => _analysis
        .formatChanges(files, within: within)
        .timeout(
          within + questionGrace,
          onTimeout: () => const FormatAnswers(),
        ),
  );

  @override
  Future<PendingFixes> pendingFixes({required Duration within}) => _outOfTurn(
    () => _analysis
        .pendingFixes(within: within)
        .timeout(
          // Past the analysis's own limit: a server that does not answer an
          // overlay is given up there, and that failure is the answer.
          fixQuestionLimit(within) + questionGrace,
          onTimeout: () => const PendingFixes(
            unfinished: 'the analysis server did not answer in time',
          ),
        ),
  );

  // No limit around it here: the files it writes must be in its answer. The
  // analysis holds `within`, a limit per request and one on the whole call.
  @override
  Future<AppliedChanges> applyFixesAndFormat({
    required Future<bool> Function(String file) leaveUnformatted,
    required Duration within,
  }) => _outOfTurn(
    () => _analysis.applyFixesAndFormat(
      leaveUnformatted: leaveUnformatted,
      within: within,
    ),
  );

  Future<T> _outOfTurn<T>(Future<T> Function() ask) async {
    _turn.give();
    try {
      return await ask();
    } finally {
      await _turn.take();
    }
  }
}

/// Appstein's MCP server (spec §8): read tools over the project's
/// knowledge, each answered from fresh knowledge, the two tools that write
/// its decisions and memory, and `verify`. [clock] gives the date those
/// writes record; the machine's clock when it is left out.
///
/// Before each answer it syncs as `appstein sync --detect` does, with
/// [syncFor]'s `KnowledgeSync` (the CLI builds one from `appstein.yaml` on
/// every call, with package skills off and a held analyzer cache). Calls
/// are answered one at a time, with one exception: while a `verify` call
/// waits for the analysis server, calls of the other tools are answered,
/// and a second `verify` call waits. A sync that fails leaves the reply marked
/// `stale`, from the files on disk; with no file to answer from, the reply
/// is an error. Nothing is ever written to stdout but protocol messages.
final class AppsteinMcpServer extends MCPServer with ToolsSupport {
  /// Serves the project at [projectRoot] over [channel]. [codeAnalysis]
  /// gives each `verify` call its code analysis. [dartSdkPath] overrides
  /// where `dart:` libraries are read from, for tests.
  AppsteinMcpServer(
    super.channel, {
    required this.projectRoot,
    required this.syncFor,
    required this.codeAnalysis,
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
            'error blocks "done"; warnings and info are reported only. '
            '`apply: true` with `scope: full` first applies `dart fix` and '
            'formats the project, and lists the files it rewrote in '
            '`applied`: read them again before you edit them.',
        inputSchema: ObjectSchema.fromMap(ToolSchemas.verifyInput),
        outputSchema: ObjectSchema.fromMap(
          toolOutputSchema(ToolSchemas.verifyResult),
        ),
      ),
      (request) => _verifyCalls.hold(() async {
        try {
          // The code analysis is entered before the calls' turn is taken:
          // entering may wait (an idle analysis server that is being
          // stopped), and no other tool waits for that.
          return await codeAnalysis(
            (analysis) => _oneAtATime(
              () => _verify(request.arguments ?? const {}, analysis),
            ),
          );
        } on CodeAnalysisException catch (error) {
          // The analysis could not be entered at all. No refresh ran, so
          // the reply states no freshness.
          return CallToolResult(
            isError: true,
            content: [TextContent(text: '$error $_doctor')],
          );
        }
      }),
    );
  }

  /// The project's folder.
  final String projectRoot;

  /// The sync to run before each answer; called once per answer.
  final KnowledgeSync Function() syncFor;

  /// Gives each `verify` call the project's code analysis, and decides how
  /// long its analysis server lives. `appstein mcp` passes
  /// `KeptAnalysisServer.use`, which keeps one server between the calls;
  /// whoever made that object closes it when this server is done.
  final CodeAnalysisScope codeAnalysis;

  /// Where `dart:` libraries are read from; null for the Flutter SDK's.
  final String? dartSdkPath;

  final DateTime Function() _clock;

  /// The turn every call answers in: one call at a time.
  final _calls = _Turn();

  /// The turn of the `verify` calls. A `verify` call gives [_calls] back
  /// while it waits for the analysis server, so that the other tools are
  /// answered meanwhile; this one it keeps, so a second `verify` call waits
  /// for the first.
  final _verifyCalls = _Turn();

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
  Future<T> _oneAtATime<T>(Future<T> Function() action) => _calls.hold(action);

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
  ///
  /// It runs in the calls' turn like every tool, and gives the turn back
  /// for as long as the run waits for the code analysis: an analysis server
  /// can take a minute to start, and no other tool waits for it. A call of
  /// another tool that is answered meanwhile may refresh the knowledge;
  /// this run then judges that newer knowledge, and its reply still states
  /// the freshness its own refresh found.
  ///
  /// With `apply: true` (full scope only), the project is fixed and
  /// formatted first (`applyToProject`), before the refresh, so the refresh
  /// and the reading are of the rewritten files, as in `appstein verify
  /// --apply`; once the knowledge is up to date, the human docs are rendered
  /// (`renderDocsForApply`), and the pages written join `applied`.
  /// Everything the call asks is checked before that, so a refusal
  /// never follows a rewrite; a failure after it still names the files it
  /// rewrote. `apply` with the fast scope is refused.
  ///
  /// [analysis] is the call's code analysis, which the caller has entered
  /// (`codeAnalysis`) before it took the calls' turn.
  Future<CallToolResult> _verify(
    Map<String, Object?> arguments,
    CodeAnalysis analysis,
  ) async {
    final mode = arguments['scope'] == 'fast'
        ? VerifyMode.fast
        : VerifyMode.full;
    // What the call asks is checked before anything is rewritten: a refusal
    // after `apply` would leave files rewritten that no result names. The
    // refusal is sent after the refresh, with the freshness it found.
    String? refusal;
    var files = const <String>[];
    var config = const AppsteinConfig();
    final apply = arguments['apply'];
    try {
      config = loadConfig(projectRoot) ?? const AppsteinConfig();
    } on ConfigException catch (error) {
      final problem = '$error'.replaceFirst(RegExp(r'\.$'), '');
      refusal =
          'The checks could not run: appstein.yaml is invalid: $problem. '
          'Fix it, then call `verify` again.';
    }
    if (refusal == null && apply is! bool?) {
      refusal =
          '`apply` must be true or false. Call `verify` again with '
          '`apply: true`, or without it.';
    }
    if (refusal == null && apply == true && mode == VerifyMode.fast) {
      // Files are never rewritten in the middle of an agent's work.
      refusal =
          '`apply` works with `scope: full` only: a fast run never rewrites '
          'files. Call `verify` again with `scope: full`, or without '
          '`apply`.';
    }
    if (refusal == null) {
      switch (arguments['files']) {
        case null:
          break;
        case final List<Object?> given when given.every((f) => f is String):
          if (mode != VerifyMode.fast) {
            refusal =
                '`files` works with `scope: fast` only: a full run checks '
                'every file. Call `verify` again without `files`, or with '
                '`scope: fast`.';
            break;
          }
          try {
            files = resolveVerifyFiles(projectRoot, given.cast<String>());
          } on VerifyFilesException catch (error) {
            final message = error.message.replaceAll('--files', '`files`');
            refusal =
                '$message Call `verify` again with paths inside the project.';
          }
        default:
          refusal =
              '`files` must be a list of paths. Call `verify` again with a '
              'list.';
      }
    }
    final codeAnalysis = _OutOfTurn(analysis, _calls);
    // `apply` rewrites the files before the knowledge is brought up to date,
    // as `appstein verify --apply` does: the refresh and the reading that
    // follow are of the rewritten files.
    var applied = const <String>[];
    var leftAlone = const <String>[];
    if (refusal == null && apply == true) {
      try {
        final changes = await applyToProject(
          codeAnalysis,
          projectRoot: projectRoot,
        );
        applied = changes.written;
        leftAlone = changes.notices;
      } on CodeAnalysisException catch (error) {
        refusal = '$error $_doctor';
      }
    }
    KnowledgeSync? sync;
    final freshness = await _freshen(built: (built) => sync = built);
    // A refusal after `apply` rewrote files still names them.
    String rewritten(String message) => applied.isEmpty
        ? message
        : '$message `apply` rewrote ${applied.join(', ')} before that: read '
              '${applied.length == 1 ? 'it' : 'them'} again before you edit '
              '${applied.length == 1 ? 'it' : 'them'}.';
    if (refusal case final message?) return _refuse(message, freshness);
    try {
      final using = sync;
      // Without a sync there are no packs, so no list of checks.
      if (using == null) {
        return _refuse(rewritten('The checks could not run.'), freshness);
      }
      // `apply` renders the human docs once the knowledge is up to date with
      // the rewritten files, as `appstein verify --apply` does
      // (`renderDocsForApply`, the code of `appstein docs`); a docs run that
      // can't be done writes nothing and is reported by `docs.stale`.
      if (apply == true) {
        final docs = await renderDocsForApply(
          projectRoot: projectRoot,
          config: config,
          packs: using.packs,
          sync: using,
          dartSdkPath: dartSdkPath,
        );
        applied = [...applied, ...docs.written];
        leftAlone = [...leftAlone, ...docs.notices];
      }
      final result = await runVerify(
        projectRoot: projectRoot,
        config: config,
        packs: using.packs,
        sync: using,
        mode: mode,
        checks: checksFor(using.packs),
        codeAnalysis: codeAnalysis,
        refreshed: KnowledgeRefresh.fromFreshness(freshness),
        dartSdkPath: dartSdkPath,
        files: files,
      );
      return switch (verifyAnswer(
        result.withApplied(applied).withNotices(leftAlone),
        mode: mode,
      )) {
        ToolReply(result: final json, :final summary) => _reply(
          json,
          summary,
          freshness,
        ),
        ToolRefusal(:final message) => _refuse(rewritten(message), freshness),
      };
    } on CodeAnalysisException catch (error) {
      // A broken setup, not a bug to report; the server keeps running.
      return _refuse(rewritten('$error $_doctor'), freshness);
    } on TestRunException catch (error) {
      // The project's tests could not be run: a broken setup as well.
      return _refuse(rewritten('$error $_doctor'), freshness);
    } on Object catch (error) {
      return _refuse(
        rewritten(
          'Appstein failed to answer: $error. $_doctor If this keeps '
          'happening, please report it.',
        ),
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
