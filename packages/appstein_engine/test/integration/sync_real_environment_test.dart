@Tags(['integration'])
library;

import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final environment = HostEnvironment.current();
  // The repo pins its Flutter in .fvmrc. The tests run from
  // packages/appstein_engine, so the pin is found above them.
  final repoRoot = readFvmPin(Directory.current.path)?.pinDirectory;

  /// The Flutter SDK Appstein finds for the repo or, when that fails, with
  /// no project. The min-sdk CI job installs 3.44 while the repo pins
  /// 3.47.5, so there only the second lookup works. With neither, the test
  /// fails in CI and is skipped elsewhere, and this returns null.
  SdkDetection? machineSdk() {
    for (final projectRoot in [repoRoot, null]) {
      final detection = SdkDetector(
        environment,
      ).detect(projectRoot: projectRoot);
      if (detection.info != null && detection.location != null) {
        return detection;
      }
    }
    const reason = 'No usable Flutter SDK on this machine.';
    if (environment.variable('CI') != null) fail(reason);
    markTestSkipped(reason);
    return null;
  }

  test("the toolchain is read from this machine's Flutter SDK, with no "
      'fallback', () {
    final sdk = machineSdk();
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
    final sdk = machineSdk();
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
