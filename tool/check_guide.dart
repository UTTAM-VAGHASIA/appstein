import 'dart:io';

import 'package:args/args.dart';

import 'src/git_repo.dart';
import 'src/guide_check.dart';
import 'src/guide_checker.dart';

/// Checks the developer guide and package READMEs (spec §19.6). Run from the
/// repo root:
///   fvm dart run tool/check_guide.dart               every check except the
///                                                    stale-page check
///   fvm dart run tool/check_guide.dart --since main  plus the stale-page
///                                                    check against main
/// The post-commit hook adds --warn-only, which prints problems, or a check
/// that could not run, as warnings and exits 0. Bad usage still exits 3.
/// CI is the gate.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'since',
      valueHelp: 'rev',
      help:
          'Also check for stale pages: compare the working tree with the '
          'merge base of <rev> and HEAD.',
    )
    ..addFlag(
      'warn-only',
      negatable: false,
      help:
          'Print problems as warnings and exit 0, even when the check '
          'cannot run (for the git hook).',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');
  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln(parser.usage);
    exitCode = 3;
    return;
  }
  if (options.flag('help')) {
    stdout.writeln(parser.usage);
    return;
  }
  if (options.rest.isNotEmpty) {
    stderr
      ..writeln('Unexpected arguments: ${options.rest.join(' ')}')
      ..writeln(parser.usage);
    exitCode = 3;
    return;
  }
  final warnOnly = options.flag('warn-only');
  final List<GuideProblem> problems;
  try {
    problems = await checkGuide(
      Directory.current.path,
      since: options.option('since'),
    );
  } on Object catch (error) {
    // The hook must never fail a commit, whatever went wrong.
    if (warnOnly) {
      stderr.writeln('warning: the guide check could not run: $error');
      return;
    }
    if (error is! GitException) rethrow;
    final hint = error.message.contains('not a git repository')
        ? 'Run this from the root of the Appstein repo. '
        : '';
    stderr.writeln('$hint$error');
    exitCode = 3;
    return;
  }
  for (final problem in problems) {
    stderr.writeln(warnOnly ? 'warning: $problem' : '$problem');
  }
  if (problems.isEmpty) {
    if (!warnOnly) stdout.writeln('Guide check passed.');
    return;
  }
  if (warnOnly) {
    stderr.writeln(
      'The developer guide may need attention (${problems.length} '
      'warning(s)). CI fails on these. See docs/guide/docs-tooling.md.',
    );
  } else {
    stdout.writeln('${problems.length} problem(s) found.');
    exitCode = 1;
  }
}
