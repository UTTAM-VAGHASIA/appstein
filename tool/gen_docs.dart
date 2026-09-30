import 'dart:io';

import 'src/generated_docs.dart';
import 'src/guide_checker.dart';

/// Regenerates the generated sections of the developer guide and the
/// progress sections of the spec's visual page (spec §19.6).
/// Run from the repo root:
///   fvm dart run tool/gen_docs.dart          rewrite out-of-date sections
///   fvm dart run tool/gen_docs.dart --check  write nothing; exit 1 if any
///                                            section is out of date
Future<void> main(List<String> arguments) async {
  final check = arguments.contains('--check');
  if (arguments.any((argument) => argument != '--check')) {
    stderr.writeln('Usage: fvm dart run tool/gen_docs.dart [--check]');
    exitCode = 3;
    return;
  }
  final root = Directory.current.path;
  final guide = await regenerateGuide(root, guidePages(root), write: !check);
  final visual = regenerateVisualPage(root, write: !check);
  final problems = [...guide.problems, ...visual.problems];
  final changed = [...guide.changedPages, ...visual.changedPages];
  for (final problem in problems) {
    stderr.writeln(problem);
  }
  for (final page in changed) {
    stdout.writeln(
      check ? '$page: generated sections are out of date.' : 'Updated $page',
    );
  }
  if (problems.isNotEmpty || (check && changed.isNotEmpty)) {
    exitCode = 1;
  } else if (changed.isEmpty) {
    stdout.writeln('Generated sections are up to date.');
  }
}
