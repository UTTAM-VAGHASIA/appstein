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
    ).writeAsStringSync('﻿{"flutter": "3.47.5"}');
    expect(readFvmPin(dir.path)!.version, '3.47.5');
  });

  test('returns null without FVM and throws on a broken file', () {
    final dir = tempDir();
    expect(readFvmPin(dir.path), isNull);
    File(p.join(dir.path, '.fvmrc')).writeAsStringSync('{not json');
    expect(() => readFvmPin(dir.path), throwsA(isA<FormatException>()));
  });
}
