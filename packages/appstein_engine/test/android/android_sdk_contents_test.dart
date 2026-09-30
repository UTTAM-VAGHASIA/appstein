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
      // The order is the file system's, so only the contents are compared.
      expect(
        contents.platforms,
        unorderedEquals([
          (name: 'android-36', level: 36),
          (name: 'android-36.1', level: 36),
          (name: 'android-37.0', level: 37),
        ]),
      );
      expect(
        contents.ignoredPlatforms,
        unorderedEquals(['android-38.0', 'android-TiramisuPrivacySandbox']),
      );
    });

    test('the highest level is the newest platform', () {
      folder('platforms/android-36');
      buildProp('android-36.1', 'ro.build.version.sdk=36\n');
      folder('platforms/android-35');
      expect(readAndroidSdkContents(sdk).latestPlatform?.level, 36);
    });

    test('among platforms of one level, the last in listing order is the '
        'newest, as in Flutter', () {
      folder('platforms/android-36');
      buildProp('android-36.1', 'ro.build.version.sdk=36\n');
      // The order is the file system's: alphabetical on NTFS, not on APFS or
      // ext4. Read the real order to know which one Flutter takes.
      final listed = [
        for (final entry in Directory(p.join(sdk, 'platforms')).listSync())
          p.basename(entry.path),
      ];
      expect(listed, hasLength(2));
      expect(readAndroidSdkContents(sdk).latestPlatform, (
        name: listed.last,
        level: 36,
      ));
    });

    test('build-tools entries are read, files too', () {
      folder('build-tools/35.0.0');
      folder('build-tools/latest');
      File(p.join(sdk, 'build-tools', '36.0.0'))
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      expect(
        readAndroidSdkContents(sdk).buildTools.map((v) => v.text),
        unorderedEquals(['35.0.0', '36.0.0']),
      );
    });

    test('among build-tools of equal numbers, the first in listing order '
        'wins, as in Flutter', () {
      folder('platforms/android-37');
      folder('build-tools/37.0.0');
      folder('build-tools/37.0.0-rc2');
      final listed = [
        for (final entry in Directory(p.join(sdk, 'build-tools')).listSync())
          p.basename(entry.path),
      ];
      expect(listed, hasLength(2));
      expect(
        readAndroidSdkContents(sdk).buildToolsForLatest?.text,
        listed.first,
      );
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
