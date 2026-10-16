import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/src/analysis/disk_look.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

// `DiskLook` alone, with no server: which files a kept server is told.
void main() {
  late String work;
  late String root;

  setUp(() {
    work = tempDir().path;
    root = p.join(work, 'app');
  });

  File write(String path, String content) => File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);

  group('a Dart file that can\'t be read', () {
    test('is noted with why, keeps its time and size, and is told at the '
        'next look, also unchanged', () async {
      final locked = write(p.join(root, 'lib', 'locked.dart'), 'int a = 1;\n');
      final open = write(p.join(root, 'lib', 'open.dart'), 'int b = 1;\n');
      final long = DateTime.now().subtract(const Duration(minutes: 5));
      for (final file in [locked, open]) {
        file.setLastModifiedSync(long);
      }
      final held = locked.openSync(mode: FileMode.append)
        ..lockSync(FileLock.exclusive);
      addTearDown(() {
        try {
          held
            ..unlockSync()
            ..closeSync();
        } on FileSystemException {
          // Already let go.
        }
      });
      final earlier = await DiskLook.of(root);
      expect(earlier.unreadable.keys, [locked.path]);
      expect(earlier.unreadable[locked.path], isNotEmpty);
      expect(earlier.dart, contains(locked.path));
      held
        ..unlockSync()
        ..closeSync();
      final now = await DiskLook.of(root);
      expect(now.unreadable, isEmpty);
      expect(now.dartChangedSince(earlier), [locked.path]);
    });
  }, testOn: 'windows');

  test('a link to a folder (a junction on Windows) is followed, its files '
      'named through the link; a link back into a folder the walk is in is '
      'not', () async {
    final shared = p.join(work, 'shared');
    final behind = write(p.join(shared, 's.dart'), 'int s = 1;\n');
    write(p.join(root, 'lib', 'main.dart'), 'int m = 1;\n');
    Link(p.join(root, 'lib', 'linked')).createSync(shared);
    Link(p.join(root, 'lib', 'loop')).createSync(p.join(root, 'lib'));
    final first = await DiskLook.of(root);
    final throughLink = p.join(root, 'lib', 'linked', 's.dart');
    expect(first.dart, contains(throughLink));
    expect(
      first.dart.keys.where((path) => path.contains('${p.separator}loop')),
      isEmpty,
    );
    final stamp = behind.lastModifiedSync();
    behind.writeAsStringSync('int s = 22;\n');
    behind.setLastModifiedSync(stamp.add(const Duration(minutes: 1)));
    final now = await DiskLook.of(root);
    expect(now.dartChangedSince(first), contains(throughLink));
  });

  test('no more than openFilesAtOnce files are open at once, in the walk and '
      'in readWhole', () async {
    final files = [
      for (var i = 0; i < 300; i++)
        write(
          p.join(root, 'lib', 'f${i % 7}', 'file_$i.dart'),
          'int a$i = $i;\n',
        ).path,
    ];
    final look = await DiskLook.of(root);
    expect(look.dart, hasLength(300));
    expect(look.unreadable, isEmpty);
    expect(look.mostOpenAtOnce, lessThanOrEqualTo(openFilesAtOnce));
    // Many more were waiting: the bound is what held them back.
    expect(look.mostOpenAtOnce, greaterThan(1));
    await look.readWhole(files);
    expect(look.texts, hasLength(300));
    expect(look.texts[files.first], 'int a0 = 0;\n');
    expect(look.mostOpenAtOnce, lessThanOrEqualTo(openFilesAtOnce));
  });

  test('a file whose name starts with a dot is left out, as the server '
      'leaves it out; a link from lib/ to the project lists what is outside '
      'lib/ again and skips lib/ under it, as the server does', () async {
    write(p.join(root, 'lib', '.dotted.dart'), 'int d = 1;\n');
    write(p.join(root, 'lib', 'main.dart'), 'int m = 1;\n');
    write(p.join(root, 'bin', 'tool.dart'), 'void main() {}\n');
    Link(p.join(root, 'lib', 'up')).createSync(root);
    final look = await DiskLook.of(root);
    String rel(String path) => p.split(p.relative(path, from: root)).join('/');
    expect(
      look.dart.keys.map(rel),
      unorderedEquals([
        'lib/main.dart',
        'bin/tool.dart',
        'lib/up/bin/tool.dart',
      ]),
    );
  });

  test('a link to a Dart file is a Dart file of the project, by the link\'s '
      'name', () async {
    final target = write(p.join(work, 'outside', 't.dart'), 'int t = 1;\n');
    final link = Link(p.join(root, 'lib', 'linked.dart'));
    try {
      link
        ..parent.createSync(recursive: true)
        ..createSync(target.path);
    } on FileSystemException catch (error) {
      // Windows lets only an administrator, or developer mode, make one.
      markTestSkipped('No file link could be made here: ${error.message}');
      return;
    }
    final first = await DiskLook.of(root);
    expect(first.dart, contains(link.path));
    target.writeAsStringSync('int t = 22;\n');
    target.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
    final now = await DiskLook.of(root);
    expect(now.dartChangedSince(first), contains(link.path));
  });

  group('a lock that does not cover the first byte', () {
    test('the walk reads one byte and misses it; readWhole finds it, and '
        'takes it back once the lock is gone', () async {
      final locked = write(
        p.join(root, 'lib', 'locked.dart'),
        'int a = 1;\nint b = 2;\n',
      );
      final held = locked.openSync(mode: FileMode.append)
        ..lockSync(FileLock.exclusive, 5);
      addTearDown(() {
        try {
          held
            ..unlockSync(5)
            ..closeSync();
        } on FileSystemException {
          // Already let go.
        }
      });
      final look = await DiskLook.of(root);
      expect(look.unreadable, isEmpty);
      await look.readWhole([locked.path]);
      expect(look.unreadable.keys, [locked.path]);
      held
        ..unlockSync(5)
        ..closeSync();
      await look.readWhole([locked.path]);
      expect(look.unreadable, isEmpty);
    });
  }, testOn: 'windows');

  group('the rule for a file written close to the last look', () {
    test('a file whose size and time are the same as at the last look is '
        'told again while its time is within diskClockStep of that look, '
        'and not when it is older', () async {
      final close = write(p.join(root, 'lib', 'close.dart'), 'int a = 12;\n');
      final old = write(p.join(root, 'lib', 'old.dart'), 'int b = 12;\n');
      final first = await DiskLook.of(root);
      // Times put as they would be after the first look's writes: one
      // within the step before the look, one well before it.
      close.setLastModifiedSync(first.at.subtract(diskClockStep ~/ 2));
      old.setLastModifiedSync(first.at.subtract(diskClockStep * 5));
      final earlier = await DiskLook.of(root);
      // Nothing changes between this look and the next: same size, same
      // time. The text of `close.dart` changes to the same size, and its
      // time is put back.
      final stamp = close.lastModifiedSync();
      close.writeAsStringSync('int a = "";\n');
      close.setLastModifiedSync(stamp);
      expect(close.lengthSync(), 12);
      final now = await DiskLook.of(root);
      expect(now.dart[close.path], earlier.dart[close.path]);
      expect(now.dart[old.path], earlier.dart[old.path]);

      final told = now.dartChangedSince(earlier);
      expect(told, contains(close.path));
      expect(told, isNot(contains(old.path)));
    });

    test('a file changed, a new one and a deleted one are told; one that '
        'did not change and is old is not', () async {
      final kept = write(p.join(root, 'lib', 'kept.dart'), 'int a = 1;\n');
      final changed = write(p.join(root, 'lib', 'changed.dart'), 'int b;\n');
      final gone = write(p.join(root, 'lib', 'gone.dart'), 'int c;\n');
      final long = DateTime.now().subtract(const Duration(minutes: 5));
      for (final file in [kept, changed, gone]) {
        file.setLastModifiedSync(long);
      }
      final earlier = await DiskLook.of(root);
      changed.writeAsStringSync('int b = 22;\n');
      final added = write(p.join(root, 'lib', 'added.dart'), 'int d;\n');
      gone.deleteSync();
      final told = (await DiskLook.of(root)).dartChangedSince(earlier);
      expect(told, [added.path, changed.path, gone.path]..sort());
    });
  });

  group('the packages', () {
    void config(List<({String name, String rootUri})> packages) => write(
      p.join(root, '.dart_tool', 'package_config.json'),
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (final package in packages)
            {
              'name': package.name,
              'rootUri': package.rootUri,
              'packageUri': 'lib/',
            },
        ],
      }),
    );

    test('a package at a relative or an absolute location outside the '
        'unchanging folders is looked at; one inside them is not', () async {
      final relative = p.join(work, 'near');
      final absolute = p.join(work, 'far away');
      final cache = p.join(work, 'cache');
      final sdk = p.join(work, 'sdk');
      for (final folder in [relative, absolute, cache, sdk]) {
        write(p.join(folder, 'lib', 'x.dart'), 'int x = 1;\n');
      }
      write(p.join(root, 'lib', 'main.dart'), 'void main() {}\n');
      config([
        (name: 'app', rootUri: '../'),
        (name: 'near', rootUri: '../../near'),
        (name: 'far', rootUri: Uri.directory(absolute).toString()),
        (name: 'cached', rootUri: Uri.directory(cache).toString()),
        (name: 'sdk', rootUri: Uri.directory(sdk).toString()),
      ]);
      final look = await DiskLook.of(root, unchanging: [cache, sdk]);
      expect(look.dart.keys, {
        p.join(root, 'lib', 'main.dart'),
        p.join(relative, 'lib', 'x.dart'),
        p.join(absolute, 'lib', 'x.dart'),
      });
    });

    test('the unchanging folders are pub\'s cache and the SDK that runs the '
        'analysis, with the Flutter SDK around it', () {
      final flutter = p.join(work, 'flutter');
      final dart = p.join(
        flutter,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      );
      final withPubCache = unchangingFolders(dart, {
        'PUB_CACHE': p.join(work, 'my cache'),
        'LOCALAPPDATA': p.join(work, 'local'),
        'HOME': p.join(work, 'home'),
      });
      expect(withPubCache, [
        p.join(flutter, 'bin', 'cache', 'dart-sdk'),
        flutter,
        p.join(work, 'my cache'),
      ]);
      final byDefault = unchangingFolders(dart, {
        'LOCALAPPDATA': p.join(work, 'local'),
        'APPDATA': p.join(work, 'roaming'),
        'HOME': p.join(work, 'home'),
      });
      expect(
        byDefault.skip(2),
        Platform.isWindows
            ? [
                p.join(work, 'local', 'Pub', 'Cache'),
                p.join(work, 'roaming', 'Pub', 'Cache'),
              ]
            : [p.join(work, 'home', '.pub-cache')],
      );
      // A Dart SDK on its own has no Flutter SDK around it.
      final plain = p.join(work, 'dart-sdk', 'bin', 'dart');
      expect(unchangingFolders(plain, const {}), [p.join(work, 'dart-sdk')]);
    });
  });
}
