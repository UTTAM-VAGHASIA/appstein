import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../decisions/support/decision_files.dart';
import '../knowledge/support/hold_lock.dart';
import '../knowledge/support/sync_harness.dart';
import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';

const _packs = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];

void main() {
  late String sdk;
  late String app;
  late FakeProcessRunner runner;

  setUp(() {
    sdk = fakeFlutter();
    app = copyFixtureApp();
    runner = FakeProcessRunner();
  });

  Future<DocsOutcome> run({
    bool check = false,
    AppsteinConfig config = const AppsteinConfig(),
    String? flutterRoot,
    Duration lockTimeout = const Duration(seconds: 10),
  }) => runDocs(
    projectRoot: app,
    config: config,
    packs: _packs,
    sync: knowledgeSync(
      flutterRoot: flutterRoot ?? sdk,
      runner: runner,
      packs: _packs,
      packageSkills: false,
      lockTimeout: lockTimeout,
    ),
    check: check,
    dartSdkPath: testDartSdk,
  );

  String docs([String path = 'docs/app']) =>
      p.joinAll([app, ...path.split('/')]);

  /// Every file under [folder], with its bytes and modified time.
  Map<String, (String, DateTime)> snapshotOf(String folder) => {
    if (Directory(folder).existsSync())
      for (final entity in Directory(folder).listSync(recursive: true))
        if (entity is File)
          p.split(p.relative(entity.path, from: folder)).join('/'): (
            entity.readAsStringSync(),
            entity.lastModifiedSync(),
          ),
  };

  Map<String, String> summary(DocsOutcome outcome) => {
    for (final change in (outcome as DocsDone).changes)
      if (change.kind != DocChangeKind.unchanged)
        change.path: '${change.kind.name}/${change.reason!.name}',
  };

  void edit(String path, String from, String to) {
    final file = File(p.joinAll([app, ...path.split('/')]));
    final text = file.readAsStringSync();
    expect(text, contains(from), reason: path);
    file.writeAsStringSync(text.replaceFirst(from, to));
  }

  const pages = [
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

  test('the first run writes every page; the second changes nothing', () async {
    final first = await run() as DocsDone;
    expect(first.check, isFalse);
    expect(first.docsPath, 'docs/app');
    expect(first.stale, isTrue);
    expect(
      {for (final change in first.changes) change.path: change.kind},
      {for (final page in pages) page: DocChangeKind.write},
    );
    final written = snapshotOf(docs());
    expect(written.keys.toSet(), pages.toSet());
    for (final MapEntry(:key, :value) in written.entries) {
      expect(value.$1, isNot(contains('\r')), reason: '$key has a CR');
      expect(value.$1, endsWith('\n'), reason: key);
      expect(value.$1, isNot(endsWith('\n\n')), reason: key);
      expect(DocMarker.of(value.$1), isNotNull, reason: key);
    }

    final second = await run() as DocsDone;
    expect(second.stale, isFalse);
    expect(second.changes, hasLength(pages.length));
    final after = snapshotOf(docs());
    for (final key in written.keys) {
      expect(after[key]!.$1, written[key]!.$1, reason: key);
      expect(after[key]!.$2, written[key]!.$2, reason: key);
    }
  });

  test('every page of the fixture app matches its golden', () async {
    handDecision(
      app,
      '0001-use-provider.md',
      title: 'Use Provider for dependency injection',
      why: 'It is what the official architecture guide uses.',
      paths: const ['lib/config/**'],
    );
    handDecision(
      app,
      '0002-cache-bookings.md',
      title: 'Cache bookings in memory',
      status: 'proposed',
      why: 'The list is read on every screen.',
    );
    await run();
    final written = snapshotOf(docs());
    expect(written.keys.toSet(), pages.toSet());
    for (final page in pages) {
      expectTextGolden('docs/$page', written[page]!.$1);
    }
  });

  test('--check writes nothing, not even the folder', () async {
    final outcome = await run(check: true) as DocsDone;
    expect(outcome.check, isTrue);
    expect(outcome.stale, isTrue);
    expect(summary(outcome).values.toSet(), {'write/missing'});
    expect(Directory(docs()).existsSync(), isFalse);
    expect(Directory(p.join(app, 'docs')).existsSync(), isFalse);
  });

  test('a changed doc comment puts only its feature page behind', () async {
    await run();
    edit(
      'lib/ui/booking/view_models/booking_viewmodel.dart',
      'Books a trip and shows the result.',
      'Holds one booking while it is edited.',
    );
    final before = snapshotOf(docs());
    final checked = await run(check: true);
    expect(summary(checked), {'features/booking.md': 'write/behind'});
    expect(snapshotOf(docs()), before, reason: '--check wrote');

    expect(summary(await run()), {'features/booking.md': 'write/behind'});
    expect(
      File(p.join(docs(), 'features', 'booking.md')).readAsStringSync(),
      contains('Holds one booking while it is edited.'),
    );
    expect((await run(check: true) as DocsDone).stale, isFalse);
  });

  test('a removed feature loses its page', () async {
    final feature = Directory(p.join(app, 'lib', 'ui', 'shop', 'cart'));
    File(p.join(feature.path, 'widgets', 'cart_badge.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        "import 'package:flutter/widgets.dart';\n\n"
        '/// Shows how many things are in the cart.\n'
        'class CartBadge extends StatelessWidget {\n'
        '  const CartBadge({super.key});\n\n'
        '  @override\n'
        '  Widget build(BuildContext context) => const SizedBox();\n'
        '}\n',
      );
    expect(summary(await run())['features/shop/cart.md'], 'write/missing');
    expect(
      File(p.join(docs(), 'README.md')).readAsStringSync(),
      contains('(features/shop/cart.md)'),
    );

    Directory(p.join(app, 'lib', 'ui', 'shop')).deleteSync(recursive: true);
    final changed = summary(await run());
    // The file counts in architecture.md and the usages in dependencies.md
    // follow the removed file too.
    expect(changed, {
      'README.md': 'write/behind',
      'architecture.md': 'write/behind',
      'dependencies.md': 'write/behind',
      'features/shop/cart.md': 'remove/notRendered',
    });
    expect(Directory(p.join(docs(), 'features', 'shop')).existsSync(), isFalse);
    expect(
      File(p.join(docs(), 'README.md')).readAsStringSync(),
      isNot(contains('shop/cart')),
    );
  });

  test('a new decision changes only decisions.md', () async {
    await run();
    handDecision(app, '0001-use-provider.md', title: 'Use Provider');
    expect(summary(await run()), {'decisions.md': 'write/behind'});
  });

  test('a team note is listed in the README and left alone', () async {
    final note = File(p.join(docs(), 'onboarding.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync('# Start here\r\n');
    final outcome = await run() as DocsDone;
    expect([for (final n in outcome.teamNotes) n.path], ['onboarding.md']);
    expect(note.readAsStringSync(), '# Start here\r\n');
    expect(
      File(p.join(docs(), 'README.md')).readAsStringSync(),
      contains('- [Start here](onboarding.md)'),
    );
  });

  test('follows docs.path, and links climb out of it', () async {
    const config = AppsteinConfig(
      docs: DocsConfig(path: 'documentation/the app/pages'),
    );
    final outcome = await run(config: config) as DocsDone;
    expect(outcome.docsPath, 'documentation/the app/pages');
    expect(Directory(docs()).existsSync(), isFalse);
    expect(
      File(
        p.join(docs('documentation/the app/pages'), 'routes.md'),
      ).readAsStringSync(),
      contains('(../../../lib/routing/router.dart#L'),
    );
  });

  group('nothing is written, removed or judged when', () {
    late Map<String, (String, DateTime)> before;

    /// Docs from an earlier good run, with a page that is no longer
    /// rendered and one that was edited by hand.
    Future<void> oldDocs() async {
      await run();
      final stale = File(p.join(docs(), 'features', 'home.md'));
      File(
        p.join(docs(), 'features', 'gone.md'),
      ).writeAsStringSync(stale.readAsStringSync());
      stale.writeAsStringSync('${stale.readAsStringSync()}By hand.\n');
      before = snapshotOf(docs());
    }

    void untouched() => expect(snapshotOf(docs()), before);

    test('the project map cannot be built', () async {
      await oldDocs();
      // Newer than the lock file: the packages need `flutter pub get`, which
      // the fake runner fails.
      File(
        p.join(app, 'pubspec.yaml'),
      ).setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5)));
      for (final check in [false, true]) {
        final outcome = await run(check: check) as DocsRefused;
        expect(outcome.docsPath, 'docs/app');
        expect(outcome.problem, startsWith('the project map is missing ('));
        expect(outcome.fixHint, contains('appstein docs'));
        untouched();
      }
    });

    test('no Flutter SDK is found', () async {
      await oldDocs();
      final outcome =
          await run(flutterRoot: p.join(app, 'no such sdk')) as DocsRefused;
      expect(outcome.problem, isNotEmpty);
      expect(outcome.fixHint, isNotNull);
      untouched();
    });

    test('another process holds the lock', () async {
      await oldDocs();
      await holdLock(p.join(app, '.appstein'), 60000);
      final outcome =
          await run(lockTimeout: const Duration(milliseconds: 300))
              as DocsRefused;
      expect(outcome.problem, contains('lock'));
      untouched();
    });

    test('a file a person wrote is where a page goes', () async {
      await oldDocs();
      File(p.join(docs(), 'routes.md')).writeAsStringSync('# Our routes\n');
      before = snapshotOf(docs());
      final outcome = await run() as DocsRefused;
      expect(outcome.problem, 'a file is in the way');
      expect(outcome.details, [
        '`routes.md` is not an Appstein page (it has no marker), and a page '
            'would be written there. Move or rename it.',
      ]);
      untouched();
    });

    test('the docs folder is a file', () async {
      File(docs())
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');
      final outcome = await run() as DocsRefused;
      expect(outcome.problem, contains('the docs folder is a file'));
      expect(File(docs()).readAsStringSync(), 'x');
    });
  });

  test('a knowledge file changed by hand is rebuilt, then rendered', () async {
    await run();
    File(
      p.join(app, '.appstein', 'map', 'routes.json'),
    ).writeAsStringSync('not json');
    final outcome = await run(check: true) as DocsDone;
    expect(outcome.stale, isFalse);
  });

  test('docs turned off: nothing runs', () async {
    final outcome = await runDocs(
      projectRoot: app,
      config: const AppsteinConfig(docs: DocsConfig(enabled: false)),
      packs: _packs,
      // No Flutter SDK here: a sync would fail.
      sync: knowledgeSync(
        flutterRoot: p.join(app, 'no such sdk'),
        runner: runner,
        packs: _packs,
      ),
      check: false,
    );
    expect(outcome, isA<DocsDisabled>());
    expect(Directory(p.join(app, '.appstein')).existsSync(), isFalse);
    expect(Directory(docs()).existsSync(), isFalse);
    expect(runner.calls, isEmpty);
  });

  test('pages checked out with CRLF line endings are not behind', () async {
    await run();
    for (final entity in Directory(docs()).listSync(recursive: true)) {
      if (entity is File) {
        entity.writeAsStringSync(
          entity.readAsStringSync().replaceAll('\n', '\r\n'),
        );
      }
    }
    final before = snapshotOf(docs());
    expect((await run(check: true) as DocsDone).stale, isFalse);
    expect((await run() as DocsDone).stale, isFalse);
    expect(snapshotOf(docs()), before);
  });
}
