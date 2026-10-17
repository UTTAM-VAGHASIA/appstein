import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import 'analysis_guard_command.dart';
import 'exit_codes.dart';
import 'failure.dart';
import 'finding_text.dart';
import 'packs.dart';
import 'project_option.dart';
import 'verify_hook.dart';
import 'version.dart';

/// Builds the checks of a project from its packs; `checksFor` by default.
typedef VerifyChecks =
    List<({VerifyCheck check, String? pack})> Function(List<Pack> packs);

/// `appstein verify [--fast | --full] [--apply] [--format text|json]
/// [--files paths]`: checks the project against its knowledge (spec §5.3,
/// §9), after bringing the knowledge up to date. Without `--apply` it never
/// writes a project file outside `.appstein/`. For the code checks it starts
/// the project's Dart analysis server, waits for the first analysis, and
/// stops the server before it returns.
///
/// `--files` (fast runs only) adds files to the unverified files, for the
/// run and after it (`resolveVerifyFiles`): a path outside the project,
/// and `--files` with a full run, are usage errors.
///
/// `--apply` (full runs only) first applies the fixes `dart fix` would apply
/// and formats the project (`applyToProject`), then refreshes the knowledge,
/// renders the human docs into the docs folder when `docs.enabled` is on
/// (`renderDocsForApply`, the code of `appstein docs`), and runs every check;
/// the result names each file it rewrote and each docs page it wrote. With
/// `--fast` it is a usage error.
///
/// Exit codes (spec §9.5): 0 when no finding is an error; 1 when one is; 3
/// when Appstein itself failed (no project, a bad `appstein.yaml`, bad
/// usage, a check that threw, an analysis server that could not answer).
final class VerifyCommand extends Command<int> {
  /// Creates the command. [checks] replaces the project's checks,
  /// [codeAnalysis] the analysis server the run would start, and
  /// [dartSdkPath] the Dart SDK the analysis reads `dart:` libraries from,
  /// for tests.
  VerifyCommand({
    required this.out,
    required this.err,
    required this.environment,
    this.checks = checksFor,
    this.codeAnalysis,
    this.dartSdkPath,
    this.hookInput,
    this.hookAnswer,
  }) {
    argParser
      ..addFlag(
        'fast',
        negatable: false,
        help: 'Run only the fast checks, as after every change.',
      )
      ..addFlag(
        'full',
        negatable: false,
        help: 'Run every check, as before a task is done (the default).',
      )
      ..addOption(
        'format',
        allowed: const ['text', 'json'],
        defaultsTo: 'text',
        help: 'How the findings are printed.',
      )
      ..addMultiOption(
        'files',
        valueHelp: 'paths',
        help:
            'With --fast: add these files to the unverified files, for this '
            'run and after it. Paths are from the project root, or absolute '
            'inside the project; a folder stands for its Dart files. '
            'Separate them with commas, or repeat the option.',
      )
      ..addFlag(
        'apply',
        negatable: false,
        help:
            'With a full run: first apply the fixes `dart fix` would apply '
            'and format the whole project (generated files left out), render '
            'the human docs when docs.enabled is on, then check. Names each '
            'file it rewrote and each docs page it wrote. Without it, verify '
            'writes no project file.',
      )
      ..addOption(
        'hook',
        allowed: const ['claude', 'codex'],
        allowedHelp: const {
          'claude': 'Answer as a Claude Code hook (with --fast).',
          'codex': 'Not available yet: Codex hooks come in a later release.',
        },
        help:
            'Answer as the hook of an agent: read its input on stdin and '
            'reply the way it reads hooks, with its own exit codes.',
      );
  }

  /// Where the findings go, in both formats.
  final StringSink out;

  /// Where problems of Appstein itself go.
  final StringSink err;

  /// The machine, used to find the project and the Flutter SDK.
  final HostEnvironment environment;

  /// Builds the project's checks from its packs.
  final VerifyChecks checks;

  /// Gives the run its code analysis. When null, the run starts an analysis
  /// server of its own and stops it when it ends ([terminalCodeAnalysis]).
  /// Only tests set it.
  final CodeAnalysisScope? codeAnalysis;

  /// Where the analysis reads `dart:` libraries from, and whose `dart` runs
  /// the analysis server, instead of the Flutter SDK's own Dart SDK. Only
  /// tests set it.
  final String? dartSdkPath;

  /// Reads the hook's input, which an agent passes on stdin, when `--hook` is
  /// given; by default stdin ([readStdinText]). Only tests set it.
  final Future<String> Function()? hookInput;

  /// The one answer a `--hook` run may give, shared with the failure handlers
  /// of the run (`runAppstein` passes its own). By default a new one.
  final HookAnswer? hookAnswer;

  @override
  String get name => 'verify';

  @override
  String get description =>
      'Check the project against its knowledge (fast or full).';

  @override
  void printUsage() => out.writeln(usage);

  @override
  Future<int> run() async {
    final results = argResults!;
    if (results.flag('fast') && results.flag('full')) {
      usageException('Pass --fast or --full, not both.');
    }
    // The unverified files belong to fast runs: a full run checks every
    // file anyway.
    if (results.wasParsed('files') && !results.flag('fast')) {
      usageException(
        '--files works with a fast run only: pass --fast with it. A full run '
        'checks every file.',
      );
    }
    // Files are never rewritten in the middle of an agent's work.
    if (results.flag('apply') && results.flag('fast')) {
      usageException(
        '--apply works with a full run only: run `appstein verify --apply` '
        'without --fast. A fast run never rewrites files.',
      );
    }
    final hook = results.option('hook');
    if (hook == 'codex') {
      usageException(
        '--hook codex is not available yet: Codex\'s hooks are checked in '
        'slice 1e. Use --hook claude for Claude Code.',
      );
    }
    if (hook != null) {
      if (results.wasParsed('format')) {
        usageException(
          '--hook has its own output: don\'t pass --format with it.',
        );
      }
      if (!results.flag('fast')) {
        usageException(
          '--hook claude works with a fast run only for now: pass --fast with '
          'it (the hook after an edit).',
        );
      }
      return _runAsHook(results);
    }
    // A run that can't start, a check that throws and an analysis server
    // that can't answer are Appstein's failure: the runner tells it
    // (`describeFailure`) and exits 3.
    final result = await _check(results, _setUp(results));
    out.write(
      results.option('format') == 'json'
          ? '${const JsonEncoder.withIndent('  ').convert(result.toJson())}\n'
          : formatVerify(result),
    );
    return verifyExitCode(result);
  }

  /// `--hook claude --fast`: reads the hook's input, runs the checks, and
  /// answers the way Claude Code reads a PostToolUse hook
  /// ([claudePostToolUseReply]). A failure of Appstein itself is told to the
  /// agent and the developer with exit 0, and never blocks
  /// ([answerHookFailure]), with the details on stderr; a usage error is
  /// still exit 3. The reply goes through [hookAnswer], so a failure handler
  /// that fires meanwhile and this command never both answer.
  ///
  /// **Nothing changed means no output** (spec §9.1, slice 1d.7): when the
  /// input names a session, the run first takes the fingerprint of everything
  /// the knowledge and the checks read ([KnowledgeSync.fingerprint], one hash
  /// scan). If it equals the fingerprint of this session's last completed
  /// hook run ([HookSessions]), nothing Appstein reads has changed since the
  /// session last heard from it, and the run exits 0 with no output, runs no
  /// check and writes no file. The comparison is with the session's own
  /// record, not with `state.json`: another session's refresh uses up the
  /// shared change list, and would hide this session's edit.
  ///
  /// The fingerprint taken at the start is saved after the reply was written,
  /// and only for a run that completed its checks ([hookRunCompleted]): one
  /// that failed, or named a check as not run, saves nothing, so the next run
  /// asks again. It is taken again after the reply and saved only if it is
  /// the same: files that changed while the checks ran, and may have changed
  /// back, were not checked as they are now, so nothing is saved and the next
  /// run checks (`_SilenceGate`). A run with no session (missing or
  /// unreadable input), and a run given `--files`, always checks.
  Future<int> _runAsHook(ArgResults results) async {
    // The input is read first, as an agent sends it and closes the pipe. A
    // missing or broken input is no session.
    var input = const HookInput();
    try {
      input = parseHookInput(await (hookInput ?? readStdinText)());
    } on Object {
      // Input that can't be read counts as no session.
    }
    final answer = hookAnswer ?? HookAnswer();
    late final _SilenceGate gate;
    final HookReply reply;
    final VerifyResult result;
    try {
      final setup = _setUp(results);
      gate = _SilenceGate(
        input.sessionId,
        sync: setup.sync,
        projectRoot: setup.projectRoot,
      );
      if (await gate.nothingChanged(filesGiven: setup.files.isNotEmpty)) {
        return answer.write(const HookReply(exitCode: ExitCodes.ok), out, err);
      }
      result = await _check(results, setup);
      reply = claudePostToolUseReply(result);
    } on UsageException {
      rethrow;
    } on Object catch (error, stackTrace) {
      return answerHookFailure(
        out,
        err,
        describeFailure(error, stackTrace),
        answer,
      );
    }
    // A failure handler that spoke first has the only answer: the run did not
    // complete as far as Claude Code is concerned.
    final spokenFor = answer.answered;
    final exitCode = answer.write(reply, out, err);
    // After the reply, so a hook killed in between is checked again.
    if (!spokenFor && hookRunCompleted(result)) await gate.save();
    return exitCode;
  }

  /// What a run needs before it checks: the project, the files it was given,
  /// its configuration and packs, and the knowledge sync. Throws
  /// [CannotStart] when there is no project or its `appstein.yaml` is
  /// invalid, and a usage error for a path given to `--files` that can't be
  /// taken.
  _RunSetup _setUp(ArgResults results) {
    final given = results.multiOption('files');
    final projectRoot = resolveProjectRoot(globalResults, environment);
    if (projectRoot == null) {
      throw CannotStart(
        'appstein verify needs a Flutter project, but there is no '
            'pubspec.yaml in ${environment.workingDirectory} or any folder '
            'above it.',
        'Run it inside the project, or pass --project <path>.',
      );
    }
    final List<String> files;
    try {
      files = resolveVerifyFiles(projectRoot, given);
    } on VerifyFilesException catch (error) {
      usageException(error.message);
    }
    final AppsteinConfig config;
    try {
      config = loadConfig(projectRoot) ?? const AppsteinConfig();
    } on ConfigException catch (error) {
      throw CannotStart(
        '$error',
        'Fix appstein.yaml, then run `appstein verify` again.',
      );
    }
    final packs = packsFor(config);
    // Package skills start a process and write agent folders, which belongs
    // to `appstein sync`.
    final sync = KnowledgeSync(
      environment: environment,
      appsteinVersion: appsteinVersion,
      packs: packs,
      baseline: config.delta.baseline,
      agents: config.integrations.agents,
      packageSkills: false,
    );
    return (
      projectRoot: projectRoot,
      files: files,
      config: config,
      packs: packs,
      sync: sync,
    );
  }

  /// Brings the knowledge up to date, runs the checks and returns the result
  /// as the terminal prints it. Throws what the run throws when Appstein
  /// itself fails: the runner reports those and exits 3.
  Future<VerifyResult> _check(ArgResults results, _RunSetup setup) async {
    final apply = results.flag('apply');
    final (:projectRoot, :files, :config, :packs, :sync) = setup;
    // What the stop of the run's own analysis server could not end: known
    // only after the run, and printed with its result.
    final left = <String>[];
    final analysis =
        codeAnalysis ??
        terminalCodeAnalysis(
          projectRoot: projectRoot,
          environment: environment,
          dartSdkPath: dartSdkPath,
          onLeft: left.addAll,
        );
    // A check that throws and an analysis server that can't answer are
    // Appstein's failure: the runner reports the `VerifyCheckError` or the
    // `CodeAnalysisException` and exits 3. The server is stopped either
    // way, by the scope.
    final found = await analysis((codeAnalysis) async {
      // `--apply` rewrites the files first: the refresh and the reading that
      // follow are of the rewritten files.
      final changes = apply
          ? await applyToProject(codeAnalysis, projectRoot: projectRoot)
          : const AppliedChanges();
      // Every file `--apply` wrote, named in the result: the fixed and
      // formatted files, then the human docs pages.
      final written = [...changes.written];
      final notices = [...changes.notices];
      try {
        // Then the human docs, once the knowledge is up to date with the
        // rewritten files: the code of `appstein docs`. A page it can't
        // render is left alone, and the run's `docs.stale` reports it.
        if (apply) {
          final docs = await renderDocsForApply(
            projectRoot: projectRoot,
            config: config,
            packs: packs,
            sync: sync,
            dartSdkPath: dartSdkPath,
          );
          written.addAll(docs.written);
          notices.addAll(docs.notices);
        }
        final result = await runVerify(
          projectRoot: projectRoot,
          config: config,
          packs: packs,
          sync: sync,
          mode: results.flag('fast') ? VerifyMode.fast : VerifyMode.full,
          checks: checks(packs),
          codeAnalysis: codeAnalysis,
          dartSdkPath: dartSdkPath,
          files: files,
        );
        return result.withApplied(written).withNotices(notices);
      } on Object {
        // The run failed after `--apply` had rewritten files: they are named
        // before the failure is reported (exit 3), so none goes unread.
        if (written.isNotEmpty) err.writeln(rewrittenBeforeFailure(written));
        rethrow;
      }
    });
    return found.withNotices(left);
  }
}

/// What a `verify` run needs before it checks (`_setUp`).
typedef _RunSetup = ({
  String projectRoot,
  List<String> files,
  AppsteinConfig config,
  List<Pack> packs,
  KnowledgeSync sync,
});

/// A hook run's memory of its session: whether the run may stay silent, and
/// the saving of what the run saw (slice 1d.7, "Nothing changed means no
/// output"). A run with no session gets a gate that is never silent and
/// saves nothing.
final class _SilenceGate {
  _SilenceGate(
    String? sessionId, {
    required this._sync,
    required this._projectRoot,
  }) : _session = sessionId == null
           ? null
           : (id: sessionId, records: HookSessions(_projectRoot));

  final ({String id, HookSessions records})? _session;
  final KnowledgeSync _sync;
  final String _projectRoot;

  /// The fingerprint taken before the checks; null when there is none.
  String? _before;

  /// Whether nothing the checks read changed since this session's last
  /// completed run: the fingerprint is taken, and equals the session's
  /// record. It is taken for a run given files too ([filesGiven]), which
  /// always checks, so that the run can save it.
  Future<bool> nothingChanged({required bool filesGiven}) async {
    final session = _session;
    if (session == null) return false;
    final before = _before = await _fingerprint();
    return before != null &&
        !filesGiven &&
        session.records.read(session.id) == before;
  }

  /// Saves the fingerprint taken before the checks, if the files are still
  /// as they were then: a second fingerprint, taken now, must equal it. Files
  /// that changed while the checks ran, and perhaps changed back, were not
  /// checked in the state they are in now, so nothing is saved and the next
  /// run checks. A record that can't be written is not an error: it only
  /// saves the next run's work.
  Future<void> save() async {
    final session = _session;
    final before = _before;
    if (session == null || before == null) return;
    if (await _fingerprint() != before) return;
    try {
      await session.records.saveFingerprint(session.id, before);
    } on Object {
      // The record only saves the next run's work.
    }
  }

  /// The fingerprint of what the checks read, or null when it can't be taken
  /// (no Flutter SDK, say): the run then checks, and reports what is wrong as
  /// it always does.
  Future<String?> _fingerprint() async {
    try {
      return await _sync.fingerprint(_projectRoot);
    } on Object {
      return null;
    }
  }
}

/// The code analysis of a run that owns its analysis server: each run
/// starts the server of the SDK the project at [projectRoot] uses, behind
/// the guard ([analysisGuardCommand]), when a check first asks, and stops
/// it when the run ends, normally or with an error. A terminal `appstein
/// verify` uses it. The `verify` tool of `appstein mcp` asks the project's
/// analysis host instead (`hostCodeAnalysis`).
///
/// [dartSdkPath] replaces the Flutter SDK's own Dart SDK, for tests.
/// [onLeft] is told, after the server was stopped, each process the stop
/// could not end because it could not be shown to be the run's own
/// (`ownAnalysisServer`). The server's cache folder is the one
/// [environment] names (`analysisServerEnvironment`).
CodeAnalysisScope terminalCodeAnalysis({
  required String projectRoot,
  required HostEnvironment environment,
  String? dartSdkPath,
  void Function(List<String> notices)? onLeft,
}) => ownAnalysisServer(
  projectRoot: projectRoot,
  guardCommand: analysisGuardCommand(),
  dartExecutable: () =>
      projectDartExecutable(environment, projectRoot, dartSdkPath: dartSdkPath),
  environment: analysisServerEnvironment(environment),
  onLeft: onLeft,
);

/// What `appstein verify --apply` prints to stderr when the run fails after
/// it rewrote [files]: each of them, to be read again before it is edited.
String rewrittenBeforeFailure(List<String> files) => [
  '--apply rewrote ${files.length == 1 ? 'this file' : 'these files'} before '
      'the run failed (read ${files.length == 1 ? 'it' : 'them'} again before '
      'you edit ${files.length == 1 ? 'it' : 'them'}):',
  for (final file in files) '  $file',
].join('\n');

/// The exit code of `appstein verify` for [result] (spec §9.5): 1 when a
/// finding is an error, else 0. Warnings, info findings and checks that did
/// not run never fail a run on their own: a check that could not run comes
/// with the error that kept it from running.
int verifyExitCode(VerifyResult result) =>
    result.errors > 0 ? ExitCodes.errorsFound : ExitCodes.ok;

String _count(int count, String one, String many) =>
    '$count ${count == 1 ? one : many}';

/// The text `appstein verify` prints for [result] (spec §9.3):
/// - first, when `--apply` rewrote files ([VerifyResult.applied]), a section
///   that names each of them, to be read again before they are edited;
///   without `--apply`, or when it rewrote nothing, there is no section;
/// - the findings in groups: `(project)` for those about no file, then one
///   group per file. A group with an error comes before a group without
///   one; inside each half, `(project)` is first and the files are in path
///   order. Each finding is a line with its severity, ID, line number when
///   it has one and message, and a `fix:` line when it has a fix hint;
/// - `Not run:` with each check that could not run and why;
/// - `Note:` with each notice of the result, which is no finding: a process
///   Appstein could not stop, and the command to end it by hand;
/// - one summary line, which is the whole output when nothing was found.
String formatVerify(VerifyResult result) {
  final lines = <String>[
    // Before the findings: the agent must read these again before it edits
    // them.
    if (result.applied.isNotEmpty) ...[
      result.applied.length == 1
          ? 'Rewritten by --apply (read this file again before you edit it):'
          : 'Rewritten by --apply (read these files again before you edit '
                'them):',
      for (final file in result.applied) '  $file',
      '',
    ],
  ];
  lines.addAll(findingLines(orderedFindings(result.findings)));
  if (result.notRun.isNotEmpty) {
    lines
      ..add('Not run:')
      ..addAll([
        for (final check in result.notRun) '  ${check.id}: ${check.reason}',
      ])
      ..add('');
  }
  if (result.notices.isNotEmpty) {
    lines
      ..add('Note:')
      ..addAll([for (final notice in result.notices) '  $notice'])
      ..add('');
  }
  lines
    ..add(
      '${_count(result.errors, 'error', 'errors')}, '
      '${_count(result.warnings, 'warning', 'warnings')}, '
      '${result.info} info. '
      '${switch (result.suppressed) {
        0 => 'No findings suppressed.',
        final count => '${_count(count, 'finding', 'findings')} suppressed by '
            '${_count(result.activeSuppressions, 'suppression', 'suppressions')}.',
      }}',
    )
    ..add('');
  return lines.join('\n');
}
