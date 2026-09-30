import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_sdk.dart';
import '../support/temp.dart';

void main() {
  test('reads .fvmrc (FVM 3)', () {
    final dir = tempDir();
    File(p.join(dir.path, '.fvmrc')).writeAsStringSync('{"flutter": "3.47.5"}');
    expect(readFvmPin(dir.path)!.version, '3.47.5');
  });

  test('reads .fvm/fvm_config.json (FVM 2)', () {
    final dir = tempDir();
    File(p.join(dir.path, '.fvm', 'fvm_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"flutterSdkVersion": "3.44.0"}');
    expect(readFvmPin(dir.path)!.version, '3.44.0');
  });

  test('reads a .fvmrc that starts with a byte order mark', () {
    final dir = tempDir();
    File(
      p.join(dir.path, '.fvmrc'),
    ).writeAsStringSync('\uFEFF{"flutter": "3.47.5"}');
    expect(readFvmPin(dir.path)!.version, '3.47.5');
  });

  test('the pin records the folder it was found in', () {
    final dir = tempDir();
    File(p.join(dir.path, '.fvmrc')).writeAsStringSync('{"flutter": "3.47.5"}');
    expect(readFvmPin(dir.path)!.pinDirectory, dir.path);
  });

  test('walks up to a parent folder, as FVM does', () {
    final root = tempDir();
    File(
      p.join(root.path, '.fvmrc'),
    ).writeAsStringSync('{"flutter": "3.47.5"}');
    final member = p.join(root.path, 'packages', 'my app');
    Directory(member).createSync(recursive: true);
    final pin = readFvmPin(member)!;
    expect(pin.version, '3.47.5');
    expect(pin.pinDirectory, root.path);
    expect(pin.configPath, p.join(root.path, '.fvmrc'));
  });

  test('the nearest pin wins over one further up', () {
    final root = tempDir();
    File(
      p.join(root.path, '.fvmrc'),
    ).writeAsStringSync('{"flutter": "3.44.0"}');
    final middle = p.join(root.path, 'packages');
    Directory(middle).createSync();
    File(p.join(middle, '.fvmrc')).writeAsStringSync('{"flutter": "3.47.5"}');
    final member = p.join(middle, 'app');
    Directory(member).createSync();
    expect(readFvmPin(member)!.version, '3.47.5');
    expect(readFvmPin(member)!.pinDirectory, middle);
  });

  test('a legacy config in a parent folder is found too', () {
    final root = tempDir();
    File(p.join(root.path, '.fvm', 'fvm_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"flutterSdkVersion": "3.44.0"}');
    final member = p.join(root.path, 'app');
    Directory(member).createSync();
    expect(readFvmPin(member)!.version, '3.44.0');
    expect(readFvmPin(member)!.pinDirectory, root.path);
  });

  test('returns null when no folder up to the root has a pin', () {
    // The temp folder has no FVM pin above it on a normal machine.
    expect(readFvmPin(tempDir().path), isNull);
  });

  test('throws on a broken file', () {
    final dir = tempDir();
    File(p.join(dir.path, '.fvmrc')).writeAsStringSync('{not json');
    expect(() => readFvmPin(dir.path), throwsA(isA<FormatException>()));
  });

  group('what a pin names', () {
    test('a channel', () {
      for (final channel in ['stable', 'beta', 'dev', 'master', 'main']) {
        expect(fvmPinChannel(channel), channel);
        expect(fvmPinVersion(channel), isNull);
        expect(describeFvmPin(channel), 'the Flutter $channel channel');
        expect(
          fvmInstallHint(channel),
          'Run `fvm install $channel` or `fvm use $channel` in the project '
          'folder.',
        );
      }
    });

    test('a version on a channel', () {
      expect(fvmPinChannel('3.24.0@beta'), 'beta');
      expect(fvmPinVersion('3.24.0@beta'), '3.24.0');
      expect(
        describeFvmPin('3.24.0@beta'),
        'Flutter 3.24.0 on the beta channel',
      );
      expect(
        fvmInstallHint('3.24.0@beta'),
        'Run `fvm install 3.24.0@beta` in the project folder.',
      );
    });

    test('a version, a git ref, or a text FVM would reject', () {
      for (final pin in ['3.47.5', 'f4c9b2a1e0', '3.24.0@nightly']) {
        expect(fvmPinChannel(pin), isNull);
        expect(fvmPinVersion(pin), pin);
        expect(describeFvmPin(pin), 'Flutter $pin');
        expect(
          fvmInstallHint(pin),
          'Run `fvm install $pin` in the project folder.',
        );
      }
    });
  });

  test('reads cachePath from the pin file, relative to its folder', () {
    final dir = tempDir();
    File(
      p.join(dir.path, '.fvmrc'),
    ).writeAsStringSync('{"flutter": "3.47.5", "cachePath": "my cache"}');
    expect(readFvmPin(dir.path)!.cachePath, p.join(dir.path, 'my cache'));
  });

  test('keeps an absolute cachePath, and ignores an empty one', () {
    final dir = tempDir();
    final absolute = p.join(tempDir().path, 'cache');
    File(p.join(dir.path, '.fvmrc')).writeAsStringSync(
      jsonEncode({'flutter': '3.47.5', 'cachePath': absolute}),
    );
    expect(readFvmPin(dir.path)!.cachePath, absolute);
    File(
      p.join(dir.path, '.fvmrc'),
    ).writeAsStringSync('{"flutter": "3.47.5", "cachePath": ""}');
    expect(readFvmPin(dir.path)!.cachePath, isNull);
  });

  group("FVM's global settings", () {
    test('live where FVM keeps them on each OS', () {
      expect(
        fvmGlobalConfigPath(
          fakeEnvironment({'APPDATA': 'roaming'}, os: HostOs.windows),
        ),
        p.join('roaming', 'fvm', '.fvmrc'),
      );
      expect(
        fvmGlobalConfigPath(fakeEnvironment({'HOME': 'me'}, os: HostOs.macos)),
        p.join('me', 'Library', 'Application Support', 'fvm', '.fvmrc'),
      );
      expect(
        fvmGlobalConfigPath(fakeEnvironment({'HOME': 'me'}, os: HostOs.linux)),
        p.join('me', '.config', 'fvm', '.fvmrc'),
      );
      expect(
        fvmGlobalConfigPath(
          fakeEnvironment({
            'HOME': 'me',
            'XDG_CONFIG_HOME': 'xdg',
          }, os: HostOs.linux),
        ),
        p.join('xdg', 'fvm', '.fvmrc'),
      );
      expect(
        fvmGlobalConfigPath(fakeEnvironment({}, os: HostOs.windows)),
        isNull,
      );
    });

    test('are read for cachePath; a missing file is null', () {
      final home = tempDir().path;
      final environment = fakeEnvironment(fvmHomeVars(home));
      expect(readFvmGlobalConfig(environment), isNull);
      File(fvmSettingsFile(home))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"cachePath": "D:/fvm cache"}');
      final config = readFvmGlobalConfig(environment)!;
      expect(config.path, fvmSettingsFile(home));
      expect(config.cachePath, 'D:/fvm cache');
      expect(config.problem, isNull);
    });

    test('that are not JSON give a problem, not an exception', () {
      final home = tempDir().path;
      File(fvmSettingsFile(home))
        ..createSync(recursive: true)
        ..writeAsStringSync('{oops');
      final config = readFvmGlobalConfig(fakeEnvironment(fvmHomeVars(home)))!;
      expect(config.cachePath, isNull);
      expect(
        config.problem,
        startsWith('${fvmSettingsFile(home)} is not valid JSON: '),
      );
    });
  });

  test("fvmCacheFolder: the pin file, FVM_CACHE_PATH, FVM_HOME, FVM's "
      'global settings, then ~/fvm', () {
    final home = tempDir().path;
    final globalCache = p.join(home, 'global cache');
    File(fvmSettingsFile(home))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'cachePath': globalCache}));
    FvmPin pinWith([String? cachePath]) => FvmPin(
      version: '3.47.5',
      configPath: p.join(home, '.fvmrc'),
      pinDirectory: home,
      cachePath: cachePath,
    );
    String? folder(FvmPin pin, Map<String, String> vars) =>
        fvmCacheFolder(pin, fakeEnvironment({...fvmHomeVars(home), ...vars}));
    const both = {'FVM_CACHE_PATH': 'env cache', 'FVM_HOME': 'fvm home'};
    expect(folder(pinWith('pin cache'), both), 'pin cache');
    expect(folder(pinWith(), both), 'env cache');
    expect(folder(pinWith(), {'FVM_HOME': 'fvm home'}), 'fvm home');
    expect(folder(pinWith(), {}), globalCache);
    File(fvmSettingsFile(home)).deleteSync();
    expect(folder(pinWith(), {}), p.join(home, 'fvm'));
  });
}
