import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  test('Windows keeps the settings in %APPDATA%\\.flutter_settings', () {
    final env = fakeEnvironment({'APPDATA': 'appdata'}, os: HostOs.windows);
    expect(flutterSettingsPath(env), p.join('appdata', '.flutter_settings'));
  });

  test('macOS and Linux use ~/.flutter_settings when it exists', () {
    final home = tempDir();
    File(p.join(home.path, '.flutter_settings')).writeAsStringSync('{}');
    final env = fakeEnvironment({'HOME': home.path}, os: HostOs.linux);
    expect(flutterSettingsPath(env), p.join(home.path, '.flutter_settings'));
  });

  test(
    r'otherwise $XDG_CONFIG_HOME/settings, then ~/.config/flutter/settings',
    () {
      final home = tempDir().path;
      expect(
        flutterSettingsPath(
          fakeEnvironment({
            'HOME': home,
            'XDG_CONFIG_HOME': 'xdg',
          }, os: HostOs.linux),
        ),
        p.join('xdg', 'settings'),
      );
      expect(
        flutterSettingsPath(fakeEnvironment({'HOME': home}, os: HostOs.linux)),
        p.join(home, '.config', 'flutter', 'settings'),
      );
    },
  );

  test('reads the JSON and treats a broken file as empty', () {
    final dir = tempDir();
    final vars = Platform.isWindows
        ? {'APPDATA': dir.path}
        : {'HOME': dir.path};
    final file = File(p.join(dir.path, '.flutter_settings'))
      ..writeAsStringSync('{"jdk-dir": "C:/jdk"}');
    expect(readFlutterSettings(fakeEnvironment(vars)), {'jdk-dir': 'C:/jdk'});
    file.writeAsStringSync('{broken');
    expect(readFlutterSettings(fakeEnvironment(vars)), isEmpty);
  });

  test('reads a settings file that starts with a UTF-8 BOM', () {
    final dir = tempDir();
    final vars = Platform.isWindows
        ? {'APPDATA': dir.path}
        : {'HOME': dir.path};
    File(
      p.join(dir.path, '.flutter_settings'),
    ).writeAsStringSync('\uFEFF{"jdk-dir": "C:/jdk"}');
    expect(readFlutterSettings(fakeEnvironment(vars)), {'jdk-dir': 'C:/jdk'});
  });
}
