import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../host/file_errors.dart';

/// A project file a native extractor read (spec §6.5).
final class NativeFile {
  const NativeFile._(this.path, {this.bytes, this.text, this.error});

  /// Its path relative to the project, with `/`, such as
  /// `android/app/build.gradle.kts`.
  final String path;

  /// Its bytes; null when it is missing or unreadable.
  final List<int>? bytes;

  /// Its text, without a leading byte order mark; null when it is missing,
  /// unreadable or not UTF-8.
  final String? text;

  /// Why there is no [text] although the file exists; null otherwise.
  final String? error;

  /// Whether the file exists.
  bool get exists => bytes != null || error != null;

  /// [path] with a 1-based [line]: `path:line`.
  String at(int line) => '$path:$line';

  /// This file's entry in an input hash: its bytes, a marker when it can't
  /// be read, or null when it is missing.
  MapEntry<String, List<int>?> get input => MapEntry(
    'file:$path',
    bytes ?? (error == null ? null : utf8.encode('unreadable: $error')),
  );
}

/// Reads [path] (relative, with `/`) in the project at [projectRoot]. It
/// never throws: a missing file, or one that can't be read or isn't UTF-8,
/// is described by the [NativeFile].
NativeFile readNativeFile(String projectRoot, String path) {
  final file = File(p.joinAll([projectRoot, ...path.split('/')]));
  if (!file.existsSync()) return NativeFile._(path);
  final List<int> bytes;
  try {
    bytes = file.readAsBytesSync();
  } on FileSystemException catch (error) {
    return NativeFile._(path, error: fileErrorReason(error));
  }
  try {
    var text = utf8.decode(bytes);
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      text = text.substring(1);
    }
    return NativeFile._(path, bytes: bytes, text: text);
  } on FormatException {
    return NativeFile._(path, bytes: bytes, error: 'not valid UTF-8');
  }
}

/// The 1-based line of [offset] in [text]. A `\r\n` counts as one line end.
int lineAt(String text, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) line++;
  }
  return line;
}

/// The project's `pubspec.yaml` as a map that keeps line numbers, or null
/// when it is missing, can't be read, or isn't a YAML map.
YamlMap? loadPubspec(NativeFile pubspec) {
  final text = pubspec.text;
  if (text == null) return null;
  try {
    final node = loadYamlNode(text);
    return node is YamlMap ? node : null;
  } on YamlException {
    return null;
  }
}

/// The 1-based line where [node] starts.
int yamlLine(YamlNode node) => node.span.start.line + 1;
