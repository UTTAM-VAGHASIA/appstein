import 'dart:io';

import 'package:appstein_engine/src/android/android_sdk_contents.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  group('LenientVersion reads folder names as Flutter does', () {
    for (final (text, parts) in [
      ('37.0.0-rc2', (37, 0, 0)),
      ('36', (36, 0, 0)),
      ('36.1', (36, 1, 0)),
      ('36.0.0.1', (36, 0, 0)),
      ('36abc', (36, 0, 0)),
      ('24.0.0-preview', (24, 0, 0)),
    ]) {
      test(text, () {
        final version = LenientVersion.tryParse(text)!;
        expect((version.major, version.minor, version.patch), parts);
        expect(version.text, text);
        expect('$version', text);
      });
    }

    test('a name that does not start with a number is not a version', () {
      for (final text in ['latest', '.DS_Store', 'android-36', '']) {
        expect(LenientVersion.tryParse(text), isNull, reason: text);
      }
    });

    test('a preview ties with its release; only numbers are compared', () {
      final rc = LenientVersion.tryParse('37.0.0-rc2')!;
      expect(rc.compareTo(LenientVersion.tryParse('37.0.0')!), 0);
      expect(LenientVersion.tryParse('36.1.0')!.compareTo(rc), lessThan(0));
    });
  });

  group('readAndroidSdkContents', () {
    late String sdk;

    setUp(() => sdk = p.join(tempDir().path, 'android sdk'));

    void folder(String path) => Directory(
      p.joinAll([sdk, ...path.split('/')]),
    ).createSync(recursive: true);

    void buildProp(String platform, String text) =>
        File(p.join(sdk, 'platforms', platform, 'build.prop'))
          ..createSync(recursive: true)
          ..writeAsStringSync(text);

    test('reads levels from names and from build.prop, and lists the rest '
        'as ignored', () {
      folder('platforms/android-36');
      buildProp(
        'android-36.1',
        'ro.build.version.release=16\nro.build.version.sdk=36\n',
      );
      buildProp('android-37.0', 'ro.build.version.sdk=37\r\n');
      // Flutter's pattern allows no spaces around "=".
      buildProp('android-38.0', 'ro.build.version.sdk = 38\n');
      folder('platforms/android-TiramisuPrivacySandbox');
      final contents = readAndroidSdkContents(sdk);
      expect(contents.platforms, [
        (name: 'android-36', level: 36),
        (name: 'android-36.1', level: 36),
        (name: 'android-37.0', level: 37),
      ]);
      expect(contents.ignoredPlatforms, [
        'android-38.0',
        'android-TiramisuPrivacySandbox',
      ]);
    });

    test('among platforms of one level, the name that sorts last is the '
        'newest', () {
      folder('platforms/android-36');
      buildProp('android-36.1', 'ro.build.version.sdk=36\n');
      folder('build-tools/36.0.0');
      expect(readAndroidSdkContents(sdk).latestPlatform, (
        name: 'android-36.1',
        level: 36,
      ));
    });

    test('build-tools entries are read by name, files too', () {
      folder('build-tools/35.0.0');
      folder('build-tools/latest');
      File(p.join(sdk, 'build-tools', '36.0.0'))
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      expect(readAndroidSdkContents(sdk).buildTools.map((v) => v.text), [
        '35.0.0',
        '36.0.0',
      ]);
    });

    test('a missing SDK folder reads as empty', () {
      final contents = readAndroidSdkContents(sdk);
      expect(contents.buildTools, isEmpty);
      expect(contents.platforms, isEmpty);
      expect(contents.latestPlatform, isNull);
      expect(contents.buildToolsForLatest, isNull);
    });
  });
}
