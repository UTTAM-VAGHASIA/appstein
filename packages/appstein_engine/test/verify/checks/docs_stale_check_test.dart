import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../knowledge/support/sync_harness.dart';
import '../../support/fake_process_runner.dart';
import '../../support/fixture_app.dart';
import '../support/verify_support.dart';

const _packs = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];
const _check = DocsStaleCheck();

const _pages = [
  'README.md',
  'architecture.md',
  'decisions.md',
  'dependencies.md',
  'features/auth/login.md',
  'features/booking.md',
  'features/home.md',
  'features/profile.md',
  'features/settings.md',
  'native.md',
  'routes.md',
];

void main() {
  late String sdk;
  late String app;

  setUp(() {
    sdk = fakeFlutter();
    app = copyFixtureApp();
  });

  Future<List<Finding>> run({
    AppsteinConfig config = const AppsteinConfig(),
  }) async => _check.run(
    await contextFor(app, flutterRoot: sdk, packs: _packs, config: config),
  );

  Future<void> render({AppsteinConfig config = const AppsteinConfig()}) async {
    final outcome = await runDocs(
      projectRoot: app,
      config: config,
      packs: _packs,
      sync: knowledgeSync(
        flutterRoot: sdk,
        runner: FakeProcessRunner(),
        packs: _packs,
        packageSkills: false,
      ),
      check: false,
      dartSdkPath: testDartSdk,
    );
    expect(outcome, isA<DocsDone>());
  }

  File page(String path, [String docs = 'docs/app']) =>
      File(p.joinAll([app, ...docs.split('/'), ...path.split('/')]));

  Map<String, String> messages(List<Finding> findings) => {
    for (final finding in findings) finding.file!: finding.message,
  };

  test('it is a full check that reads the map', () {
    expect(_check.ids, ['docs.stale']);
    expect(_check.mode, VerifyMode.full);
    expect(_check.needsMap, isTrue);
  });

  test('pages that are up to date give no finding', () async {
    await render();
    expect(await run(), isEmpty);
  });

  // Review Focus 1.
  test('a project that never rendered its docs: every page is missing, and '
      'nothing is written', () async {
    final findings = await run();
    expect(messages(findings), {
      for (final path in _pages) 'docs/app/$path': 'The page is missing.',
    });
    for (final finding in findings) {
      expect(finding.id, 'docs.stale');
      expect(finding.severity, Severity.warning);
      expect(finding.line, isNull);
      expect(finding.fixHint, 'Run `appstein docs`.');
      expect(finding.knowledgeRef, '.appstein/INDEX.md');
    }
    expect(Directory(p.join(app, 'docs')).existsSync(), isFalse);
  });

  test('a page behind the app', () async {
    await render();
    File(p.join(app, 'test', 'ui', 'profile', 'profile_test.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}\n');
    final findings = await run();
    // The feature's page lists its tests; the architecture page counts the
    // files of each layer.
    expect(messages(findings), {
      'docs/app/architecture.md': 'The page is behind the app.',
      'docs/app/features/profile.md': 'The page is behind the app.',
    });
    expect(findings.first.fixHint, 'Run `appstein docs`.');
  });

  test('a page edited by hand, in a merge conflict, and left over', () async {
    await render();
    final routes = page('routes.md').readAsStringSync();
    page('routes.md').writeAsStringSync('${routes}My note.\n');
    page('native.md').writeAsStringSync(
      '<<<<<<< HEAD\n${page('native.md').readAsStringSync()}',
    );
    page(
      'features/gone.md',
    ).writeAsStringSync(page('features/home.md').readAsStringSync());
    page('features/kept.md').writeAsStringSync(
      '${page('features/home.md').readAsStringSync()}My note.\n',
    );
    final findings = await run();
    expect(messages(findings), {
      'docs/app/features/gone.md': 'The page is no longer rendered.',
      'docs/app/features/kept.md':
          'The page is no longer rendered, and was edited by hand.',
      'docs/app/native.md': 'The page has a merge conflict.',
      'docs/app/routes.md':
          'The page was edited by hand; `appstein docs` will overwrite the '
          'edit.',
    });
    final hints = {
      for (final finding in findings) finding.file!: finding.fixHint,
    };
    expect(hints['docs/app/features/gone.md'], 'Run `appstein docs`.');
    expect(hints['docs/app/native.md'], 'Run `appstein docs`.');
    expect(
      hints['docs/app/features/kept.md'],
      'Delete it, or remove its first line to keep it as a team note.',
    );
    expect(
      hints['docs/app/routes.md'],
      'Run `appstein docs`, and keep your own text in a file without the '
      'marker line.',
    );
    // It only reports.
    expect(page('routes.md').readAsStringSync(), '${routes}My note.\n');
    expect(page('features/gone.md').existsSync(), isTrue);
  });

  test("a person's file where a page goes is reported, with the other "
      'pages', () async {
    await render();
    page('routes.md').writeAsStringSync('# Our routes\n');
    page(
      'native.md',
    ).writeAsStringSync('${page('native.md').readAsStringSync()}My note.\n');
    final findings = await run();
    expect(
      [for (final finding in findings) '${finding.file}: ${finding.message}'],
      [
        'docs/app: `routes.md` is not an Appstein page (it has no marker), '
            'and a page would be written there. Move or rename it.',
        // README lists the team note now.
        'docs/app/README.md: The page is behind the app.',
        'docs/app/native.md: The page was edited by hand; `appstein docs` '
            'will overwrite the edit.',
      ],
    );
    expect(findings.first.fixHint, isNull);
  });

  test('a docs folder that cannot be read', () async {
    File(p.join(app, 'docs', 'app'))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    final findings = await run();
    expect(messages(findings), {
      'docs/app':
          'The pages could not be compared: the docs folder is a file, not '
          'a folder. Move or rename it.',
    });
  });

  test('two features that would be one page', () async {
    await run();
    final file = File(p.join(app, '.appstein', 'map', 'features.json'));
    final text = file.readAsStringSync();
    expect(text, contains('"home": {'));
    // What a project with the folders `home` and `Home` has on Linux.
    file.writeAsStringSync(
      text.replaceFirst(
        '"home": {',
        '"Home": {"folder": "lib/ui/Home", "viewModels": [], "screens": [], '
            '"repositories": [], "services": [], "models": [], "tests": [], '
            '"files": []}, "home": {',
      ),
    );
    final findings = await _check.run(
      VerifyContext(
        projectRoot: app,
        config: const AppsteinConfig(),
        packs: _packs,
        knowledge: KnowledgeSnapshot(app),
        decisions: readDecisions(app),
      ),
    );
    expect(findings.single.file, 'docs/app');
    expect(
      findings.single.message,
      'The pages could not be compared: two pages would be the same file '
      'where letter case is ignored (`features/Home.md` and '
      '`features/home.md`).',
    );
    expect(findings.single.fixHint, contains('Rename one of the folders'));
  });

  test('docs turned off: no finding, and the folder is not read', () async {
    File(p.join(app, 'docs', 'app'))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    expect(
      await run(config: const AppsteinConfig(docs: DocsConfig(enabled: false))),
      isEmpty,
    );
  });

  test('another docs.path', () async {
    const config = AppsteinConfig(docs: DocsConfig(path: 'handbook'));
    final findings = await run(config: config);
    expect(findings.map((finding) => finding.file), [
      for (final path in _pages) 'handbook/$path',
    ]);
    await render(config: config);
    expect(await run(config: config), isEmpty);
  });
}
