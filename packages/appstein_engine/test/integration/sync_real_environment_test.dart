@Tags(['integration'])
library;

import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/machine_sdk.dart';

void main() {
  final environment = HostEnvironment.current();

  test("the toolchain is read from this machine's Flutter SDK, with no "
      'fallback', () {
    final sdk = machineSdk(environment);
    if (sdk == null) return;
    final version = sdk.info!.flutterVersion;
    final toolchain = readToolchain(
      sdk.location!.root,
      flutterVersion: version,
      notes: CuratedNotes.bundled(),
    ).toolchain;
    expect(
      toolchain.fallbacks,
      isEmpty,
      reason: 'Flutter $version at ${sdk.location!.root}',
    );
    expect(toolchain.android?.source, ToolchainSource.sdk);
    expect(toolchain.ios?.source, ToolchainSource.sdk);
    expect(toolchain.macos?.source, ToolchainSource.sdk);
  });

  test('sync writes the platform layer, then a second sync changes '
      'nothing', () async {
    final sdk = machineSdk(environment);
    if (sdk == null) return;
    final project = Directory.systemTemp.createTempSync('appstein sync tëst ');
    addTearDown(() => project.deleteSync(recursive: true));
    File(
      p.join(project.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: sample\nenvironment:\n  sdk: ^3.12.0\n');
    final sync = PlatformSync(
      environment: environment,
      appsteinVersion: 'integration-test',
    );
    final first = await sync.run(project.path, sdk: sdk);
    expect(first.files.values, everyElement(isTrue));
    expect(first.sdk.flutterVersion, sdk.info!.flutterVersion);
    expect(first.fallbacks, isEmpty);
    final second = await sync.run(project.path, sdk: sdk);
    expect(second.files.values, everyElement(isFalse));
  });
}
