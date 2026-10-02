import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../host/host_environment.dart';
import '../knowledge/input_hash.dart';
import '../packs/pack.dart';
import 'project_analysis.dart';

/// What the project map is built from (spec §6.2, §6.5), read before any
/// analysis, so `sync --detect` can tell whether the map is current.
final class MapInputs {
  /// Creates the inputs.
  const MapInputs({required this.sources, required this.inputHash});

  /// The SHA-256 of each input file, by input name, or null when the file
  /// can't be read:
  /// - `project:<path>` for each `.dart` file under
  ///   [ProjectAnalysis.folders];
  /// - `pubspec.yaml`, `pubspec.lock` (the workspace root's) and
  ///   `analysis_options.yaml`;
  /// - `local-package:<name>/<path>` for a local package's `pubspec.yaml`
  ///   and each `.dart` or `.yaml` file under its `lib/`
  ///   ([localPackageRoots]).
  ///
  /// The folders are walked as the analyzer walks them: links to folders
  /// (and Windows junctions) are followed, and a file behind one is named by
  /// its path through the link (`project:lib/linked/s.dart`). A folder that
  /// can't be listed is an input named after that folder alone, with a
  /// trailing `/` and null (`project:lib/locked/`,
  /// `local-package:<name>/lib/locked/`, or `project:lib/` when `lib/`
  /// itself can't be); its siblings are still hashed. The analyzer skips
  /// that folder too.
  final Map<String, String?> sources;

  /// The input hash every map file shares: [sources], the Flutter version,
  /// and the packs' ids and versions.
  final String inputHash;
}

/// Reads the inputs of the map of the project at [projectRoot], whose
/// `pubspec.lock` and package config are in [workspaceRoot] (the project
/// itself, or its pub workspace's root), for Flutter [flutterVersion] at
/// [flutterRoot].
MapInputs readMapInputs(
  String projectRoot, {
  required String workspaceRoot,
  required String flutterVersion,
  required String flutterRoot,
  required List<Pack> packs,
  required String appsteinVersion,
  required HostEnvironment environment,
}) {
  final sources = <String, String?>{
    'pubspec.yaml': _digest(p.join(projectRoot, 'pubspec.yaml')),
    'pubspec.lock': _digest(p.join(workspaceRoot, 'pubspec.lock')),
    // Its `exclude:` changes which files the map covers.
    'analysis_options.yaml': _digest(
      p.join(projectRoot, 'analysis_options.yaml'),
    ),
  };
  for (final folder in ProjectAnalysis.folders) {
    final (:files, :unlisted) = _filesUnder(p.join(projectRoot, folder), const [
      '.dart',
    ]);
    for (final file in files) {
      sources['project:${_relative(file, projectRoot)}'] = _digest(file);
    }
    for (final dir in unlisted) {
      sources['project:${_relative(dir, projectRoot)}/'] = null;
    }
  }
  final locals = localPackageRoots(
    projectRoot,
    workspaceRoot: workspaceRoot,
    flutterRoot: flutterRoot,
    environment: environment,
  );
  for (final MapEntry(key: name, value: root) in locals.entries) {
    sources['local-package:$name/pubspec.yaml'] = _digest(
      p.join(root, 'pubspec.yaml'),
    );
    final (:files, :unlisted) = _filesUnder(p.join(root, 'lib'), const [
      '.dart',
      '.yaml',
    ]);
    for (final file in files) {
      sources['local-package:$name/${_relative(file, root)}'] = _digest(file);
    }
    for (final dir in unlisted) {
      sources['local-package:$name/${_relative(dir, root)}/'] = null;
    }
  }
  return MapInputs(
    sources: sources,
    inputHash: inputHashOfDigests(
      {
        ...sources,
        'flutter': sha256Hex(utf8.encode(flutterVersion)),
        'packs': sha256Hex(
          utf8.encode(
            [for (final pack in packs) '${pack.id}@${pack.version}'].join(','),
          ),
        ),
      },
      appsteinVersion: appsteinVersion,
      formatVersion: knowledgeFormatVersion,
    ),
  );
}

/// The project's local packages, by name, with their folders.
///
/// A local package is a package in the workspace's
/// `.dart_tool/package_config.json` that is in neither the Flutter SDK at
/// [flutterRoot] nor a pub cache folder ([pubCacheFolders]), other than the
/// project itself. A path dependency or a workspace sibling can change
/// without `pubspec.lock` changing, so the map hashes its files. Packages
/// from pub.dev or git are pinned by `pubspec.lock`, and the SDK's by the
/// Flutter version.
///
/// A missing or damaged package config gives none.
Map<String, String> localPackageRoots(
  String projectRoot, {
  required String workspaceRoot,
  required String flutterRoot,
  required HostEnvironment environment,
}) {
  final config = File(
    p.join(workspaceRoot, '.dart_tool', 'package_config.json'),
  );
  final Object? json;
  try {
    json = jsonDecode(config.readAsStringSync());
  } on FileSystemException {
    return const {};
  } on FormatException {
    return const {};
  }
  if (json case {'packages': final List<Object?> packages}) {
    final skipped = [
      p.normalize(p.absolute(flutterRoot)),
      ...pubCacheFolders(environment),
    ];
    final project = p.normalize(p.absolute(projectRoot));
    // Root URIs are relative to the package config file itself.
    final base = Uri.file(config.absolute.path);
    final roots = <String, String>{};
    for (final package in packages) {
      if (package case {
        'name': final String name,
        'rootUri': final String rootUri,
      }) {
        final String root;
        try {
          root = p.normalize(base.resolve(rootUri).toFilePath());
        } on FormatException {
          continue;
        } on UnsupportedError {
          // Not a file URI.
          continue;
        }
        if (p.equals(root, project) ||
            skipped.any(
              (folder) => p.equals(folder, root) || p.isWithin(folder, root),
            )) {
          continue;
        }
        roots[name] = root;
      }
    }
    return roots;
  }
  return const {};
}

/// Where pub keeps downloaded packages: `PUB_CACHE` when it is set, else
/// pub's default for the OS. On Windows that is `%LOCALAPPDATA%\Pub\Cache`,
/// and the older `%APPDATA%\Pub\Cache` too. A cache missing from this list
/// costs only time: its packages are hashed as local ones.
List<String> pubCacheFolders(HostEnvironment environment) {
  if (environment.variable('PUB_CACHE') case final cache?) {
    return [p.normalize(p.absolute(cache))];
  }
  if (environment.os == HostOs.windows) {
    return [
      for (final name in const ['LOCALAPPDATA', 'APPDATA'])
        if (environment.variable(name) case final base?)
          p.join(base, 'Pub', 'Cache'),
    ];
  }
  return [if (environment.homeDir case final home?) p.join(home, '.pub-cache')];
}

/// The files under [folder] whose names end with one of [extensions], and
/// the folders under it (or [folder] itself) that can't be listed. A missing
/// folder has neither.
///
/// The walk matches the analyzer's (analyzer 14.4.0,
/// `ContextRootImpl._includedFilesInFolder`), so the inputs cover exactly
/// the files the map is built from:
/// - a link to a folder, or a Windows junction, is walked into, and the
///   files behind it are named by their path through the link
///   (`lib/linked/s.dart`);
/// - a folder whose resolved path is one the walk is already inside (a link
///   loop) is skipped. As in the analyzer, this tracks only the folders on
///   the current path, so two links to one folder are both walked;
/// - a folder that can't be listed, or whose link can't be resolved, is
///   recorded in `unlisted`, and its siblings are still walked. The analyzer
///   skips it too, so the map and the inputs agree.
({List<String> files, List<String> unlisted}) _filesUnder(
  String folder,
  List<String> extensions,
) {
  final files = <String>[];
  final unlisted = <String>[];
  if (!Directory(folder).existsSync()) {
    return (files: files, unlisted: unlisted);
  }
  // The resolved paths of the folders the walk is inside. Like the
  // analyzer's, it doesn't hold the top folder.
  final inside = <String>{};
  void walk(String dir) {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(dir).listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException {
      unlisted.add(dir);
      return;
    }
    for (final entry in entries) {
      final path = entry.path;
      // Follows links: a link to a folder (or a junction) is a directory.
      switch (FileSystemEntity.typeSync(path)) {
        case FileSystemEntityType.directory:
          final String resolved;
          try {
            resolved = Directory(path).resolveSymbolicLinksSync();
          } on FileSystemException {
            unlisted.add(path);
            continue;
          }
          if (inside.add(resolved)) {
            walk(path);
            inside.remove(resolved);
          }
        case FileSystemEntityType.file:
          if (extensions.any(path.endsWith)) files.add(path);
        // A broken link, or something that is neither: the analyzer skips
        // it too.
        default:
      }
    }
  }

  walk(folder);
  return (files: files, unlisted: unlisted);
}

String _relative(String file, String root) =>
    p.split(p.relative(file, from: root)).join('/');

String? _digest(String path) {
  try {
    return sha256Hex(File(path).readAsBytesSync());
  } on FileSystemException {
    return null;
  }
}
