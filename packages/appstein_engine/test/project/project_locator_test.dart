import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  test('finds the nearest folder with pubspec.yaml above the start', () {
    final root = tempDir();
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: app');
    final nested = Directory(p.join(root.path, 'lib', 'ui'))
      ..createSync(recursive: true);
    expect(findProjectRoot(nested.path), root.path);
  });

  test('returns null when no folder above has a pubspec.yaml', () {
    expect(findProjectRoot(tempDir().path), isNull);
  });
}
