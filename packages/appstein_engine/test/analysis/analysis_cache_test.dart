import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  group('analysisCacheFolder, the SDK\'s rule', () {
    late String home;

    setUp(() => home = tempDir().path);

    String? folder(Map<String, String> variables, {HostOs? os}) =>
        analysisCacheFolder(fakeEnvironment(variables, os: os));

    test('the override, when it is set', () {
      final override = p.join(home, 'my cache');
      expect(
        folder({analysisCacheVariable: override, 'LOCALAPPDATA': home}),
        override,
      );
      expect(folder({analysisCacheVariable: override, 'HOME': home}), override);
    });

    test('a relative override is taken from the current folder', () {
      expect(
        folder({analysisCacheVariable: 'cache'}),
        p.join(Directory.current.path, 'cache'),
      );
    });

    test('an empty override is set, so the default does not apply, and the '
        'folder can\'t be told', () {
      expect(folder({analysisCacheVariable: '', 'LOCALAPPDATA': home}), isNull);
      expect(folder({analysisCacheVariable: '', 'HOME': home}), isNull);
    });

    test('otherwise .dartServer in LOCALAPPDATA on Windows, and in HOME '
        'elsewhere', () {
      expect(
        folder({'LOCALAPPDATA': home, 'HOME': 'unused'}, os: HostOs.windows),
        p.join(home, '.dartServer'),
      );
      for (final os in [HostOs.linux, HostOs.macos]) {
        expect(
          folder({'HOME': home, 'LOCALAPPDATA': 'unused'}, os: os),
          p.join(home, '.dartServer'),
        );
      }
    });

    test('none when that folder is unset or does not exist', () {
      expect(folder({}, os: HostOs.windows), isNull);
      expect(folder({}, os: HostOs.linux), isNull);
      final missing = p.join(home, 'no such folder');
      expect(folder({'LOCALAPPDATA': missing}, os: HostOs.windows), isNull);
      expect(folder({'HOME': missing}, os: HostOs.linux), isNull);
    });

    test('on Windows a name matches in any case', () {
      final override = p.join(home, 'my cache');
      expect(
        folder({
          analysisCacheVariable.toLowerCase(): override,
        }, os: HostOs.windows),
        override,
      );
      expect(
        folder({'LocalAppData': home}, os: HostOs.windows),
        p.join(home, '.dartServer'),
      );
      expect(
        folder({
          analysisCacheVariable.toLowerCase(): override,
        }, os: HostOs.linux),
        isNull,
      );
    });
  });

  test('analysisServerEnvironment passes the override on, when the machine '
      'sets it', () {
    expect(
      analysisServerEnvironment(
        fakeEnvironment({analysisCacheVariable: 'here', 'PATH': 'x'}),
      ),
      {analysisCacheVariable: 'here'},
    );
    expect(analysisServerEnvironment(fakeEnvironment({'PATH': 'x'})), isEmpty);
  });

  group('removeHalfWrittenFiles', () {
    const id = 4242;
    late String cache;
    late Directory driver;

    setUp(() {
      cache = tempDir().path;
      driver = Directory(p.join(cache, analysisDriverFolder))..createSync();
    });

    File write(String relative) =>
        File(p.joinAll([driver.path, ...relative.split('/')]))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('x');

    List<String> left() => [
      for (final entry in driver.listSync(recursive: true, followLinks: false))
        p.relative(entry.path, from: driver.path).replaceAll(r'\', '/'),
    ]..sort();

    test('deletes the files of the ID directly in the folder, and nothing '
        'else', () async {
      write('0c9e.unlinked2-temp-$id');
      write('11fc.resolved2-temp-$id');
      write('0c/0c9e.unlinked2');
      write('0c/0c9e.unlinked2-temp-$id');
      write('a.unlinked2-temp-1$id');
      write('b.unlinked2-temp-${id}0');
      write('c.unlinked2-temp-$id-plugin');
      write('d.unlinked2-temp-7');
      write('-temp-$id');
      write('e.unlinked2-TEMP-$id');
      expect(await removeHalfWrittenFiles(cache, id), 2);
      expect(left(), [
        '-temp-$id',
        '0c',
        '0c/0c9e.unlinked2',
        '0c/0c9e.unlinked2-temp-$id',
        'a.unlinked2-temp-1$id',
        'b.unlinked2-temp-${id}0',
        'c.unlinked2-temp-$id-plugin',
        'd.unlinked2-temp-7',
        'e.unlinked2-TEMP-$id',
      ]);
    });

    test('a missing cache or folder is no error', () async {
      expect(await removeHalfWrittenFiles(p.join(cache, 'no such'), id), 0);
      driver.deleteSync();
      expect(await removeHalfWrittenFiles(cache, id), 0);
    });

    test('never follows a link out of the folder, nor deletes one', () async {
      final outside = Directory(p.join(tempDir().path, 'outside'))
        ..createSync();
      final target = File(p.join(outside.path, 'x.unlinked2-temp-$id'))
        ..writeAsStringSync('x');
      // A link with the name of a half-written file.
      final named = Link(p.join(driver.path, 'f.unlinked2-temp-$id'))
        ..createSync(outside.path);
      addTearDown(() {
        if (named.existsSync()) named.deleteSync();
      });
      expect(await removeHalfWrittenFiles(cache, id), 0);
      expect(named.existsSync(), isTrue);
      expect(target.existsSync(), isTrue);

      // The folder itself a link: it is left alone.
      named.deleteSync();
      driver.deleteSync(recursive: true);
      final linked = Link(driver.path)..createSync(outside.path);
      addTearDown(() {
        if (linked.existsSync()) linked.deleteSync();
      });
      expect(await removeHalfWrittenFiles(cache, id), 0);
      expect(target.existsSync(), isTrue);
    });

    test('a file that can\'t be deleted is skipped, and the rest are '
        'deleted', () async {
      final held = write('held.unlinked2-temp-$id');
      write('free.unlinked2-temp-$id');
      // Dart opens a file on Windows without sharing its deletion; elsewhere
      // an open file can be deleted, and both are.
      final open = held.openSync();
      addTearDown(open.closeSync);
      final removed = await removeHalfWrittenFiles(cache, id);
      expect(removed, Platform.isWindows ? 1 : 2);
      expect(
        File(p.join(driver.path, 'free.unlinked2-temp-$id')).existsSync(),
        isFalse,
      );
      expect(held.existsSync(), Platform.isWindows);
    });
  });
}
