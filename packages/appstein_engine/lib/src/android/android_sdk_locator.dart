import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/executable_finder.dart';
import '../host/file_links.dart';
import '../host/host_environment.dart';

/// Finds the Android SDK the way Flutter does (`locateAndroidSdk` in
/// `flutter_tools/lib/src/android/android_sdk.dart`, Flutter 3.47).
///
/// The first *defined* of `flutter config --android-sdk`, ANDROID_HOME,
/// ANDROID_SDK_ROOT and the default folder is used (or its `sdk` subfolder).
/// An empty variable counts as unset here, unlike in Flutter.
/// When that isn't a valid SDK, every `aapt` on PATH is tried, with the SDK
/// three folders above it (`build-tools/<version>/aapt`), then every `adb`,
/// with the SDK two folders above it (`platform-tools/adb`). Links are
/// resolved first. A folder is an SDK when it has `licenses/` or
/// `platform-tools/`.
String? locateAndroidSdk(
  HostEnvironment environment,
  Map<String, Object?> settings,
) {
  final configured = settings['android-sdk'];
  final candidate = configured is String
      ? configured
      : environment.variable('ANDROID_HOME') ??
            environment.variable('ANDROID_SDK_ROOT') ??
            _defaultAndroidSdk(environment);
  if (candidate != null) {
    if (_isAndroidSdk(candidate)) return candidate;
    final nested = p.join(candidate, 'sdk');
    if (_isAndroidSdk(nested)) return nested;
  }
  for (final aapt in findAllExecutables('aapt', environment)) {
    final root = p.dirname(p.dirname(p.dirname(resolveLinks(aapt))));
    if (_isAndroidSdk(root)) return root;
  }
  for (final adb in findAllExecutables('adb', environment)) {
    final root = p.dirname(p.dirname(resolveLinks(adb)));
    if (_isAndroidSdk(root)) return root;
  }
  return null;
}

String? _defaultAndroidSdk(HostEnvironment environment) {
  final home = environment.homeDir;
  if (home == null) return null;
  return switch (environment.os) {
    HostOs.windows => p.join(home, 'AppData', 'Local', 'Android', 'sdk'),
    HostOs.macos => p.join(home, 'Library', 'Android', 'sdk'),
    HostOs.linux => p.join(home, 'Android', 'Sdk'),
  };
}

bool _isAndroidSdk(String dir) =>
    Directory(p.join(dir, 'licenses')).existsSync() ||
    Directory(p.join(dir, 'platform-tools')).existsSync();
