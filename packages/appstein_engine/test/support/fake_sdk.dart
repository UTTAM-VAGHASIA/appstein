import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;

/// Builds the parts of a Flutter SDK folder that Appstein reads, at [root].
///
/// With [setUp] false, it leaves out the version files, like an SDK that
/// FVM downloaded but Flutter hasn't run yet ("Need setup").
/// The JSON matches Flutter 3.47.5's real `bin/cache/flutter.version.json`.
String createFakeSdk(
  String root, {
  String flutter = '3.47.5',
  String dart = '3.13.4',
  String channel = 'stable',
  bool setUp = true,
}) {
  Directory(p.join(root, 'packages', 'flutter')).createSync(recursive: true);
  final bin = Directory(p.join(root, 'bin'))..createSync(recursive: true);
  final launcher = File(
    p.join(bin.path, Platform.isWindows ? 'flutter.bat' : 'flutter'),
  )..writeAsStringSync('');
  // Like the real SDK's launcher, so a PATH lookup on POSIX finds it.
  if (!Platform.isWindows) Process.runSync('chmod', ['+x', launcher.path]);
  if (setUp) {
    final cache = Directory(p.join(bin.path, 'cache', 'dart-sdk'))
      ..createSync(recursive: true);
    File(p.join(cache.path, 'version')).writeAsStringSync('$dart\n');
    File(p.join(bin.path, 'cache', 'flutter.version.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'frameworkVersion': flutter,
        'channel': channel,
        'repositoryUrl': 'https://github.com/flutter/flutter.git',
        'frameworkRevision': '6a19cca56475dbfba1478ee68d7bd0c2ef891da1',
        'dartSdkVersion': dart,
        'devToolsVersion': '2.60.0',
        'flutterVersion': flutter,
      }),
    );
  }
  return root;
}

/// Variables that make [home] the user's home folder, and the folder FVM's
/// global settings file lives under, for this OS (see [fvmSettingsFile]).
Map<String, String> fvmHomeVars(String home) => switch (HostOs.current) {
  HostOs.windows => {'USERPROFILE': home, 'APPDATA': home},
  HostOs.macos => {'HOME': home},
  HostOs.linux => {'HOME': home, 'XDG_CONFIG_HOME': home},
};

/// Where FVM's global settings file is, with the variables of
/// [fvmHomeVars] for [home].
String fvmSettingsFile(String home) => switch (HostOs.current) {
  HostOs.windows || HostOs.linux => p.join(home, 'fvm', '.fvmrc'),
  HostOs.macos => p.join(
    home,
    'Library',
    'Application Support',
    'fvm',
    '.fvmrc',
  ),
};
