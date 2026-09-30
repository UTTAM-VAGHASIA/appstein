import 'dart:io';

import 'package:path/path.dart' as p;

import 'markdown.dart';

/// A problem found in a Markdown file.
final class GuideProblem {
  /// Creates a problem at [line] of [file]; [line] is null when the problem
  /// is about the whole file.
  const GuideProblem(this.file, this.line, this.message);

  /// The file, relative to the repo root.
  final String file;

  /// The 1-based line, or null for the whole file.
  final int? line;

  /// What is wrong.
  final String message;

  @override
  String toString() =>
      line == null ? '$file: $message' : '$file:$line: $message';
}

final _codeSpan = RegExp(r'`([^`\s]+)`');
final _repoPath = RegExp(r'^(packages|docs|tool|test|\.github)/');

/// Checks one Markdown file of the developer guide (spec §19.6):
/// - relative links must resolve;
/// - repo paths in backticks must exist;
/// - Dart code blocks are refused until slice 1f adds snippet analysis.
List<GuideProblem> checkMarkdown(String repoRoot, String relativePath) {
  final file = File(p.join(repoRoot, relativePath));
  final problems = <GuideProblem>[];
  final fences = FenceTracker();
  final lines = file.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final kind = fences.next(line);
    if (kind == FenceLine.open &&
        line.trimLeft().substring(3).trim().toLowerCase() == 'dart') {
      problems.add(
        GuideProblem(
          relativePath,
          i + 1,
          'Dart code blocks are not analyzed yet (slice 1f adds that). '
          'Link to real code in the repo instead.',
        ),
      );
    }
    if (kind != FenceLine.prose) continue;
    for (final link in fileLinks(line)) {
      final resolved = p.normalize(p.join(p.dirname(file.path), link.path));
      if (FileSystemEntity.typeSync(resolved) ==
          FileSystemEntityType.notFound) {
        problems.add(
          GuideProblem(relativePath, i + 1, 'Broken link: ${link.target}'),
        );
      }
    }
    for (final match in _codeSpan.allMatches(line)) {
      final text = match.group(1)!;
      if (!_repoPath.hasMatch(text) ||
          text.contains('*') ||
          text.contains('<')) {
        continue;
      }
      final resolved = p.join(
        repoRoot,
        text.endsWith('/') ? text.substring(0, text.length - 1) : text,
      );
      if (FileSystemEntity.typeSync(resolved) ==
          FileSystemEntityType.notFound) {
        problems.add(
          GuideProblem(relativePath, i + 1, 'Path does not exist: $text'),
        );
      }
    }
  }
  return problems;
}

/// The files the guide check covers: every Markdown file under
/// `docs/guide/`, plus each package README. Paths are relative to
/// [repoRoot], with forward slashes, and sorted.
List<String> guideFiles(String repoRoot) {
  final files = <String>[];
  final guide = Directory(p.join(repoRoot, 'docs', 'guide'));
  if (guide.existsSync()) {
    for (final entry in guide.listSync(recursive: true)) {
      if (entry is File && entry.path.endsWith('.md')) {
        files.add(toPosix(p.relative(entry.path, from: repoRoot)));
      }
    }
  }
  final packages = Directory(p.join(repoRoot, 'packages'));
  if (packages.existsSync()) {
    for (final entry in packages.listSync().whereType<Directory>()) {
      final readme = File(p.join(entry.path, 'README.md'));
      if (readme.existsSync()) {
        files.add(toPosix(p.relative(readme.path, from: repoRoot)));
      }
    }
  }
  return files..sort();
}

/// The relative [path] with forward slashes, the form every guide tool
/// compares.
String toPosix(String path) => p.split(path).join('/');

/// The developer guide's pages: every Markdown file under `docs/guide/`, as
/// repo-relative paths with forward slashes, sorted.
List<String> guidePages(String repoRoot) => [
  for (final file in guideFiles(repoRoot))
    if (file.startsWith('docs/guide/')) file,
];

/// Guide pages that no chain of relative links reaches from
/// `docs/guide/README.md` (spec §19.6: nothing is left unlinked). [pages]
/// are repo-relative with forward slashes, as [guidePages] returns them.
/// Links inside code fences are examples and don't count.
List<GuideProblem> checkLinked(String repoRoot, List<String> pages) {
  const start = 'docs/guide/README.md';
  final known = pages.toSet();
  if (!known.contains(start)) {
    return [const GuideProblem(start, null, 'The guide has no start page.')];
  }
  final reached = {start};
  final queue = [start];
  while (queue.isNotEmpty) {
    final page = queue.removeLast();
    final fences = FenceTracker();
    for (final line in File(p.join(repoRoot, page)).readAsLinesSync()) {
      if (fences.next(line) != FenceLine.prose) continue;
      for (final link in fileLinks(line)) {
        final linked = p.posix.normalize(
          p.posix.join(p.posix.dirname(page), link.path),
        );
        if (known.contains(linked) && reached.add(linked)) queue.add(linked);
      }
    }
  }
  return [
    for (final page in pages)
      if (!reached.contains(page))
        GuideProblem(
          page,
          null,
          'Not linked from the guide. Link it from docs/guide/README.md or '
          'from a page linked there.',
        ),
  ];
}
