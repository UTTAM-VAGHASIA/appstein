import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../knowledge/support/hold_lock.dart';
import '../knowledge/support/sync_harness.dart';
import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import 'support/verify_support.dart';

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

  Future<VerifyResult> run(
    List<VerifyCheck> checks, {
    VerifyMode mode = VerifyMode.full,
    AppsteinConfig config = const AppsteinConfig(),
    KnowledgeRefresh? refreshed,
    String? flutterRoot,
    Duration lockTimeout = const Duration(seconds: 10),
    Map<VerifyCheck, String> from = const {},
  }) => runVerify(
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
    mode: mode,
    checks: [for (final check in checks) (check: check, pack: from[check])],
    refreshed: refreshed,
    dartSdkPath: testDartSdk,
  );

  List<String> ids(VerifyResult result) => [
    for (final finding in result.findings) finding.id,
  ];

  test('fast mode runs the fast checks; full mode runs them all', () async {
    final fast = FakeCheck(['a.fast'], mode: VerifyMode.fast);
    final full = FakeCheck(['a.full']);
    await run([fast, full], mode: VerifyMode.fast);
    expect((fast.runs, full.runs), (1, 0));
    await run([fast, full]);
    expect((fast.runs, full.runs), (2, 1));
  });

  test('every check gets the same reading of the knowledge', () async {
    final first = FakeCheck(['a.a']);
    final second = FakeCheck(['b.b'], needsMap: true);
    const config = AppsteinConfig(docs: DocsConfig(enabled: false));
    final result = await run([first, second], config: config);
    expect(result.findings, isEmpty);
    expect(result.notRun, isEmpty);
    expect(result.suppressed, 0);
    expect(first.seen, same(second.seen));
    expect(first.seen!.projectRoot, app);
    expect(first.seen!.config, same(config));
    expect(first.seen!.packs, _packs);
    expect(first.seen!.knowledge.features.problem, isNull);
    expect(first.seen!.decisions.entries, isEmpty);
  });

  test('the knowledge is brought up to date first', () async {
    await run([]);
    expect(File(p.join(app, '.appstein', 'INDEX.md')).existsSync(), isTrue);
  });

  group('the knowledge cannot be brought up to date', () {
    test('knowledge.stale is an error; map checks are named, others '
        'run', () async {
      final mapCheck = FakeCheck(['map.check'], needsMap: true);
      final other = FakeCheck(['other.check'], findings: [finding('other.x')])
        ..ids.add('other.x');
      final result = await run([
        mapCheck,
        other,
      ], flutterRoot: p.join(app, 'no such sdk'));
      expect(ids(result), ['knowledge.stale', 'other.x']);
      final stale = result.findings.first;
      expect(stale.severity, Severity.error);
      expect(stale.file, isNull);
      expect(
        stale.message,
        startsWith('The knowledge could not be brought up to date: '),
      );
      expect(stale.message, endsWith('.'));
      expect(stale.message, isNot(endsWith('..')));
      expect(stale.fixHint, isNotNull);
      expect(mapCheck.runs, 0);
      expect(other.runs, 1);
      expect(
        [for (final entry in result.notRun) '${entry.id}: ${entry.reason}'],
        ['map.check: the project map is not up to date'],
      );
    });

    test('a map check of another mode is not listed as not run', () async {
      final result = await run(
        [
          FakeCheck(['map.check'], needsMap: true),
        ],
        mode: VerifyMode.fast,
        flutterRoot: p.join(app, 'no such sdk'),
      );
      expect(ids(result), ['knowledge.stale']);
      expect(result.notRun, isEmpty);
    });

    test('a damaged map file', () async {
      await run([]);
      File(
        p.join(app, '.appstein', 'map', 'features.json'),
      ).writeAsStringSync('{');
      final mapCheck = FakeCheck(['map.check'], needsMap: true);
      final result = await run([
        mapCheck,
      ], refreshed: const KnowledgeRefresh.current());
      expect(ids(result), ['knowledge.stale']);
      expect(
        result.findings.single.message,
        contains('`.appstein/map/features.json` is damaged'),
      );
      expect(result.findings.single.fixHint, contains('appstein sync'));
      expect(mapCheck.runs, 0);
    });

    test('a refresh the caller ran is used, and no sync runs', () async {
      final result = await run(
        [],
        refreshed: const KnowledgeRefresh.failed('x', fixHint: 'Do y.'),
      );
      expect(
        result.findings.single.message,
        'The knowledge could not be brought up to date: x.',
      );
      expect(result.findings.single.fixHint, 'Do y.');
      expect(File(p.join(app, '.appstein', 'INDEX.md')).existsSync(), isFalse);
    });

    // Review Focus 4.
    test('another process holds the lock: it gives up at the '
        'timeout', () async {
      await run([]);
      await holdLock(p.join(app, '.appstein'), 60000);
      final mapCheck = FakeCheck(['map.check'], needsMap: true);
      final other = FakeCheck(['other.check']);
      final watch = Stopwatch()..start();
      final result = await run(
        [mapCheck, other],
        refreshed: const KnowledgeRefresh.current(),
        lockTimeout: const Duration(milliseconds: 200),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(ids(result), ['knowledge.stale']);
      expect(result.findings.single.message, contains(lockBusyProblem));
      expect(result.findings.single.fixHint, contains('appstein verify'));
      expect((mapCheck.runs, other.runs), (0, 1));
      expect(result.notRun.single.id, 'map.check');
    });
  });

  group('a check that misbehaves is Appstein failing', () {
    test('a check that throws', () async {
      final error = StateError('boom');
      await expectLater(
        run([
          FakeCheck(['a.b', 'a.c'], error: error),
        ]),
        throwsA(
          isA<VerifyCheckError>()
              .having((e) => e.checkId, 'checkId', 'a.b')
              .having((e) => e.error, 'error', same(error))
              .having((e) => '$e', 'text', contains('`a.b`')),
        ),
      );
    });

    test('a check that reports an ID it does not declare', () async {
      await expectLater(
        run([
          FakeCheck(['a.b'], findings: [finding('c.d')]),
        ]),
        throwsA(
          isA<VerifyCheckError>().having(
            (e) => '$e',
            'text',
            allOf(contains('`a.b`'), contains('`c.d`')),
          ),
        ),
      );
    });
  });

  test('a finding is stamped with the pack whose check reported it', () async {
    final packCheck = FakeCheck(
      ['p.a', 'p.b'],
      findings: [
        finding('p.a'),
        finding('p.b', pack: 'ios'),
      ],
    );
    final engineCheck = FakeCheck(['e.a'], findings: [finding('e.a')]);
    final result = await run(
      [packCheck, engineCheck],
      from: {packCheck: 'android'},
    );
    expect(
      {for (final finding in result.findings) finding.id: finding.pack},
      {'p.a': 'android', 'p.b': 'ios', 'e.a': null},
    );
  });

  group('verify.severity', () {
    test('changes a finding\'s severity', () async {
      final result = await run(
        [
          FakeCheck(['a.b', 'a.c'], findings: [finding('a.b'), finding('a.c')]),
        ],
        config: const AppsteinConfig(
          verify: VerifyConfig(severity: {'a.b': Severity.error}),
        ),
      );
      expect(
        {for (final finding in result.findings) finding.id: finding.severity},
        {'a.b': Severity.error, 'a.c': Severity.warning},
      );
      expect(result.errors, 1);
    });

    test('never changes knowledge.stale', () async {
      final result = await run(
        [],
        refreshed: const KnowledgeRefresh.failed('x'),
        config: const AppsteinConfig(
          verify: VerifyConfig(severity: {'knowledge.stale': Severity.info}),
        ),
      );
      expect(result.findings.single.severity, Severity.error);
    });
  });

  group('suppressions', () {
    AppsteinConfig suppressing(
      String id, {
      Map<String, Severity> severity = const {},
    }) => AppsteinConfig(
      verify: VerifyConfig(severity: severity),
      suppressions: [
        SuppressionEntry(id: id, path: 'lib/**', reason: 'Accepted.', line: 4),
      ],
    );

    test('a finding is hidden and counted', () async {
      final result = await run([
        FakeCheck(['a.b'], findings: [finding('a.b', file: 'lib/x.dart')]),
      ], config: suppressing('a.b'));
      expect(result.findings, isEmpty);
      expect(result.suppressed, 1);
    });

    test('severity overrides come first, then suppressions', () async {
      final result = await run([
        FakeCheck(['a.b'], findings: [finding('a.b', file: 'lib/x.dart')]),
      ], config: suppressing('a.b', severity: {'a.b': Severity.error}));
      expect(result.findings, isEmpty);
      expect(result.errors, 0);
    });

    test('an ID is known when any check of the project has it, whatever '
        'the mode', () async {
      final result = await run(
        [
          FakeCheck(['a.b']),
        ],
        mode: VerifyMode.fast,
        config: suppressing('a.b'),
      );
      expect(result.findings, isEmpty);
    });

    test('an ID no check has is reported, and sorted with the rest', () async {
      final result = await run([
        FakeCheck(['a.b'], findings: [finding('a.b', file: 'zzz.dart')]),
      ], config: suppressing('a.c'));
      expect(ids(result), ['suppression.unknown_check', 'a.b']);
      expect(result.findings.first.file, 'appstein.yaml');
      expect(result.errors, 1);
    });

    test('no override changes a suppression finding', () async {
      final result = await run(
        [],
        config: suppressing(
          'a.c',
          severity: {'suppression.unknown_check': Severity.info},
        ),
      );
      expect(result.findings.single.severity, Severity.error);
    });
  });

  test('findings and checks not run come back in order', () async {
    final result = await run([
      FakeCheck(['z.z'], needsMap: true),
      FakeCheck(
        ['b.b'],
        findings: [
          finding('b.b', file: 'b.md'),
          finding('b.b', file: 'a.md'),
          finding('b.b'),
        ],
      ),
      FakeCheck(['a.a'], needsMap: true),
    ], refreshed: const KnowledgeRefresh.failed('x'));
    expect(
      [for (final finding in result.findings) finding.file],
      [null, null, 'a.md', 'b.md'],
    );
    expect([for (final entry in result.notRun) entry.id], ['a.a', 'z.z']);
  });
}
