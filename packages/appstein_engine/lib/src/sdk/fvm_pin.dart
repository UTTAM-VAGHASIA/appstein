import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A Flutter version a project pins with FVM, and the file that pins it.
final class FvmPin {
  /// Creates a pin.
  const FvmPin({required this.version, required this.configPath});

  /// The pinned version, such as `3.47.5` or `stable`.
  final String version;

  /// The file the pin came from.
  final String configPath;
}

/// Reads the FVM pin of [projectRoot]: `.fvmrc` (FVM 3) or
/// `.fvm/fvm_config.json` (FVM 2).
///
/// Returns null when the project doesn't use FVM. Throws a
/// [FormatException] when a pin file exists but can't be read.
FvmPin? readFvmPin(String projectRoot) {
  final fvmrc = File(p.join(projectRoot, '.fvmrc'));
  if (fvmrc.existsSync()) {
    return FvmPin(version: _read(fvmrc, 'flutter'), configPath: fvmrc.path);
  }
  final legacy = File(p.join(projectRoot, '.fvm', 'fvm_config.json'));
  if (legacy.existsSync()) {
    return FvmPin(
      version: _read(legacy, 'flutterSdkVersion'),
      configPath: legacy.path,
    );
  }
  return null;
}

/// Windows PowerShell 5.1 writes a byte order mark that `jsonDecode` rejects.
String _stripBom(String text) =>
    text.startsWith('﻿') ? text.substring(1) : text;

String _read(File file, String key) {
  final Object? data;
  try {
    data = jsonDecode(_stripBom(file.readAsStringSync()));
  } on FileSystemException catch (error) {
    throw FormatException(
      'Could not read ${file.path}: ${error.osError?.message ?? error.message}',
    );
  } on FormatException catch (error) {
    throw FormatException('${file.path} is not valid JSON: ${error.message}');
  }
  if (data is Map<String, Object?>) {
    final version = data[key];
    if (version is String && version.isNotEmpty) return version;
  }
  throw FormatException('${file.path} has no "$key" version.');
}
