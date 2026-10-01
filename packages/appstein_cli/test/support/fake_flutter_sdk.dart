import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Builds the parts of a Flutter 3.47.5 SDK that SDK detection reads, at
/// [root], and returns [root]. It has no toolchain files, so `sync` takes
/// the toolchain from the curated notes.
String createFakeFlutterSdk(String root) {
  Directory(p.join(root, 'packages', 'flutter')).createSync(recursive: true);
  final bin = Directory(p.join(root, 'bin'))..createSync(recursive: true);
  final launcher = File(
    p.join(bin.path, Platform.isWindows ? 'flutter.bat' : 'flutter'),
  )..writeAsStringSync('');
  if (!Platform.isWindows) Process.runSync('chmod', ['+x', launcher.path]);
  final cache = Directory(p.join(bin.path, 'cache', 'dart-sdk'))
    ..createSync(recursive: true);
  File(p.join(cache.path, 'version')).writeAsStringSync('3.13.4\n');
  File(p.join(bin.path, 'cache', 'flutter.version.json')).writeAsStringSync(
    jsonEncode({
      'frameworkVersion': '3.47.5',
      'channel': 'stable',
      'dartSdkVersion': '3.13.4',
      'flutterVersion': '3.47.5',
    }),
  );
  return root;
}
