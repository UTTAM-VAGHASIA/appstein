import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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
}
