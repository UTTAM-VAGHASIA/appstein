import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;

import '../../decisions/decision_store.dart';
import '../decision_check.dart';
import '../verify_check.dart';

/// `..` as a whole segment of a pattern, or as one of the alternatives in
/// braces, which the glob would expand to a segment.
final _parent = RegExp(r'(^|[/{,])\.\.([/},]|$)');
final _absolute = RegExp('^(/|[A-Za-z]:)');
final _globCharacter = RegExp(r'[*?\[\]{}]');

/// `paths.exist`, the engine's decision check (spec §6.7): every path
/// pattern of the decision still matches a file or a folder of the project.
///
/// A pattern is followed only inside the project. One that could leave it
/// (an absolute path, or `..` as a segment) is reported and never expanded,
/// so a decision file can't make `verify` list folders outside the project.
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
      var pattern = raw.replaceAll(r'\', '/');
      if (_absolute.hasMatch(pattern) || _parent.hasMatch(pattern)) {
        problems.add(
          'The path `$raw` could leave the project, so it was not checked.',
        );
        continue;
      }
      while (pattern.startsWith('./')) {
        pattern = pattern.substring(2);
      }
      pattern = pattern.replaceFirst(RegExp(r'/+$'), '');

      final bool found;
      if (!_globCharacter.hasMatch(pattern)) {
        found =
            FileSystemEntity.typeSync(
              p.joinAll([root, ...pattern.split('/')]),
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound;
      } else {
        final Glob glob;
        try {
          // Patterns use `/` on every system; the context only says where
          // the listing starts and how this system writes paths.
          glob = Glob(pattern, context: p.Context(current: root));
        } on FormatException {
          problems.add('The path `$raw` is not a valid pattern.');
          continue;
        }
        var any = false;
        try {
          any = glob.listSync(root: root, followLinks: false).isNotEmpty;
        } on FileSystemException {
          // A folder the pattern starts in isn't there, or can't be listed:
          // nothing in it matches.
        }
        found = any;
      }
      if (!found) problems.add('The path `$raw` matches no file.');
    }
    return problems;
  }
}
