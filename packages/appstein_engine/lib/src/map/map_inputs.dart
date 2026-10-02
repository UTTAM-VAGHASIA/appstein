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
  /// A folder that can't be listed is an input named after it
  /// (`project:lib/`, `local-package:<name>/lib/`) with null.
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
    final files = _filesUnder(p.join(projectRoot, folder), const ['.dart']);
    if (files == null) {
      sources['project:$folder/'] = null;
      continue;
    }
    for (final file in files) {
      sources['project:${_relative(file, projectRoot)}'] = _digest(file);
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
    final files = _filesUnder(p.join(root, 'lib'), const ['.dart', '.yaml']);
    if (files == null) {
      sources['local-package:$name/lib/'] = null;
      continue;
    }
    for (final file in files) {
      sources['local-package:$name/${_relative(file, root)}'] = _digest(file);
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

/// The files under [folder] whose names end with one of [extensions], or
/// null when it can't be listed. A missing folder has none.
List<String>? _filesUnder(String folder, List<String> extensions) {
  final directory = Directory(folder);
  if (!directory.existsSync()) return const [];
  try {
    return [
      for (final entity in directory.listSync(
        recursive: true,
        followLinks: false,
      ))
        if (entity is File && extensions.any(entity.path.endsWith)) entity.path,
    ];
  } on FileSystemException {
    return null;
  }
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
