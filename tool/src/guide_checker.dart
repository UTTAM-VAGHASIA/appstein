import 'dart:io';

import 'package:path/path.dart' as p;

/// A problem found in a Markdown file.
final class GuideProblem {
  /// Creates a problem at [line] of [file].
  const GuideProblem(this.file, this.line, this.message);

  /// The file, relative to the repo root.
  final String file;

  /// The 1-based line.
  final int line;

  /// What is wrong.
  final String message;

  @override
  String toString() => '$file:$line: $message';
}

final _link = RegExp(r'\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)');
final _codeSpan = RegExp(r'`([^`\s]+)`');
final _repoPath = RegExp(r'^(packages|docs|tool|\.github)/');

/// Checks one Markdown file of the developer guide (spec §19.6):
/// - relative links must resolve;
/// - repo paths in backticks must exist;
/// - Dart code blocks are refused until slice 1f adds snippet analysis.
List<GuideProblem> checkMarkdown(String repoRoot, String relativePath) {
  final file = File(p.join(repoRoot, relativePath));
  final problems = <GuideProblem>[];
  var inFence = false;
  final lines = file.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```')) {
      if (!inFence && trimmed.substring(3).trim().toLowerCase() == 'dart') {
        problems.add(
          GuideProblem(
            relativePath,
            i + 1,
            'Dart code blocks are not analyzed yet (slice 1f adds that). '
            'Link to real code in the repo instead.',
          ),
        );
      }
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    for (final match in _link.allMatches(line)) {
      final target = match.group(1)!;
      if (target.startsWith('http://') ||
          target.startsWith('https://') ||
          target.startsWith('mailto:') ||
          target.startsWith('#')) {
        continue;
      }
      final path = Uri.decodeFull(target.split('#').first);
      final resolved = p.normalize(p.join(p.dirname(file.path), path));
      if (FileSystemEntity.typeSync(resolved) ==
          FileSystemEntityType.notFound) {
        problems.add(GuideProblem(relativePath, i + 1, 'Broken link: $target'));
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
/// [repoRoot] and sorted.
List<String> guideFiles(String repoRoot) {
  final files = <String>[];
  final guide = Directory(p.join(repoRoot, 'docs', 'guide'));
  if (guide.existsSync()) {
    for (final entry in guide.listSync(recursive: true)) {
      if (entry is File && entry.path.endsWith('.md')) {
        files.add(p.relative(entry.path, from: repoRoot));
      }
    }
  }
  final packages = Directory(p.join(repoRoot, 'packages'));
  if (packages.existsSync()) {
    for (final entry in packages.listSync().whereType<Directory>()) {
      final readme = File(p.join(entry.path, 'README.md'));
      if (readme.existsSync()) {
        files.add(p.relative(readme.path, from: repoRoot));
      }
    }
  }
  return files..sort();
}
