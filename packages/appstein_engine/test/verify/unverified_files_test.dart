import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

// `resolveVerifyFiles` and `UnverifiedFiles` alone (slice 1d.2, ticket 06).
void main() {
  late String root;

  setUp(() {
    root = p.join(tempDir().path, 'my app');
    for (final file in [
      'lib/Home.dart',
      'lib/ui/a.dart',
      'lib/ui/deep/b.dart',
      'lib/ui/notes.txt',
      'lib/ui/.hidden/c.dart',
    ]) {
      File(p.joinAll([root, ...file.split('/')]))
        ..createSync(recursive: true)
        ..writeAsStringSync('int a = 1;\n');
    }
  });

  test('a folder stands for the Dart files under it, dot folders left '
      'out', () {
    expect(resolveVerifyFiles(root, ['lib/ui']), [
      'lib/ui/a.dart',
      'lib/ui/deep/b.dart',
    ]);
    expect(resolveVerifyFiles(root, [p.join(root, 'lib', 'ui', 'deep')]), [
      'lib/ui/deep/b.dart',
    ]);
  });

  test('a path in another letter case is named as the file is on disk, '
      'once', () {
    expect(resolveVerifyFiles(root, ['LIB/home.DART', 'lib/Home.dart']), [
      'lib/Home.dart',
    ]);
    expect(resolveVerifyFiles(root, ['LIB/UI']), [
      'lib/ui/a.dart',
      'lib/ui/deep/b.dart',
    ]);
  }, testOn: 'windows || mac-os');

  test('a deleted file and a file that is not Dart are kept as given', () {
    expect(resolveVerifyFiles(root, ['lib/gone.dart', 'lib/ui/notes.txt']), [
      'lib/gone.dart',
      'lib/ui/notes.txt',
    ]);
  });

  test('one entry per file where names do not depend on letter case', () {
    final files = UnverifiedFiles(['lib/Home.dart', 'lib/home.dart', 'b.dart']);
    expect(files.files, ['b.dart', 'lib/Home.dart']);
    expect(files.contains('LIB/HOME.DART'), isTrue);
  }, testOn: 'windows || mac-os');
}
