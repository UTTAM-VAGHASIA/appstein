import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../host/host_environment.dart';

/// The channels an FVM pin can name. FVM 4 counts `main` as a channel; FVM 3
/// treats it as a release name, but installs it in the same place.
const fvmChannels = ['stable', 'beta', 'dev', 'master', 'main'];

/// A Flutter version a project pins with FVM, and the file that pins it.
final class FvmPin {
  /// Creates a pin.
  const FvmPin({
    required this.version,
    required this.configPath,
    required this.pinDirectory,
    this.cachePath,
  });

  /// The pin as written: a version such as `3.47.5`, a channel such as
  /// `stable`, a version on a channel such as `3.24.0@beta`, or a git
  /// reference. It is also the name of its folder in FVM's cache.
  final String version;

  /// The file the pin came from.
  final String configPath;

  /// The folder that holds the pin. It can be a parent of the project, and
  /// it is where FVM keeps the `.fvm/flutter_sdk` link for the pin.
  final String pinDirectory;

  /// The FVM cache folder the pin file sets with `cachePath`, as an absolute
  /// path (a relative one is taken from [pinDirectory]), or null when it sets
  /// none.
  final String? cachePath;

  /// The channel the pin names; see [fvmPinChannel].
  String? get channel => fvmPinChannel(version);

  /// The Flutter version to compare with an SDK's; see [fvmPinVersion].
  String? get flutterVersion => fvmPinVersion(version);
}

/// The channel [pin] names: `stable` for `stable`, `beta` for `3.24.0@beta`,
/// and null for a version or a git reference.
String? fvmPinChannel(String pin) =>
    fvmChannels.contains(pin) ? pin : _versionOnChannel(pin)?.channel;

/// The Flutter version [pin] names, to compare with an SDK's version:
/// `3.24.0` for `3.24.0@beta`, the pin itself for a version or a git
/// reference, and null for a bare channel such as `stable`.
String? fvmPinVersion(String pin) {
  if (fvmChannels.contains(pin)) return null;
  return _versionOnChannel(pin)?.version ?? pin;
}

/// How messages name what [pin] pins: `Flutter 3.47.5`,
/// `the Flutter stable channel`, or `Flutter 3.24.0 on the beta channel`.
String describeFvmPin(String pin) {
  if (fvmChannels.contains(pin)) return 'the Flutter $pin channel';
  final split = _versionOnChannel(pin);
  if (split != null) {
    return 'Flutter ${split.version} on the ${split.channel} channel';
  }
  return 'Flutter $pin';
}

/// The fix for a pin FVM doesn't have: `fvm install <pin>`, and for a bare
/// channel also `fvm use <channel>`, run in the project folder.
String fvmInstallHint(String pin) => fvmChannels.contains(pin)
    ? 'Run `fvm install $pin` or `fvm use $pin` in the project folder.'
    : 'Run `fvm install $pin` in the project folder.';

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
  for (final (file, key) in [
    (File(p.join(directory, '.fvmrc')), 'flutter'),
    (File(p.join(directory, '.fvm', 'fvm_config.json')), 'flutterSdkVersion'),
  ]) {
    if (!file.existsSync()) continue;
    final data = _readJson(file);
    final version = data[key];
    if (version is! String || version.isEmpty) {
      throw FormatException('${file.path} has no "$key" version.');
    }
    final cache = data['cachePath'];
    return FvmPin(
      version: version,
      configPath: file.path,
      pinDirectory: directory,
      cachePath: cache is String && cache.isNotEmpty
          ? p.normalize(p.join(directory, cache))
          : null,
    );
  }
  return null;
}

/// Where FVM keeps its global settings, the file `fvm config` writes:
/// `%APPDATA%\fvm\.fvmrc` on Windows,
/// `~/Library/Application Support/fvm/.fvmrc` on macOS, and
/// `$XDG_CONFIG_HOME/fvm/.fvmrc` (or `~/.config/fvm/.fvmrc`) on Linux.
/// Null when the variable it needs isn't set.
String? fvmGlobalConfigPath(HostEnvironment environment) {
  final home = environment.homeDir;
  final String? folder = switch (environment.os) {
    HostOs.windows => environment.variable('APPDATA'),
    HostOs.macos =>
      home == null ? null : p.join(home, 'Library', 'Application Support'),
    HostOs.linux =>
      environment.variable('XDG_CONFIG_HOME') ??
          (home == null ? null : p.join(home, '.config')),
  };
  return folder == null ? null : p.join(folder, 'fvm', '.fvmrc');
}

/// What FVM's global settings file says, as far as Appstein uses it.
final class FvmGlobalConfig {
  /// Creates the result for the file at [path].
  const FvmGlobalConfig({required this.path, this.cachePath, this.problem});

  /// The settings file.
  final String path;

  /// The FVM cache folder it sets with `cachePath`, or null.
  final String? cachePath;

  /// Why the file can't be used, or null when it can. FVM itself stops with
  /// an error then; Appstein ignores the file.
  final String? problem;
}

/// Reads FVM's global settings file (see [fvmGlobalConfigPath]). Null when
/// there is no such file. Never throws: a file that can't be read or isn't
/// a JSON object gives a [FvmGlobalConfig.problem] instead.
FvmGlobalConfig? readFvmGlobalConfig(HostEnvironment environment) {
  final path = fvmGlobalConfigPath(environment);
  if (path == null) return null;
  final file = File(path);
  if (!file.existsSync()) return null;
  final Object? data;
  try {
    data = jsonDecode(_stripBom(file.readAsStringSync()));
  } on FileSystemException catch (error) {
    return FvmGlobalConfig(
      path: path,
      problem: 'Could not read $path: ${fileErrorReason(error)}',
    );
  } on FormatException catch (error) {
    return FvmGlobalConfig(
      path: path,
      problem: '$path is not valid JSON: ${error.message}',
    );
  }
  if (data is! Map<String, Object?>) {
    return FvmGlobalConfig(path: path, problem: '$path is not a JSON object.');
  }
  final cache = data['cachePath'];
  return FvmGlobalConfig(
    path: path,
    cachePath: cache is String && cache.isNotEmpty ? cache : null,
  );
}

/// The folder FVM keeps its Flutter versions in, for [pin], in FVM's own
/// order, highest first: the pin file's `cachePath`, `FVM_CACHE_PATH`,
/// `FVM_HOME` (FVM's older name for it), the global settings' `cachePath`,
/// then `fvm` in the home folder. Null when none applies.
String? fvmCacheFolder(FvmPin pin, HostEnvironment environment) {
  final home = environment.homeDir;
  return pin.cachePath ??
      environment.variable('FVM_CACHE_PATH') ??
      environment.variable('FVM_HOME') ??
      readFvmGlobalConfig(environment)?.cachePath ??
      (home == null ? null : p.join(home, 'fvm'));
}

/// `3.24.0@beta` split into its version and channel, or null when [pin]
/// isn't a version on a known channel. FVM rejects an unknown channel
/// after `@`; here such a pin is left whole, as a version.
({String version, String channel})? _versionOnChannel(String pin) {
  final at = pin.lastIndexOf('@');
  if (at <= 0) return null;
  final channel = pin.substring(at + 1);
  return fvmChannels.contains(channel)
      ? (version: pin.substring(0, at), channel: channel)
      : null;
}

/// The JSON object in [file]; empty when the JSON isn't an object. Throws a
/// [FormatException] when the file can't be read or isn't JSON.
Map<String, Object?> _readJson(File file) {
  final Object? data;
  try {
    data = jsonDecode(_stripBom(file.readAsStringSync()));
  } on FileSystemException catch (error) {
    throw FormatException(
      'Could not read ${file.path}: ${fileErrorReason(error)}',
    );
  } on FormatException catch (error) {
    throw FormatException('${file.path} is not valid JSON: ${error.message}');
  }
  return data is Map<String, Object?> ? data : const {};
}

/// Windows PowerShell 5.1 writes a byte order mark that `jsonDecode` rejects.
String _stripBom(String text) =>
    text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? text.substring(1) : text;
