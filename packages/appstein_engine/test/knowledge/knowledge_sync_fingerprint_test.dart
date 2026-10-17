import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/analyzer_warm_up.dart';
import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import 'support/sync_harness.dart';

void main() {
  setUpAll(warmUpAnalyzer);

  late String sdk;
  late FakeProcessRunner runner;
  late String app;

  setUp(() {
    sdk = fakeFlutter();
    runner = FakeProcessRunner();
    app = copyFixtureApp();
  });

  KnowledgeSync sync({
    List<Pack> packs = const [OfficialMvvmPack()],
    String appsteinVersion = '0.1.0-dev',
  }) => knowledgeSync(
    flutterRoot: sdk,
    runner: runner,
    packs: packs,
    appsteinVersion: appsteinVersion,
  );

  Future<String> fingerprint({
    List<Pack> packs = const [OfficialMvvmPack()],
    String appsteinVersion = '0.1.0-dev',
  }) => sync(
    packs: packs,
    appsteinVersion: appsteinVersion,
  ).fingerprint(app, sdk: null);

  File fileOf(String relative) =>
      File(p.joinAll([app, ...relative.split('/')]));

  void write(String relative, String text) => fileOf(relative)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  test('is the same while nothing the knowledge reads changes, with or '
      'without a sync between', () async {
    await sync().run(app, dartSdkPath: testDartSdk);
    final first = await fingerprint();
    expect(first, isNotEmpty);
    expect(await fingerprint(), first);
    // A refresh (which writes `.appstein/`) changes nothing it reads.
    await sync().detect(app, dartSdkPath: testDartSdk);
    expect(await fingerprint(), first);
    // A file it doesn't read.
    write('README.md', '# An app\n');
    write('assets/logo.txt', 'x');
    expect(await fingerprint(), first);
  });

  test('writes nothing', () async {
    await sync().run(app, dartSdkPath: testDartSdk);
    final before = knowledgeFiles(app);
    final stateBefore = fileOf('.appstein/state.json').readAsStringSync();
    write('lib/extra.dart', '/// E.\nclass E {}\n');
    await fingerprint();
    expect(knowledgeFiles(app), before);
    expect(fileOf('.appstein/state.json').readAsStringSync(), stateBefore);
  });

  group('changes with', () {
    late String first;

    setUp(() async {
      await sync().run(app, dartSdkPath: testDartSdk);
      first = await fingerprint();
    });

    test('an edit to a Dart file of the map\'s folders', () async {
      write(
        'lib/main.dart',
        '// edited\n${fileOf('lib/main.dart').readAsStringSync()}',
      );
      expect(await fingerprint(), isNot(first));
    });

    test('a new Dart file, in or outside the map\'s folders', () async {
      write('lib/extra.dart', '/// E.\nclass E {}\n');
      final inLib = await fingerprint();
      expect(inLib, isNot(first));
      write('bin/tool.dart', 'void main() {}\n');
      expect(await fingerprint(), isNot(inLib));
    });

    test('a Dart file deleted', () async {
      write('bin/tool.dart', 'void main() {}\n');
      final with_ = await fingerprint();
      fileOf('bin/tool.dart').deleteSync();
      expect(await fingerprint(), isNot(with_));
      expect(await fingerprint(), first);
    });

    test('an edit to a Dart file outside the map\'s folders', () async {
      write('bin/tool.dart', 'void main() {}\n');
      final before = await fingerprint();
      write('bin/tool.dart', 'void main() { print(1); }\n');
      expect(await fingerprint(), isNot(before));
    });

    test('pubspec.yaml, and analysis_options.yaml', () async {
      final pubspec = fileOf('pubspec.yaml').readAsStringSync();
      write('pubspec.yaml', '$pubspec\n# edited\n');
      final edited = await fingerprint();
      expect(edited, isNot(first));
      write('analysis_options.yaml', 'linter:\n  rules: []\n');
      expect(await fingerprint(), isNot(edited));
    });

    test('appstein.yaml: a suppression added, edited and removed, a '
        'severity raised', () async {
      const entry =
          'suppressions:\n'
          '  - check: dart.error\n'
          '    path: lib/main.dart\n'
          '    reason: Known.\n';
      write('appstein.yaml', 'appstein: 1\n$entry');
      final suppressed = await fingerprint();
      expect(suppressed, isNot(first));
      write('appstein.yaml', 'appstein: 1\n');
      final removed = await fingerprint();
      expect(removed, isNot(suppressed));
      write(
        'appstein.yaml',
        'appstein: 1\nverify:\n  severity:\n'
            '    dart.warning: error\n',
      );
      final raised = await fingerprint();
      expect(raised, isNot(removed));
      // The file gone is its own state, and the same every time.
      fileOf('appstein.yaml').deleteSync();
      expect(await fingerprint(), first);
    });

    test('an analysis_options.yaml in a folder below the root, appearing, '
        'edited and gone', () async {
      write('lib/ui/analysis_options.yaml', 'linter:\n  rules: []\n');
      final added = await fingerprint();
      expect(added, isNot(first));
      expect(await fingerprint(), added, reason: 'stable while it is');
      write('lib/ui/analysis_options.yaml', 'linter:\n  rules: [a]\n');
      final edited = await fingerprint();
      expect(edited, isNot(added));
      fileOf('lib/ui/analysis_options.yaml').deleteSync();
      expect(await fingerprint(), first);
    });

    test('a nested analysis_options.yaml outside the folders the map reads, '
        'and not inside a folder the scan skips', () async {
      write('tool/deep/analysis_options.yaml', 'a: 1\n');
      final outside = await fingerprint();
      expect(outside, isNot(first));
      // The scan leaves out folders that start with a dot.
      write('.hidden/analysis_options.yaml', 'a: 1\n');
      expect(await fingerprint(), outside);
    });

    test('a file analysis_options.yaml includes, and a file that file '
        'includes, inside the project or outside it', () async {
      write('analysis_options.yaml', 'include: shared/base.yaml\n');
      write('shared/base.yaml', 'include: ../more/deeper.yaml\n');
      write('more/deeper.yaml', 'linter:\n  rules: []\n');
      final chain = await fingerprint();
      expect(chain, isNot(first));
      write('more/deeper.yaml', 'linter:\n  rules: [a]\n');
      final deeper = await fingerprint();
      expect(deeper, isNot(chain));
      write('shared/base.yaml', 'include: ../more/deeper.yaml\n# edited\n');
      final base = await fingerprint();
      expect(base, isNot(deeper));
      // A cycle ends.
      write('more/deeper.yaml', 'include: ../analysis_options.yaml\n');
      final cycle = await fingerprint();
      expect(cycle, isNot(base));
      expect(await fingerprint(), cycle);
      // A list of includes, and a `package:` include, which the package
      // configuration covers.
      write(
        'analysis_options.yaml',
        'include:\n  - package:lints/recommended.yaml\n  - shared/base.yaml\n',
      );
      final listed = await fingerprint();
      write('shared/base.yaml', '# another\n');
      expect(await fingerprint(), isNot(listed));
      // A file that is missing is its own state: when it appears, the
      // fingerprint changes.
      write('analysis_options.yaml', 'include: shared/gone.yaml\n');
      final missing = await fingerprint();
      expect(await fingerprint(), missing, reason: 'stable while missing');
      write('shared/gone.yaml', 'a: 1\n');
      expect(await fingerprint(), isNot(missing));
      // A file outside the project is followed too, as the analyzer does: a
      // package of a monorepo often includes `../../analysis_options.yaml`.
      final outside = File(p.join(p.dirname(app), 'outside_options.yaml'))
        ..writeAsStringSync('a: 1\n');
      write('analysis_options.yaml', 'include: ../outside_options.yaml\n');
      final reaching = await fingerprint();
      outside.writeAsStringSync('a: 2\n');
      expect(await fingerprint(), isNot(reaching));
    });

    test('an analysis_options.yaml in a folder above the project, which the '
        'analyzer applies when the project has none, and a file it includes; '
        'not when the project has its own', () async {
      File above(String name) => File(p.join(p.dirname(app), name));
      above('analysis_options.yaml').writeAsStringSync('include: base.yaml\n');
      final base = above('base.yaml')..writeAsStringSync('a: 1\n');
      final added = await fingerprint();
      expect(added, isNot(first));
      expect(await fingerprint(), added, reason: 'stable while it is');
      above(
        'analysis_options.yaml',
      ).writeAsStringSync('include: base.yaml\nlinter:\n  rules: []\n');
      final edited = await fingerprint();
      expect(edited, isNot(added));
      base.writeAsStringSync('a: 2\n');
      final included = await fingerprint();
      expect(included, isNot(edited));
      // The project's own options file takes over: the one above is no input.
      write('analysis_options.yaml', 'linter:\n  rules: []\n');
      final own = await fingerprint();
      above('analysis_options.yaml').writeAsStringSync('a: 3\n');
      expect(await fingerprint(), own);
      // Gone, the file above is the state it was without it.
      fileOf('analysis_options.yaml').deleteSync();
      above('analysis_options.yaml').deleteSync();
      expect(await fingerprint(), first);
    });

    test('pubspec.lock, and the package configuration', () async {
      final lock = fileOf('pubspec.lock');
      write('pubspec.lock', '${lock.readAsStringSync()}\n# edited\n');
      final locked = await fingerprint();
      expect(locked, isNot(first));
      final config = fileOf('.dart_tool/package_config.json');
      write('.dart_tool/package_config.json', '${config.readAsStringSync()}\n');
      expect(await fingerprint(), isNot(locked));
    });

    test(
      'a decision record and the current work, which INDEX.md reads',
      () async {
        write(
          '.appstein/memory/current.md',
          '# Current\n\n- Working on the home screen.\n',
        );
        final current = await fingerprint();
        expect(current, isNot(first));
        write(
          '.appstein/decisions/0001-state.md',
          '# State\n\nStatus: accepted\n',
        );
        expect(await fingerprint(), isNot(current));
      },
    );

    test('another Appstein version', () async {
      expect(await fingerprint(appsteinVersion: '0.2.0'), isNot(first));
    });
  });

  test('changes with a native file the platform packs read', () async {
    const packs = [OfficialMvvmPack(), AndroidPack()];
    await sync(packs: packs).run(app, dartSdkPath: testDartSdk);
    final first = await fingerprint(packs: packs);
    write('android/app/src/main/AndroidManifest.xml', '<manifest/>\n');
    expect(await fingerprint(packs: packs), isNot(first));
  });
}
