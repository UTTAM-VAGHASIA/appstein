import 'dart:io';

import 'src/guide_checker.dart';

/// Checks the developer guide and package READMEs. Run from the repo root:
///   fvm dart run tool/check_guide.dart
void main() {
  final root = Directory.current.path;
  final files = guideFiles(root);
  final problems = [for (final file in files) ...checkMarkdown(root, file)];
  for (final problem in problems) {
    stderr.writeln(problem);
  }
  stdout.writeln(
    problems.isEmpty
        ? 'Guide check passed (${files.length} files).'
        : '${problems.length} problem(s) found.',
  );
  if (problems.isNotEmpty) exitCode = 1;
}
