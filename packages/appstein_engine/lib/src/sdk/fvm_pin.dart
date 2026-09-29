import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A Flutter version a project pins with FVM, and the file that pins it.
final class FvmPin {
  /// Creates a pin.
  const FvmPin({
    required this.version,
    required this.configPath,
    required this.pinDirectory,
  });

  /// The pinned version, such as `3.47.5` or `stable`.
  final String version;

  /// The file the pin came from.
  final String configPath;

  /// The folder that holds the pin. It can be a parent of the project, and
  /// it is where FVM keeps the `.fvm/flutter_sdk` link for the pin.
  final String pinDirectory;
}

/// Reads the FVM pin that applies to [projectRoot]: `.fvmrc` (FVM 3) or
/// `.fvm/fvm_config.json` (FVM 2).
///
/// Like FVM, this looks in [projectRoot] and then in each parent folder up to
/// the filesystem root. The nearest folder with either file wins, so a
/// project inside a monorepo uses the repo's pin.
///
/// Returns null when no folder up the chain pins a version. Throws a
/// [FormatException] when the pin file it finds can't be read.
FvmPin? readFvmPin(String projectRoot) {
  var directory = p.absolute(projectRoot);
  while (true) {
    final pin = _readIn(directory);
    if (pin != null) return pin;
    final parent = p.dirname(directory);
    if (parent == directory) return null;
    directory = parent;
  }
}

FvmPin? _readIn(String directory) {
  final fvmrc = File(p.join(directory, '.fvmrc'));
  if (fvmrc.existsSync()) {
    return FvmPin(
      version: _read(fvmrc, 'flutter'),
      configPath: fvmrc.path,
      pinDirectory: directory,
    );
  }
  final legacy = File(p.join(directory, '.fvm', 'fvm_config.json'));
  if (legacy.existsSync()) {
    return FvmPin(
      version: _read(legacy, 'flutterSdkVersion'),
      configPath: legacy.path,
      pinDirectory: directory,
    );
  }
  return null;
}

/// Windows PowerShell 5.1 writes a byte order mark that `jsonDecode` rejects.
String _stripBom(String text) =>
    text.startsWith('\uFEFF') ? text.substring(1) : text;

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
