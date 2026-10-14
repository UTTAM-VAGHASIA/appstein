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
