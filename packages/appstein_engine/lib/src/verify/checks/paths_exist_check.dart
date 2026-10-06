import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import '../../decisions/decision_store.dart';
import '../decision_check.dart';
import '../verify_check.dart';

/// A segment of a pattern, or an alternative inside braces, that is made of
/// dots and spaces and has two dots or more: `..`, and what Windows reads
/// as `..` because it drops trailing dots and spaces (`.. `, `...`).
final _parent = RegExp(r'(^|[/{,])(?=[. ]*\.[. ]*\.)[. ]+([/},]|$)');
final _absolute = RegExp('^(/|[A-Za-z]:)');
final _globCharacter = RegExp(r'[*?\[\]{}]');

/// Folders at the top of a project that tools fill: the pub cache, build
/// output, git's own files. A pattern is never looked for there unless it
/// names the folder outright (`build/**`), so `**/x.dart` doesn't walk
/// thousands of generated files on every run.
const _toolFolders = {'.dart_tool', '.git', 'build'};

/// What a pattern matches.
enum _Match { found, none, leaves }

/// `paths.exist`, the engine's decision check (spec §6.7): every path
/// pattern of the decision still matches a file or a folder of the project.
///
/// - **It never leaves the project.** An absolute path, `..` as a segment
///   (also inside braces, and in the forms Windows reads as `..`) and a path
///   through a link are reported and never followed, so a decision file
///   can't make `verify` look at folders outside the project.
/// - **Letter case counts on every system,** so the same decision holds on
///   a Windows laptop and in CI on Linux.
/// - **It stops at the first match,** starts in the folders the pattern
///   names before its first wildcard, and skips a folder it can't list.
final class PathsExistCheck implements DecisionCheck {
  /// Creates the check.
  const PathsExistCheck();

  @override
  String get id => 'paths.exist';

  @override
  bool get needsMap => false;

  @override
  List<String> problems(DecisionEntry decision, VerifyContext context) {
    final root = context.projectRoot;
    final problems = <String>[];
    for (final raw in decision.record.paths) {
      const leaves = 'could leave the project, so it was not checked.';
      var pattern = raw.replaceAll(r'\', '/');
      if (_absolute.hasMatch(pattern) || _parent.hasMatch(pattern)) {
        problems.add('The path `$raw` $leaves');
        continue;
      }
      while (pattern.startsWith('./')) {
        pattern = pattern.substring(2);
      }
      pattern = pattern.replaceFirst(RegExp(r'/+$'), '');
      final segments = [
        for (final segment in pattern.split('/'))
          if (segment.isNotEmpty && segment != '.') segment,
      ];

      // The folders named before the first wildcard: where the search
      // starts.
      final fixed = segments
          .takeWhile((segment) => !_globCharacter.hasMatch(segment))
          .toList();
      final _Match match;
      if (fixed.length == segments.length) {
        match = _exact(root, segments);
      } else {
        final Glob glob;
        try {
          glob = Glob(segments.join('/'), context: p.posix);
        } on FormatException {
          problems.add('The path `$raw` is not a valid pattern.');
          continue;
        }
        match = switch (_exact(root, fixed)) {
          _Match.found => _search(root, fixed, glob),
          final other => other,
        };
      }
      switch (match) {
        case _Match.found:
          break;
        case _Match.none:
          problems.add('The path `$raw` matches no file.');
        case _Match.leaves:
          problems.add('The path `$raw` $leaves');
      }
    }
    return problems;
  }
}

/// Whether [segments] name a file or folder below [root], by their exact
/// names. A link on the way is never followed.
_Match _exact(String root, List<String> segments) {
  var folder = root;
  for (final (index, segment) in segments.indexed) {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(folder).listSync(followLinks: false);
    } on FileSystemException {
      return _Match.none;
    }
    FileSystemEntity? entry;
    for (final candidate in entries) {
      if (p.basename(candidate.path) == segment) entry = candidate;
    }
    if (entry == null) return _Match.none;
    if (entry is Link) return _Match.leaves;
    if (index < segments.length - 1 && entry is! Directory) return _Match.none;
    folder = entry.path;
  }
  return _Match.found;
}

/// Whether [glob] matches a file or folder below the folder [fixed] names
/// in [root]. It stops at the first match.
_Match _search(String root, List<String> fixed, Glob glob) {
  bool visit(String folder, List<String> above) {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(folder).listSync(followLinks: false);
    } on FileSystemException {
      // One folder that can't be listed doesn't decide the others.
      return false;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    final folders = <(String, List<String>)>[];
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (above.isEmpty && _toolFolders.contains(name)) continue;
      final path = [...above, name];
      if (glob.matches(path.join('/'))) return true;
      if (entry is Directory) folders.add((entry.path, path));
    }
    for (final (path, names) in folders) {
      if (visit(path, names)) return true;
    }
    return false;
  }

  return visit(p.joinAll([root, ...fixed]), fixed) ? _Match.found : _Match.none;
}
