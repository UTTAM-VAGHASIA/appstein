import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  // An AOT binary can't read pubspec.yaml at run time, so the version is a
  // constant. This test keeps the two in step. Run it from the package folder.
  test('appsteinVersion matches pubspec.yaml', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    expect(appsteinVersion, pubspec['version']);
  });
}
