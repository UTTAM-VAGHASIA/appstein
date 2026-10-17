import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../knowledge/support/sync_harness.dart';
import '../support/analyzer_warm_up.dart';
import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';

const _packs = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];

void main() {
  setUpAll(warmUpAnalyzer);

  late String sdk;
  late String app;
  late FakeProcessRunner runner;

  setUp(() {
    sdk = fakeFlutter();
    app = copyFixtureApp();
    runner = FakeProcessRunner();
  });

  KnowledgeSync sync() => knowledgeSync(
    flutterRoot: sdk,
    runner: runner,
    packs: _packs,
    packageSkills: false,
  );

  Future<({List<String> written, List<String> notices})> renderBoth({
    AppsteinConfig config = const AppsteinConfig(),
  }) => renderDocsForApply(
    projectRoot: app,
    config: config,
    packs: _packs,
    sync: sync(),
    dartSdkPath: testDartSdk,
  );

  /// The pages written, the notices being checked where a test cares.
  Future<List<String>> render({
    AppsteinConfig config = const AppsteinConfig(),
  }) async => (await renderBoth(config: config)).written;

  void edit(String path, String from, String to) {
    final file = File(p.joinAll([app, ...path.split('/')]));
    final text = file.readAsStringSync();
    expect(text, contains(from), reason: path);
    file.writeAsStringSync(text.replaceFirst(from, to));
  }

  Future<DocsDone> docsCheck() async =>
      await runDocs(
            projectRoot: app,
            config: const AppsteinConfig(),
            packs: _packs,
            sync: sync(),
            check: true,
            dartSdkPath: testDartSdk,
          )
          as DocsDone;

  String docs([String path = '']) =>
      p.joinAll([app, 'docs', 'app', ...path.split('/')]);

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

  test(
    'renders the pages that are behind and names each, from the project '
    'root; the pages then match what `appstein docs --check` finds',
    () async {
      expect(await render(), [for (final page in pages) 'docs/app/$page']);
      expect((await docsCheck()).stale, isFalse);
    },
  );

  test(
    'a page that did not change is not listed: a second run lists none',
    () async {
      await render();
      final second = await renderBoth();
      expect(second.written, isEmpty);
      expect(second.notices, isEmpty);
    },
  );

  test('a page that is behind the app, with no hand edit, is written and '
      'listed alone, with no notice', () async {
    await render();
    // A doc comment changed: only its feature page is behind.
    edit(
      'lib/ui/booking/view_models/booking_viewmodel.dart',
      'Books a trip and shows the result.',
      'Holds one booking while it is edited.',
    );
    final readme = File(docs('README.md')).lastModifiedSync();
    final result = await renderBoth();
    expect(result.written, ['docs/app/features/booking.md']);
    expect(result.notices, isEmpty);
    expect(File(docs('README.md')).lastModifiedSync(), readme);
    expect(
      File(docs('features/booking.md')).readAsStringSync(),
      contains('Holds one booking while it is edited.'),
    );
  });

  test('a page edited by hand is written over, listed, and a notice says its '
      'hand edits were overwritten', () async {
    await render();
    final routes = File(docs('routes.md'));
    final rendered = routes.readAsStringSync();
    // A body that no longer matches the hash in the marker: a hand edit.
    routes.writeAsStringSync(rendered.replaceFirst('# ', '# Our '));
    expect(routes.readAsStringSync(), isNot(rendered));
    final result = await renderBoth();
    expect(result.written, ['docs/app/routes.md']);
    expect(result.notices, hasLength(1));
    expect(result.notices.single, contains('`docs/app/routes.md`'));
    expect(result.notices.single, contains('overwrote hand edits'));
    expect(routes.readAsStringSync(), rendered);
    expect((await docsCheck()).stale, isFalse);
  });

  test('a page no longer rendered is removed and is not listed; the pages '
      'its removal puts behind are', () async {
    File(p.join(app, 'lib', 'ui', 'shop', 'cart', 'widgets', 'cart_badge.dart'))
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
    expect(await render(), contains('docs/app/features/shop/cart.md'));
    Directory(p.join(app, 'lib', 'ui', 'shop')).deleteSync(recursive: true);

    final result = await renderBoth();
    expect(File(docs('features/shop/cart.md')).existsSync(), isFalse);
    expect(result.written, [
      'docs/app/README.md',
      'docs/app/architecture.md',
      'docs/app/dependencies.md',
    ]);
    expect(result.notices, isEmpty);
  });

  test(
    'with docs.enabled false nothing is rendered and nothing is listed',
    () async {
      final result = await render(
        config: const AppsteinConfig(docs: DocsConfig(enabled: false)),
      );
      expect(result, isEmpty);
      expect(Directory(docs()).existsSync(), isFalse);
    },
  );

  test('a person\'s file where a page goes leaves every page alone and lists '
      'none; the check still finds the pages behind', () async {
    Directory(docs()).createSync(recursive: true);
    final theirs = File(docs('routes.md'))
      ..writeAsStringSync('# Our routes\n\nWritten by a person.\n');
    final result = await renderBoth();
    expect(result.written, isEmpty);
    expect(result.notices, isEmpty);
    expect(theirs.readAsStringSync(), '# Our routes\n\nWritten by a person.\n');
    expect(
      Directory(docs())
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => p.basename(file.path)),
      ['routes.md'],
    );
    // `appstein docs` refuses the same way: the run is not Appstein failing.
    expect(
      await runDocs(
        projectRoot: app,
        config: const AppsteinConfig(),
        packs: _packs,
        sync: sync(),
        check: true,
        dartSdkPath: testDartSdk,
      ),
      isA<DocsRefused>(),
    );
  });
}
