import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The real environment without git's own `GIT_*` variables, plus [extra].
///
/// A git hook sets `GIT_DIR`. Without this, a test started from a hook would
/// run its git commands against the Appstein repo instead of the temp repo.
Map<String, String> gitEnvironment([Map<String, String> extra = const {}]) => {
  for (final entry in Platform.environment.entries)
    if (!entry.key.toUpperCase().startsWith('GIT_')) entry.key: entry.value,
  ...extra,
};

/// Creates a temporary folder whose path contains a space and a non-ASCII
/// character, and deletes it after the test.
Directory tempFolder() {
  final dir = Directory.systemTemp.createTempSync('appstein guide tëst ');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Git marks object files read-only on Windows, which can block the
      // delete. A leftover temp folder is harmless.
    }
  });
  return dir;
}

/// Creates an empty git repo, on branch `main`, in a [tempFolder].
Directory tempRepo() {
  final dir = tempFolder();
  runGit(dir, ['init', '-q', '-b', 'main']);
  return dir;
}

/// Runs git in [repo] with a fixed identity, no signing and no line-ending
/// conversion, and returns the whole result without checking it. Hooks print
/// to stderr, so this is how a test reads what a hook said.
ProcessResult gitResult(
  Directory repo,
  List<String> arguments, {
  Map<String, String> environment = const {},
}) => Process.runSync(
  'git',
  [
    '-c',
    'user.name=Appstein Test',
    '-c',
    'user.email=test@example.com',
    '-c',
    'commit.gpgsign=false',
    '-c',
    'core.autocrlf=false',
    ...arguments,
  ],
  workingDirectory: repo.path,
  environment: gitEnvironment(environment),
  includeParentEnvironment: false,
);

/// Runs git in [repo] like [gitResult], and returns what it printed to
/// stdout. Throws when git fails.
String runGit(
  Directory repo,
  List<String> arguments, {
  Map<String, String> environment = const {},
}) {
  final result = gitResult(repo, arguments, environment: environment);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout as String;
}

/// Writes [text] to [path] (with forward slashes) under [root], creating the
/// folders it needs.
void writeFile(Directory root, String path, String text) {
  File(p.joinAll([root.path, ...path.split('/')]))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
}
