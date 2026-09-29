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
