import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../host/file_links.dart';
import '../knowledge/dart_files.dart';

/// The unverified files of one `verify` run (slice 1d.2, spec §9.1): the
/// files changed since a run last found no error in them, and the files the
/// run was given with `--files` or the tool's `files` input. A fast run
/// reports warnings, lints and formatting only on these.
///
/// Each is a path from the project root with `/` separators. Where file
/// names don't depend on letter case (Windows, and macOS by default:
/// `caseInsensitiveFiles`), a path names the same file whatever its case,
/// [contains] answers so, and two spellings of one file are one entry.
final class UnverifiedFiles {
  /// The unverified files [files], one entry per file (the first spelling
  /// given), sorted.
  UnverifiedFiles(Iterable<String> files)
    : files = List.unmodifiable(
        <String, String>{
          for (final file in files.toList().reversed) fileKey(file): file,
        }.values.toList()..sort(),
      );

  /// None.
  static final none = UnverifiedFiles(const []);

  /// The files, sorted.
  final List<String> files;

  late final _keys = {for (final file in files) fileKey(file)};

  /// Whether [file], a path from the project root with `/`, is one of them.
  bool contains(String file) => _keys.contains(fileKey(file));

  /// Whether [a] and [b], each a path from the project root with `/`, name
  /// the same file on this system.
  static bool same(String a, String b) => fileKey(a) == fileKey(b);
}

/// `--files` or the tool's `files` input named a path `verify` can't take:
/// one outside the project. That is a usage error (exit `3`, spec §9.5).
final class VerifyFilesException implements Exception {
  /// Creates the error with its [message], a whole sentence.
  const VerifyFilesException(this.message);

  /// What is wrong, and what to pass instead.
  final String message;

  @override
  String toString() => message;
}

/// [paths], as `--files` or the tool's `files` input gave them, as paths
/// from the project at [projectRoot] with `/` separators, each once, in the
/// order given.
///
/// - A relative path is taken from the project root, not from the folder
///   `verify` runs in: an agent names the files of the project.
/// - An absolute path is accepted when it is inside the project, also by
///   the project's real location when [projectRoot] is reached through a
///   link or a junction (macOS's temp folder `/var/…` is a link to
///   `/private/var/…`).
/// - A path that isn't a Dart file, or no longer exists, is accepted: a
///   deleted file is a change too.
/// - A folder stands for the Dart files under it (folders whose name starts
///   with a dot left out, as the analysis server leaves them out).
/// - Where names don't depend on letter case, a file that exists is named
///   with the letter case it has on disk, so it matches the analyzer's name
///   for it.
///
/// Throws a [VerifyFilesException] for a path outside the project, the
/// project folder itself, or an empty path.
List<String> resolveVerifyFiles(String projectRoot, Iterable<String> paths) {
  final root = p.normalize(p.absolute(projectRoot));
  final found = <String>[];
  // The root's real location, looked up once, at the first path outside.
  (String?,)? real;
  void add(String relative) {
    if (!found.any((file) => UnverifiedFiles.same(file, relative))) {
      found.add(relative);
    }
  }

  for (final path in paths) {
    if (path.trim().isEmpty) {
      throw const VerifyFilesException(
        'A path given to --files is empty. Name a file of the project, from '
        'the project root or as an absolute path inside it.',
      );
    }
    var absolute = p.normalize(p.isAbsolute(path) ? path : p.join(root, path));
    // A path by the root's real location, when the root is reached through
    // a link, is taken as the same path under the root.
    if (!p.isWithin(root, absolute) && !p.equals(root, absolute)) {
      real ??= (realFolder(root),);
      if (real.$1 case final realRoot?) {
        if (p.equals(realRoot, absolute)) {
          absolute = root;
        } else if (p.isWithin(realRoot, absolute)) {
          absolute = p.join(root, p.relative(absolute, from: realRoot));
        }
      }
    }
    if (!p.isWithin(root, absolute)) {
      throw VerifyFilesException(
        p.equals(root, absolute)
            ? 'The path `$path` given to --files is the project folder '
                  'itself. Name files inside it.'
            : 'The path `$path` given to --files is outside the project '
                  '($root). Name a file of the project, from the project '
                  'root or as an absolute path inside it.',
      );
    }
    final relative = _onDisk(root, p.split(p.relative(absolute, from: root)));
    if (FileSystemEntity.isDirectorySync(absolute)) {
      for (final file in _dartFilesUnder(
        p.joinAll([root, ...relative.split('/')]),
      )) {
        add(p.split(p.relative(file, from: root)).join('/'));
      }
    } else {
      add(relative);
    }
  }
  return found;
}

/// The Dart files under [folder], links to folders followed, folders whose
/// name starts with a dot left out.
List<String> _dartFilesUnder(String folder) {
  final found = <String>[];
  void walk(String dir, Set<String> inside) {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(dir).listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (entry is File) {
        if (name.endsWith('.dart')) found.add(entry.path);
      } else if (!name.startsWith('.') &&
          FileSystemEntity.isDirectorySync(entry.path)) {
        final String resolved;
        try {
          resolved = Directory(entry.path).resolveSymbolicLinksSync();
        } on FileSystemException {
          continue;
        }
        if (inside.contains(fileKey(resolved))) continue;
        walk(entry.path, {...inside, fileKey(resolved)});
      }
    }
  }

  try {
    walk(folder, {fileKey(Directory(folder).resolveSymbolicLinksSync())});
  } on FileSystemException {
    // Gone meanwhile: no files.
  }
  return found..sort();
}

/// [parts] of a path below [root], each with the letter case the folder
/// listing gives it where one matches, joined with `/`. Where names depend
/// on letter case, or where nothing matches, as given.
String _onDisk(String root, List<String> parts) {
  if (!caseInsensitiveFiles) return parts.join('/');
  var folder = root;
  final named = <String>[];
  for (final part in parts) {
    String? match;
    try {
      for (final entry in Directory(folder).listSync(followLinks: false)) {
        final name = p.basename(entry.path);
        if (name.toLowerCase() == part.toLowerCase()) {
          match = name;
          break;
        }
      }
    } on FileSystemException {
      // Not there, or not listable: the rest is kept as given.
    }
    named.add(match ?? part);
    folder = p.join(folder, match ?? part);
  }
  return named.join('/');
}

/// The unverified files `state.json` should hold after a `verify` run, or
/// null when they are the ones it holds ([now]).
///
/// - Each of [added] (the run's `--files`) joins them, as the refresh's
///   changes did before the run, and the rule below applies to it too.
/// - Each of [verified] leaves: the files of the run's unverified set on
///   which the run reported no error. One leaves only when its hash in
///   [now] is still the one the run started from ([hashesAtStart]): a
///   refresh since then saw it change again, after the analysis read it.
/// - Each of [unreadable] (Dart files that could not be read, so nothing in
///   them was checked) joins them and never leaves.
List<String>? unverifiedAfterVerify(
  KnowledgeState now, {
  required Iterable<String> added,
  required Iterable<String> unreadable,
  required Iterable<String> verified,
  required Map<String, String>? hashesAtStart,
}) {
  final neverLeave = UnverifiedFiles(unreadable);
  final leaving = UnverifiedFiles([
    for (final file in verified)
      if (!neverLeave.contains(file) &&
          now.dartFiles?[file] == hashesAtStart?[file])
        file,
  ]);
  final next = UnverifiedFiles([
    for (final file in [...now.unverified, ...added, ...neverLeave.files])
      if (!leaving.contains(file)) file,
  ]).files;
  final same =
      next.length == now.unverified.length &&
      [
        for (var i = 0; i < next.length; i++) next[i] == now.unverified[i],
      ].every((equal) => equal);
  return same ? null : next;
}
