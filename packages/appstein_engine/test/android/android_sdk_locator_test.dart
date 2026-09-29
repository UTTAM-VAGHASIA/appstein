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
}
