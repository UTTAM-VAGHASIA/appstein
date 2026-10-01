import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/flutter_fixtures.dart';
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

  // The test context's Flutter SDK (3.47.5) has no files under /sdk, so the
  // minimums come from the curated notes.
  const notesSource =
      "Flutter's minimums (Android SDK 36, build-tools 28.0.3) come from "
      "Appstein's curated notes for Flutter 3.47, because this Flutter SDK's "
      'files could not be read.';

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
    expect(result.details, ['Path: $sdk', pairing, notesSource]);
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

  test('a release and its preview tie, and the first one the file system '
      'lists wins, as in Flutter', () async {
    platform('android-37');
    buildTools('37.0.0-rc2');
    buildTools('37.0.0');
    final first = Directory(
      p.join(sdk, 'build-tools'),
    ).listSync().map((e) => p.basename(e.path)).first;
    expect((await run()).summary, 'platform android-37, build-tools $first');
  });

  test('build-tools names that are not full versions count, as in '
      'Flutter', () async {
    platform('android-36');
    buildTools('35.0');
    buildTools('36');
    buildTools('latest');
    expect((await run()).summary, 'platform android-36, build-tools 36');
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

  group("Flutter's minimum platform and build-tools", () {
    test('an older platform is an error, in the words flutter doctor '
        'uses', () async {
      platform('android-35');
      buildTools('35.0.0');
      final result = await run();
      expect(result.status, CheckStatus.error);
      expect(
        result.summary,
        'platform android-35, build-tools 35.0.0, older than Flutter requires',
      );
      expect(
        result.details,
        contains(
          'Flutter requires Android SDK 36 and the Android BuildTools 28.0.3.',
        ),
      );
      expect(result.details, contains(notesSource));
      // Only the failing part is named.
      expect(result.fixHint, contains('Platform 36'));
      expect(result.fixHint, contains('android-36'));
      expect(result.fixHint, isNot(contains('build-tools')));
    });

    test(
      'older build-tools are an error, and the hint names only them',
      () async {
        platform('android-36');
        buildTools('28.0.2');
        final result = await run();
        expect(result.status, CheckStatus.error);
        expect(result.fixHint, contains('build-tools 28.0.3 or newer'));
        expect(result.fixHint, contains('build-tools;<version>'));
        expect(result.fixHint, isNot(contains('Platform')));
        expect(result.fixHint, isNot(contains('platforms;')));
      },
    );

    test('both below minimum names both in the hint', () async {
      platform('android-35');
      buildTools('28.0.2');
      final hint = (await run()).fixHint!;
      expect(hint, contains('Platform 36'));
      expect(hint, contains('build-tools 28.0.3 or newer'));
    });

    test('says when the minimums come from the SDK files', () async {
      final flutter = p.join(tempDir().path, 'flutter');
      addToolchainFiles(flutter, '3.47.5');
      platform('android-36');
      buildTools('36.0.0');
      final result = await const AndroidSdkCheck().run(
        testContext(
          environment: fakeEnvironment({'ANDROID_HOME': sdk}),
          sdk: foundSdk(root: flutter),
        ),
      );
      expect(
        result.details,
        contains(
          "Flutter's minimums (Android SDK 36, build-tools 28.0.3) come from "
          "this Flutter SDK's gradle_utils.dart.",
        ),
      );
    });

    test("the minimums come from the detected Flutter SDK's own "
        'files', () async {
      final flutter = p.join(tempDir().path, 'flutter');
      addToolchainFiles(flutter, '3.47.5');
      final gradleUtils = File(
        p.joinAll([flutter, ...ToolchainFiles.gradleUtils.split('/')]),
      );
      gradleUtils.writeAsStringSync(
        gradleUtils.readAsStringSync().replaceFirst(
          'const compileSdkVersionInt = 36;',
          'const compileSdkVersionInt = 37;',
        ),
      );
      platform('android-36');
      buildTools('36.0.0');
      final result = await const AndroidSdkCheck().run(
        testContext(
          environment: fakeEnvironment({'ANDROID_HOME': sdk}),
          sdk: foundSdk(root: flutter),
        ),
      );
      expect(result.status, CheckStatus.error);
      expect(
        result.details,
        contains(
          'Flutter requires Android SDK 37 and the Android BuildTools 28.0.3.',
        ),
      );
    });

    test('unknown minimums skip this part of the check', () async {
      platform('android-30');
      buildTools('30.0.0');
      final result = await const AndroidSdkCheck().run(
        testContext(
          environment: fakeEnvironment({'ANDROID_HOME': sdk}),
          sdk: foundSdk(flutter: '3.38.6'),
        ),
      );
      expect(result.status, CheckStatus.ok);
    });
  });
}
