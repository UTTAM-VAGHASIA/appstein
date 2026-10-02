import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  late String root;

  setUp(() => root = tempDir().path);

  void write(String path, List<int> bytes) =>
      File(p.joinAll([root, ...path.split('/')]))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes);

  test('a missing file has no bytes, text or error, and hashes as missing', () {
    final file = readNativeFile(root, 'ios/Podfile');
    expect(file.exists, isFalse);
    expect(file.text, isNull);
    expect(file.error, isNull);
    expect(file.input, isA<MapEntry<String, List<int>?>>());
    expect(file.input.key, 'file:ios/Podfile');
    expect(file.input.value, isNull);
  });

  test('a byte order mark is dropped from the text but kept in the bytes', () {
    write('android/gradle.properties', [
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode('a=1\n'),
    ]);
    final file = readNativeFile(root, 'android/gradle.properties');
    expect(file.text, 'a=1\n');
    expect(file.bytes!.length, 7);
    expect(file.at(3), 'android/gradle.properties:3');
  });

  test('a file that is not UTF-8 exists, has bytes, and says why there is no '
      'text', () {
    write('ios/Runner/Info.plist', [0xFF, 0xFE, 0x00]);
    final file = readNativeFile(root, 'ios/Runner/Info.plist');
    expect(file.exists, isTrue);
    expect(file.text, isNull);
    expect(file.error, 'not valid UTF-8');
  });

  test('a folder where a file should be counts as missing', () {
    Directory(p.join(root, 'ios', 'Podfile')).createSync(recursive: true);
    expect(readNativeFile(root, 'ios/Podfile').exists, isFalse);
  });

  test('lineAt counts lines from 1, with CRLF or LF', () {
    const text = 'a\r\nb\nc';
    expect(lineAt(text, 0), 1);
    expect(lineAt(text, text.indexOf('b')), 2);
    expect(lineAt(text, text.indexOf('c')), 3);
  });

  test('loadPubspec gives the map with lines, or null when it is broken', () {
    write('pubspec.yaml', utf8.encode('name: app\nversion: 1.2.3+4\n'));
    final pubspec = loadPubspec(readNativeFile(root, 'pubspec.yaml'))!;
    expect(yamlLine(pubspec.nodes['version']!), 2);
    write('pubspec.yaml', utf8.encode('name: [\n'));
    expect(loadPubspec(readNativeFile(root, 'pubspec.yaml')), isNull);
    write('pubspec.yaml', utf8.encode('- a list\n'));
    expect(loadPubspec(readNativeFile(root, 'pubspec.yaml')), isNull);
  });
}
