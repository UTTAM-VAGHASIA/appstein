import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:args/command_runner.dart';

import 'exit_codes.dart';
import 'packs.dart';
import 'project_option.dart';
import 'version.dart';

/// Builds the checks of a project from its packs; `checksFor` by default.
typedef VerifyChecks =
    List<({VerifyCheck check, String? pack})> Function(List<Pack> packs);

/// `appstein verify [--fast | --full] [--format text|json]`: checks the
/// project against its knowledge (spec §5.3, §9), after bringing the
/// knowledge up to date. It never writes a project file outside
/// `.appstein/`.
///
/// Exit codes (spec §9.5): 0 when no finding is an error; 1 when one is; 3
/// when Appstein itself failed (no project, a bad `appstein.yaml`, bad
/// usage, a check that threw).
final class VerifyCommand extends Command<int> {
  /// Creates the command. [checks] replaces the project's checks, for
  /// tests.
  VerifyCommand({
    required this.out,
    required this.err,
    required this.environment,
    this.checks = checksFor,
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
    // A check that throws is Appstein's failure: the runner reports the
    // `VerifyCheckError` and exits 3.
    final result = await runVerify(
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
    );
    out.write(
      results.option('format') == 'json'
          ? '${const JsonEncoder.withIndent('  ').convert(result.toJson())}\n'
          : formatVerify(result),
    );
    return verifyExitCode(result);
  }
}

/// The exit code of `appstein verify` for [result] (spec §9.5): 1 when a
/// finding is an error, else 0. Warnings, info findings and checks that did
/// not run never fail a run on their own: a check that could not run comes
/// with the error that kept it from running.
int verifyExitCode(VerifyResult result) =>
    result.errors > 0 ? ExitCodes.errorsFound : ExitCodes.ok;

String _count(int count, String one, String many) =>
    '$count ${count == 1 ? one : many}';

/// The text `appstein verify` prints for [result] (spec §9.3):
/// - the findings in groups: `(project)` for those about no file, then one
///   group per file. A group with an error comes before a group without
///   one; inside each half, `(project)` is first and the files are in path
///   order. Each finding is a line with its severity, ID, line number when
///   it has one and message, and a `fix:` line when it has a fix hint;
/// - `Not run:` with each check that could not run and why;
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

  final lines = <String>[];
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
