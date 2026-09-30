import 'dart:convert';
import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'guide_checker.dart';
import 'markdown.dart';

/// The files spec §19.6 calls source. Each must be covered by a guide page.
const sourceGlobs = [
  'packages/*/lib/**',
  'packages/*/bin/**',
  'tool/**',
  '.github/workflows/**',
];

/// A guide page's `<!-- covers: … -->` comment: the files the page explains.
final class CoversComment {
  /// Creates a comment that starts on [line] and lists [globs].
  const CoversComment(this.globs, this.line);

  /// Repo-relative globs with forward slashes. Empty for `covers: none`.
  final List<String> globs;

  /// The 1-based line the comment starts on.
  final int line;
}

/// Thrown when a covers comment is malformed.
final class CoversException implements Exception {
  /// Creates the exception for [line].
  const CoversException(this.line, this.message);

  /// The 1-based line.
  final int line;

  /// What is wrong.
  final String message;

  @override
  String toString() => 'line $line: $message';
}

final _coversStart = RegExp(r'^<!--\s*covers:');

/// Reads the covers comment of a guide page (spec §19.6).
///
/// The comment must be the first non-blank line of the page, and it may run
/// over several lines until `-->`. Entries are separated by spaces, commas
/// or line breaks, and `none` marks a page that explains no particular file.
/// Comments inside code fences are examples and are ignored. Returns null
/// when the page has no comment. Throws [CoversException] when the comment
/// is malformed.
CoversComment? parseCovers(String markdown) {
  final lines = const LineSplitter().convert(markdown);
  final starts = <int>[];
  final fences = FenceTracker();
  for (var i = 0; i < lines.length; i++) {
    if (fences.next(lines[i]) == FenceLine.prose &&
        _coversStart.hasMatch(lines[i].trim())) {
      starts.add(i);
    }
  }
  if (starts.isEmpty) return null;
  if (starts.length > 1) {
    throw CoversException(starts[1] + 1, 'A page has only one covers comment.');
  }
  final start = starts.single;
  if (start != lines.indexWhere((line) => line.trim().isNotEmpty)) {
    throw CoversException(
      start + 1,
      'The covers comment must be the first line of the page.',
    );
  }
  final text = StringBuffer();
  var closed = false;
  for (var i = start; i < lines.length && !closed; i++) {
    var line = lines[i].trim();
    if (i == start) {
      line = line.substring(line.indexOf('covers:') + 'covers:'.length);
    }
    final close = line.indexOf('-->');
    if (close >= 0) {
      if (line.substring(close + 3).trim().isNotEmpty) {
        throw CoversException(
          i + 1,
          'Nothing may follow --> on the line that closes the covers comment.',
        );
      }
      line = line.substring(0, close);
      closed = true;
    }
    text.write(' $line');
  }
  if (!closed) {
    throw CoversException(
      start + 1,
      'The covers comment is never closed with -->.',
    );
  }
  final entries = text
      .toString()
      .split(RegExp(r'[\s,]+'))
      .where((entry) => entry.isNotEmpty)
      .toList();
  if (entries.isEmpty) {
    throw CoversException(
      start + 1,
      'List the paths this page explains, or write `none`.',
    );
  }
  if (entries.contains('none')) {
    if (entries.length > 1) {
      throw CoversException(start + 1, "`none` can't be combined with paths.");
    }
    return CoversComment(const [], start + 1);
  }
  for (final entry in entries) {
    if (entry.contains(r'\') ||
        entry.startsWith('/') ||
        entry.startsWith('./') ||
        entry.contains(':') ||
        entry.split('/').contains('..')) {
      throw CoversException(
        start + 1,
        'Covers entries are repo-relative paths with forward slashes: $entry',
      );
    }
  }
  return CoversComment(entries, start + 1);
}

/// The covers comment of every guide page.
final class CoverMap {
  /// Creates a map from each page to its comment.
  CoverMap(this.pages)
    : _globs = {
        for (final entry in pages.entries)
          entry.key: [
            for (final glob in entry.value.globs) Glob(glob, context: p.posix),
          ],
      };

  /// Each guide page (repo-relative, forward slashes) and its comment.
  final Map<String, CoversComment> pages;

  final Map<String, List<Glob>> _globs;

  /// The pages whose covers match [file] (repo-relative, forward slashes),
  /// sorted.
  List<String> pagesCovering(String file) => [
    for (final entry in _globs.entries)
      if (entry.value.any((glob) => glob.matches(file))) entry.key,
  ]..sort();
}

/// Reads the covers comment of each of [pages] (repo-relative, forward
/// slashes). A page without a comment, or with a malformed one, becomes a
/// problem and is left out of the map.
({CoverMap map, List<GuideProblem> problems}) readCoverMap(
  String repoRoot,
  List<String> pages,
) {
  final comments = <String, CoversComment>{};
  final problems = <GuideProblem>[];
  for (final page in pages) {
    try {
      final comment = parseCovers(
        File(p.join(repoRoot, page)).readAsStringSync(),
      );
      if (comment == null) {
        problems.add(
          GuideProblem(
            page,
            1,
            'Start the page with a covers comment: '
            '<!-- covers: <paths> --> or <!-- covers: none -->.',
          ),
        );
      } else {
        comments[page] = comment;
      }
    } on CoversException catch (error) {
      problems.add(GuideProblem(page, error.line, error.message));
    }
  }
  return (map: CoverMap(comments), problems: problems);
}

/// Checks the coverage map against [files], which is every file in the
/// working tree (repo-relative, forward slashes). Each covers entry must
/// match a file, and each source file ([sourceGlobs]) must be covered by a
/// page.
List<GuideProblem> checkCoverage(CoverMap map, List<String> files) {
  final problems = <GuideProblem>[];
  for (final entry in map.pages.entries) {
    for (final pattern in entry.value.globs) {
      final glob = Glob(pattern, context: p.posix);
      if (!files.any(glob.matches)) {
        problems.add(
          GuideProblem(
            entry.key,
            entry.value.line,
            'Covers $pattern, which matches no file.',
          ),
        );
      }
    }
  }
  final source = [for (final glob in sourceGlobs) Glob(glob, context: p.posix)];
  for (final file in files) {
    if (source.any((glob) => glob.matches(file)) &&
        map.pagesCovering(file).isEmpty) {
      problems.add(
        GuideProblem(
          file,
          null,
          'No guide page covers this file. Add it to the covers comment of '
          'the page that explains it.',
        ),
      );
    }
  }
  return problems;
}
