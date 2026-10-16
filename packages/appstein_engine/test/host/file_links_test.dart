import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  group('pathFromRoot', () {
    final root = p.absolute('project');
    final real = p.absolute('real', 'project');

    test('a path under the root, with `/`', () {
      expect(
        pathFromRoot(p.join(root, 'test', 'a_test.dart'), root),
        'test/a_test.dart',
      );
    });

    test('a relative path is taken from the root', () {
      expect(
        pathFromRoot(p.join('test', 'a_test.dart'), root),
        'test/a_test.dart',
      );
    });

    test('a path under the real location of the root is inside too', () {
      expect(
        pathFromRoot(
          p.join(real, 'test', 'my folder', 'a_test.dart'),
          root,
          realRoot: real,
        ),
        'test/my folder/a_test.dart',
      );
    });

    test('outside both: null', () {
      expect(
        pathFromRoot(p.absolute('elsewhere', 'a.dart'), root, realRoot: real),
        isNull,
      );
      expect(pathFromRoot(p.join(real, 'a.dart'), root), isNull);
    });

    // macOS: the root `/var/…/app` is the end of its real form
    // `/private/var/…/app`.
    test('a root that is part of its real location: a path under either is '
        'named from the root', () {
      final root = p.absolute('var', 'app');
      final real = p.absolute('private', 'var', 'app');
      for (final under in [root, real]) {
        expect(
          pathFromRoot(p.join(under, 'test', 'a.dart'), root, realRoot: real),
          'test/a.dart',
        );
      }
    });
  });

  group('withoutFolders', () {
    // On macOS the root `/var/…/app` is a part of its real form
    // `/private/var/…/app`: taking the root out first left `/private`.
    test('a folder that is a part of the other: each path loses the whole '
        'folder, in either order', () {
      const root = '/var/folders/ab/T/app';
      const real = '/private/var/folders/ab/T/app';
      const text =
          'Failed at /private/var/folders/ab/T/app/test/fixtures/a.json, '
          'file:///private/var/folders/ab/T/app/test/a_test.dart and '
          '/var/folders/ab/T/app/lib/b.dart';
      const expected =
          'Failed at test/fixtures/a.json, test/a_test.dart and lib/b.dart';
      expect(withoutFolders(text, [root, real]), expected);
      expect(withoutFolders(text, [real, root]), expected);
    });

    test('a Windows folder, with `\\` or `/`', () {
      expect(
        withoutFolders(r'see C:/my app/test/a.dart', [r'C:\my app']),
        'see test/a.dart',
      );
    }, testOn: 'windows');
  });

  group('realFolder', () {
    test('a folder reached through a link (a junction on Windows): where it '
        'really is', () {
      final folder = Directory(p.join(tempDir().path, 'real app'))
        ..createSync();
      final linked = p.join(tempDir().path, 'linked app');
      Link(linked).createSync(folder.path);
      expect(
        p.equals(realFolder(linked)!, folder.resolveSymbolicLinksSync()),
        isTrue,
      );
    });

    // As on macOS, where `/var` is a link to `/private/var`: the link's path
    // is the end of the real one.
    test('a link whose path is a part of its real location: where it really '
        'is', () {
      final tmp = Directory(tempDir().path).resolveSymbolicLinksSync();
      final linked = p.join(tmp, 'a', 'app');
      final real = Directory('${p.join(tmp, 'p')}$linked')
        ..createSync(recursive: true);
      Directory(p.dirname(linked)).createSync();
      Link(linked).createSync(real.path);
      expect(realFolder(linked), real.path);
      expect(realFolder(linked)!.endsWith(linked), isTrue);
    }, testOn: '!windows');

    test('a folder that is where it says, or does not exist: null', () {
      final folder = Directory(tempDir().path).resolveSymbolicLinksSync();
      expect(realFolder(folder), isNull);
      expect(realFolder(p.join(folder, 'missing')), isNull);
    });
  });
}
