import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/src/analysis/disk_look.dart' show diskClockStep;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

// `readDartFileHashes` alone: the scan the refresh makes for the unverified
// files (slice 1d.2, ticket 06).
void main() {
  late String root;

  setUp(() => root = p.join(tempDir().path, 'app'));

  File write(String relative, String text) =>
      File(p.joinAll([root, ...relative.split('/')]))
        ..createSync(recursive: true)
        ..writeAsStringSync(text);

  final long = DateTime.now().subtract(const Duration(minutes: 5));

  group('a file is read again only when it may have changed', () {
    test('an unchanged file keeps its hash without being read; a file whose '
        'time or size changed is read', () async {
      final a = write('bin/a.dart', 'int a = 1;\n')..setLastModifiedSync(long);
      final b = write('bin/b.dart', 'int b = 1;\n')..setLastModifiedSync(long);
      final first = await readDartFileHashes(root);
      expect(first.read, 2);
      expect(first.stamps.keys, unorderedEquals(['bin/a.dart', 'bin/b.dart']));

      var again = await readDartFileHashes(root, previous: first);
      expect(again.read, 0);
      expect(again.hashes, first.hashes);

      // Same size, new time: read again, same hash.
      a.setLastModifiedSync(long.add(const Duration(minutes: 1)));
      // New text and size.
      b.writeAsStringSync('int b = 22;\n');
      b.setLastModifiedSync(long);
      again = await readDartFileHashes(root, previous: first);
      expect(again.read, 2);
      expect(again.hashes['bin/a.dart'], first.hashes['bin/a.dart']);
      expect(again.hashes['bin/b.dart'], isNot(first.hashes['bin/b.dart']));
    });

    test('a file whose time lies within diskClockStep of the last scan is '
        'read again, though its time and size are the same', () async {
      final close = write('bin/close.dart', 'int a = 1;\n');
      final first = await readDartFileHashes(root);
      close.setLastModifiedSync(first.at.subtract(diskClockStep ~/ 2));
      final stamped = await readDartFileHashes(root, previous: first);
      expect(stamped.read, 1);
      // Same time, same size, other text: seen because of the rule.
      final stamp = close.lastModifiedSync();
      close.writeAsStringSync('int a = 2;\n');
      close.setLastModifiedSync(stamp);
      final again = await readDartFileHashes(root, previous: stamped);
      expect(again.read, 1);
      expect(
        again.hashes['bin/close.dart'],
        isNot(stamped.hashes['bin/close.dart']),
      );
    });

    test(
      'a file the map\'s inputs hashed is neither read nor stamped',
      () async {
        write('lib/main.dart', 'int m = 1;\n');
        final scan = await readDartFileHashes(
          root,
          known: {'project:lib/main.dart': 'from the map'},
        );
        expect(scan.read, 0);
        expect(scan.hashes, {'lib/main.dart': 'from the map'});
        expect(scan.stamps, isEmpty);
      },
    );
  });

  test('a link from lib/ to the project lists what is outside lib/ a second '
      'time and skips lib/ under it, as the analysis server does (checked '
      'with a junction on Windows)', () async {
    write('lib/main.dart', 'int m = 1;\n');
    write('bin/tool.dart', 'void main() {}\n');
    Link(p.join(root, 'lib', 'up')).createSync(root);
    final scan = await readDartFileHashes(root);
    expect(
      scan.hashes.keys,
      unorderedEquals([
        'lib/main.dart',
        'bin/tool.dart',
        'lib/up/bin/tool.dart',
      ]),
    );
  });

  test('a file whose name starts with a dot is left out, as the server '
      'leaves it out', () async {
    write('lib/.dotted.dart', 'int d = 1;\n');
    write('lib/main.dart', 'int m = 1;\n');
    final scan = await readDartFileHashes(root);
    expect(scan.hashes.keys, ['lib/main.dart']);
  });
}
