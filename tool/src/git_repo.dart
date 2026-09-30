import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Thrown when a git command fails.
final class GitException implements Exception {
  /// Creates the exception.
  const GitException(this.message);

  /// What failed, with git's own error.
  final String message;

  @override
  String toString() => message;
}

/// The read-only git queries the guide check needs, run in the repo at
/// [root].
///
/// Git's own `GIT_*` variables are dropped from the environment. A git hook
/// sets `GIT_DIR`, and a check started from a hook must still look at
/// [root].
final class GitRepo {
  /// Creates a view of the repo at [root]. [environment] defaults to this
  /// process's environment.
  GitRepo(this.root, {Map<String, String>? environment})
    : _environment = {
        for (final entry in (environment ?? Platform.environment).entries)
          if (!entry.key.toUpperCase().startsWith('GIT_'))
            entry.key: entry.value,
      };

  /// The repo's top folder.
  final String root;

  final Map<String, String> _environment;

  /// Every file in the working tree that git tracks or would track, as
  /// repo-relative paths with forward slashes, sorted. Untracked files
  /// count; ignored files, and tracked files deleted from disk, don't.
  List<String> files() => [
    for (final path in _paths([
      'ls-files',
      '-z',
      '--cached',
      '--others',
      '--exclude-standard',
    ]))
      if (File(p.join(root, path)).existsSync()) path,
  ];

  /// Whether [rev] names a commit.
  bool hasCommit(String rev) =>
      _run(['rev-parse', '-q', '--verify', '$rev^{commit}']).exitCode == 0;

  /// The files that differ between the merge base of [rev] and HEAD, and the
  /// working tree: committed, staged, unstaged and untracked changes, sorted.
  /// A rename appears as both its old and its new path.
  List<String> changedSince(String rev) {
    final base = _mergeBase(rev);
    return {
      ..._paths(['diff', '--name-only', '-z', '--no-renames', base]),
      ..._paths(['ls-files', '-z', '--others', '--exclude-standard']),
    }.toList()..sort();
  }

  /// The full messages of the commits between the merge base of [rev] and
  /// HEAD.
  List<String> messagesSince(String rev) => [
    for (final message in _git([
      'log',
      '-z',
      '--format=%B',
      '${_mergeBase(rev)}..HEAD',
    ]).split('\x00'))
      if (message.trim().isNotEmpty) message,
  ];

  String _mergeBase(String rev) => _git(['merge-base', rev, 'HEAD']).trim();

  List<String> _paths(List<String> arguments) {
    final paths = {
      for (final path in _git(arguments).split('\x00'))
        if (path.isNotEmpty) path,
    };
    return paths.toList()..sort();
  }

  String _git(List<String> arguments) {
    final result = _run(arguments);
    if (result.exitCode != 0) {
      throw GitException(
        'git ${arguments.join(' ')} failed: '
        '${(result.stderr as String).trim()}',
      );
    }
    return result.stdout as String;
  }

  ProcessResult _run(List<String> arguments) => Process.runSync(
    'git',
    arguments,
    workingDirectory: root,
    environment: _environment,
    includeParentEnvironment: false,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
}
