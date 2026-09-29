import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/host_environment.dart';

/// Where Flutter keeps the user settings that `flutter config` writes.
///
/// This mirrors `Config._configPath` in
/// `flutter_tools/lib/src/base/config.dart` (Flutter 3.47):
/// - Windows: `%APPDATA%\.flutter_settings`.
/// - macOS and Linux: `~/.flutter_settings` if it exists; otherwise
///   `$XDG_CONFIG_HOME/settings`, or `~/.config/flutter/settings` when
///   XDG_CONFIG_HOME is unset.
String? flutterSettingsPath(HostEnvironment environment) {
  if (environment.os == HostOs.windows) {
    final appData = environment.variable('APPDATA');
    return appData == null ? null : p.join(appData, '.flutter_settings');
  }
  final home = environment.variable('HOME');
  if (home == null) return null;
  final legacy = p.join(home, '.flutter_settings');
  if (File(legacy).existsSync()) return legacy;
  final configDir =
      environment.variable('XDG_CONFIG_HOME') ??
      p.join(home, '.config', 'flutter');
  return p.join(configDir, 'settings');
}

/// Flutter's user settings, such as `jdk-dir` and `android-sdk`. Empty when
/// the file is missing or unreadable.
Map<String, Object?> readFlutterSettings(HostEnvironment environment) {
  final path = flutterSettingsPath(environment);
  if (path == null) return const {};
  final file = File(path);
  if (!file.existsSync()) return const {};
  try {
    final data = jsonDecode(file.readAsStringSync());
    return data is Map<String, Object?> ? data : const {};
  } on FormatException {
    return const {};
  }
}
