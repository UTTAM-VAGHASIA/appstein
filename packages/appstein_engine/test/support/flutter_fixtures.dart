import 'dart:io';
import 'dart:isolate';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;

/// The Flutter versions whose toolchain files are test fixtures: the newest
/// patch of each supported stable minor when this was written.
///
/// The files under `test/fixtures/flutter_sdk/<version>/` are Flutter's own,
/// downloaded from the flutter/flutter repo at that tag. They keep their
/// license header (BSD-3-Clause, The Flutter Authors). Each name ends in
/// `.fixture`, so the analyzer doesn't compile them and graphify doesn't
/// index them.
const fixtureFlutterVersions = ['3.44.9', '3.47.5'];

/// The text of the SDK file at [sdkPath] (`/`-separated, such as
/// [ToolchainFiles.gradleUtils]) in Flutter [version].
String fixtureText(String version, String sdkPath) => File(
  '${p.joinAll([_packageRoot, 'test', 'fixtures', 'flutter_sdk', version, ...sdkPath.split('/')])}.fixture',
).readAsStringSync();

/// The engine package's folder, found from the package itself and not from
/// `Directory.current`: test files run concurrently in one process, and one
/// of them changes the working folder.
final String _packageRoot = () {
  final library = Isolate.resolvePackageUriSync(
    Uri.parse('package:appstein_engine/appstein_engine.dart'),
  )!;
  // <package>/lib/appstein_engine.dart
  return p.dirname(p.dirname(library.toFilePath()));
}();

/// Copies Flutter [version]'s toolchain files into the fake SDK at
/// [sdkRoot], under their real names.
void addToolchainFiles(String sdkRoot, String version) {
  for (final sdkPath in ToolchainFiles.all) {
    final target = File(p.joinAll([sdkRoot, ...sdkPath.split('/')]));
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(fixtureText(version, sdkPath));
  }
}
