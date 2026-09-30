import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/temp.dart';

void main() {
  late String sdk;

  setUp(() {
    sdk = p.join(tempDir().path, 'android sdk');
    Directory(p.join(sdk, 'platform-tools')).createSync(recursive: true);
  });

  const pairing =
      'Flutter pairs the newest platform with the newest build-tools of the '
      'same major version, previews included, or else with the newest '
      'build-tools.';

  void buildTools(String version, {bool zipalign = true}) {
    final dir = Directory(p.join(sdk, 'build-tools', version))
      ..createSync(recursive: true);
    if (zipalign) {
      File(
        p.join(dir.path, Platform.isWindows ? 'zipalign.exe' : 'zipalign'),
      ).writeAsStringSync('');
    }
  }

  /// A folder in `platforms/`, with a `build.prop` giving [sdkLevel] when it
  /// is set, written with [newline] line endings.
  void platform(String name, {int? sdkLevel, String newline = '\n'}) {
    final dir = Directory(p.join(sdk, 'platforms', name))
      ..createSync(recursive: true);
    if (sdkLevel != null) {
      File(p.join(dir.path, 'build.prop')).writeAsStringSync(
        [
          '# begin build properties',
          'ro.build.version.release=$sdkLevel',
          'ro.build.version.sdk=$sdkLevel',
          '',
        ].join(newline),
      );
    }
  }

  Future<CheckResult> run() => const AndroidSdkCheck().run(
    testContext(environment: fakeEnvironment({'ANDROID_HOME': sdk})),
  );

  // The development machine on 2026-09-30. `flutter doctor -v` printed
  // "Platform android-37.0, build-tools 37.0.0-rc2".
  test('regression: the platform and build-tools flutter doctor -v '
      'reports', () async {
    for (final name in ['android-33', 'android-34', 'android-35']) {
      platform(name);
    }
    platform('android-36');
    platform('android-36.1', sdkLevel: 36);
    platform('android-37.0', sdkLevel: 37, newline: '\r\n');
    buildTools('35.0.0');
    buildTools('36.1.0');
    buildTools('37.0.0-rc2');
    final result = await run();
    expect(result.status, CheckStatus.ok);
    expect(result.summary, 'platform android-37.0, build-tools 37.0.0-rc2');
    expect(result.details, ['Path: $sdk', pairing]);
  });

  test("the build-tools match the platform's major version, or else the "
      'newest', () async {
    platform('android-34');
    platform('android-36');
    buildTools('34.0.0');
    buildTools('35.0.0');
    expect((await run()).summary, 'platform android-36, build-tools 35.0.0');
    buildTools('36.0.0');
    expect((await run()).summary, 'platform android-36, build-tools 36.0.0');
  });

  test('a release and its preview tie, and the release wins, as on NTFS '
      'and APFS', () async {
    platform('android-37');
    buildTools('37.0.0-rc2');
    buildTools('37.0.0');
    expect((await run()).summary, 'platform android-37, build-tools 37.0.0');
  });

  test('build-tools names that are not full versions count, as in '
      'Flutter', () async {
    platform('android-34');
    buildTools('33.0');
    buildTools('34');
    buildTools('latest');
    expect((await run()).summary, 'platform android-34, build-tools 34');
  });

  // Review Focus 1.
  test('a dotted platform without build.prop is ignored, and named', () async {
    platform('android-36');
    platform('android-37.0');
    buildTools('36.0.0');
    buildTools('37.0.0');
    final result = await run();
    expect(result.status, CheckStatus.ok);
    expect(result.summary, 'platform android-36, build-tools 36.0.0');
    expect(
      result.details,
      contains(
        'Flutter ignores these platform folders, because it finds no API '
        'level in them: android-37.0.',
      ),
    );
  });

  test('a build-tools entry that is a file is still picked, with a '
      'warning', () async {
    platform('android-38');
    buildTools('37.0.0');
    File(p.join(sdk, 'build-tools', '38.0.0')).writeAsStringSync('');
    final result = await run();
    expect(result.status, CheckStatus.warning);
    expect(
      result.summary,
      'platform android-38, build-tools 38.0.0, but with gaps',
    );
    expect(
      result.details,
      contains(
        'build-tools/38.0.0 is not a folder, but Flutter still picks it. '
        'Remove it, or reinstall build-tools 38.0.0.',
      ),
    );
  });

  test('warning when the paired build-tools has no zipalign', () async {
    platform('android-36');
    buildTools('36.1.0', zipalign: false);
    final result = await run();
    expect(result.status, CheckStatus.warning);
    expect(
      result.details,
      contains(
        'build-tools 36.1.0 has no zipalign, so the 16 KB page-size check '
        'will be skipped.',
      ),
    );
  });

  test('error without build-tools', () async {
    platform('android-36');
    final result = await run();
    expect(result.status, CheckStatus.error);
    expect(result.summary, 'The Android SDK has no build-tools.');
    expect(
      result.fixHint,
      'Install build-tools with `sdkmanager "build-tools;<version>"`, or in '
      'Android Studio (SDK Manager, SDK Tools tab).',
    );
  });

  test('error without a platform that has an API level', () async {
    platform('android-37.0');
    buildTools('36.0.0');
    final result = await run();
    expect(result.status, CheckStatus.error);
    expect(
      result.summary,
      "The Android SDK has no platforms, so Flutter can't build for Android.",
    );
    expect(
      result.fixHint,
      'Install a platform with `sdkmanager "platforms;android-<API level>"`, '
      'or in Android Studio (SDK Manager, SDK Platforms tab).',
    );
    expect(result.details.join('\n'), contains('android-37.0'));
  });

  test('error without any Android SDK', () async {
    final result = await const AndroidSdkCheck().run(
      testContext(environment: fakeEnvironment({})),
    );
    expect(result.status, CheckStatus.error);
    expect(result.fixHint, contains('ANDROID_HOME'));
  });

  group('more than one adb', () {
    /// Puts an `adb` program in the folder [dir]: `adb.exe` on Windows, an
    /// executable `adb` elsewhere. Returns its path.
    String placeAdb(String dir) {
      final file = File(p.join(dir, Platform.isWindows ? 'adb.exe' : 'adb'))
        ..createSync(recursive: true);
      if (!Platform.isWindows) Process.runSync('chmod', ['+x', file.path]);
      return file.path;
    }

    Future<CheckResult> runWithPath(String path) => const AndroidSdkCheck().run(
      testContext(
        environment: fakeEnvironment({
          'ANDROID_HOME': sdk,
          'PATH': path,
          'PATHEXT': defaultPathExt,
        }),
      ),
    );

    setUp(() {
      platform('android-36');
      buildTools('36.0.0');
    });

    test('lists every adb, and the status stays ok', () async {
      final sdkAdb = placeAdb(p.join(sdk, 'platform-tools'));
      final other = placeAdb(p.join(tempDir().path, 'other adb'));
      final result = await runWithPath(p.dirname(other));
      expect(result.status, CheckStatus.ok);
      expect(
        result.details,
        containsAllInOrder([
          'More than one adb was found. They can conflict, and devices may '
              'not be detected:',
          '- ${resolveLinks(sdkAdb)}',
          '- ${resolveLinks(other)}',
        ]),
      );
    });

    test("says nothing when the adb on PATH is the SDK's own", () async {
      placeAdb(p.join(sdk, 'platform-tools'));
      final result = await runWithPath(p.join(sdk, 'platform-tools'));
      expect(result.details.where((line) => line.contains('adb')), isEmpty);
    });
  });
}
