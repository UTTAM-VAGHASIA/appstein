import 'dart:io';

import 'src/generated_docs.dart';
import 'src/guide_checker.dart';

/// Regenerates the generated sections of the developer guide (spec §19.6).
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
  final result = await regenerateGuide(root, guidePages(root), write: !check);
  for (final problem in result.problems) {
    stderr.writeln(problem);
  }
  for (final page in result.changedPages) {
    stdout.writeln(
      check ? '$page: generated sections are out of date.' : 'Updated $page',
    );
  }
  if (result.problems.isNotEmpty || (check && result.changedPages.isNotEmpty)) {
    exitCode = 1;
  } else if (result.changedPages.isEmpty) {
    stdout.writeln('Generated sections are up to date.');
  }
}
