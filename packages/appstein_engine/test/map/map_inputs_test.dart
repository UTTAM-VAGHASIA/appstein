import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/temp.dart';

void main() {
  MapInputs read(String app, {List<Pack> packs = const [OfficialMvvmPack()]}) =>
      readMapInputs(
        app,
        workspaceRoot: app,
        flutterVersion: '3.47.5',
        flutterRoot: p.join(tempDir().path, 'no flutter here'),
        packs: packs,
        appsteinVersion: '0.1.0-dev',
        environment: fakeEnvironment({}),
      );

  test('the project files, pubspec.yaml, the lock and analysis_options.yaml '
      'are inputs', () {
    final app = copyFixtureApp();
    final sources = read(app).sources;
    expect(sources['project:lib/main.dart'], isNotNull);
    expect(sources['pubspec.yaml'], isNotNull);
    expect(sources['pubspec.lock'], isNotNull);
    expect(sources.containsKey('analysis_options.yaml'), isTrue);
    expect(sources['analysis_options.yaml'], isNull);
    expect(
      sources.keys.where((name) => name.startsWith('project:')),
      everyElement(matches(RegExp(r'^project:(lib|test|testing)/.+\.dart$'))),
    );
  });

  test("a local package's lib files and pubspec are inputs; the project "
      'itself is not a local package', () {
    final app = copyFixtureApp();
    expect(
      localPackageRoots(
        app,
        workspaceRoot: app,
        flutterRoot: p.join(tempDir().path, 'no flutter here'),
        environment: fakeEnvironment({}),
      ).keys,
      unorderedEquals(['flutter', 'flutter_test', 'go_router']),
    );
    final sources = read(app).sources;
    expect(sources['local-package:go_router/lib/go_router.dart'], isNotNull);
    expect(sources['local-package:go_router/lib/fix_data.yaml'], isNotNull);
    expect(sources.containsKey('local-package:go_router/pubspec.yaml'), isTrue);
  });

  test('packages in the pub cache or the Flutter SDK are not local', () {
    final work = tempDir().path;
    final project = p.join(work, 'app');
    final cache = p.join(work, 'pub cache');
    final flutter = p.join(work, 'flutter');
    File(p.join(project, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'hosted',
              'rootUri': Uri.directory(
                p.join(cache, 'hosted', 'pub.dev', 'hosted-1.0.0'),
              ).toString(),
              'packageUri': 'lib/',
            },
            {
              'name': 'flutter',
              'rootUri': Uri.directory(
                p.join(flutter, 'packages', 'flutter'),
              ).toString(),
              'packageUri': 'lib/',
            },
            {'name': 'core', 'rootUri': '../../core', 'packageUri': 'lib/'},
          ],
        }),
      );
    expect(
      localPackageRoots(
        project,
        workspaceRoot: project,
        flutterRoot: flutter,
        environment: fakeEnvironment({'PUB_CACHE': cache}),
      ),
      {'core': p.join(work, 'core')},
    );
  });

  test('a missing or damaged package config means no local packages', () {
    final project = p.join(tempDir().path, 'app');
    Map<String, String> roots() => localPackageRoots(
      project,
      workspaceRoot: project,
      flutterRoot: 'flutter',
      environment: fakeEnvironment({}),
    );
    expect(roots(), isEmpty);
    File(p.join(project, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{not json');
    expect(roots(), isEmpty);
  });

  test('pubCacheFolders follows PUB_CACHE, then the OS default', () {
    expect(
      pubCacheFolders(fakeEnvironment({'PUB_CACHE': p.join('x', 'cache')})),
      [p.normalize(p.absolute(p.join('x', 'cache')))],
    );
    expect(
      pubCacheFolders(
        fakeEnvironment({
          'LOCALAPPDATA': r'C:\Users\a\AppData\Local',
          'APPDATA': r'C:\Users\a\AppData\Roaming',
        }, os: HostOs.windows),
      ),
      [
        p.join(r'C:\Users\a\AppData\Local', 'Pub', 'Cache'),
        p.join(r'C:\Users\a\AppData\Roaming', 'Pub', 'Cache'),
      ],
    );
    expect(
      pubCacheFolders(fakeEnvironment({'HOME': '/home/a'}, os: HostOs.linux)),
      [p.join('/home/a', '.pub-cache')],
    );
  });

  test("editing a local package's file changes the hash", () {
    final app = copyFixtureApp();
    final before = read(app).inputHash;
    File(
      p.join(p.dirname(app), 'stubs', 'go_router', 'lib', 'go_router.dart'),
    ).writeAsStringSync('\n// edited\n', mode: FileMode.append);
    expect(read(app).inputHash, isNot(before));
  });

  test('the same files give the same hash, wherever the project is', () {
    expect(read(copyFixtureApp()).inputHash, read(copyFixtureApp()).inputHash);
  });

  test('the packs are part of the hash', () {
    final app = copyFixtureApp();
    expect(read(app).inputHash, isNot(read(app, packs: const []).inputHash));
  });

  group('links, walked as the analyzer walks them', () {
    /// A folder `shared` beside [app] holding `s.dart`, returned.
    String sharedFolder(String app) {
      final shared = p.join(p.dirname(app), 'shared');
      File(p.join(shared, 's.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('/// S.\nclass S {}\n');
      return shared;
    }

    test('a linked folder in lib/ is an input, named through the link; an '
        'edit behind the link changes the hash', () {
      final app = copyFixtureApp();
      final shared = sharedFolder(app);
      // On Windows this is a junction, which needs no admin.
      Link(p.join(app, 'lib', 'linked')).createSync(shared);
      final before = read(app);
      expect(before.sources['project:lib/linked/s.dart'], isNotNull);
      File(
        p.join(shared, 's.dart'),
      ).writeAsStringSync('\n// edited\n', mode: FileMode.append);
      expect(read(app).inputHash, isNot(before.inputHash));
    });

    test('two links to one folder are each inputs, so removing one changes '
        'the hash', () {
      final app = copyFixtureApp();
      final shared = sharedFolder(app);
      Link(p.join(app, 'lib', 'a')).createSync(shared);
      final second = Link(p.join(app, 'lib', 'b'))..createSync(shared);
      final before = read(app);
      expect(before.sources['project:lib/a/s.dart'], isNotNull);
      expect(before.sources['project:lib/b/s.dart'], isNotNull);
      second.deleteSync();
      expect(read(app).inputHash, isNot(before.inputHash));
    });

    test('a link loop ends: every real file is read under its own path, and '
        'the loop is walked once, as the analyzer walks it', () {
      final app = copyFixtureApp();
      final lib = p.join(app, 'lib');
      final real = [
        for (final entity in Directory(lib).listSync(recursive: true))
          if (entity is File && entity.path.endsWith('.dart'))
            p.split(p.relative(entity.path, from: lib)).join('/'),
      ];
      expect(real, isNotEmpty);
      Link(p.join(lib, 'loop')).createSync(lib);
      final sources = read(app).sources;
      for (final file in real) {
        expect(sources['project:lib/$file'], isNotNull, reason: file);
      }
      // The analyzer walks `lib/loop/` once (it is not yet among the folders
      // it is inside), then stops at `lib/loop/loop/`.
      expect(
        sources.keys.where((name) => name.startsWith('project:lib/loop/')),
        unorderedEquals([for (final file in real) 'project:lib/loop/$file']),
      );
    });
  });

  test(
    'an unreadable folder is a null input on its own; its siblings are still '
    'hashed',
    () {
      final app = copyFixtureApp();
      final locked = Directory(p.join(app, 'lib', 'locked'))
        ..createSync(recursive: true);
      File(p.join(locked.path, 'hidden.dart')).writeAsStringSync('// x\n');
      Process.runSync('chmod', ['000', locked.path]);
      addTearDown(() => Process.runSync('chmod', ['755', locked.path]));
      try {
        locked.listSync();
        // Root reads anything: chmod blocks nothing here.
        markTestSkipped('chmod does not block reads (running as root?)');
        return;
      } on FileSystemException {
        // Unreadable, as intended.
      }
      final before = read(app);
      expect(before.sources.containsKey('project:lib/locked/'), isTrue);
      expect(before.sources['project:lib/locked/'], isNull);
      expect(before.sources['project:lib/main.dart'], isNotNull);
      File(
        p.join(app, 'lib', 'main.dart'),
      ).writeAsStringSync('\n// edited\n', mode: FileMode.append);
      expect(read(app).inputHash, isNot(before.inputHash));
    },
    skip: Platform.isWindows ? 'needs chmod' : false,
  );
}
