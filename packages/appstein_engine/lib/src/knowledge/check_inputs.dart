import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'dart_files.dart' show fileKey;
import 'input_hash.dart';

/// The name of the options file the analyzer reads in a folder.
const optionsFileName = 'analysis_options.yaml';

/// The SHA-256 of each file a check's findings depend on that the map's
/// inputs and the scan of the Dart files do not cover, by input name, or
/// null for a file that is missing (slice 1d.7): a file that appears or
/// disappears changes the digests, and a missing file gives the same value
/// every time.
///
/// - `config:appstein.yaml`: the suppressions and `verify.severity` change
///   what a run reports;
/// - `config:package_config.json`: the package configuration of the
///   workspace root (`.dart_tool/package_config.json`) decides what the
///   analysis resolves, `pubspec.lock` (a map input) what it resolves to;
/// - `options:<path>`: every `analysis_options.yaml` the scan found in the
///   project ([optionsFiles], from the project root with `/`), the root's
///   always, and each local file they `include:`, followed through the
///   includes of the files that are included, wherever they are, as the
///   analyzer follows them (a package of a monorepo often includes
///   `../../analysis_options.yaml`). A `package:` include is a file of a
///   package, which the package configuration covers. When the root has no
///   options file, the one the analyzer applies instead
///   ([enclosingOptionsPath], in a folder above the project) is hashed too,
///   with its includes. A file is named by its path from the root
///   (`../analysis_options.yaml`), or by its full path when it is on another
///   drive.
Map<String, String?> checkInputDigests(
  String projectRoot, {
  required String workspaceRoot,
  required List<String> optionsFiles,
}) {
  final root = p.normalize(p.absolute(projectRoot));
  final digests = <String, String?>{
    'config:appstein.yaml': _digest(p.join(root, 'appstein.yaml')),
    'config:package_config.json': _digest(
      p.join(workspaceRoot, '.dart_tool', 'package_config.json'),
    ),
  };
  final seen = <String>{};
  final enclosing = enclosingOptionsPath(root);
  final queue = [
    for (final file in {...optionsFiles, optionsFileName})
      p.joinAll([root, ...file.split('/')]),
    ?enclosing,
  ];
  while (queue.isNotEmpty) {
    final path = queue.removeLast();
    final key = 'options:${_nameFrom(root, path)}';
    if (!seen.add(fileKey(key))) continue;
    final List<int> bytes;
    try {
      bytes = File(path).readAsBytesSync();
    } on FileSystemException {
      digests[key] = null;
      continue;
    }
    digests[key] = sha256Hex(bytes);
    for (final include in _includesOf(
      utf8.decode(bytes, allowMalformed: true),
    )) {
      if (includedOptionsPath(path, include) case final target?) {
        queue.add(target);
      }
    }
  }
  return digests;
}

/// [path]'s name in an input: its path from [root] with `/`, or the full
/// path for a file on another drive, which has no path from the root.
String _nameFrom(String root, String path) {
  try {
    return p.split(p.relative(path, from: root)).join('/');
  } on p.PathException {
    return p.split(p.normalize(path)).join('/');
  }
}

/// The path of the nearest `analysis_options.yaml` in a folder above
/// [projectRoot] that the analyzer applies to it; null when the root has an
/// options file of its own (the analyzer then looks no further), or none
/// above it does. Compared with `dart analyze` of the pinned SDK on
/// 2026-10-14: the nearest file wins, with or without a `pubspec.yaml` in
/// between.
String? enclosingOptionsPath(String projectRoot) {
  var folder = p.normalize(p.absolute(projectRoot));
  if (File(p.join(folder, optionsFileName)).existsSync()) return null;
  while (true) {
    final parent = p.dirname(folder);
    if (parent == folder) return null;
    folder = parent;
    final candidate = p.join(folder, optionsFileName);
    if (File(candidate).existsSync()) return candidate;
  }
}

/// The path of the file the `include:` text [include] names in the options
/// file at [includingPath]; null when it names no local file.
///
/// The analyzer reads the text as a URI and resolves it against the
/// including file: a path is relative to that file's folder (with `/` or, on
/// Windows, `\`, and `%20` for a space), a `file:` URI is that file, and a
/// `package:` URI is a file of a package, which is not followed here. A text
/// with any other scheme, such as `C:/dir/x.yaml` (the analyzer reads the
/// drive letter as a scheme), names no file.
String? includedOptionsPath(String includingPath, String include) {
  final uri = Uri.tryParse(include.trim());
  if (uri == null || include.trim().isEmpty) return null;
  final resolved = Uri.file(p.absolute(includingPath)).resolveUri(uri);
  if (!resolved.isScheme('file')) return null;
  try {
    return resolved.toFilePath();
  } on UnsupportedError {
    return null;
  }
}

/// What `include:` names in the options [content]: one string, or each
/// string of a list; nothing for a text that isn't YAML or has another shape.
List<String> _includesOf(String content) {
  final YamlNode root;
  try {
    root = loadYamlNode(content);
  } on YamlException {
    return const [];
  }
  if (root is! YamlMap) return const [];
  return switch (root.nodes['include']) {
    YamlScalar(value: final String text) => [text],
    final YamlList list => [
      for (final item in list.nodes)
        if (item is YamlScalar && item.value is String) item.value as String,
    ],
    _ => const [],
  };
}

String? _digest(String path) {
  try {
    return sha256Hex(File(path).readAsBytesSync());
  } on FileSystemException {
    return null;
  }
}
