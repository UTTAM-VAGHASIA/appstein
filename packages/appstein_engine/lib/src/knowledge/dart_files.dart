import 'dart:async';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../analysis/disk_look.dart' show diskClockStep;
import 'input_hash.dart';

/// What `state.json`'s `dartFiles` holds for a Dart file that could not be
/// read when the knowledge was refreshed.
const unreadableDartFile = 'unreadable';

/// Whether this system's file names are the same whatever their letter case,
/// as on Windows, and on macOS by default. There a path names one file
/// whatever its case, and the unverified files keep one entry per file.
final caseInsensitiveFiles = Platform.isWindows || Platform.isMacOS;

/// [file] as a key that is the same for two spellings of one file name on
/// this system ([caseInsensitiveFiles]).
String fileKey(String file) => caseInsensitiveFiles ? file.toLowerCase() : file;

/// The SHA-256 of every Dart file the analysis server covers in the project
/// at [projectRoot], by its path from the root with `/` separators: what
/// the knowledge refresh compares to find the files that join the
/// unverified files (slice 1d.2). A file that can't be read is
/// [unreadableDartFile].
///
/// It walks the project folder as the analysis server does, which was
/// checked with a real server (slice 1d.2, ticket 06, fix round 1):
/// - **folders whose name starts with a dot are left out**; the server
///   leaves them out too. It analyzes `build/`, `ios/Pods/` and any other
///   folder, so those are walked;
/// - **a link to a folder (a Windows junction) is followed**, and a file
///   behind it is named by its path through the link, as the server names
///   it (`lib/linked/a.dart`). A link back to a folder the walk is already
///   inside is not followed again;
/// - **what the project's `analysis_options.yaml` excludes
///   (`analyzer: exclude:`) is left out**, as the server leaves it out: a
///   folder when a pattern ends in `/**` and the rest matches the folder,
///   and a file that a pattern matches.
///
/// It lets other work run every few milliseconds, so an MCP server answers
/// its other tools meanwhile. [known] are the map's inputs, by
/// input name (`project:<path>`), already hashed by the same refresh: a file
/// found there is not read again.
///
/// **A file is hashed again only when it may have changed** (the owner's
/// decision of 2026-10-14): [previous] is the last scan, from `state.json`.
/// A file whose time of last change and size are the ones that scan
/// recorded, and whose time lies more than `diskClockStep` before that
/// scan, keeps its hash; any other is read. The known limit is the look's:
/// an edit that keeps the size and whose time is put back is not seen.
/// [now] is the scan's time, the machine's clock unless a sync's clock is
/// given (a test's fixed one keeps `state.json` the same from run to run).
Future<DartFileScan> readDartFileHashes(
  String projectRoot, {
  Map<String, String?> known = const {},
  DartFileScan? previous,
  DateTime? now,
}) async {
  final root = p.normalize(p.absolute(projectRoot));
  final excluded = _excludesOf(root);
  final at = (now ?? DateTime.now()).toUtc();
  final hashes = <String, String>{};
  final stamps = <String, String>{};
  final optionsFiles = <String>[];
  final scan = DartFileScan(
    hashes: hashes,
    stamps: stamps,
    at: at,
    optionsFiles: optionsFiles,
  );
  final String rootResolved;
  try {
    rootResolved = Directory(root).resolveSymbolicLinksSync();
  } on FileSystemException {
    return scan;
  }
  // A file whose time is at or after this may have changed again within
  // one step of a coarse file-system clock after the last scan read it.
  final trustedBefore = previous?.at.subtract(diskClockStep);

  // The folders still to list: each with its path with every link resolved,
  // and the resolved folders the walk is inside there. Like the analyzer's
  // walk, the top folder is not among them: a link back to it is walked
  // once.
  final queue = <(String, String, Set<String>)>[(root, rootResolved, {})];
  // Measured on a 200-file app with a `build/` of 20,000 files (fix round 1
  // of ticket 06): listing each folder at once and letting other work run
  // every few milliseconds took as long as the blocking walk (383 ms against
  // 366 ms) and never held the event loop past the timer's own step; a walk
  // that lists every folder asynchronously at once took 17 s.
  final slice = Stopwatch()..start();
  while (queue.isNotEmpty) {
    if (slice.elapsedMilliseconds >= 4) {
      await Future<void>.delayed(Duration.zero);
      slice.reset();
    }
    final (folder, resolved, inside) = queue.removeLast();
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(folder).listSync(followLinks: false);
    } on FileSystemException {
      // The analysis server can't list it either.
      continue;
    }
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (name.startsWith('.')) continue;
      // Every entry's path starts with the root's: cut it off, as
      // `p.relative` would at many times the cost.
      final cut = entry.path.substring(root.length + 1);
      final relative = Platform.isWindows ? cut.replaceAll(r'\', '/') : cut;
      var isFile = entry is File;
      if (entry is Directory) {
        if (_folderExcluded(excluded, relative)) continue;
        final here = p.join(resolved, name);
        // Through a link the walk can reach a folder it is already inside
        // (a link from `lib/up` to the project: `lib/up/lib`); the server
        // skips that folder, and so does the walk.
        if (inside.contains(fileKey(here))) continue;
        queue.add((entry.path, here, {...inside, fileKey(here)}));
      } else if (entry is Link) {
        // A link is followed, to a folder or to a file, as the analyzer
        // follows it.
        final type = FileSystemEntity.typeSync(entry.path);
        if (type == FileSystemEntityType.directory) {
          if (_folderExcluded(excluded, relative)) continue;
          final String target;
          try {
            target = Directory(entry.path).resolveSymbolicLinksSync();
          } on FileSystemException {
            continue;
          }
          if (inside.contains(fileKey(target))) continue;
          queue.add((entry.path, target, {...inside, fileKey(target)}));
        }
        isFile = type == FileSystemEntityType.file;
      }
      // Found in the walk the scan does anyway, so the fingerprint needs no
      // second one.
      if (isFile && name == 'analysis_options.yaml') {
        optionsFiles.add(relative);
      }
      if (isFile && name.endsWith('.dart')) {
        if (excluded.any((glob) => glob.matches(relative))) continue;
        if (known['project:$relative'] case final hash?) {
          hashes[relative] = hash;
          continue;
        }
        final FileStat stat;
        try {
          stat = FileStat.statSync(entry.path);
        } on FileSystemException {
          hashes[relative] = unreadableDartFile;
          continue;
        }
        final stamp =
            '${stat.modified.toUtc().microsecondsSinceEpoch}/${stat.size}';
        stamps[relative] = stamp;
        final before = previous?.hashes[relative];
        if (before != null &&
            before != unreadableDartFile &&
            previous!.stamps[relative] == stamp &&
            stat.modified.isBefore(trustedBefore!)) {
          hashes[relative] = before;
          continue;
        }
        scan._read++;
        hashes[relative] = await _digest(entry.path) ?? unreadableDartFile;
      }
    }
  }
  return scan;
}

/// One scan of a project's Dart files ([readDartFileHashes]): what
/// `state.json` keeps as `dartFiles`, `dartStamps` and `dartScannedAt`.
final class DartFileScan {
  /// Creates a scan.
  DartFileScan({
    required this.hashes,
    required this.stamps,
    required this.at,
    this.optionsFiles = const [],
  });

  /// The scan `state` recorded; null when it recorded none (a state written
  /// before the stamps were kept), and then every file is read.
  static DartFileScan? of(KnowledgeState? state) {
    final hashes = state?.dartFiles;
    final stamps = state?.dartStamps;
    final at = DateTime.tryParse(state?.dartScannedAt ?? '');
    if (hashes == null || stamps == null || at == null) return null;
    return DartFileScan(hashes: hashes, stamps: stamps, at: at);
  }

  /// The SHA-256 of each Dart file, by its path from the project root with
  /// `/`, or [unreadableDartFile].
  final Map<String, String> hashes;

  /// The time of last change and size of each file the scan looked at
  /// itself (not those the map's inputs hashed), as
  /// `<microseconds since the epoch, UTC>/<bytes>`.
  final Map<String, String> stamps;

  /// When the scan began, in UTC.
  final DateTime at;

  /// Every `analysis_options.yaml` the walk met, by its path from the project
  /// root with `/`, in the order of the walk. Not kept in `state.json`: the
  /// hook's fingerprint hashes them (`checkInputDigests`).
  final List<String> optionsFiles;

  /// How many files this scan read to hash them.
  int get read => _read;
  var _read = 0;
}

/// The `analyzer: exclude:` patterns of the `analysis_options.yaml` in
/// [root]; none when there is no such file, or it can't be read as YAML.
List<Glob> _excludesOf(String root) {
  final Object? yaml;
  try {
    yaml = loadYaml(
      File(p.join(root, 'analysis_options.yaml')).readAsStringSync(),
    );
  } on FileSystemException {
    return const [];
  } on YamlException {
    return const [];
  }
  if (yaml case {'analyzer': {'exclude': final YamlList patterns}}) {
    return [
      for (final pattern in patterns.whereType<String>()) ?_glob(pattern),
    ];
  }
  return const [];
}

Glob? _glob(String pattern) {
  try {
    return Glob(pattern, context: p.posix);
  } on FormatException {
    return null;
  }
}

/// Whether a pattern of [excluded] leaves out the whole folder [relative]:
/// one that ends in `/**` whose rest matches the folder.
bool _folderExcluded(List<Glob> excluded, String relative) =>
    excluded.any((glob) {
      final pattern = glob.pattern;
      if (!pattern.endsWith('/**')) return false;
      final folder = _glob(pattern.substring(0, pattern.length - 3));
      return folder != null && folder.matches(relative);
    });

Future<String?> _digest(String path) async {
  try {
    return sha256Hex(await File(path).readAsBytes());
  } on FileSystemException {
    return null;
  }
}

/// The unverified files after a knowledge refresh that found the Dart files
/// as [dartFiles] ([readDartFileHashes]), where `state.json` was [before]:
/// those it held, and each file whose hash changed since, that appeared or
/// that is gone, sorted (slice 1d.2, spec §9.1).
///
/// - **With no earlier state** (the first sync of a project, or a
///   `state.json` that was deleted or can't be read), every Dart file is
///   unverified: nothing counts as verified before it was checked (the
///   owner's decision of 2026-10-14).
/// - A state written before slice 1d.2 has no hashes: it is read like a
///   missing one, and every Dart file is unverified (the owner's decision
///   of 2026-10-14, after the second review).
/// - Where file names don't depend on letter case ([caseInsensitiveFiles]),
///   one file is one entry: a file renamed in letter case only keeps its
///   new name.
List<String> unverifiedAfterRefresh(
  KnowledgeState? before,
  Map<String, String> dartFiles,
) {
  final earlier = before?.dartFiles;
  if (before == null || earlier == null) return dartFiles.keys.toList()..sort();
  final found = {
    ...before.unverified,
    for (final MapEntry(key: file, value: hash) in dartFiles.entries)
      if (earlier[file] != hash) file,
    for (final file in earlier.keys)
      if (!dartFiles.containsKey(file)) file,
  };
  // One entry per file: the name it has now, when it has one.
  final now = {for (final file in dartFiles.keys) fileKey(file): file};
  final byKey = <String, String>{};
  for (final file in found) {
    final key = fileKey(file);
    byKey[key] = now[key] ?? byKey[key] ?? file;
  }
  return byKey.values.toList()..sort();
}
