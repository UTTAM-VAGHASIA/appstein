import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import '../../decisions/decision_path.dart';
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
enum _Match { found, none, leaves, invalid }

/// `paths.exist`, the engine's decision check (spec §6.7): every path
/// pattern of the decision still matches a file or a folder of the project.
///
/// - **It never leaves the project.** An absolute path, `..` as a segment
///   (also inside braces, and in the forms Windows reads as `..`) and a path
///   through a link are reported and never followed, so a decision file
///   can't make `verify` look at folders outside the project.
/// - **A `\` has two readings, and the path matches when either does.** As
///   a Windows separator (`lib\ui\x.dart`), or, right before `[`, `]`, `{`
///   or `}`, as an escape (`a\[1\].dart` names the file `a[1].dart`). A
///   reading that isn't a valid glob is dropped, and the path is "not a valid
///   pattern" only when no reading is valid ([decisionPathReadings]). Every
///   guard here applies to each reading.
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
      // The path matches when any of its readings does. One that leaves the
      // project is not followed and outweighs "no file", so a reading that
      // might be the one meant is never skipped quietly.
      var leaves = false;
      var valid = false;
      var found = false;
      for (final reading in decisionPathReadings(raw)) {
        switch (_match(root, reading)) {
          case _Match.found:
            found = true;
            valid = true;
          case _Match.none:
            valid = true;
          case _Match.leaves:
            leaves = true;
          case _Match.invalid:
            break;
        }
        if (found) break;
      }
      if (found) continue;
      if (leaves) {
        problems.add(
          'The path `$raw` could leave the project, so it was not checked.',
        );
      } else if (valid) {
        problems.add('The path `$raw` matches no file.');
      } else {
        problems.add('The path `$raw` is not a valid pattern.');
      }
    }
    return problems;
  }
}

/// What one [reading] of a path matches below [root].
_Match _match(String root, DecisionPathReading reading) {
  final pattern = reading.pattern;
  if (_absolute.hasMatch(pattern) || _parent.hasMatch(pattern)) {
    return _Match.leaves;
  }
  if (!reading.valid) return _Match.invalid;
  final segments = [
    for (final segment in pattern.split('/'))
      if (segment.isNotEmpty && segment != '.') segment,
  ];

  // The folders named before the first wildcard: where the search starts.
  final fixed = segments
      .takeWhile((segment) => !_globCharacter.hasMatch(segment))
      .toList();
  if (fixed.length == segments.length) return _exact(root, segments);
  final Glob glob;
  try {
    glob = Glob(segments.join('/'), context: p.posix);
  } on FormatException {
    return _Match.invalid;
  }
  return switch (_exact(root, fixed)) {
    _Match.found => _search(root, fixed, glob),
    final other => other,
  };
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
