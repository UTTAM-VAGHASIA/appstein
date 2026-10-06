import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../knowledge/support/sync_harness.dart';
import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import 'support/verify_support.dart';

const _packs = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];

/// A pack that only adds [checks], for the check list's tests.
final class _CheckPack implements Pack {
  _CheckPack(this.id, this.checks);

  @override
  final String id;

  @override
  final List<VerifyCheck> checks;

  @override
  List<DecisionCheck> get decisionChecks => const [];

  @override
  PackKind get kind => PackKind.stack;

  @override
  String get version => '1';

  @override
  List<MapExtractor> get extractors => const [];

  @override
  NativeExtractor? get nativeExtractor => null;

  @override
  LayerRules? get layerRules => null;

  @override
  List<DocPage> get docPages => const [];
}

void main() {
  group('checksFor', () {
    test('lists the engine\'s checks, then each pack\'s with its pack', () {
      final first = FakeCheck(['a.one']);
      final second = FakeCheck(['b.one', 'b.two']);
      final checks = checksFor([
        ..._packs,
        _CheckPack('a', [first]),
        _CheckPack('b', [second]),
      ]);
      expect(
        [for (final (:check, :pack) in checks) (check.ids.first, pack)],
        [
          ('docs.stale', null),
          ('decision.drift', null),
          ('memory.lessons_long', null),
          ('verify.test_required', null),
          ('a.one', 'a'),
          ('b.one', 'b'),
        ],
      );
      final decisions = checks[1].check as DecisionsCheck;
      expect(decisions.decisionChecks.map((check) => check.id), [
        'paths.exist',
        'stack.provider',
      ]);
    });

    test('two checks with one ID are a bug in a pack: a StateError names '
        'the ID and both sources', () {
      expect(
        () => checksFor([
          _CheckPack('a', [
            FakeCheck(['x.one', 'docs.stale']),
          ]),
        ]),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('`docs.stale`'),
              contains('the engine'),
              contains('`a`'),
            ),
          ),
        ),
      );
      expect(
        () => checksFor([
          _CheckPack('a', [
            FakeCheck(['x.one']),
          ]),
          _CheckPack('b', [
            FakeCheck(['x.one']),
          ]),
        ]),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('`x.one`'), contains('`a`'), contains('`b`')),
          ),
        ),
      );
    });
  });

  group('on the fixture app', () {
    late String sdk;
    late String app;

    setUp(() {
      sdk = fakeFlutter();
      app = copyFixtureApp();
    });

    KnowledgeSync sync({String? flutterRoot}) => knowledgeSync(
      flutterRoot: flutterRoot ?? sdk,
      runner: FakeProcessRunner(),
      packs: _packs,
      packageSkills: false,
    );

    Future<VerifyResult> verify({
      VerifyMode mode = VerifyMode.full,
      AppsteinConfig config = const AppsteinConfig(),
      String? flutterRoot,
    }) => runVerify(
      projectRoot: app,
      config: config,
      packs: _packs,
      sync: sync(flutterRoot: flutterRoot),
      mode: mode,
      checks: checksFor(_packs),
      dartSdkPath: testDartSdk,
    );

    List<String> ids(VerifyResult result) => [
      for (final finding in result.findings) finding.id,
    ];

    test('full, with the docs rendered: only the features without a '
        'test', () async {
      final outcome = await runDocs(
        projectRoot: app,
        config: const AppsteinConfig(),
        packs: _packs,
        sync: sync(),
        check: false,
        dartSdkPath: testDartSdk,
      );
      expect(outcome, isA<DocsDone>());

      final result = await verify();
      expect(
        [for (final finding in result.findings) (finding.id, finding.file)],
        [
          ('verify.test_required', 'lib/ui/auth/login'),
          ('verify.test_required', 'lib/ui/profile'),
          ('verify.test_required', 'lib/ui/settings'),
        ],
      );
      expect(result.errors, 0);
      expect(result.warnings, 3);
      expect(result.notRun, isEmpty);
      expect(result.suppressed, 0);
    });

    test('full, with the docs never rendered: every page is missing '
        'too', () async {
      final result = await verify();
      expect(ids(result).where((id) => id == 'docs.stale'), hasLength(11));
      expect(
        ids(result).where((id) => id == 'verify.test_required'),
        hasLength(3),
      );
      expect(result.findings, hasLength(14));
      expect(result.errors, 0);
    });

    test('fast: no full check runs', () async {
      // A file where the docs folder belongs: full mode reports it, and fast
      // mode never looks.
      File(p.join(app, 'docs', 'app'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('in the way');
      final fast = await verify(mode: VerifyMode.fast);
      expect(fast.findings, isEmpty);
      expect(fast.notRun, isEmpty);

      final full = await verify();
      expect(ids(full), contains('docs.stale'));
    });

    test('full, when the knowledge cannot be refreshed: an error, and the '
        'map checks are named as not run', () async {
      // Something for a check that needs no map to find.
      File(p.join(app, '.appstein', 'decisions', '0001-broken.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('no front matter\n');
      File(p.join(app, '.appstein', 'memory', 'lessons.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('- one lesson\n' * 201);

      final result = await verify(flutterRoot: p.join(app, 'no such sdk'));
      expect(ids(result), [
        'knowledge.stale',
        'decision.unreadable',
        'memory.lessons_long',
      ]);
      expect(result.errors, 1);
      expect(
        [for (final check in result.notRun) check.id],
        ['docs.stale', 'verify.test_required'],
      );
    });
  });
}
