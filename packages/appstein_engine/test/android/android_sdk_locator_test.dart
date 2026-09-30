import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

String fakeAndroidSdk(String root) {
  Directory(p.join(root, 'platform-tools')).createSync(recursive: true);
  return root;
}

void main() {
  test('the settings value wins over ANDROID_HOME', () {
    final a = fakeAndroidSdk(p.join(tempDir().path, 'a'));
    final b = fakeAndroidSdk(p.join(tempDir().path, 'b'));
    expect(
      locateAndroidSdk(fakeEnvironment({'ANDROID_HOME': b}), {
        'android-sdk': a,
      }),
      a,
    );
  });

  test('ANDROID_HOME, then ANDROID_SDK_ROOT', () {
    final a = fakeAndroidSdk(p.join(tempDir().path, 'a'));
    expect(locateAndroidSdk(fakeEnvironment({'ANDROID_HOME': a}), {}), a);
    expect(locateAndroidSdk(fakeEnvironment({'ANDROID_SDK_ROOT': a}), {}), a);
  });

  test('falls back to the default folder under the home folder', () {
    final home = tempDir().path;
    final defaultPath = switch (HostOs.current) {
      HostOs.windows => p.join(home, 'AppData', 'Local', 'Android', 'sdk'),
      HostOs.macos => p.join(home, 'Library', 'Android', 'sdk'),
      HostOs.linux => p.join(home, 'Android', 'Sdk'),
    };
    fakeAndroidSdk(defaultPath);
    final vars = Platform.isWindows ? {'USERPROFILE': home} : {'HOME': home};
    expect(locateAndroidSdk(fakeEnvironment(vars), {}), defaultPath);
  });

  test('a folder without licenses or platform-tools is not an SDK', () {
    final empty = tempDir().path;
    expect(
      locateAndroidSdk(fakeEnvironment({'ANDROID_HOME': empty}), {}),
      isNull,
    );
  });

  group('the PATH fallback, when the chosen folder is not an SDK', () {
    final separator = Platform.isWindows ? ';' : ':';

    test('every aapt on PATH, with the SDK three folders up', () {
      final root = tempDir();
      final elsewhere = Directory(p.join(root.path, 'other', 'bin', 'x'))
        ..createSync(recursive: true);
      fakeExecutable(elsewhere, 'aapt');
      final sdk = fakeAndroidSdk(p.join(root.path, 'real sdk'));
      final tools = Directory(p.join(sdk, 'build-tools', '36.0.0'))
        ..createSync(recursive: true);
      fakeExecutable(tools, 'aapt');
      final env = fakeEnvironment({
        'ANDROID_HOME': p.join(root.path, 'no sdk here'),
        'PATH': [elsewhere.path, tools.path].join(separator),
        'PATHEXT': defaultPathExt,
      });
      expect(p.equals(locateAndroidSdk(env, {})!, resolveLinks(sdk)), isTrue);
    });

    test('then every adb on PATH, with the SDK two folders up, skipping '
        'shims', () {
      final root = tempDir();
      final shims = Directory(p.join(root.path, 'shims', 'bin'))
        ..createSync(recursive: true);
      fakeExecutable(shims, 'adb');
      final sdk = fakeAndroidSdk(p.join(root.path, 'real sdk'));
      fakeExecutable(Directory(p.join(sdk, 'platform-tools')), 'adb');
      final env = fakeEnvironment({
        'ANDROID_HOME': p.join(root.path, 'no sdk here'),
        'PATH': [shims.path, p.join(sdk, 'platform-tools')].join(separator),
        'PATHEXT': defaultPathExt,
      });
      expect(p.equals(locateAndroidSdk(env, {})!, resolveLinks(sdk)), isTrue);
    });

    test('aapt comes before adb, whatever the PATH order', () {
      final root = tempDir();
      final viaAapt = fakeAndroidSdk(p.join(root.path, 'sdk a'));
      final tools = Directory(p.join(viaAapt, 'build-tools', '36.0.0'))
        ..createSync(recursive: true);
      fakeExecutable(tools, 'aapt');
      final viaAdb = fakeAndroidSdk(p.join(root.path, 'sdk b'));
      fakeExecutable(Directory(p.join(viaAdb, 'platform-tools')), 'adb');
      final env = fakeEnvironment({
        'PATH': [p.join(viaAdb, 'platform-tools'), tools.path].join(separator),
        'PATHEXT': defaultPathExt,
      });
      expect(
        p.equals(locateAndroidSdk(env, {})!, resolveLinks(viaAapt)),
        isTrue,
      );
    });
  });
}
