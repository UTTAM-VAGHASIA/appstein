import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_sdk.dart';
import '../support/temp.dart';

void main() {
  test('reads Flutter, Dart and channel from flutter.version.json', () {
    final sdk = createFakeSdk(p.join(tempDir().path, 'sdk'));
    final versions = readSdkVersions(sdk);
    expect(versions.flutter, '3.47.5');
    expect(versions.dart, '3.13.4');
    expect(versions.channel, 'stable');
  });

  test('keeps only the version from a beta Dart string', () {
    final sdk = createFakeSdk(
      p.join(tempDir().path, 'sdk'),
      dart: '3.14.0 (build 3.14.0-150.0.dev)',
      channel: 'beta',
    );
    expect(readSdkVersions(sdk).dart, '3.14.0');
  });

  test('an SDK that was never run is "not set up"', () {
    final sdk = createFakeSdk(p.join(tempDir().path, 'sdk'), setUp: false);
    expect(() => readSdkVersions(sdk), throwsA(isA<SdkNotSetUpException>()));
  });

  test('an unexpected file format is a FormatException', () {
    final sdk = createFakeSdk(p.join(tempDir().path, 'sdk'));
    File(
      p.join(sdk, 'bin', 'cache', 'flutter.version.json'),
    ).writeAsStringSync('[]');
    expect(() => readSdkVersions(sdk), throwsA(isA<FormatException>()));
  });
}
