import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/large_build.dart';

void main() {
  late Directory app;

  setUp(() {
    app = Directory.systemTemp.createTempSync('appstein large build ');
    addTearDown(() => app.deleteSync(recursive: true));
  });

  List<File> filesUnder(String folder) => Directory(
    p.join(app.path, folder),
  ).listSync(recursive: true).whereType<File>().toList();

  test('writes exactly the number of files asked, under build/', () {
    final dart = writeLargeBuild(app.path, files: 230);
    expect(filesUnder('build'), hasLength(230));
    // Nothing outside build/.
    expect(app.listSync().map((entry) => p.basename(entry.path)), ['build']);
    expect(dart, isPositive);
  });

  test('every 20th file is a Dart file by default, and the count it returns '
      'is the number written', () {
    final dart = writeLargeBuild(app.path, files: 100);
    final written = filesUnder(
      'build',
    ).where((file) => file.path.endsWith('.dart'));
    expect(written, hasLength(5));
    expect(dart, 5);
  });

  test('the Dart files are valid Dart', () {
    writeLargeBuild(app.path, files: 40, dartEvery: 10);
    final dartFiles = filesUnder(
      'build',
    ).where((file) => file.path.endsWith('.dart'));
    expect(dartFiles, hasLength(4));
    for (final file in dartFiles) {
      expect(
        file.readAsStringSync(),
        matches(RegExp(r'^const int \w+ = \d+;')),
      );
    }
  });

  test('the files are spread over nested folders, at most 50 in each', () {
    writeLargeBuild(app.path, files: 1200);
    final perFolder = <String, int>{};
    for (final file in filesUnder('build')) {
      perFolder.update(p.dirname(file.path), (n) => n + 1, ifAbsent: () => 1);
    }
    expect(perFolder.values.every((count) => count <= 50), isTrue);
    expect(perFolder.length, greaterThanOrEqualTo(24));
    final depth = p.split(p.relative(perFolder.keys.first, from: app.path));
    expect(depth.length, greaterThanOrEqualTo(3));
  });

  test('no folder or file name starts with a dot, since the analysis leaves '
      'those out', () {
    writeLargeBuild(app.path, files: 300);
    for (final file in filesUnder('build')) {
      final relative = p.split(p.relative(file.path, from: app.path));
      expect(relative.any((part) => part.startsWith('.')), isFalse);
    }
  });

  test('is a no-op for zero files', () {
    expect(writeLargeBuild(app.path, files: 0), 0);
    expect(Directory(p.join(app.path, 'build')).existsSync(), isFalse);
  });
}
