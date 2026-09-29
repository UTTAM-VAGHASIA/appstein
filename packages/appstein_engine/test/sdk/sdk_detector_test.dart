import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_sdk.dart';
import '../support/temp.dart';

void main() {
  test('combines location, versions and the project language version', () {
    final work = tempDir();
    final project = p.join(work.path, 'my app');
    Directory(project).createSync();
    File(
      p.join(project, 'pubspec.yaml'),
    ).writeAsStringSync('name: a\nenvironment:\n  sdk: ^3.9.0\n');
    File(p.join(project, '.fvmrc')).writeAsStringSync('{"flutter": "3.47.5"}');
    final cache = p.join(work.path, 'fvm');
    createFakeSdk(p.join(cache, 'versions', '3.47.5'));
    final detection = SdkDetector(
      fakeEnvironment({'FVM_CACHE_PATH': cache}),
    ).detect(projectRoot: project);
    expect(detection.info!.toJson(), {
      'flutter': '3.47.5',
      'dart': '3.13.4',
      'channel': 'stable',
      'languageVersion': '3.9',
      'fvm': '3.47.5',
    });
  });

  group('when the FVM pin is not installed', () {
    late Directory work;
    late String project;

    setUp(() {
      work = tempDir();
      project = p.join(work.path, 'my app');
      Directory(project).createSync();
      File(p.join(project, 'pubspec.yaml')).writeAsStringSync('name: a\n');
      File(
        p.join(project, '.fvmrc'),
      ).writeAsStringSync('{"flutter": "3.47.5"}');
    });

    SdkDetection detect(String sdk) => SdkDetector(
      fakeEnvironment({
        'FVM_CACHE_PATH': p.join(work.path, 'empty'),
        'FLUTTER_ROOT': sdk,
      }),
    ).detect(projectRoot: project);

    test('a FLUTTER_ROOT SDK at the pinned version is used', () {
      final detection = detect(createFakeSdk(p.join(work.path, 'sdk')));
      expect(detection.info!.flutterVersion, '3.47.5');
      // fvmVersion is the version the project pins, however it was met.
      expect(detection.info!.fvmVersion, '3.47.5');
    });

    test('a FLUTTER_ROOT SDK at another version fails', () {
      final detection = detect(
        createFakeSdk(p.join(work.path, 'sdk'), flutter: '3.46.0'),
      );
      expect(detection.info, isNull);
      expect(detection.problem, contains('3.47.5'));
      expect(detection.problem, contains('3.46.0'));
      expect(detection.fixHint, contains('fvm install 3.47.5'));
      expect(detection.location, isNotNull);
    });
  });

  test('an SDK that was never run explains how to set it up', () {
    final sdk = createFakeSdk(p.join(tempDir().path, 'sdk'), setUp: false);
    final detection = SdkDetector(
      fakeEnvironment({'FLUTTER_ROOT': sdk}),
    ).detect();
    expect(detection.info, isNull);
    expect(detection.location, isNotNull);
    expect(detection.fixHint, contains('--version'));
  });
}
