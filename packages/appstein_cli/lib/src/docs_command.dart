import 'dart:math';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:args/command_runner.dart';

import 'exit_codes.dart';
import 'packs.dart';
import 'project_option.dart';
import 'version.dart';

/// `appstein docs [--check]`: renders the human docs into the project's
/// docs folder (spec §5.3, §6.9), after bringing the knowledge up to date.
/// With `--check` it writes no page and exits 1 when a page is stale.
///
/// Exit codes: 0 when the docs are written, current or turned off; 1 when
/// nothing could be rendered or, with `--check`, a page is stale; 3 when
/// Appstein itself failed (no project, a bad `appstein.yaml`, a page that
/// can't be written).
final class DocsCommand extends Command<int> {
  /// Creates the command.
  DocsCommand({
    required this.out,
    required this.err,
    required this.environment,
  }) {
    argParser.addFlag(
      'check',
      negatable: false,
      help:
          'Write no page; exit 1 if a page is missing, behind the app, '
          'edited by hand or no longer rendered.',
    );
  }

  /// Where the report goes.
  final StringSink out;

  /// Where problems go.
  final StringSink err;

  /// The machine, used to find the project and the Flutter SDK.
  final HostEnvironment environment;

  @override
  String get name => 'docs';

  @override
  String get description =>
      'Render the human docs (docs/app/) from the knowledge.';

  @override
  void printUsage() => out.writeln(usage);

  @override
  Future<int> run() async {
    final projectRoot = resolveProjectRoot(globalResults, environment);
    if (projectRoot == null) {
      err
        ..writeln(
          'appstein docs needs a Flutter project, but there is no '
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
        ..writeln('Fix appstein.yaml, then run `appstein docs` again.');
      return ExitCodes.appsteinFailed;
    }
    final packs = packsFor(config);
    final check = argResults!['check'] as bool;
    final DocsOutcome outcome;
    try {
      outcome = await runDocs(
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
        check: check,
      );
    } on KnowledgeWriteException catch (error) {
      err
        ..writeln(error)
        ..writeln(
          'Some pages may already be written. Fix that, then run `appstein '
          'docs` again to finish.',
        );
      return ExitCodes.appsteinFailed;
    }
    switch (outcome) {
      case DocsDisabled():
        out.write(formatDocs(outcome));
        return ExitCodes.ok;
      case DocsRefused():
        err.write(formatDocs(outcome));
        return ExitCodes.errorsFound;
      case DocsDone(:final stale):
        out.write(formatDocs(outcome));
        return check && stale ? ExitCodes.errorsFound : ExitCodes.ok;
    }
  }
}

String _count(int count, String one, String many) =>
    '$count ${count == 1 ? one : many}';

/// The text `appstein docs` prints for [outcome] (spec §6.9):
/// - written docs: how many pages were written, removed and unchanged, then
///   a line for each page written or removed, saying when hand edits were
///   lost;
/// - `--check`: each stale page with why it is stale, and what to run;
/// - nothing to do: one line with the number of pages;
/// - a refusal: that nothing was changed, why, any details, and what to do;
/// - docs turned off: one line.
///
/// Unchanged pages are counted, never listed.
String formatDocs(DocsOutcome outcome) {
  switch (outcome) {
    case DocsDisabled():
      return 'Human docs are turned off (docs.enabled is false in '
          'appstein.yaml).\n';
    case DocsRefused(
      :final docsPath,
      :final problem,
      :final details,
      :final fixHint,
    ):
      return [
        'Nothing in $docsPath/ was changed: '
            '$problem${problem.endsWith('.') ? '' : '.'}',
        for (final detail in details) '  $detail',
        ?fixHint,
        '',
      ].join('\n');
    case DocsDone(:final docsPath, :final check, :final changes):
      final stale = [
        for (final change in changes)
          if (change.kind != DocChangeKind.unchanged) change,
      ];
      if (stale.isEmpty) {
        return '$docsPath/ is up to date '
            '(${_count(changes.length, 'page', 'pages')}).\n';
      }
      final width = stale.map((change) => change.path.length).fold(0, max);
      String line(DocChange change, String what) =>
          '  ${change.path.padRight(width)}  $what';
      if (check) {
        return [
          '$docsPath/ is behind the app: ${stale.length} of '
              '${_count(changes.length, 'page', 'pages')}.',
          for (final change in stale)
            line(change, switch (change.reason!) {
              DocStaleReason.missing => 'missing',
              DocStaleReason.behind => 'behind the app',
              DocStaleReason.handEdited => 'hand-edited',
              DocStaleReason.notRendered => 'no longer rendered',
            }),
          'Run `appstein docs` to update '
              '${stale.length == 1 ? 'it' : 'them'}.',
          '',
        ].join('\n');
      }
      final written = stale
          .where((change) => change.kind == DocChangeKind.write)
          .length;
      final removed = stale.length - written;
      final unchanged = changes.length - stale.length;
      return [
        'Rendered $docsPath/: ${[if (written > 0) '$written written', if (removed > 0) '$removed removed', if (unchanged > 0) '$unchanged unchanged'].join(', ')}.',
        for (final change in stale)
          line(
            change,
            change.kind == DocChangeKind.write
                ? 'written'
                      '${change.hadHandEdits ? ' (overwrote hand edits)' : ''}'
                : 'removed'
                      '${change.hadHandEdits ? ' (it had hand edits)' : ''}',
          ),
        '',
      ].join('\n');
  }
}
