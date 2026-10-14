import 'dart:async';
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
import '../support/analyzer_warm_up.dart';
import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import '../support/scripted_code_analysis.dart';
import 'support/verify_support.dart';

const _packs = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];

/// A check that needs no map itself, with a part that does: it skips that
/// part while the map can't be used, as the decisions check does.
final class _SkippingCheck implements VerifyCheck {
  @override
  List<String> get ids => const ['part.check'];

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    if (context.mapProblem != null) context.skipped('part.inner');
    return const [];
  }
}

/// A check that gathers the code analysis's reading, and keeps the one it
/// was given when it ran. It writes what it does to [log].
final class _ReadingCheck implements GatheringCheck {
  _ReadingCheck(this.name, {this.needsMap = false, this.log, this.gatherError});

  final String name;

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  final bool needsMap;

  final List<String>? log;

  /// What [gather] throws instead of asking, when set.
  final Object? gatherError;

  /// The reading [run] was given.
  CodeReading? seen;

  @override
  List<String> get ids => [name];

  @override
  Future<void> gather(VerifyGathering gathering) async {
    log?.add('gather $name');
    if (gatherError case final error?) throw error;
    await gathering.code();
  }

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    log?.add('run $name');
    seen = context.code;
    return const [];
  }
}

/// A check that reads the code analysis's reading without gathering it:
/// a bug.
final class _ForgetfulCheck implements VerifyCheck {
  @override
  List<String> get ids => const ['forgetful.check'];

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    context.code;
    return const [];
  }
}

/// A check that gathers the project's ignore comments, and keeps the list
/// it was given when it ran. It writes what it does to [log].
final class _IgnoresCheck implements GatheringCheck {
  _IgnoresCheck(
    this.name, {
    this.needsMap = false,
    this.readsCode = false,
    this.log,
    this.beforeAsking,
    this.afterAsking,
  });

  final String name;

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  final bool needsMap;

  /// Whether [run] also reads the code reading, which it never gathered.
  final bool readsCode;

  final List<String>? log;

  /// Called in [gather], before and after it asks for the comments.
  final void Function()? beforeAsking;
  final Future<void> Function()? afterAsking;

  /// The comments [run] was given.
  List<DeprecationIgnore>? seen;

  @override
  List<String> get ids => [name];

  @override
  Future<void> gather(VerifyGathering gathering) async {
    log?.add('gather $name');
    beforeAsking?.call();
    await gathering.deprecationIgnores();
    await afterAsking?.call();
  }

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    log?.add('run $name');
    seen = context.deprecationIgnores;
    if (readsCode) context.code;
    return const [];
  }
}

/// A check that reads the project's ignore comments without gathering
/// them: a bug.
/// A code check that names itself as not run, as a `dart.*` check that
/// couldn't do its work would.
final class _DartNotRunCheck implements VerifyCheck {
  const _DartNotRunCheck();

  @override
  List<String> get ids => const ['dart.partly'];

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    context.notRun('dart.partly', 'it could not run');
    return const [];
  }
}

final class _ForgetfulIgnoresCheck implements VerifyCheck {
  @override
  List<String> get ids => const ['forgetful.ignores'];

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    context.deprecationIgnores;
    return const [];
  }
}

/// A check that, once the run knows which findings stay, adds [adds] when
/// `a.noisy` is not among them. It writes what it was shown to [seen].
final class _FollowingCheck implements FollowingCheck {
  _FollowingCheck(this.adds);

  final Finding adds;

  @override
  VerifyMode get mode => VerifyMode.full;

  final seen = <List<String>>[];

  @override
  List<String> get ids => const ['a.follow'];

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) async => const [];

  @override
  List<Finding> following(VerifyContext context, List<Finding> kept) {
    seen.add([for (final finding in kept) finding.id]);
    return kept.any((finding) => finding.id == 'a.noisy') ? const [] : [adds];
  }
}

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

  Future<VerifyResult> run(
    List<VerifyCheck> checks, {
    VerifyMode mode = VerifyMode.full,
    AppsteinConfig config = const AppsteinConfig(),
    KnowledgeRefresh? refreshed,
    String? flutterRoot,
    Duration lockTimeout = const Duration(seconds: 10),
    Map<VerifyCheck, String> from = const {},
    CodeAnalysis? codeAnalysis,
    List<String> files = const [],
  }) => runVerify(
    files: files,
    codeAnalysis: codeAnalysis ?? ScriptedCodeAnalysis(),
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

    test('`.appstein` is a file: still a result, never a crash', () async {
      File(p.join(app, '.appstein')).writeAsStringSync('in the way');
      final other = FakeCheck(['other.check']);
      final result = await run([
        FakeCheck(['map.check'], needsMap: true),
        other,
      ]);
      expect(ids(result), ['knowledge.stale']);
      expect(result.notRun.single.id, 'map.check');
      expect(other.runs, 1);
    });

    test('a suppression of a check that did not run is not called '
        'unused', () async {
      final result = await run(
        [
          FakeCheck(['map.check'], needsMap: true),
          FakeCheck(['other.check']),
        ],
        flutterRoot: p.join(app, 'no such sdk'),
        config: const AppsteinConfig(
          suppressions: [
            SuppressionEntry(
              id: 'map.check',
              path: 'lib',
              reason: 'r',
              line: 3,
            ),
            SuppressionEntry(
              id: 'other.check',
              path: 'lib',
              reason: 'r',
              line: 6,
            ),
          ],
        ),
      );
      // The entry for the check that ran, and hid nothing, is still unused.
      expect(ids(result), ['knowledge.stale', 'suppression.unused']);
      expect(result.findings.last.line, 6);
    });

    test('what a check says it skipped is named as not run, and its '
        'suppressions are not called unused', () async {
      final result = await run(
        [_SkippingCheck()],
        flutterRoot: p.join(app, 'no such sdk'),
        config: const AppsteinConfig(
          suppressions: [
            SuppressionEntry(
              id: 'part.check',
              path: 'lib',
              reason: 'r',
              line: 3,
            ),
          ],
        ),
      );
      expect(ids(result), ['knowledge.stale']);
      expect(
        [for (final entry in result.notRun) '${entry.id}: ${entry.reason}'],
        ['part.inner: the project map is not up to date'],
      );
    });

    test('another process holds the lock while the knowledge needs a '
        'rebuild: one wait, and a fix hint', () async {
      await run([]);
      // Newer than the lock file: the packages need `flutter pub get`, which
      // the fake runner fails, so the rebuild skips the map and costs next to
      // nothing, however busy the machine is. What is measured is the lock.
      File(
        p.join(app, 'pubspec.yaml'),
      ).setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5)));
      await holdLock(p.join(app, '.appstein'), 60000);
      Future<Duration> timed(Duration lockTimeout) async {
        final watch = Stopwatch()..start();
        final result = await run([
          FakeCheck(['map.check'], needsMap: true),
          FakeCheck(['other.check']),
        ], lockTimeout: lockTimeout);
        expect(ids(result), ['knowledge.stale'], reason: '$lockTimeout');
        return watch.elapsed;
      }

      // The same run with no wait at all: it does the same work (a run that
      // gives up writes nothing, and does not save the analyzer cache), so
      // what the real run takes beyond it is the waiting.
      final without = await timed(Duration.zero);
      const timeout = Duration(seconds: 3);
      final other = FakeCheck(['other.check']);
      final watch = Stopwatch()..start();
      final result = await run([
        FakeCheck(['map.check'], needsMap: true),
        other,
      ], lockTimeout: timeout);
      final waited = watch.elapsed - without;
      // It waited for the lock, and once: a second wait would take twice the
      // timeout.
      expect(watch.elapsed, greaterThanOrEqualTo(timeout));
      expect(
        waited,
        lessThan(timeout * 1.8),
        reason:
            'ran ${watch.elapsed} where the same run with no wait took '
            '$without',
      );
      expect(ids(result), ['knowledge.stale']);
      expect(result.findings.single.message, contains(lockBusyProblem));
      expect(
        result.findings.single.fixHint,
        'Wait for it to finish. Then run `appstein verify` again.',
      );
      expect(other.runs, 1);
      expect(result.notRun.single.id, 'map.check');
    }, timeout: const Timeout(Duration(minutes: 2)));

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

  group('a check that follows what stays', () {
    final noisy = FakeCheck(['a.noisy'], findings: [finding('a.noisy')]);

    test('sees the findings that stay, after severity and suppressions, '
        'and adds nothing while a.noisy stays', () async {
      final follower = _FollowingCheck(
        finding('a.follow', severity: Severity.error),
      );
      final result = await run(
        [noisy, follower],
        config: const AppsteinConfig(
          verify: VerifyConfig(severity: {'a.follow': Severity.info}),
          suppressions: [
            SuppressionEntry(
              id: 'a.noisy',
              path: 'lib',
              reason: 'Quiet.',
              line: 2,
            ),
          ],
        ),
      );
      // `a.noisy` has no file, so the suppression hides nothing: the unused
      // one is told, and the check sees it was kept.
      expect(follower.seen, [
        ['a.noisy', 'suppression.unused'],
      ]);
      expect(ids(result), ['a.noisy', 'suppression.unused']);
    });

    test('adds its finding when the others are gone, as set by '
        'verify.severity', () async {
      final follower = _FollowingCheck(
        finding('a.follow', severity: Severity.error),
      );
      final result = await run(
        [follower],
        config: const AppsteinConfig(
          verify: VerifyConfig(severity: {'a.follow': Severity.info}),
        ),
      );
      expect(
        [for (final f in result.findings) (f.id, f.severity)],
        [('a.follow', Severity.info)],
      );
    });

    test('is not asked in a fast run when it is a full check', () async {
      final follower = _FollowingCheck(finding('a.follow'));
      final result = await run([follower], mode: VerifyMode.fast);
      expect(follower.seen, isEmpty);
      expect(result.findings, isEmpty);
    });

    test('a finding with an ID it does not declare is Appstein failing', () {
      final follower = _FollowingCheck(finding('c.d'));
      return expectLater(
        run([follower]),
        throwsA(
          isA<VerifyCheckError>().having(
            (e) => '$e',
            'text',
            allOf(contains('`a.follow`'), contains('`c.d`')),
          ),
        ),
      );
    });

    test('the finding carries the pack the check came from', () async {
      final follower = _FollowingCheck(finding('a.follow'));
      final result = await run([follower], from: {follower: 'some_pack'});
      expect(result.findings.single.pack, 'some_pack');
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

  group('the code analysis', () {
    CodeDiagnostic diagnostic(
      DiagnosticLevel level, {
      String file = 'lib/a.dart',
      int line = 3,
      String code = 'some_code',
      String message = 'Something is wrong.',
      String? correction,
    }) => CodeDiagnostic(
      file: file,
      line: line,
      code: code,
      message: message,
      level: level,
      correction: correction,
    );

    test('a run in which no check gathers it never asks it', () async {
      final analysis = ScriptedCodeAnalysis();
      await run([
        FakeCheck(['a.a']),
      ], codeAnalysis: analysis);
      expect(analysis.asked, 0);
    });

    test('it is asked once per run, before any check runs, and every check '
        'judges that one reading', () async {
      final log = <String>[];
      late ScriptedCodeAnalysis analysis;
      analysis = ScriptedCodeAnalysis(
        found: [diagnostic(DiagnosticLevel.error, code: 'first')],
        onAsked: () async {
          log.add('asked');
          // A second ask would answer something else.
          if (analysis.asked > 1) {
            analysis.found = [diagnostic(DiagnosticLevel.error, code: 'later')];
          }
        },
      );
      final one = _ReadingCheck('one.check', log: log);
      final two = _ReadingCheck('two.check', log: log);
      await run([one, two], codeAnalysis: analysis);
      expect(analysis.asked, 1);
      expect(log, [
        'gather one.check',
        'asked',
        'gather two.check',
        'run one.check',
        'run two.check',
      ]);
      expect(one.seen, same(two.seen));
      expect(
        [for (final found in one.seen!.diagnostics) found.code],
        ['first'],
      );
    });

    test('it is asked while the knowledge lock is free', () async {
      // A lock taken from here would wait if the run held it: on Windows a
      // second handle in one process can't share a file lock.
      Object? lockProblem;
      final analysis = ScriptedCodeAnalysis(
        onAsked: () async {
          try {
            await KnowledgeStore(
              app,
            ).locked(() async {}, timeout: const Duration(milliseconds: 300));
          } on Object catch (error) {
            lockProblem = error;
          }
        },
      );
      await run([_ReadingCheck('one.check')], codeAnalysis: analysis);
      expect(analysis.asked, 1);
      expect(lockProblem, isNull);
    });

    test('a check that reads the reading without gathering it fails '
        'loudly', () async {
      await expectLater(
        run([_ForgetfulCheck()]),
        throwsA(
          isA<VerifyCheckError>()
              .having((e) => e.checkId, 'checkId', 'forgetful.check')
              .having((e) => '$e', 'text', contains('GatheringCheck')),
        ),
      );
    });

    test('also when another check of the run gathered it, and the error '
        'names the check that didn\'t', () async {
      final gathered = _ReadingCheck('one.check');
      await expectLater(
        run([gathered, _ForgetfulCheck()]),
        throwsA(
          isA<VerifyCheckError>()
              .having((e) => e.checkId, 'checkId', 'forgetful.check')
              .having(
                (e) => '${e.error}',
                'the error',
                allOf(
                  isA<String>(),
                  contains(
                    'The check `forgetful.check` read the code analysis '
                    'without gathering it.',
                  ),
                ),
              ),
        ),
      );
      // The check that gathered it was given it.
      expect(gathered.seen, isNotNull);
    });

    test('a check that throws while gathering is a failed check', () async {
      await expectLater(
        run([_ReadingCheck('bad.check', gatherError: StateError('boom'))]),
        throwsA(
          isA<VerifyCheckError>().having(
            (e) => e.checkId,
            'checkId',
            'bad.check',
          ),
        ),
      );
    });

    test('a map check gathers nothing while the knowledge is stale', () async {
      final analysis = ScriptedCodeAnalysis();
      final check = _ReadingCheck('map.check', needsMap: true);
      final result = await run(
        [check],
        codeAnalysis: analysis,
        refreshed: const KnowledgeRefresh.failed('x'),
      );
      expect(analysis.asked, 0);
      expect(check.seen, isNull);
      expect(result.notRun.single.id, 'map.check');
    });

    test('dart.plugin_failed: each plugin failure is an error on the '
        'project, in a fast run too', () async {
      final result = await run(
        [const DartErrorCheck(), const PluginFailedCheck()],
        mode: VerifyMode.fast,
        codeAnalysis: ScriptedCodeAnalysis(
          pluginFailures: [
            'An error occurred while setting up the analyzer plugin package '
                'at X: version solving failed',
          ],
        ),
      );
      final failed = result.findings.single;
      expect(failed.id, pluginFailedId);
      expect(pluginFailedId, 'dart.plugin_failed');
      expect(failed.severity, Severity.error);
      expect(failed.file, isNull);
      expect(failed.line, isNull);
      expect(
        failed.message,
        'An analyzer plugin failed, so its rules were not checked: An error '
        'occurred while setting up the analyzer plugin package at X: '
        'version solving failed.',
      );
      expect(
        failed.fixHint,
        allOf(
          contains('`appstein doctor`'),
          contains('`plugins:`'),
          contains('`analysis_options.yaml`'),
        ),
      );
      expect(result.errors, 1);
    });

    test('dart.plugin_failed: nothing when every plugin loaded', () async {
      final result = await run([
        const PluginFailedCheck(),
      ], codeAnalysis: ScriptedCodeAnalysis());
      expect(result.findings, isEmpty);
    });

    test('dart.error: an error-level diagnostic is an error with its file, '
        'line, message, code and correction', () async {
      final result = await run(
        [const DartErrorCheck()],
        mode: VerifyMode.fast,
        codeAnalysis: ScriptedCodeAnalysis(
          found: [
            diagnostic(
              DiagnosticLevel.error,
              file: 'lib/ui/home screen.dart',
              line: 12,
              code: 'undefined_method',
              message: "The method 'go' isn't defined for the type 'Home'.",
              correction: "Try correcting the name, or defining 'go'.",
            ),
            diagnostic(DiagnosticLevel.error, code: 'no_correction'),
          ],
        ),
      );
      expect(ids(result), ['dart.error', 'dart.error']);
      final [plain, full] = result.findings;
      expect(full.severity, Severity.error);
      expect(full.file, 'lib/ui/home screen.dart');
      expect(full.line, 12);
      expect(
        full.message,
        "The method 'go' isn't defined for the type 'Home'. "
        '(`undefined_method`)',
      );
      expect(full.fixHint, "Try correcting the name, or defining 'go'.");
      expect(full.pack, isNull);
      expect(plain.message, 'Something is wrong. (`no_correction`)');
      expect(plain.fixHint, isNull);
      expect(result.errors, 2);
    });

    test('dart.error: a warning and an info-level diagnostic are not '
        'reported', () async {
      final result = await run(
        [const DartErrorCheck()],
        codeAnalysis: ScriptedCodeAnalysis(
          found: [
            diagnostic(DiagnosticLevel.warning, code: 'unused_import'),
            diagnostic(DiagnosticLevel.info, code: 'prefer_const'),
          ],
        ),
      );
      expect(result.findings, isEmpty);
    });

    test('dart.error runs while the knowledge is stale', () async {
      final result = await run(
        [const DartErrorCheck()],
        refreshed: const KnowledgeRefresh.failed('the packages are missing'),
        codeAnalysis: ScriptedCodeAnalysis(
          found: [diagnostic(DiagnosticLevel.error)],
        ),
      );
      expect(ids(result), ['knowledge.stale', 'dart.error']);
      expect(result.notRun, isEmpty);
    });

    test('dart.error: verify.severity changes it and a suppression hides '
        'it', () async {
      final analysis = ScriptedCodeAnalysis(
        found: [
          diagnostic(DiagnosticLevel.error, file: 'lib/a.dart'),
          diagnostic(DiagnosticLevel.error, file: 'lib/legacy/b.dart'),
        ],
      );
      final result = await run(
        [const DartErrorCheck()],
        codeAnalysis: analysis,
        config: const AppsteinConfig(
          verify: VerifyConfig(severity: {'dart.error': Severity.warning}),
          suppressions: [
            SuppressionEntry(
              id: 'dart.error',
              path: 'lib/legacy',
              reason: 'Rewritten next month.',
              line: 4,
            ),
          ],
        ),
      );
      expect(
        [for (final found in result.findings) (found.file, found.severity)],
        [('lib/a.dart', Severity.warning)],
      );
      expect(result.suppressed, 1);
      expect(result.errors, 0);
    });

    test('a server that can\'t answer fails the run, and no check is '
        'blamed', () async {
      const failure = CodeAnalysisException(
        'its analysis was not done within 180 s',
      );
      final other = FakeCheck(['other.check']);
      await expectLater(
        run([
          other,
          const DartErrorCheck(),
        ], codeAnalysis: ScriptedCodeAnalysis(failure: failure)),
        throwsA(same(failure)),
      );
      // It is known before any check runs, and before the lock is taken.
      expect(other.runs, 0);
      expect(
        '$failure',
        'The Dart analysis server could not answer: its analysis was not '
            'done within 180 s.',
      );
    });

    test('a full check gathers nothing in a fast run', () async {
      final analysis = ScriptedCodeAnalysis();
      await run(
        [_ReadingCheck('full.check')],
        mode: VerifyMode.fast,
        codeAnalysis: analysis,
      );
      expect(analysis.asked, 0);
    });

    group('dart.deprecated', () {
      void write(String relative, String content) =>
          File(p.joinAll([app, ...relative.split('/')]))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(content);

      const hint =
          'Replace it with the API the message names. `dart fix --dry-run` '
          'lists the uses it can migrate by itself.';

      for (final mode in VerifyMode.values) {
        test('${mode.name}: each deprecated_member_use diagnostic and each '
            'variant is an error with its file, line, message and code, at '
            'any level', () async {
          final result = await run(
            [const DartDeprecatedCheck()],
            mode: mode,
            codeAnalysis: ScriptedCodeAnalysis(
              found: [
                diagnostic(
                  DiagnosticLevel.info,
                  file: 'lib/ui/home screen.dart',
                  line: 12,
                  code: 'deprecated_member_use',
                  message:
                      "'withOpacity' is deprecated and shouldn't be used. "
                      'Use withValues.',
                  correction:
                      'Try replacing the use of the deprecated member with '
                      'the replacement.',
                ),
                diagnostic(
                  DiagnosticLevel.info,
                  file: 'lib/ui/home screen.dart',
                  line: 20,
                  code: 'deprecated_member_use_from_same_package',
                  message: "'old' is deprecated and shouldn't be used.",
                ),
                diagnostic(
                  DiagnosticLevel.warning,
                  file: 'test/a_test.dart',
                  line: 4,
                  code: 'deprecated_member_use_with_message',
                  message: 'Raised to a warning.',
                ),
                diagnostic(
                  DiagnosticLevel.error,
                  file: 'test/a_test.dart',
                  line: 7,
                  code: 'DEPRECATED_MEMBER_USE',
                  message: 'Raised to an error.',
                ),
              ],
            ),
          );
          expect(
            [
              for (final found in result.findings)
                (found.id, found.severity, found.file, found.line),
            ],
            [
              (
                'dart.deprecated',
                Severity.error,
                'lib/ui/home screen.dart',
                12,
              ),
              (
                'dart.deprecated',
                Severity.error,
                'lib/ui/home screen.dart',
                20,
              ),
              ('dart.deprecated', Severity.error, 'test/a_test.dart', 4),
              ('dart.deprecated', Severity.error, 'test/a_test.dart', 7),
            ],
          );
          expect(
            [for (final found in result.findings) found.message],
            [
              "'withOpacity' is deprecated and shouldn't be used. Use "
                  'withValues. (`deprecated_member_use`)',
              "'old' is deprecated and shouldn't be used. "
                  '(`deprecated_member_use_from_same_package`)',
              'Raised to a warning. (`deprecated_member_use_with_message`)',
              'Raised to an error. (`DEPRECATED_MEMBER_USE`)',
            ],
          );
          // The general hint, with or without the analyzer's correction.
          expect({for (final found in result.findings) found.fixHint}, {hint});
          expect({for (final found in result.findings) found.pack}, {null});
          expect(result.errors, 4);
        });
      }

      test('a diagnostic with another code is not reported, whatever its '
          'level', () async {
        final result = await run(
          [const DartDeprecatedCheck()],
          codeAnalysis: ScriptedCodeAnalysis(
            found: [
              diagnostic(DiagnosticLevel.error, code: 'undefined_method'),
              diagnostic(DiagnosticLevel.warning, code: 'unused_import'),
              diagnostic(DiagnosticLevel.info, code: 'deprecated_export_use'),
              // It only starts like one: no analyzer has this code.
              diagnostic(DiagnosticLevel.info, code: 'deprecated_member_use_x'),
              diagnostic(DiagnosticLevel.info, code: 'prefer_const'),
            ],
          ),
        );
        expect(result.findings, isEmpty);
      });

      test('with dart.error: a deprecated use the project made an error is '
          'reported once, as dart.deprecated', () async {
        final analysis = ScriptedCodeAnalysis(
          found: [
            diagnostic(DiagnosticLevel.error, code: 'deprecated_member_use'),
            diagnostic(
              DiagnosticLevel.error,
              line: 5,
              code: 'DEPRECATED_MEMBER_USE_FROM_SAME_PACKAGE',
            ),
            diagnostic(DiagnosticLevel.info, code: 'deprecated_member_use'),
            diagnostic(DiagnosticLevel.error, line: 9, code: 'other_error'),
          ],
        );
        final result = await run(
          [const DartErrorCheck(), const DartDeprecatedCheck()],
          mode: VerifyMode.fast,
          codeAnalysis: analysis,
        );
        expect(
          [for (final found in result.findings) (found.id, found.line)],
          [
            ('dart.deprecated', 3),
            ('dart.deprecated', 3),
            ('dart.deprecated', 5),
            ('dart.error', 9),
          ],
        );
        // Also when `dart.error` runs alone.
        final alone = await run(
          [const DartErrorCheck()],
          mode: VerifyMode.fast,
          codeAnalysis: analysis,
        );
        expect(
          [for (final found in alone.findings) (found.id, found.line)],
          [('dart.error', 9)],
        );
      });

      for (final mode in VerifyMode.values) {
        test('${mode.name}: a comment that says type=hint is an error on '
            'its line; one that says type=lint is not', () async {
          write('lib/hints.dart', '''
// ignore_for_file: type=lint
void f() {
  // ignore: type=hint
  g();
  g(); // ignore: type=lint
}

void g() {}
// ignore_for_file: unused_element, TYPE = HINT
''');
          final result = await run(
            [const DartDeprecatedCheck()],
            mode: mode,
            codeAnalysis: ScriptedCodeAnalysis(
              analyzedFiles: ['lib/hints.dart'],
            ),
          );
          expect(
            [
              for (final found in result.findings)
                (found.id, found.severity, found.file, found.line),
            ],
            [
              ('dart.deprecated', Severity.error, 'lib/hints.dart', 3),
              ('dart.deprecated', Severity.error, 'lib/hints.dart', 9),
            ],
          );
          final [forLine, forFile] = result.findings;
          expect(
            forLine.message,
            'This `// ignore:` comment says `type=hint`: it tells the '
            'analyzer to hide every hint on its line, and the use of a '
            'deprecated API is a hint.',
          );
          expect(
            forFile.message,
            'This `// ignore_for_file:` comment says `type=hint`: it tells '
            'the analyzer to hide every hint in this file, and the use of a '
            'deprecated API is a hint.',
          );
          expect(
            {for (final found in result.findings) found.fixHint},
            {
              'Name the hints to hide in place of `type=hint`, and replace '
                  'any deprecated API. If it has to stay, accept the finding '
                  'where it can be seen: a `suppressions:` entry for '
                  '`dart.deprecated` with a `reason` in `appstein.yaml`.',
            },
          );
        });

        test('${mode.name}: an analysis_options.yaml entry that switches a '
            'deprecated-use diagnostic off is an error on its line, in the '
            'root\'s file and in a folder\'s', () async {
          write('analysis_options.yaml', '''
analyzer:
  exclude:
    - lib/generated/**
  errors:
    unused_import: ignore
    deprecated_member_use: ignore
    todo: info
''');
          write('packages/inner/analysis_options.yaml', '''
analyzer:
  errors:
    deprecated_member_use_from_same_package: false
    deprecated_member_use: warning
''');
          final result = await run(
            [const DartDeprecatedCheck()],
            mode: mode,
            codeAnalysis: ScriptedCodeAnalysis(
              analyzedFiles: [
                'analysis_options.yaml',
                'packages/inner/analysis_options.yaml',
                'pubspec.yaml',
              ],
            ),
          );
          expect(
            [
              for (final found in result.findings)
                (found.id, found.severity, found.file, found.line),
            ],
            [
              ('dart.deprecated', Severity.error, 'analysis_options.yaml', 6),
              (
                'dart.deprecated',
                Severity.error,
                'packages/inner/analysis_options.yaml',
                3,
              ),
            ],
          );
          final [root, inner] = result.findings;
          expect(
            root.message,
            'This entry sets `deprecated_member_use` to `ignore`: it tells '
            'the analyzer not to report the use of a deprecated API in the '
            'files this options file covers.',
          );
          expect(
            inner.message,
            'This entry sets `deprecated_member_use_from_same_package` to '
            '`false`: it tells the analyzer not to report the use of a '
            'deprecated API in the files this options file covers.',
          );
          expect(
            {for (final found in result.findings) found.fixHint},
            {
              'Remove the entry and replace the deprecated APIs. If it has to '
                  'stay, accept the finding where it can be seen: a '
                  '`suppressions:` entry for `dart.deprecated` with a `reason` '
                  'in `appstein.yaml`.',
            },
          );
        });
      }

      // The analyzer applies the nearest options file above a project that
      // has none, so that file is read though the server doesn't list it. It
      // is outside the project: its path starts with `../`, which no
      // `suppressions:` path may (the config refuses it), so the fix hint
      // doesn't offer that way out.
      test('an analysis_options.yaml above a project without one is an error '
          'on its line, with a fix hint that offers no suppression', () async {
        File(p.join(p.dirname(app), 'analysis_options.yaml')).writeAsStringSync(
          '# Shared.\nanalyzer:\n  errors:\n    deprecated_member_use: ignore\n',
        );
        final result = await run([
          const DartDeprecatedCheck(),
        ], codeAnalysis: ScriptedCodeAnalysis(analyzedFiles: ['pubspec.yaml']));
        final finding = result.findings.single;
        expect(
          (finding.id, finding.severity, finding.file, finding.line),
          ('dart.deprecated', Severity.error, '../analysis_options.yaml', 4),
        );
        expect(
          finding.message,
          'This entry sets `deprecated_member_use` to `ignore`: it tells the '
          'analyzer not to report the use of a deprecated API in the files '
          'this options file covers.',
        );
        expect(
          finding.fixHint,
          'Remove the entry and replace the deprecated APIs. When that file '
          'is shared and has to stay as it is, give the project an '
          '`analysis_options.yaml` of its own that names the file above '
          'under `include:`, so its other rules still apply, and sets '
          '`deprecated_member_use` back to `info` under `analyzer: errors:`. '
          'An options file without that `include:` switches every rule of '
          'the file above off. A `suppressions:` path must be inside the '
          'project, so this finding can\'t be accepted there.',
        );
      });

      // The analyzer follows an `include:` and applies the included file's
      // settings, so a switch-off there hides the use as much as one in the
      // project's own file. The finding is on the included file's line.
      test('a switch-off in a file above the project that the project\'s own '
          'options file includes is an error on that file, with the short '
          'way out', () async {
        File(p.join(p.dirname(app), 'base_options.yaml')).writeAsStringSync(
          '# Shared.\nanalyzer:\n  errors:\n    deprecated_member_use: ignore\n',
        );
        write('analysis_options.yaml', 'include: ../base_options.yaml\n');
        final result = await run(
          [const DartDeprecatedCheck()],
          codeAnalysis: ScriptedCodeAnalysis(
            analyzedFiles: ['analysis_options.yaml'],
          ),
        );
        final finding = result.findings.single;
        expect(
          (finding.id, finding.severity, finding.file, finding.line),
          ('dart.deprecated', Severity.error, '../base_options.yaml', 4),
        );
        expect(
          finding.message,
          'This entry sets `deprecated_member_use` to `ignore`: it tells the '
          'analyzer not to report the use of a deprecated API in the files '
          'covered by the options files that include this file.',
        );
        expect(
          finding.fixHint,
          'Remove the entry and replace the deprecated APIs. When that shared '
          'file has to stay as it is, set `deprecated_member_use` back to '
          '`info` under `analyzer: errors:` in `analysis_options.yaml`, '
          'which includes it: the setting of the including file wins. A '
          '`suppressions:` path must be inside the project, so this finding '
          'can\'t be accepted there.',
        );
      });

      test('the project\'s own options file that sets the code back to info '
          'leaves the included file\'s switch-off unreported', () async {
        File(p.join(p.dirname(app), 'base_options.yaml')).writeAsStringSync(
          'analyzer:\n  errors:\n    deprecated_member_use: ignore\n',
        );
        write(
          'analysis_options.yaml',
          'include: ../base_options.yaml\n'
              'analyzer:\n  errors:\n    deprecated_member_use: info\n',
        );
        final result = await run(
          [const DartDeprecatedCheck()],
          codeAnalysis: ScriptedCodeAnalysis(
            analyzedFiles: ['analysis_options.yaml'],
          ),
        );
        expect(result.findings, isEmpty);
      });

      test('a switch-off in a file inside the project that two options files '
          'include is one error, with the ordinary hint and way out', () async {
        write(
          'shared/base.yaml',
          'analyzer:\n  errors:\n    deprecated_member_use: false\n',
        );
        write('analysis_options.yaml', 'include: shared/base.yaml\n');
        write(
          'packages/inner/analysis_options.yaml',
          'include: ../../shared/base.yaml\n',
        );
        final result = await run(
          [const DartDeprecatedCheck()],
          codeAnalysis: ScriptedCodeAnalysis(
            analyzedFiles: [
              'analysis_options.yaml',
              'packages/inner/analysis_options.yaml',
            ],
          ),
        );
        final finding = result.findings.single;
        expect(
          (finding.id, finding.severity, finding.file, finding.line),
          ('dart.deprecated', Severity.error, 'shared/base.yaml', 3),
        );
        expect(
          finding.message,
          'This entry sets `deprecated_member_use` to `false`: it tells the '
          'analyzer not to report the use of a deprecated API in the files '
          'covered by the options files that include this file.',
        );
        expect(
          finding.fixHint,
          'Remove the entry and replace the deprecated APIs. If it has to '
          'stay, accept the finding where it can be seen: a `suppressions:` '
          'entry for `dart.deprecated` with a `reason` in `appstein.yaml`.',
        );
      });

      // Neither of the two files is in the project: the project has no
      // options file of its own to name, so the hint is the one for a file
      // above the project.
      test('a switch-off in a file that only the options file above the '
          'project includes keeps the hint for a file above', () async {
        File(
          p.join(p.dirname(app), 'analysis_options.yaml'),
        ).writeAsStringSync('include: base_options.yaml\n');
        File(p.join(p.dirname(app), 'base_options.yaml')).writeAsStringSync(
          'analyzer:\n  errors:\n    deprecated_member_use: ignore\n',
        );
        final result = await run([
          const DartDeprecatedCheck(),
        ], codeAnalysis: ScriptedCodeAnalysis(analyzedFiles: ['pubspec.yaml']));
        final finding = result.findings.single;
        expect((finding.file, finding.line), ('../base_options.yaml', 3));
        expect(
          finding.fixHint,
          startsWith(
            'Remove the entry and replace the deprecated APIs. When that file '
            'is shared and has to stay as it is, give the project an '
            '`analysis_options.yaml` of its own that names the file above '
            'under `include:`',
          ),
        );
      });

      test('an analysis_options.yaml that can\'t be parsed, or that the '
          'server did not analyze, does not fail the run and reports '
          'nothing', () async {
        write('analysis_options.yaml', 'analyzer: [\n  errors\n');
        write(
          'tool/analysis_options.yaml',
          'analyzer:\n  errors:\n    deprecated_member_use: ignore\n',
        );
        final result = await run(
          [const DartDeprecatedCheck()],
          codeAnalysis: ScriptedCodeAnalysis(
            analyzedFiles: ['analysis_options.yaml'],
          ),
        );
        expect(result.findings, isEmpty);
      });

      test('a suppression with a reason hides the entry\'s finding, and '
          'verify.severity changes it', () async {
        const off = 'analyzer:\n  errors:\n    deprecated_member_use: ignore\n';
        write('analysis_options.yaml', off);
        write('packages/inner/analysis_options.yaml', off);
        final result = await run(
          [const DartDeprecatedCheck()],
          codeAnalysis: ScriptedCodeAnalysis(
            analyzedFiles: [
              'analysis_options.yaml',
              'packages/inner/analysis_options.yaml',
            ],
          ),
          config: const AppsteinConfig(
            verify: VerifyConfig(
              severity: {'dart.deprecated': Severity.warning},
            ),
            suppressions: [
              SuppressionEntry(
                id: 'dart.deprecated',
                path: 'analysis_options.yaml',
                reason: 'Migrated in the next sprint.',
                line: 4,
              ),
            ],
          ),
        );
        expect(
          [for (final found in result.findings) (found.file, found.severity)],
          [('packages/inner/analysis_options.yaml', Severity.warning)],
        );
        expect(result.suppressed, 1);
      });

      for (final mode in VerifyMode.values) {
        test('${mode.name}: a comment that names a deprecated-use code is an '
            'error on the comment\'s line, with the way out', () async {
          write('lib/my folder/hides.dart', '''
/// Hides.
void f() {
  // ignore: deprecated_member_use
  g();
  g(); // ignore: unused_local_variable, deprecated_member_use_from_same_package
}

/// Old.
void g() {}
''');
          write('test/whole_file_test.dart', '''
void main() {}

// ignore_for_file: deprecated_member_use, deprecated_member_use_from_same_package
''');
          final result = await run(
            [const DartDeprecatedCheck()],
            mode: mode,
            // The comments work: the analyzer has nothing to say, but it
            // names the files it analyzed.
            codeAnalysis: ScriptedCodeAnalysis(
              analyzedFiles: [
                'lib/my folder/hides.dart',
                'pubspec.yaml',
                'test/whole_file_test.dart',
              ],
            ),
          );
          expect(
            [
              for (final found in result.findings)
                (found.id, found.severity, found.file, found.line),
            ],
            [
              (
                'dart.deprecated',
                Severity.error,
                'lib/my folder/hides.dart',
                3,
              ),
              (
                'dart.deprecated',
                Severity.error,
                'lib/my folder/hides.dart',
                5,
              ),
              (
                'dart.deprecated',
                Severity.error,
                'test/whole_file_test.dart',
                3,
              ),
            ],
          );
          final [above, atEnd, wholeFile] = result.findings;
          expect(
            above.message,
            'This `// ignore:` comment names `deprecated_member_use`: it '
            'tells the analyzer to hide the use of a deprecated API.',
          );
          expect(
            atEnd.message,
            'This `// ignore:` comment names '
            '`deprecated_member_use_from_same_package`: it tells the '
            'analyzer to hide the use of a deprecated API.',
          );
          expect(
            wholeFile.message,
            'This `// ignore_for_file:` comment names '
            '`deprecated_member_use` and '
            '`deprecated_member_use_from_same_package`: it tells the '
            'analyzer to hide every use of a deprecated API in this file.',
          );
          const wayOut =
              'Take the code out of the comment and replace the deprecated '
              'API. If it has to stay, accept the finding where it can be '
              'seen: a `suppressions:` entry for `dart.deprecated` with a '
              '`reason` in `appstein.yaml`.';
          expect(
            {for (final found in result.findings) found.fixHint},
            {wayOut},
          );
          expect(result.errors, 3);
        });
      }

      test('an ignore comment for other codes, and text that looks like one '
          'in a string or a doc comment\'s sample, is not reported', () async {
        write('lib/not_hiding.dart', r"""
// ignore_for_file: unused_import, avoid_print
import 'dart:math';

/// Says how to hide it, which hides nothing.
///
/// ```dart
/// // ignore: deprecated_member_use
/// g();
/// ```
const advice = '// ignore: deprecated_member_use';

/// More of it.
const more = '''
// ignore_for_file: deprecated_member_use
''';

/// Prints.
void f() {
  // ignore: avoid_print
  print('$advice $more');
}
""");
        final result = await run(
          [const DartDeprecatedCheck()],
          codeAnalysis: ScriptedCodeAnalysis(
            analyzedFiles: ['lib/not_hiding.dart'],
          ),
        );
        expect(result.findings, isEmpty);
      });

      test('only the files the analysis server analyzed are read: a comment '
          'in a file it left out is not reported, and one in a part file '
          'with another ending is', () async {
        const hiding = '// ignore_for_file: deprecated_member_use\n';
        // Excluded in `analysis_options.yaml`, say: the server didn't list
        // it.
        write('lib/generated/api.dart', hiding);
        write('lib/whole.dart', "part 'odd.part';\n");
        write('lib/odd.part', "${hiding}part of 'whole.dart';\n");
        final result = await run(
          [const DartDeprecatedCheck()],
          codeAnalysis: ScriptedCodeAnalysis(
            analyzedFiles: ['lib/odd.part', 'lib/whole.dart', 'pubspec.yaml'],
          ),
        );
        expect(
          [for (final found in result.findings) (found.file, found.line)],
          [('lib/odd.part', 1)],
        );
      });

      test('a comment with a made-up name that starts like one is not '
          'reported', () async {
        write(
          'lib/made_up.dart',
          '// ignore_for_file: deprecated_member_use_x\n',
        );
        final result = await run(
          [const DartDeprecatedCheck()],
          codeAnalysis: ScriptedCodeAnalysis(
            analyzedFiles: ['lib/made_up.dart'],
          ),
        );
        expect(result.findings, isEmpty);
      });

      test('a use and the comment that fails to hide it are both '
          'reported', () async {
        write(
          'lib/both.dart',
          '// ignore_for_file: deprecated_member_use_from_same_package\n'
              'int a = 1;\n',
        );
        final result = await run(
          [const DartDeprecatedCheck()],
          codeAnalysis: ScriptedCodeAnalysis(
            analyzedFiles: ['lib/both.dart'],
            found: [
              diagnostic(
                DiagnosticLevel.info,
                file: 'lib/both.dart',
                line: 2,
                code: 'deprecated_member_use',
              ),
            ],
          ),
        );
        expect(
          [for (final found in result.findings) (found.file, found.line)],
          [('lib/both.dart', 1), ('lib/both.dart', 2)],
        );
      });

      test('verify.severity changes both kinds, and a suppression with a '
          'reason hides both', () async {
        write(
          'lib/legacy/old.dart',
          '// ignore_for_file: deprecated_member_use\n',
        );
        write('lib/new.dart', '// ignore_for_file: deprecated_member_use\n');
        final result = await run(
          [const DartDeprecatedCheck()],
          mode: VerifyMode.fast,
          codeAnalysis: ScriptedCodeAnalysis(
            analyzedFiles: ['lib/legacy/old.dart', 'lib/new.dart'],
            found: [
              diagnostic(
                DiagnosticLevel.info,
                file: 'lib/a.dart',
                code: 'deprecated_member_use',
              ),
              diagnostic(
                DiagnosticLevel.info,
                file: 'lib/legacy/b.dart',
                code: 'deprecated_member_use',
              ),
            ],
          ),
          config: const AppsteinConfig(
            verify: VerifyConfig(
              severity: {'dart.deprecated': Severity.warning},
            ),
            suppressions: [
              SuppressionEntry(
                id: 'dart.deprecated',
                path: 'lib/legacy',
                reason: 'Rewritten next month.',
                line: 4,
              ),
            ],
          ),
        );
        expect(
          [for (final found in result.findings) (found.file, found.severity)],
          [
            ('lib/a.dart', Severity.warning),
            ('lib/new.dart', Severity.warning),
          ],
        );
        expect(result.suppressed, 2);
        expect(result.activeSuppressions, 1);
        expect(result.errors, 0);
      });

      test('it runs while the knowledge is stale', () async {
        write('lib/hides.dart', '// ignore_for_file: deprecated_member_use\n');
        final result = await run(
          [const DartDeprecatedCheck()],
          refreshed: const KnowledgeRefresh.failed('the packages are missing'),
          codeAnalysis: ScriptedCodeAnalysis(
            analyzedFiles: ['lib/hides.dart'],
            found: [
              diagnostic(DiagnosticLevel.info, code: 'deprecated_member_use'),
            ],
          ),
        );
        expect(ids(result), [
          'knowledge.stale',
          'dart.deprecated',
          'dart.deprecated',
        ]);
        expect(result.notRun, isEmpty);
      });

      test('beside another check that gathers the reading, the server is '
          'asked once', () async {
        write('lib/hides.dart', '// ignore_for_file: deprecated_member_use\n');
        final analysis = ScriptedCodeAnalysis(
          analyzedFiles: ['lib/hides.dart'],
        );
        final result = await run([
          _ReadingCheck('one.check'),
          const DartDeprecatedCheck(),
        ], codeAnalysis: analysis);
        expect(analysis.asked, 1);
        expect(ids(result), ['dart.deprecated']);
      });

      test(
        'a check that gathers only the comments has the server asked '
        'once, for the files to read, and may not read the reading',
        () async {
          write(
            'lib/hides.dart',
            '// ignore_for_file: deprecated_member_use\n',
          );
          final analysis = ScriptedCodeAnalysis(
            analyzedFiles: ['lib/hides.dart'],
          );
          final check = _IgnoresCheck('one.check');
          await run([check], codeAnalysis: analysis);
          expect(analysis.asked, 1);
          expect(
            [for (final comment in check.seen!) comment.file],
            ['lib/hides.dart'],
          );
          await expectLater(
            run([_IgnoresCheck('two.check', readsCode: true)]),
            throwsA(
              isA<VerifyCheckError>().having(
                (e) => '${e.error}',
                'the error',
                contains('read the code analysis without gathering it'),
              ),
            ),
          );
        },
      );

      test('the source files are read once per run, before any check runs, '
          'and every check that asked judges that one list', () async {
        const file = 'lib/hides.dart';
        write(file, '// ignore_for_file: deprecated_member_use\n');
        final log = <String>[];
        final analysis = ScriptedCodeAnalysis(analyzedFiles: [file]);
        final one = _IgnoresCheck('one.check', log: log);
        // By the time the second check asks, the file names nothing: a
        // second reading would find no comment.
        final two = _IgnoresCheck(
          'two.check',
          log: log,
          beforeAsking: () => write(file, 'int a = 1;\n'),
        );
        await run([one, two], codeAnalysis: analysis);
        expect(analysis.asked, 1);
        expect(log, [
          'gather one.check',
          'gather two.check',
          'run one.check',
          'run two.check',
        ]);
        expect(one.seen, hasLength(1));
        expect(two.seen, same(one.seen));
      });

      test('the source files are read while the knowledge lock is '
          'free', () async {
        write('lib/hides.dart', '// ignore_for_file: deprecated_member_use\n');
        // A lock taken from here would wait if the run held it: on Windows
        // a second handle in one process can't share a file lock.
        Object? lockProblem;
        var tried = false;
        final check = _IgnoresCheck(
          'one.check',
          afterAsking: () async {
            tried = true;
            try {
              await KnowledgeStore(
                app,
              ).locked(() async {}, timeout: const Duration(milliseconds: 300));
            } on Object catch (error) {
              lockProblem = error;
            }
          },
        );
        await run(
          [check],
          codeAnalysis: ScriptedCodeAnalysis(analyzedFiles: ['lib/hides.dart']),
        );
        // The files had been read by then.
        expect(check.seen, hasLength(1));
        expect(tried, isTrue);
        expect(lockProblem, isNull);
      });

      test('a full check gathers no comments in a fast run, and a map check '
          'none while the knowledge is stale', () async {
        write('lib/hides.dart', '// ignore_for_file: deprecated_member_use\n');
        final analysis = ScriptedCodeAnalysis(
          analyzedFiles: ['lib/hides.dart'],
        );
        final full = _IgnoresCheck('full.check');
        await run([full], mode: VerifyMode.fast, codeAnalysis: analysis);
        final map = _IgnoresCheck('map.check', needsMap: true);
        await run(
          [map],
          codeAnalysis: analysis,
          refreshed: const KnowledgeRefresh.failed('x'),
        );
        expect(analysis.asked, 0);
        expect((full.seen, map.seen), (null, null));
      });

      test('a server that can\'t answer fails the run when the comments are '
          'asked for, and no check is blamed', () async {
        const failure = CodeAnalysisException('it ended by itself');
        await expectLater(
          run([
            _IgnoresCheck('one.check'),
          ], codeAnalysis: ScriptedCodeAnalysis(failure: failure)),
          throwsA(same(failure)),
        );
      });

      test('a check that reads the ignore comments without gathering them '
          'fails loudly, also beside one that did', () async {
        await expectLater(
          run([const DartDeprecatedCheck(), _ForgetfulIgnoresCheck()]),
          throwsA(
            isA<VerifyCheckError>()
                .having((e) => e.checkId, 'checkId', 'forgetful.ignores')
                .having(
                  (e) => '${e.error}',
                  'the error',
                  allOf(
                    contains(
                      'The check `forgetful.ignores` read the project\'s '
                      'ignore comments without gathering them.',
                    ),
                    contains('gathering.deprecationIgnores()'),
                  ),
                ),
          ),
        );
      });
    });

    // Slice 1d.2, ticket 06: the unverified files, `dart.warning`,
    // `dart.lint` and `dart.unreadable`, through the scripted stand-in.
    group('the unverified files', () {
      const dartChecks = <VerifyCheck>[
        DartErrorCheck(),
        DartDeprecatedCheck(),
        DartUnreadableCheck(),
        DartWarningCheck(),
        DartLintCheck(),
      ];
      KnowledgeStore store() => KnowledgeStore(app);

      List<String> unverifiedNow() => store().readState().state!.unverified;

      Future<void> markUnverified(List<String> files) async {
        final now = store().readState().state!;
        await store().locked(
          () => store().writeState(now.copyWith(unverified: files)),
        );
      }

      // A first run syncs, so `state.json` exists.
      setUp(() => run([]));

      List<(String, String?, int?)> found(VerifyResult result) => [
        for (final finding in result.findings)
          (finding.id, finding.file, finding.line),
      ];

      test('a warning is a dart.warning warning and an info-level diagnostic '
          'a dart.lint info finding, with the file, line, message, code and '
          'correction; deprecated use is left to dart.deprecated', () async {
        final result = await run(
          dartChecks,
          codeAnalysis: ScriptedCodeAnalysis(
            found: [
              diagnostic(
                DiagnosticLevel.warning,
                file: 'lib/a.dart',
                line: 2,
                code: 'unused_import',
                message: "Unused import: 'dart:math'.",
                correction: 'Try removing the import directive.',
              ),
              diagnostic(
                DiagnosticLevel.info,
                file: 'test/b_test.dart',
                line: 7,
                code: 'prefer_const_constructors',
                message: "Use 'const' with the constructor.",
              ),
              diagnostic(
                DiagnosticLevel.warning,
                file: 'lib/a.dart',
                line: 9,
                code: 'deprecated_member_use',
              ),
              diagnostic(
                DiagnosticLevel.info,
                file: 'lib/a.dart',
                line: 10,
                code: 'deprecated_member_use_from_same_package',
              ),
            ],
          ),
        );
        expect(found(result), [
          ('dart.deprecated', 'lib/a.dart', 9),
          ('dart.deprecated', 'lib/a.dart', 10),
          ('dart.warning', 'lib/a.dart', 2),
          ('dart.lint', 'test/b_test.dart', 7),
        ]);
        final [_, _, warning, lint] = result.findings;
        expect(warning.severity, Severity.warning);
        expect(
          warning.message,
          "Unused import: 'dart:math'. (`unused_import`)",
        );
        expect(warning.fixHint, 'Try removing the import directive.');
        expect(lint.severity, Severity.info);
        expect(
          lint.message,
          "Use 'const' with the constructor. (`prefer_const_constructors`)",
        );
        expect(lint.fixHint, isNull);
        expect((result.warnings, result.info), (1, 1));
      });

      test('a fast run reports them only on the unverified files and the '
          'files it was given; a full run everywhere', () async {
        await markUnverified(['lib/changed.dart']);
        final analysis = ScriptedCodeAnalysis(
          found: [
            for (final file in [
              'lib/changed.dart',
              'lib/given.dart',
              'lib/untouched.dart',
            ]) ...[
              diagnostic(DiagnosticLevel.warning, file: file),
              diagnostic(DiagnosticLevel.info, file: file),
            ],
          ],
        );
        final fast = await run(
          dartChecks,
          mode: VerifyMode.fast,
          codeAnalysis: analysis,
          files: ['lib/given.dart'],
        );
        expect(
          {for (final finding in fast.findings) finding.file},
          {'lib/changed.dart', 'lib/given.dart'},
        );
        expect(ids(fast), [
          'dart.warning',
          'dart.lint',
          'dart.warning',
          'dart.lint',
        ]);
        final full = await run(dartChecks, codeAnalysis: analysis);
        expect(full.findings, hasLength(6));
      });

      test('the scenario from the interview: break A and run; fix nothing, '
          'edit B correctly and run again; A is still unverified and its '
          'warnings are still reported', () async {
        await markUnverified(['lib/a.dart']);
        final analysis = ScriptedCodeAnalysis(
          found: [
            diagnostic(DiagnosticLevel.error, file: 'lib/a.dart'),
            diagnostic(DiagnosticLevel.warning, file: 'lib/a.dart', line: 5),
          ],
        );
        await run(dartChecks, mode: VerifyMode.fast, codeAnalysis: analysis);
        expect(unverifiedNow(), ['lib/a.dart']);
        // B is edited correctly: it joins, and leaves after this run.
        await markUnverified(['lib/a.dart', 'lib/b.dart']);
        final second = await run(
          dartChecks,
          mode: VerifyMode.fast,
          codeAnalysis: analysis,
        );
        expect(found(second), [
          ('dart.error', 'lib/a.dart', 3),
          ('dart.warning', 'lib/a.dart', 5),
        ]);
        expect(unverifiedNow(), ['lib/a.dart']);
      });

      test('a file leaves when a run, fast or full, reports no error on it: '
          'a warning keeps no file, nor does an error hidden by a '
          'suppression or lowered by verify.severity; a deleted file '
          'leaves too', () async {
        for (final mode in VerifyMode.values) {
          await markUnverified([
            'lib/broken.dart',
            'lib/deleted.dart',
            'lib/hidden.dart',
            'lib/lowered.dart',
            'lib/warned.dart',
          ]);
          await run(
            dartChecks,
            mode: mode,
            config: const AppsteinConfig(
              suppressions: [
                SuppressionEntry(
                  id: 'dart.error',
                  path: 'lib/hidden.dart',
                  reason: 'Known.',
                  line: 3,
                ),
              ],
            ),
            codeAnalysis: ScriptedCodeAnalysis(
              found: [
                diagnostic(DiagnosticLevel.error, file: 'lib/broken.dart'),
                diagnostic(DiagnosticLevel.error, file: 'lib/hidden.dart'),
                diagnostic(DiagnosticLevel.warning, file: 'lib/warned.dart'),
              ],
            ),
          );
          expect(unverifiedNow(), ['lib/broken.dart'], reason: mode.name);
        }
        // An error that `verify.severity` lowers to a warning is no error.
        await markUnverified(['lib/lowered.dart']);
        await run(
          dartChecks,
          config: const AppsteinConfig(
            verify: VerifyConfig(severity: {'dart.error': Severity.warning}),
          ),
          codeAnalysis: ScriptedCodeAnalysis(
            found: [
              diagnostic(DiagnosticLevel.error, file: 'lib/lowered.dart'),
            ],
          ),
        );
        expect(unverifiedNow(), isEmpty);
      });

      test('the files survive between runs, and a run whose Dart checks '
          'did not run verifies none', () async {
        await markUnverified(['lib/a.dart']);
        await run([
          FakeCheck(['a.a']),
        ]);
        await run([
          FakeCheck(['a.a']),
        ], mode: VerifyMode.fast);
        expect(unverifiedNow(), ['lib/a.dart']);
      });

      test('files given to the run join the unverified files after it '
          'while they have an error; a file with none leaves', () async {
        await run(
          dartChecks,
          mode: VerifyMode.fast,
          files: ['lib/given.dart', 'lib/clean.dart', 'README.md'],
          codeAnalysis: ScriptedCodeAnalysis(
            found: [diagnostic(DiagnosticLevel.error, file: 'lib/given.dart')],
          ),
        );
        expect(unverifiedNow(), ['lib/given.dart']);
      });

      test('what is gathered and what is judged see one set: a change to '
          'state.json while the run gathers is not seen by its checks, and '
          'dart fix is asked about before the knowledge lock', () async {
        await markUnverified(['lib/a.dart']);
        final use = CodeDiagnostic(
          file: 'lib/a.dart',
          line: 4,
          offset: 40,
          code: 'deprecated_member_use',
          message: "'old' is deprecated and shouldn't be used.",
          level: DiagnosticLevel.info,
        );
        final elsewhere = diagnostic(
          DiagnosticLevel.info,
          file: 'lib/b.dart',
          code: 'deprecated_member_use',
        );
        var lockFree = false;
        final analysis = ScriptedCodeAnalysis(
          found: [
            use,
            elsewhere,
            diagnostic(DiagnosticLevel.warning, file: 'lib/a.dart'),
            diagnostic(DiagnosticLevel.warning, file: 'lib/b.dart'),
          ],
          fixable: {use},
        );
        analysis
          ..onAsked = (() => markUnverified(['lib/b.dart']))
          ..onFixAsked = () async {
            final lock = await KnowledgeLock.acquire(
              p.join(app, '.appstein'),
              timeout: const Duration(milliseconds: 100),
            );
            lock.release();
            lockFree = true;
          };
        final result = await run(
          dartChecks,
          mode: VerifyMode.fast,
          codeAnalysis: analysis,
        );
        expect(analysis.askedFixes, [same(use)]);
        expect(lockFree, isTrue);
        expect(
          [
            for (final finding in result.findings)
              if (finding.id == 'dart.warning') finding.file,
          ],
          ['lib/a.dart'],
        );
        final [onA, onB] = [
          for (final finding in result.findings)
            if (finding.id == 'dart.deprecated') finding,
        ];
        expect(
          onA.fixHint,
          'The package that deprecated this API describes a migration for it '
          '(`fix_data.yaml`): `dart fix --apply` applies it, unless the '
          'package marks it for the IDE only. Or replace it with the API the '
          'message names.',
        );
        expect(onB.fixHint, contains('`dart fix --dry-run` lists the uses'));
      });

      test('on an unverified file, a use dart fix can\'t migrate says '
          'so', () async {
        await markUnverified(['lib/a.dart']);
        final result = await run(
          [const DartDeprecatedCheck()],
          mode: VerifyMode.fast,
          codeAnalysis: ScriptedCodeAnalysis(
            found: [
              diagnostic(
                DiagnosticLevel.info,
                file: 'lib/a.dart',
                code: 'deprecated_member_use',
              ),
            ],
          ),
        );
        expect(
          result.findings.single.fixHint,
          "`dart fix` can't migrate this use: replace it with the API the "
          'message names.',
        );
      });

      test('dart.unreadable: a file that can\'t be read is an error, in fast '
          'and full runs, and never leaves the unverified files, even '
          'hidden or lowered', () async {
        for (final mode in VerifyMode.values) {
          final result = await run(
            dartChecks,
            mode: mode,
            codeAnalysis: ScriptedCodeAnalysis(
              unreadableFiles: {
                'lib/locked.dart':
                    'The process cannot access the file because another '
                    'process has locked a portion of the file.\r\n',
              },
            ),
          );
          final unreadable = result.findings.single;
          expect(unreadable.id, 'dart.unreadable');
          expect(unreadable.severity, Severity.error);
          expect(unreadable.file, 'lib/locked.dart');
          expect(unreadable.line, isNull);
          expect(
            unreadable.message,
            'This file could not be read (The process cannot access the '
            'file because another process has locked a portion of the '
            'file), so nothing in it was checked.',
          );
          expect(unreadable.fixHint, contains('`appstein verify` again'));
          expect(unverifiedNow(), ['lib/locked.dart']);
        }
        final hidden = await run(
          dartChecks,
          config: const AppsteinConfig(
            verify: VerifyConfig(severity: {'dart.unreadable': Severity.info}),
            suppressions: [
              SuppressionEntry(
                id: 'dart.unreadable',
                path: 'lib/hidden.dart',
                reason: 'Locked by the IDE.',
                line: 3,
              ),
            ],
          ),
          codeAnalysis: ScriptedCodeAnalysis(
            unreadableFiles: {
              'lib/locked.dart': 'locked',
              'lib/hidden.dart': 'locked',
            },
          ),
        );
        expect(
          [
            for (final finding in hidden.findings)
              (finding.file, finding.severity),
          ],
          [('lib/locked.dart', Severity.info)],
        );
        expect(hidden.suppressed, 1);
        expect(unverifiedNow(), ['lib/hidden.dart', 'lib/locked.dart']);
      });

      test('the first sync made every Dart file of the project unverified, '
          'and a run with no error lets them leave', () async {
        expect(unverifiedNow(), contains('lib/main.dart'));
        await run(dartChecks, mode: VerifyMode.fast);
        expect(unverifiedNow(), isEmpty);
      });

      group('a partial run lets no file leave', () {
        setUp(() => markUnverified(['lib/a.dart', 'lib/b.dart']));

        test('one that reports dart.plugin_failed', () async {
          await run(
            [...dartChecks, const PluginFailedCheck()],
            mode: VerifyMode.fast,
            files: ['lib/c.dart'],
            codeAnalysis: ScriptedCodeAnalysis(pluginFailures: ['broken']),
          );
          expect(unverifiedNow(), ['lib/a.dart', 'lib/b.dart', 'lib/c.dart']);
        });

        test('one that reports knowledge.stale', () async {
          await run(
            dartChecks,
            mode: VerifyMode.fast,
            refreshed: const KnowledgeRefresh.failed('the packages are gone'),
          );
          expect(unverifiedNow(), ['lib/a.dart', 'lib/b.dart']);
        });

        test('one in which a dart.* check was named as not run', () async {
          final result = await run([
            ...dartChecks,
            const _DartNotRunCheck(),
          ], mode: VerifyMode.fast);
          expect([
            for (final check in result.notRun) check.id,
          ], contains('dart.partly'));
          expect(unverifiedNow(), ['lib/a.dart', 'lib/b.dart']);
        });
      });

      test('tests not run (test.failed, while the code has an error) don\'t '
          'make a run partial: a clean file leaves', () async {
        await markUnverified(['lib/a.dart', 'lib/b.dart']);
        final result = await run(
          [...dartChecks, const TestFailedCheck()],
          codeAnalysis: ScriptedCodeAnalysis(
            found: [diagnostic(DiagnosticLevel.error, file: 'lib/a.dart')],
          ),
        );
        expect([
          for (final check in result.notRun) check.id,
        ], contains('test.failed'));
        expect(unverifiedNow(), ['lib/a.dart']);
      });

      test('a file a refresh saw change again during the run stays, though '
          'the run found no error on it', () async {
        await markUnverified(['lib/a.dart', 'lib/b.dart']);
        final analysis = ScriptedCodeAnalysis();
        analysis.onAsked = () async {
          // As a refresh of another call would record a new edit of a.dart.
          final now = store().readState().state!;
          await store().locked(
            () => store().writeState(
              now.copyWith(
                dartFiles: {...?now.dartFiles, 'lib/a.dart': 'edited again'},
              ),
            ),
          );
        };
        await run(dartChecks, mode: VerifyMode.fast, codeAnalysis: analysis);
        expect(unverifiedNow(), ['lib/a.dart']);
      });

      test('a dart fix question the analysis can\'t answer gives the general '
          'hint, and the run neither fails nor blames a check; any other '
          'error is a bug and fails the run', () async {
        await markUnverified(['lib/a.dart']);
        ScriptedCodeAnalysis failing(Object failure) => ScriptedCodeAnalysis(
          found: [
            diagnostic(
              DiagnosticLevel.info,
              file: 'lib/a.dart',
              code: 'deprecated_member_use',
            ),
          ],
        )..fixFailure = failure;
        final result = await run(
          [const DartDeprecatedCheck()],
          mode: VerifyMode.fast,
          codeAnalysis: failing(
            const CodeAnalysisException('it was asked with no reading taken'),
          ),
        );
        expect(
          result.findings.single.fixHint,
          contains('`dart fix --dry-run` lists the uses'),
        );
        await expectLater(
          run(
            [const DartDeprecatedCheck()],
            mode: VerifyMode.fast,
            codeAnalysis: failing(StateError('a bug')),
          ),
          throwsA(
            isA<VerifyCheckError>().having(
              (e) => e.checkId,
              'checkId',
              'dart.deprecated',
            ),
          ),
        );
      });

      test('the dart fix questions are capped by dartFixBudget: a question '
          'still unanswered then is given up, and the uses not answered get '
          'the general hint', () async {
        await markUnverified(['lib/a.dart']);
        final uses = [
          for (var line = 1; line <= 3; line++)
            diagnostic(
              DiagnosticLevel.info,
              file: 'lib/a.dart',
              line: line,
              code: 'deprecated_member_use',
            ),
        ];
        final analysis = ScriptedCodeAnalysis(found: uses, fixable: {...uses})
          // The first answer would come long after the budget.
          ..onFixAsked = (() => Future<void>.delayed(dartFixBudget * 5));
        final gathering = VerifyGathering(
          analysis,
          unverified: UnverifiedFiles(['lib/a.dart']),
        );
        final spent = Stopwatch()..start();
        await gathering.code();
        final answers = await gathering.dartFixes();
        spent.stop();
        expect(answers, isEmpty);
        expect(spent.elapsed, lessThan(dartFixBudget * 2));
        final result = await run(
          [const DartDeprecatedCheck()],
          mode: VerifyMode.fast,
          codeAnalysis: analysis,
        );
        expect(analysis.askedFixes, [same(uses.first), same(uses.first)]);
        expect(
          [
            for (final finding in result.findings)
              finding.fixHint!.contains('`dart fix --dry-run`'),
          ],
          [true, true, true],
        );
      });

      test('files given to a run whose lock stays busy are checked, and the '
          'result says they were not kept', () async {
        final lock = await KnowledgeLock.acquire(p.join(app, '.appstein'));
        addTearDown(lock.release);
        final result = await run(
          dartChecks,
          mode: VerifyMode.fast,
          files: ['lib/given.dart'],
          refreshed: const KnowledgeRefresh.current(),
          lockTimeout: const Duration(milliseconds: 200),
          codeAnalysis: ScriptedCodeAnalysis(
            found: [
              diagnostic(DiagnosticLevel.warning, file: 'lib/given.dart'),
            ],
          ),
        );
        expect(
          [
            for (final finding in result.findings)
              if (finding.file != null) finding.file,
          ],
          ['lib/given.dart'],
        );
        expect(result.notices, [contains('not kept among the unverified')]);
        lock.release();
        expect(unverifiedNow(), isNot(contains('lib/given.dart')));
      });
    });

    // Slice 1d.2, ticket 07: `dart.unformatted`, through the scripted
    // stand-in. The agreement with the real formatter is checked with a real
    // server in `verify_dart_test.dart`.
    group('dart.unformatted', () {
      const check = DartUnformattedCheck();
      const dartChecks = <VerifyCheck>[
        DartErrorCheck(),
        DartUnreadableCheck(),
        check,
      ];
      KnowledgeStore store() => KnowledgeStore(app);

      List<String> unverifiedNow() => store().readState().state!.unverified;

      Future<void> markUnverified(List<String> files) async {
        final now = store().readState().state!;
        await store().locked(
          () => store().writeState(now.copyWith(unverified: files)),
        );
      }

      void write(String relative, String text) => File(
        p.joinAll([app, ...relative.split('/')]),
      ).writeAsStringSync(text);

      // A first run syncs, so `state.json` exists. The files the stand-in
      // lists are on disk: a listed file that is not is a deleted one.
      setUp(() async {
        for (final name in [
          'a',
          'b',
          'c',
          'changed',
          'given',
          'locked',
          'untouched',
        ]) {
          write('lib/$name.dart', 'int $name = 1;\n');
        }
        await run([]);
      });

      test('a file the analysis lists that is no longer on disk is not asked '
          'about: the server has not noticed the deletion yet', () async {
        final analysis = ScriptedCodeAnalysis(
          analyzedFiles: ['lib/a.dart', 'lib/deleted.dart'],
        )..unformatted = {'lib/a.dart', 'lib/deleted.dart'};
        final result = await run(dartChecks, codeAnalysis: analysis);
        expect(analysis.askedFormats.single, ['lib/a.dart']);
        expect(
          [for (final finding in result.findings) finding.file],
          ['lib/a.dart'],
        );
      });

      test('a file the formatter would change is a dart.unformatted warning '
          'on the file, with no line and a hint that names --apply; only '
          'Dart files are asked about', () async {
        final analysis = ScriptedCodeAnalysis(
          analyzedFiles: [
            'analysis_options.yaml',
            'lib/a.dart',
            'lib/b.dart',
            'pubspec.yaml',
          ],
        )..unformatted = {'lib/a.dart'};
        final result = await run(dartChecks, codeAnalysis: analysis);
        final finding = result.findings.single;
        expect(finding.id, 'dart.unformatted');
        expect(finding.severity, Severity.warning);
        expect(finding.file, 'lib/a.dart');
        expect(finding.line, isNull);
        expect(finding.message, contains('formatting'));
        expect(finding.message, contains('`dart format`'));
        expect(finding.fixHint, contains('`appstein verify --apply`'));
        expect(analysis.askedFormats, [
          ['lib/a.dart', 'lib/b.dart'],
        ]);
        expect(result.notRun, isEmpty);
      });

      test('a fast run reports it only for the unverified files and the '
          'files it was given; a full run for every file', () async {
        await markUnverified(['lib/changed.dart']);
        final analysis =
            ScriptedCodeAnalysis(
                analyzedFiles: [
                  'lib/changed.dart',
                  'lib/given.dart',
                  'lib/untouched.dart',
                ],
              )
              ..unformatted = {
                'lib/changed.dart',
                'lib/given.dart',
                'lib/untouched.dart',
              };
        final fast = await run(
          dartChecks,
          mode: VerifyMode.fast,
          codeAnalysis: analysis,
          files: ['lib/given.dart'],
        );
        expect(
          [for (final finding in fast.findings) finding.file],
          ['lib/changed.dart', 'lib/given.dart'],
        );
        // The files the run is not about are not even asked about.
        expect(analysis.askedFormats, [
          ['lib/changed.dart', 'lib/given.dart'],
        ]);
        expect(analysis.formatWithin, [formatBudgetFast]);
        final full = await run(dartChecks, codeAnalysis: analysis);
        expect(full.findings, hasLength(3));
        expect(analysis.askedFormats.last, hasLength(3));
        expect(analysis.formatWithin, [formatBudgetFast, formatBudgetFull]);
      });

      test('a file that starts with a GENERATED CODE - DO NOT MODIFY header '
          'is never asked about or reported; the words elsewhere do not '
          'make a file generated', () async {
        write(
          'lib/gen.dart',
          '// GENERATED CODE - DO NOT MODIFY BY HAND\n\nint a( int x )=>x;\n',
        );
        write(
          'lib/gen_after_license.dart',
          '// Copyright.\n\n// GENERATED CODE - DO NOT MODIFY BY HAND\nint a( int x )=>x;\n',
        );
        write(
          'lib/gen_crlf.dart',
          '// GENERATED CODE - DO NOT MODIFY BY HAND\r\nint a( int x )=>x;\r\n',
        );
        write(
          'lib/gen_bom.dart',
          '\u{FEFF}// GENERATED CODE - DO NOT MODIFY BY HAND\nint a( int x )=>x;\n',
        );
        write(
          'lib/not_gen.dart',
          'int a( int x )=>x; // GENERATED CODE - DO NOT MODIFY BY HAND\n',
        );
        write(
          'lib/not_gen_later.dart',
          'int a( int x )=>x;\n// GENERATED CODE - DO NOT MODIFY BY HAND\n',
        );
        final files = [
          'lib/gen.dart',
          'lib/gen_after_license.dart',
          'lib/gen_bom.dart',
          'lib/gen_crlf.dart',
          'lib/not_gen.dart',
          'lib/not_gen_later.dart',
        ];
        final analysis = ScriptedCodeAnalysis(analyzedFiles: files)
          ..unformatted = {...files};
        final result = await run(dartChecks, codeAnalysis: analysis);
        expect(
          [for (final finding in result.findings) finding.file],
          ['lib/not_gen.dart', 'lib/not_gen_later.dart'],
        );
        expect(analysis.askedFormats.single, [
          'lib/not_gen.dart',
          'lib/not_gen_later.dart',
        ]);
      });

      test('a file that could not be read is not asked about: the server '
          'read it as empty, and an empty text is not a format to ask '
          'for', () async {
        final analysis = ScriptedCodeAnalysis(
          analyzedFiles: ['lib/a.dart', 'lib/locked.dart'],
          unreadableFiles: {'lib/locked.dart': 'locked'},
        )..unformatted = {'lib/a.dart', 'lib/locked.dart'};
        final result = await run(dartChecks, codeAnalysis: analysis);
        expect(analysis.askedFormats.single, ['lib/a.dart']);
        expect(
          [for (final finding in result.findings) finding.id],
          ['dart.unformatted', 'dart.unreadable'],
        );
      });

      test('no Dart file to ask about is no question', () async {
        final analysis = ScriptedCodeAnalysis(analyzedFiles: ['pubspec.yaml']);
        await run(dartChecks, codeAnalysis: analysis);
        expect(analysis.askedFormats, isEmpty);
      });

      test('verify.severity changes it and a suppression hides it, in the '
          'config and in the file', () async {
        write(
          'lib/b.dart',
          '// appstein:ignore-file dart.unformatted — a sketch\nint b( ) => 1;\n',
        );
        final analysis = ScriptedCodeAnalysis(
          analyzedFiles: ['lib/a.dart', 'lib/b.dart', 'lib/c.dart'],
        )..unformatted = {'lib/a.dart', 'lib/b.dart', 'lib/c.dart'};
        final result = await run(
          dartChecks,
          codeAnalysis: analysis,
          config: const AppsteinConfig(
            verify: VerifyConfig(
              severity: {'dart.unformatted': Severity.error},
            ),
            suppressions: [
              SuppressionEntry(
                id: 'dart.unformatted',
                path: 'lib/c.dart',
                reason: 'Hand-aligned table.',
                line: 3,
              ),
            ],
          ),
        );
        expect(
          [
            for (final finding in result.findings)
              (finding.file, finding.severity),
          ],
          [('lib/a.dart', Severity.error)],
        );
        expect(result.suppressed, 2);
      });

      test('a warning keeps no file unverified', () async {
        await markUnverified(['lib/a.dart']);
        await run(
          dartChecks,
          mode: VerifyMode.fast,
          codeAnalysis: ScriptedCodeAnalysis(analyzedFiles: ['lib/a.dart'])
            ..unformatted = {'lib/a.dart'},
        );
        expect(unverifiedNow(), isEmpty);
      });

      test('the formatting is asked while gathering, before the knowledge '
          'lock, and once however the check runs', () async {
        var lockFree = false;
        final analysis = ScriptedCodeAnalysis(analyzedFiles: ['lib/a.dart'])
          ..onFormatAsked = () async {
            final lock = await KnowledgeLock.acquire(
              p.join(app, '.appstein'),
              timeout: const Duration(milliseconds: 100),
            );
            lock.release();
            lockFree = true;
          };
        await run(dartChecks, codeAnalysis: analysis);
        expect(lockFree, isTrue);
        expect(analysis.asked, 1);
        expect(analysis.askedFormats, hasLength(1));
      });

      test('files not answered in time are named among the checks not run, '
          'what was answered is reported, and no file leaves the unverified '
          'files', () async {
        await markUnverified(['lib/a.dart', 'lib/b.dart', 'lib/c.dart']);
        final analysis =
            ScriptedCodeAnalysis(
                analyzedFiles: ['lib/a.dart', 'lib/b.dart', 'lib/c.dart'],
              )
              ..unformatted = {'lib/a.dart', 'lib/b.dart'}
              ..formatSilent = {'lib/b.dart', 'lib/c.dart'};
        final result = await run(
          dartChecks,
          mode: VerifyMode.fast,
          codeAnalysis: analysis,
        );
        expect(
          [for (final finding in result.findings) finding.file],
          ['lib/a.dart'],
        );
        final [notRun] = result.notRun;
        expect(notRun.id, 'dart.unformatted');
        expect(notRun.reason, contains('2 of 3 files'));
        expect(notRun.reason, contains('was not checked'));
        expect(unverifiedNow(), ['lib/a.dart', 'lib/b.dart', 'lib/c.dart']);
      });

      test('a suppression of a check that was not run in full is not called '
          'unused', () async {
        final result = await run(
          dartChecks,
          mode: VerifyMode.fast,
          files: ['lib/a.dart'],
          codeAnalysis: ScriptedCodeAnalysis(analyzedFiles: ['lib/a.dart'])
            ..formatSilent = {'lib/a.dart'},
          config: const AppsteinConfig(
            suppressions: [
              SuppressionEntry(
                id: 'dart.unformatted',
                path: 'lib/a.dart',
                reason: 'Hand-aligned table.',
                line: 3,
              ),
            ],
          ),
        );
        expect([for (final finding in result.findings) finding.id], isEmpty);
      });

      test('a file the server refuses is named as not checked, with why, '
          'and the answers for the other files are kept; no file leaves the '
          'unverified files', () async {
        await markUnverified(['lib/a.dart', 'lib/b.dart', 'lib/c.dart']);
        final analysis =
            ScriptedCodeAnalysis(
                analyzedFiles: ['lib/a.dart', 'lib/b.dart', 'lib/c.dart'],
              )
              ..unformatted = {'lib/a.dart', 'lib/c.dart'}
              ..formatRefused = {
                'lib/b.dart': 'it refused a request (the formatter threw)',
              };
        final result = await run(
          dartChecks,
          mode: VerifyMode.fast,
          codeAnalysis: analysis,
        );
        expect(
          [for (final finding in result.findings) finding.file],
          ['lib/a.dart', 'lib/c.dart'],
        );
        final [notRun] = result.notRun;
        expect(notRun.id, 'dart.unformatted');
        expect(notRun.reason, contains('1 of 3 files was not checked'));
        expect(
          notRun.reason,
          contains('lib/b.dart (it refused a request (the formatter threw))'),
        );
        expect(unverifiedNow(), ['lib/a.dart', 'lib/b.dart', 'lib/c.dart']);
      });

      test('a server that fails while it is asked about the formatting '
          'fails the run as it does for the reading (exit 3 in the '
          'terminal): the exception is passed on as it is and no check is '
          'blamed; any other error is a bug', () async {
        const failure = CodeAnalysisException('it ended by itself');
        final analysis = ScriptedCodeAnalysis(
          analyzedFiles: ['lib/a.dart', 'lib/b.dart'],
        )..formatFailure = failure;
        await expectLater(
          run(dartChecks, codeAnalysis: analysis),
          throwsA(same(failure)),
        );
        await expectLater(
          run(
            dartChecks,
            codeAnalysis: ScriptedCodeAnalysis(analyzedFiles: ['lib/a.dart'])
              ..formatFailure = StateError('a bug'),
          ),
          throwsA(
            isA<VerifyCheckError>().having(
              (e) => e.checkId,
              'checkId',
              'dart.unformatted',
            ),
          ),
        );
      });

      test('a reading that cannot be taken fails the run as it does for '
          'every code check', () async {
        const failure = CodeAnalysisException('it never started');
        await expectLater(
          run(dartChecks, codeAnalysis: ScriptedCodeAnalysis(failure: failure)),
          throwsA(same(failure)),
        );
      });

      test('a server that is alive but slow is a partial run, not a failure: '
          'it is given the budget, and its files are named as not '
          'checked', () async {
        final analysis = ScriptedCodeAnalysis(analyzedFiles: ['lib/a.dart'])
          ..onFormatAsked = (() => Completer<void>().future);
        final gathering = VerifyGathering(
          analysis,
          projectRoot: app,
          mode: VerifyMode.fast,
          unverified: UnverifiedFiles(['lib/a.dart']),
        );
        final spent = Stopwatch()..start();
        await gathering.code();
        final reading = await gathering.formatting();
        expect(reading.unformatted, isEmpty);
        expect(reading.unchecked, ['lib/a.dart']);
        expect(
          reading.why,
          'the analysis server did not answer within 1 s for 1 file',
        );
        expect(analysis.formatWithin, [formatBudgetFast]);
        expect(spent.elapsed, lessThan(formatBudgetFast * 2));
      });

      test('the dart fix questions are given the time that is left, not a '
          'limit around the call', () async {
        final use = diagnostic(
          DiagnosticLevel.info,
          file: 'lib/a.dart',
          code: 'deprecated_member_use',
        );
        final analysis = ScriptedCodeAnalysis(
          analyzedFiles: ['lib/a.dart'],
          found: [use],
          fixable: {use},
        );
        final gathering = VerifyGathering(
          analysis,
          projectRoot: app,
          unverified: UnverifiedFiles(['lib/a.dart']),
        );
        await gathering.code();
        expect(await gathering.dartFixes(), {use: true});
        expect(analysis.fixWithin.single, lessThanOrEqualTo(dartFixBudget));
        expect(analysis.fixWithin.single, greaterThan(Duration.zero));
      });
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
