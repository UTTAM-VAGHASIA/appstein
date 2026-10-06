import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import 'support/hold_lock.dart';
import 'support/sync_harness.dart';

const _again = 'Then run `appstein verify` again.';

void main() {
  late String sdk;
  late String app;
  late FakeProcessRunner runner;

  setUp(() {
    sdk = fakeFlutter();
    app = copyFixtureApp();
    runner = FakeProcessRunner();
  });

  Future<KnowledgeRefresh> refresh({
    String? flutterRoot,
    Duration lockTimeout = const Duration(seconds: 10),
  }) => refreshKnowledge(
    knowledgeSync(
      flutterRoot: flutterRoot ?? sdk,
      runner: runner,
      packageSkills: false,
      lockTimeout: lockTimeout,
    ),
    app,
    dartSdkPath: testDartSdk,
    runAgain: _again,
  );

  test('a healthy project is brought up to date', () async {
    final first = await refresh();
    expect(first.ok, isTrue);
    expect(first.problem, isNull);
    expect(first.fixHint, isNull);
    expect(File(p.join(app, '.appstein', 'INDEX.md')).existsSync(), isTrue);
    expect((await refresh()).ok, isTrue);
  });

  test('no Flutter SDK: the sync\'s own problem and fix', () async {
    final result = await refresh(flutterRoot: p.join(app, 'no such sdk'));
    expect(result.ok, isFalse);
    expect(result.problem, isNotEmpty);
    expect(result.fixHint, isNotNull);
  });

  test('another process holds the lock: it gives up at the timeout', () async {
    expect((await refresh()).ok, isTrue);
    File(
      p.join(app, 'lib', 'main.dart'),
    ).writeAsStringSync('// changed\n', mode: FileMode.append);
    await holdLock(p.join(app, '.appstein'), 60000);
    final watch = Stopwatch()..start();
    final result = await refresh(
      lockTimeout: const Duration(milliseconds: 200),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(result.problem, lockBusyProblem);
    expect(result.fixHint, isNull);
  });

  test('the packages cannot be fetched: the map is missing', () async {
    expect((await refresh()).ok, isTrue);
    // Newer than the lock file: the packages need `flutter pub get`, which
    // the fake runner fails.
    File(
      p.join(app, 'pubspec.yaml'),
    ).setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5)));
    final result = await refresh();
    expect(result.problem, startsWith('the project map is missing ('));
    expect(result.problem, isNot(endsWith('.)')));
    expect(result.fixHint, contains('flutter pub get'));
    expect(result.fixHint, endsWith(_again));
  });

  group('fromFreshness', () {
    test('current and rebuilt are up to date', () {
      expect(
        KnowledgeRefresh.fromFreshness(const FreshnessReport.current()).ok,
        isTrue,
      );
      expect(
        KnowledgeRefresh.fromFreshness(
          const FreshnessReport.rebuilt(because: ['x'], changed: ['a']),
        ).ok,
        isTrue,
      );
    });

    test('a rebuild that skipped the map is not', () {
      final result = KnowledgeRefresh.fromFreshness(
        const FreshnessReport.rebuilt(
          because: ['x'],
          changed: [],
          mapSkipped: 'the packages could not be fetched.',
        ),
      );
      expect(
        result.problem,
        'the project map is missing (the packages could not be fetched)',
      );
      expect(result.fixHint, isNull);
    });

    test('stale carries the problem and the fix', () {
      final result = KnowledgeRefresh.fromFreshness(
        const FreshnessReport.stale(problem: 'no SDK', fixHint: 'Install it.'),
      );
      expect(result.problem, 'no SDK');
      expect(result.fixHint, 'Install it.');
    });
  });
}
