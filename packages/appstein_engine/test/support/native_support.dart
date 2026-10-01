import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import 'fake_sdk.dart';
import 'fixture_app.dart';
import 'flutter_fixtures.dart';
import 'temp.dart';

/// `test/fixtures/native/template_app`: the native files of a new app from
/// Flutter 3.47.5's `flutter create --platforms=android,ios --org
/// dev.sample --project-name probe_app`, after `flutter pub get`.
String get nativeTemplateDir =>
    p.join(p.dirname(fixtureAppsDir), 'native', 'template_app');

/// Copies the template into a new temp folder, as `native app`, and returns
/// that folder.
String copyNativeTemplate() {
  final app = p.join(tempDir().path, 'native app');
  copyFixtureTree(nativeTemplateDir, app);
  return app;
}

/// Writes [files] (a path relative to [root], with `/`, to its text).
void writeProjectFiles(String root, Map<String, String> files) {
  for (final MapEntry(key: path, value: text) in files.entries) {
    File(p.joinAll([root, ...path.split('/')]))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }
}

/// Flutter 3.47.5's Android values, read the way `sync` reads them: from
/// the SDK fixture's `gradle_utils.dart`.
Sourced<AndroidToolchain> flutterAndroidValues() {
  final sdk = p.join(tempDir().path, 'flutter');
  createFakeSdk(sdk);
  addToolchainFiles(sdk, '3.47.5');
  return readToolchain(
    sdk,
    flutterVersion: '3.47.5',
    notes: CuratedNotes.bundled(),
  ).toolchain.android!;
}

/// A [NativeContext] for the project at [projectRoot] on a machine with
/// only [variables]. `APPDATA` and `HOME` point at an empty temp folder,
/// so the real machine's Flutter settings are never read.
NativeContext nativeContext(
  String projectRoot, {
  Map<String, String> variables = const {},
  Sourced<AndroidToolchain>? android,
  String flutterVersion = '3.47.5',
  String channel = 'stable',
  HostOs? os,
}) {
  final home = tempDir().path;
  return NativeContext(
    projectRoot: projectRoot,
    flutterVersion: flutterVersion,
    channel: channel,
    environment: fakeEnvironment({
      'APPDATA': home,
      'HOME': home,
      ...variables,
    }, os: os),
    android: android,
  );
}
