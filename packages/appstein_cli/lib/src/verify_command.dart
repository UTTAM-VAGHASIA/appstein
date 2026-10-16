import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:args/command_runner.dart';

import 'analysis_guard_command.dart';
import 'exit_codes.dart';
import 'packs.dart';
import 'project_option.dart';
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
/// and formats the project (`applyToProject`), then refreshes the knowledge
/// and runs every check; the result names each file it rewrote. With
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
            'and format the whole project (generated files left out), then '
            'check. Names each file it rewrote. Without it, verify writes no '
            'project file.',
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
    final given = results.multiOption('files');
    // The unverified files belong to fast runs: a full run checks every
    // file anyway.
    if (results.wasParsed('files') && !results.flag('fast')) {
      usageException(
        '--files works with a fast run only: pass --fast with it. A full run '
        'checks every file.',
      );
    }
    final apply = results.flag('apply');
    // Files are never rewritten in the middle of an agent's work.
    if (apply && results.flag('fast')) {
      usageException(
        '--apply works with a full run only: run `appstein verify --apply` '
        'without --fast. A fast run never rewrites files.',
      );
    }
    final projectRoot = resolveProjectRoot(globalResults, environment);
    if (projectRoot == null) {
      err
        ..writeln(
          'appstein verify needs a Flutter project, but there is no '
          'pubspec.yaml in ${environment.workingDirectory} or any folder '
          'above it.',
        )
        ..writeln('Run it inside the project, or pass --project <path>.');
      return ExitCodes.appsteinFailed;
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
      err
        ..writeln(error)
        ..writeln('Fix appstein.yaml, then run `appstein verify` again.');
      return ExitCodes.appsteinFailed;
    }
    final packs = packsFor(config);
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
      final VerifyResult result;
      try {
        result = await runVerify(
          projectRoot: projectRoot,
          config: config,
          packs: packs,
          // Package skills start a process and write agent folders, which
          // belongs to `appstein sync`.
          sync: KnowledgeSync(
            environment: environment,
            appsteinVersion: appsteinVersion,
            packs: packs,
            baseline: config.delta.baseline,
            agents: config.integrations.agents,
            packageSkills: false,
          ),
          mode: results.flag('fast') ? VerifyMode.fast : VerifyMode.full,
          checks: checks(packs),
          codeAnalysis: codeAnalysis,
          dartSdkPath: dartSdkPath,
          files: files,
        );
      } on Object {
        // The run failed after `--apply` had rewritten files: they are named
        // before the failure is reported (exit 3), so none goes unread.
        if (changes.written.isNotEmpty) {
          err.writeln(rewrittenBeforeFailure(changes.written));
        }
        rethrow;
      }
      return result.withApplied(changes.written).withNotices(changes.notices);
    });
    final result = found.withNotices(left);
    out.write(
      results.option('format') == 'json'
          ? '${const JsonEncoder.withIndent('  ').convert(result.toJson())}\n'
          : formatVerify(result),
    );
    return verifyExitCode(result);
  }
}

/// The code analysis of a run that owns its analysis server: each run
/// starts the server of the SDK the project at [projectRoot] uses, behind
/// the guard ([analysisGuardCommand]), when a check first asks, and stops
/// it when the run ends, normally or with an error. A terminal `appstein
/// verify` uses it. `appstein mcp` keeps one server between its `verify`
/// calls instead (`keptCodeAnalysis`).
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
  final groups = <String?, List<Finding>>{};
  for (final finding in result.findings) {
    (groups[finding.file] ??= []).add(finding);
  }
  bool hasError(String? file) =>
      groups[file]!.any((finding) => finding.severity == Severity.error);
  // The findings are sorted already (`sortFindings`): no file first, then
  // by path. A stable split keeps that order inside each half.
  final files = [
    for (final file in groups.keys)
      if (hasError(file)) file,
    for (final file in groups.keys)
      if (!hasError(file)) file,
  ];

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
  for (final file in files) {
    lines.add(file ?? '(project)');
    for (final finding in groups[file]!) {
      final line = switch (finding.line) {
        final line? => ' (line $line)',
        null => '',
      };
      lines.add(
        '  ${finding.severity.name} ${finding.id}$line: ${finding.message}',
      );
      if (finding.fixHint case final fix?) lines.add('    fix: $fix');
    }
    lines.add('');
  }
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
