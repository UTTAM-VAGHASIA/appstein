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
import '../support/scripted_code_analysis.dart';
import 'support/verify_support.dart';

const _packs = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];

/// A check that gathers the code analysis's reading (so the run reads the
/// project's comments) and reports [findings]. When [notRunReason] is set it
/// says it did not run.
final class _Reporting implements GatheringCheck {
  _Reporting(
    this.ids,
    this.findings, {
    this.mode = VerifyMode.full,
    this.notRunReason,
    this.skipsPart = false,
    this.needsMap = false,
    this.duringRun,
  });

  @override
  final List<String> ids;

  @override
  final VerifyMode mode;

  @override
  final bool needsMap;

  final List<Finding> findings;
  final String? notRunReason;

  /// Whether it leaves a part of its work out, as the decisions check does
  /// for the stack rule while the map can't be used.
  final bool skipsPart;

  /// Called when the check runs, under the knowledge lock.
  final Future<void> Function()? duringRun;

  @override
  Future<void> gather(VerifyGathering gathering) => gathering.code();

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    await duringRun?.call();
    if (notRunReason case final reason?) context.notRun(ids.first, reason);
    if (skipsPart) context.skipped('part.inner');
    return findings;
  }
}

/// A check that adds `a.follow` when no `a.noisy` stays.
final class _Following implements FollowingCheck {
  final seen = <List<String>>[];

  @override
  List<String> get ids => const ['a.follow'];

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) async => const [];

  @override
  List<Finding> following(VerifyContext context, List<Finding> kept) {
    seen.add([for (final finding in kept) finding.id]);
    return kept.any((finding) => finding.id == 'a.noisy')
        ? const []
        : [finding('a.follow', severity: Severity.error)];
  }
}

// `// appstein:ignore` and `// appstein:ignore-file` comments in Dart files,
// applied by `runVerify` with a scripted analysis that names the files it
// analyzed (slice 1d.2, ticket 09, spec §9.7).
void main() {
  late String sdk;
  late String app;
  late ScriptedCodeAnalysis analysis;

  setUp(() {
    sdk = fakeFlutter();
    app = copyFixtureApp();
    analysis = ScriptedCodeAnalysis();
  });

  void write(String relative, String content) {
    final file = File(p.joinAll([app, ...relative.split('/')]));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    if (relative.endsWith('.dart')) {
      analysis.analyzedFiles = [...analysis.analyzedFiles, relative]..sort();
    }
  }

  Future<VerifyResult> run(
    List<VerifyCheck> checks, {
    VerifyMode mode = VerifyMode.full,
    AppsteinConfig config = const AppsteinConfig(),
    KnowledgeRefresh? refreshed,
  }) => runVerify(
    refreshed: refreshed,
    codeAnalysis: analysis,
    projectRoot: app,
    config: config,
    packs: _packs,
    sync: knowledgeSync(
      flutterRoot: sdk,
      runner: FakeProcessRunner(),
      packs: _packs,
      packageSkills: false,
    ),
    mode: mode,
    checks: [for (final check in checks) (check: check, pack: null)],
    dartSdkPath: testDartSdk,
  );

  /// `(id, file, line)` of each finding.
  List<(String, String?, int?)> shown(VerifyResult result) => [
    for (final finding in result.findings)
      (finding.id, finding.file, finding.line),
  ];

  Finding at(String id, String? file, int? line, {String message = 'm'}) =>
      finding(id, file: file, line: line, message: message);

  group('appstein:ignore', () {
    test('at the end of a line hides that line\'s finding of that check, '
        'and nothing else', () async {
      write('lib/a.dart', '''
int a = 1;
int b = 2; // appstein:ignore a.noisy — accepted
int c = 3;
''');
      final result = await run([
        _Reporting(
          const ['a.noisy', 'a.other'],
          [
            at('a.noisy', 'lib/a.dart', 1),
            at('a.noisy', 'lib/a.dart', 2),
            at('a.noisy', 'lib/a.dart', 3),
            at('a.other', 'lib/a.dart', 2),
            at('a.noisy', 'lib/b.dart', 2),
          ],
        ),
      ]);
      expect(shown(result), [
        ('a.noisy', 'lib/a.dart', 1),
        ('a.other', 'lib/a.dart', 2),
        ('a.noisy', 'lib/a.dart', 3),
        ('a.noisy', 'lib/b.dart', 2),
      ]);
      expect(result.suppressed, 1);
      expect(result.activeSuppressions, 1);
    });

    test('alone on a line hides the next line of code, over blank lines '
        'and comments', () async {
      write('lib/a.dart', '''
int a = 1;
// appstein:ignore a.noisy — accepted

// another note
int b = 2;
int c = 3;
''');
      final result = await run([
        _Reporting(
          const ['a.noisy'],
          [
            at('a.noisy', 'lib/a.dart', 1),
            at('a.noisy', 'lib/a.dart', 5),
            at('a.noisy', 'lib/a.dart', 6),
          ],
        ),
      ]);
      expect([for (final f in result.findings) f.line], [1, 6]);
      expect(result.suppressed, 1);
      expect(result.activeSuppressions, 1);
    });

    test('a finding with no line is not hidden by it', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.noisy — r\n');
      final result = await run([
        _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', null)]),
      ]);
      expect(result.findings.map((f) => f.id), [
        'a.noisy',
        'suppression.unused',
      ]);
    });

    test('the comment hides a finding of a check whichever it is, when '
        'the finding\'s file is that Dart file', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore x.some-check — r\n');
      final result = await run([
        _Reporting(
          const ['x.some-check'],
          [at('x.some-check', 'lib/a.dart', 1)],
        ),
      ]);
      expect(result.findings, isEmpty);
      expect(result.suppressed, 1);
    });
  });

  group('appstein:ignore-file', () {
    test('before the first declaration hides the check\'s findings in '
        'the file, with or without a line', () async {
      write('lib/a.dart', '''
// appstein:ignore-file a.noisy — generated by hand
import 'dart:io';

class A {}
''');
      final result = await run([
        _Reporting(
          const ['a.noisy', 'a.other'],
          [
            at('a.noisy', 'lib/a.dart', 3),
            at('a.noisy', 'lib/a.dart', null),
            at('a.other', 'lib/a.dart', 3),
            at('a.noisy', 'lib/b.dart', 3),
          ],
        ),
      ]);
      expect(shown(result), [
        ('a.other', 'lib/a.dart', 3),
        ('a.noisy', 'lib/b.dart', 3),
      ]);
      expect(result.suppressed, 2);
      expect(result.activeSuppressions, 1);
    });

    test('after the first declaration hides nothing and is reported as '
        'unused', () async {
      write('lib/a.dart', '''
class A {}

// appstein:ignore-file a.noisy — too late
class B {}
''');
      final result = await run([
        _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 1)]),
      ]);
      expect(shown(result), [
        ('a.noisy', 'lib/a.dart', 1),
        ('suppression.unused', 'lib/a.dart', 3),
      ]);
      final unused = result.findings.last;
      expect(unused.severity, Severity.warning);
      expect(unused.message, contains('first declaration'));
      expect(result.suppressed, 0);
      expect(result.activeSuppressions, 0);
    });

    for (final (above, label) in [
      ('/// A class.', 'a doc comment'),
      ('@deprecated', 'an annotation'),
    ]) {
      test('between $label and the declaration it comes after the start of '
          'the declaration, and the message says so', () async {
        write('lib/a.dart', '''
$above
// appstein:ignore-file a.noisy — r
class A {}
''');
        final result = await run([
          _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 3)]),
        ]);
        expect(shown(result), [
          ('suppression.unused', 'lib/a.dart', 2),
          ('a.noisy', 'lib/a.dart', 3),
        ]);
        final unused = result.findings.first;
        expect(unused.message, contains('start of the first declaration'));
        expect(unused.message, contains('doc comment or annotation'));
        expect(unused.fixHint, contains('above'));
        expect(unused.fixHint, contains('doc comment'));
        expect(result.suppressed, 0);
      });
    }

    test('above the doc comment of the first declaration it is in '
        'force', () async {
      write('lib/a.dart', '''
// appstein:ignore-file a.noisy — r
/// A class.
@deprecated
class A {}
''');
      final result = await run([
        _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 4)]),
      ]);
      expect(result.findings, isEmpty);
      expect(result.suppressed, 1);
    });
  });

  group('a separator typed wrong, and two comments on a line', () {
    for (final (text, label) in [
      ('a.noisy – the reason', 'an en dash'),
      ('a.noisy -', 'a lone hyphen at the end'),
      ('a.noisy-', 'a hyphen glued to the ID at the end'),
    ]) {
      test('$label: no reason, and the hint names the separators', () async {
        write('lib/a.dart', 'int a = 1; // appstein:ignore $text\n');
        final result = await run([
          _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 1)]),
        ]);
        expect(shown(result), [
          ('suppression.no_reason', 'lib/a.dart', 1),
          ('a.noisy', 'lib/a.dart', 1),
        ]);
        final report = result.findings.first;
        expect(report.fixHint, contains('`—`, `--` or ` - `'));
        expect(report.fixHint, contains('en dash'));
        expect(result.suppressed, 0);
      });
    }

    test('an en dash before a real separator is an unknown check that '
        'names the separators', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.noisy – x — why\n');
      final result = await run([
        _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 1)]),
      ]);
      final report = result.findings.firstWhere(
        (f) => f.id == 'suppression.unknown_check',
      );
      expect(report.fixHint, contains('`—`, `--` or ` - `'));
      expect(result.suppressed, 0);
    });

    for (final (text, label) in [
      ('a.noisy- the reason', 'a hyphen glued to the ID, then a space'),
      ('a.noisy -the reason', 'a hyphen after a space, glued to the reason'),
    ]) {
      test('$label: no reason, and the hint names the separators', () async {
        write('lib/a.dart', 'int a = 1; // appstein:ignore $text\n');
        final result = await run([
          _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 1)]),
        ]);
        expect(shown(result), [
          ('suppression.no_reason', 'lib/a.dart', 1),
          ('a.noisy', 'lib/a.dart', 1),
        ]);
        expect(result.findings.first.fixHint, contains('`—`, `--` or ` - `'));
        expect(result.suppressed, 0);
      });
    }

    test('a mistyped separator gives only the separator sentence, not the '
        '"one comment for each" one', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.noisy – x — why\n');
      final result = await run([
        _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 1)]),
      ]);
      final report = result.findings.firstWhere(
        (f) => f.id == 'suppression.unknown_check',
      );
      expect(report.fixHint, contains('`—`, `--` or ` - `'));
      expect(report.fixHint, isNot(contains('one comment for each')));
      // The same with an en dash glued to the ID.
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.noisy–x — why\n');
      final glued = await run([
        _Reporting(const ['a.noisy'], const []),
      ]);
      final gluedReport = glued.findings.firstWhere(
        (f) => f.id == 'suppression.unknown_check',
      );
      expect(gluedReport.fixHint, contains('`—`, `--` or ` - `'));
    });

    for (final text in ['a.noisy, a.other', 'a.noisy a.other']) {
      test('several IDs and no reason ($text) is unknown_check, which also '
          'says the reason is missing', () async {
        write('lib/a.dart', 'int a = 1; // appstein:ignore $text\n');
        final result = await run([
          _Reporting(
            const ['a.noisy', 'a.other'],
            [at('a.noisy', 'lib/a.dart', 1)],
          ),
        ]);
        expect(shown(result), [
          ('suppression.unknown_check', 'lib/a.dart', 1),
          ('a.noisy', 'lib/a.dart', 1),
        ]);
        final report = result.findings.first;
        expect(report.message, contains('more than one check'));
        expect(report.message, contains('no reason'));
        expect(report.fixHint, contains('one comment for each'));
        expect(result.suppressed, 0);
      });
    }

    test('words after a lone ID with no separator are a missing reason, not '
        'a list of IDs', () async {
      write(
        'lib/a.dart',
        'int a = 1; // appstein:ignore a.noisy because it is old, see docs.md\n',
      );
      final result = await run([
        _Reporting(const ['a.noisy'], const []),
      ]);
      expect(result.findings.single.id, 'suppression.no_reason');
    });

    test('a reason that quotes a whole comment in backticks, or holds a '
        'URL, is not a second comment', () async {
      write('lib/a.dart', '''
void f() {} // appstein:ignore a.noisy — the `// appstein:ignore-file a.noisy` form fails here
void g() {} // appstein:ignore a.noisy — see https://x.dev//appstein:ignore a.other for why
void h() {} // appstein:ignore a.noisy — a `// appstein:ignore a.other` and then // appstein:ignore a.other — r
''');
      final result = await run([
        _Reporting(
          const ['a.noisy', 'a.other'],
          [
            at('a.noisy', 'lib/a.dart', 1),
            at('a.noisy', 'lib/a.dart', 2),
            at('a.noisy', 'lib/a.dart', 3),
          ],
        ),
      ]);
      // The first two comments hide their lines. The third quotes one in
      // backticks and then has a real second comment after whitespace.
      expect(shown(result), [
        ('suppression.unknown_check', 'lib/a.dart', 3),
        ('a.noisy', 'lib/a.dart', 3),
      ]);
      expect(result.suppressed, 2);
    });

    test('an ordinary missing reason says nothing of the separator', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.noisy\n');
      final result = await run([
        _Reporting(const ['a.noisy'], const []),
      ]);
      expect(result.findings.single.fixHint, isNot(contains('en dash')));
    });

    test('two comments at the end of one line name more than one check: '
        'unknown_check, and neither hides anything', () async {
      write('lib/a.dart', '''
int a = 1; // appstein:ignore a.noisy — r // appstein:ignore a.other — r
int b = 1; // appstein:ignore a.noisy — r // appstein:ignore-file a.other — r
''');
      final result = await run([
        _Reporting(
          const ['a.noisy', 'a.other'],
          [
            at('a.noisy', 'lib/a.dart', 1),
            at('a.other', 'lib/a.dart', 1),
            at('a.noisy', 'lib/a.dart', 2),
          ],
        ),
      ]);
      expect(shown(result), [
        ('suppression.unknown_check', 'lib/a.dart', 1),
        ('suppression.unknown_check', 'lib/a.dart', 2),
        ('a.noisy', 'lib/a.dart', 1),
        ('a.other', 'lib/a.dart', 1),
        ('a.noisy', 'lib/a.dart', 2),
      ]);
      final report = result.findings.first;
      expect(report.severity, Severity.error);
      expect(report.message, contains('more than one check'));
      expect(report.fixHint, contains('line of its own'));
      expect(result.suppressed, 0);
      expect(result.activeSuppressions, 0);
    });

    test('a reason that merely mentions the word is one comment', () async {
      write(
        'lib/a.dart',
        'int a = 1; // appstein:ignore a.noisy — see appstein:ignore docs\n',
      );
      final result = await run([
        _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 1)]),
      ]);
      expect(result.findings, isEmpty);
      expect(result.suppressed, 1);
    });
  });

  group('when the comments are read, and when unused is judged', () {
    test('they are read before the checks run under the knowledge lock, '
        'whichever check took the code reading', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.noisy — r\n');
      Object? underLock;
      final result = await run([
        _Reporting(
          const ['a.noisy'],
          [at('a.noisy', 'lib/a.dart', 1)],
          duringRun: () async {
            // The check runs under the lock: a second taker waits.
            try {
              await KnowledgeStore(
                app,
              ).locked(() async {}, timeout: const Duration(milliseconds: 200));
            } on Object catch (error) {
              underLock = error;
            }
            // The comment is gone from the file by now; it was read before.
            File(
              p.join(app, 'lib', 'a.dart'),
            ).writeAsStringSync('int a = 1;\n');
          },
        ),
      ]);
      expect(underLock, isA<KnowledgeLockTimeout>());
      expect(result.findings, isEmpty);
      expect(result.suppressed, 1);
      expect(analysis.asked, 1);
    });

    test('a comment of a check that left a part of its work out is not '
        'unused', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.noisy — r\n');
      final result = await run([
        _Reporting(const ['a.noisy'], const [], skipsPart: true),
      ]);
      expect(result.findings, isEmpty);
      expect([for (final n in result.notRun) n.id], ['part.inner']);
    });

    test('a comment of a map check that did not run, the knowledge being '
        'stale, is not unused', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.map — r\n');
      final result = await run(
        [
          _Reporting(const ['a.noisy'], const []),
          _Reporting(const ['a.map'], const [], needsMap: true),
        ],
        refreshed: const KnowledgeRefresh.failed(
          'the packages are not fetched',
        ),
      );
      expect([
        for (final f in result.findings) f.id,
      ], isNot(contains('suppression.unused')));
      expect([for (final n in result.notRun) n.id], ['a.map']);
    });
  });

  group('the suppression findings', () {
    test('a comment without a reason is an error on its line and hides '
        'nothing', () async {
      write('lib/a.dart', '''
int a = 1; // appstein:ignore a.noisy
int b = 1; // appstein:ignore a.noisy —
// appstein:ignore-file a.noisy
''');
      final result = await run([
        _Reporting(
          const ['a.noisy'],
          [at('a.noisy', 'lib/a.dart', 1), at('a.noisy', 'lib/a.dart', 2)],
        ),
      ]);
      expect(shown(result), [
        ('suppression.no_reason', 'lib/a.dart', 1),
        ('suppression.no_reason', 'lib/a.dart', 2),
        ('suppression.no_reason', 'lib/a.dart', 3),
        ('a.noisy', 'lib/a.dart', 1),
        ('a.noisy', 'lib/a.dart', 2),
      ]);
      for (final f in result.findings.where(
        (f) => f.id == 'suppression.no_reason',
      )) {
        expect(f.severity, Severity.error);
        expect(f.message, contains('no reason'));
        expect(f.fixHint, contains('appstein:ignore'));
      }
      expect(result.suppressed, 0);
      expect(result.activeSuppressions, 0);
    });

    test('an ID no check has is an error on its line, with the closest '
        'ID', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.noisi — r\n');
      final result = await run([
        _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 1)]),
      ]);
      expect(shown(result), [
        ('suppression.unknown_check', 'lib/a.dart', 1),
        ('a.noisy', 'lib/a.dart', 1),
      ]);
      final unknown = result.findings.first;
      expect(unknown.severity, Severity.error);
      expect(unknown.message, contains('`a.noisi`'));
      expect(unknown.fixHint, contains('`a.noisy`'));
    });

    test('a comment with several IDs names an unknown check, whatever the '
        'IDs are', () async {
      write('lib/a.dart', '''
int a = 1; // appstein:ignore a.noisy, a.other — r
int b = 1; // appstein:ignore a.noisy a.other — r
''');
      final result = await run([
        _Reporting(
          const ['a.noisy', 'a.other'],
          [
            at('a.noisy', 'lib/a.dart', 1),
            at('a.other', 'lib/a.dart', 1),
            at('a.noisy', 'lib/a.dart', 2),
          ],
        ),
      ]);
      final unknown = [
        for (final f in result.findings)
          if (f.id == 'suppression.unknown_check') f,
      ];
      expect([for (final f in unknown) f.line], [1, 2]);
      expect(unknown.first.message, contains('`a.noisy, a.other`'));
      expect(unknown.first.fixHint, contains('one check'));
      expect(result.suppressed, 0);
    });

    test('the four findings nothing can hide are named by a comment as '
        'unknown checks, and are not hidden', () async {
      write('lib/a.dart', '''
// appstein:ignore knowledge.stale — r
// appstein:ignore suppression.unused — r
// appstein:ignore suppression.no_reason — r
// appstein:ignore suppression.unknown_check — r
int a = 1; // appstein:ignore suppression.unused
''');
      final result = await run([
        _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 5)]),
      ]);
      expect(shown(result), [
        ('suppression.unknown_check', 'lib/a.dart', 1),
        ('suppression.unknown_check', 'lib/a.dart', 2),
        ('suppression.unknown_check', 'lib/a.dart', 3),
        ('suppression.unknown_check', 'lib/a.dart', 4),
        ('suppression.no_reason', 'lib/a.dart', 5),
        ('a.noisy', 'lib/a.dart', 5),
      ]);
      expect(result.findings.first.message, contains("can't be suppressed"));
    });

    test('a file comment cannot hide the suppression findings of the same '
        'file', () async {
      write('lib/a.dart', '''
// appstein:ignore-file suppression.no_reason — r
int a = 1; // appstein:ignore a.noisy
''');
      final result = await run([
        _Reporting(const ['a.noisy'], const []),
      ]);
      expect(shown(result), [
        ('suppression.unknown_check', 'lib/a.dart', 1),
        ('suppression.no_reason', 'lib/a.dart', 2),
      ]);
    });

    test('an unused comment is a warning on its line, in a full run '
        'only', () async {
      write('lib/a.dart', '''
int a = 1;
int b = 2; // appstein:ignore a.noisy — nothing here
''');
      final checks = [
        _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 1)]),
      ];
      final full = await run(checks);
      expect(shown(full), [
        ('a.noisy', 'lib/a.dart', 1),
        ('suppression.unused', 'lib/a.dart', 2),
      ]);
      expect(full.findings.last.severity, Severity.warning);
      expect(full.findings.last.message, contains('hides no finding'));
      final fast = await run([
        _Reporting(
          const ['a.noisy'],
          [at('a.noisy', 'lib/a.dart', 1)],
          mode: VerifyMode.fast,
        ),
      ], mode: VerifyMode.fast);
      expect(shown(fast), [('a.noisy', 'lib/a.dart', 1)]);
    });

    test('a fast run still reports a comment with no reason or an unknown '
        'check', () async {
      write('lib/a.dart', '''
int a = 1; // appstein:ignore a.noisy
int b = 1; // appstein:ignore a.nope — r
''');
      final result = await run([
        _Reporting(const ['a.noisy'], const [], mode: VerifyMode.fast),
      ], mode: VerifyMode.fast);
      expect(shown(result), [
        ('suppression.no_reason', 'lib/a.dart', 1),
        ('suppression.unknown_check', 'lib/a.dart', 2),
      ]);
    });

    test('a comment of a check that did not run is not unused', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.noisy — r\n');
      final result = await run([
        _Reporting(
          const ['a.noisy'],
          const [],
          notRunReason: 'the code has analyzer errors',
        ),
      ]);
      expect(result.findings, isEmpty);
      expect([for (final n in result.notRun) n.id], ['a.noisy']);
    });

    test('severity overrides do not change a suppression finding', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.noisy\n');
      final result = await run(
        [
          _Reporting(const ['a.noisy'], const []),
        ],
        config: const AppsteinConfig(
          verify: VerifyConfig(
            severity: {'suppression.no_reason': Severity.info},
          ),
        ),
      );
      expect(result.findings.single.severity, Severity.error);
    });
  });

  group('the summary counts', () {
    test(
      'count the comments together with the appstein.yaml entries',
      () async {
        write('lib/a.dart', '''
// appstein:ignore-file a.noisy — r
int a = 1;
int b = 2; // appstein:ignore a.other — r
''');
        final result = await run(
          [
            _Reporting(
              const ['a.noisy', 'a.other'],
              [
                at('a.noisy', 'lib/a.dart', 2),
                at('a.noisy', 'lib/a.dart', 3),
                at('a.other', 'lib/a.dart', 3),
                at('a.other', 'lib/c.dart', 1),
                at('a.other', 'lib/c.dart', 2),
              ],
            ),
          ],
          config: const AppsteinConfig(
            suppressions: [
              SuppressionEntry(
                id: 'a.other',
                path: 'lib/c.dart',
                reason: 'r',
                line: 3,
              ),
            ],
          ),
        );
        expect(result.findings, isEmpty);
        // Two in a.dart by the file comment, one by the line comment, two in
        // c.dart by the entry; three suppressions hid something.
        expect(result.suppressed, 5);
        expect(result.activeSuppressions, 3);
      },
    );

    test('a finding hidden twice is counted once, and both hid it', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.noisy — r\n');
      final result = await run(
        [
          _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 1)]),
        ],
        config: const AppsteinConfig(
          suppressions: [
            SuppressionEntry(
              id: 'a.noisy',
              path: 'lib/a.dart',
              reason: 'r',
              line: 3,
            ),
          ],
        ),
      );
      expect(result.findings, isEmpty);
      expect(result.suppressed, 1);
      expect(result.activeSuppressions, 2);
    });
  });

  group('beside a check that follows what stays', () {
    test('it is shown the findings that stay, so a hidden one is not '
        'among them', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.noisy — r\n');
      final following = _Following();
      final result = await run([
        _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 1)]),
        following,
      ]);
      expect(following.seen, [<String>[]]);
      expect(shown(result), [('a.follow', null, null)]);
    });

    test('what it adds has no file, so no comment hides it', () async {
      write('lib/a.dart', '''
// appstein:ignore-file a.follow — r
class A {}
''');
      final result = await run([
        _Reporting(const ['a.noisy'], const []),
        _Following(),
      ]);
      // The comment names a check that only reports after the suppressions:
      // its finding is on the project, and the comment hid nothing.
      expect(shown(result), [
        ('a.follow', null, null),
        ('suppression.unused', 'lib/a.dart', 1),
      ]);
      expect(result.suppressed, 0);
    });
  });

  group('what is read', () {
    test('a Dart file the analysis did not analyze is not read', () async {
      write('lib/a.dart', 'int a = 1;\n');
      File(
        p.join(app, 'lib', 'generated.dart'),
      ).writeAsStringSync('int a = 1; // appstein:ignore a.nope\n');
      final result = await run([
        _Reporting(const ['a.noisy'], const []),
      ]);
      expect(result.findings, isEmpty);
    });

    test('text in a string is not a comment', () async {
      write('lib/a.dart', r"""
const a = '// appstein:ignore a.nope';
const b = '''
// appstein:ignore a.noisy
''';
""");
      final result = await run([
        _Reporting(const ['a.noisy'], [at('a.noisy', 'lib/a.dart', 3)]),
      ]);
      expect(shown(result), [('a.noisy', 'lib/a.dart', 3)]);
    });

    test('a run in which no check gathers the reading asks no analysis '
        'and reads no comment', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.nope\n');
      final result = await run([
        FakeCheck(const ['a.fake']),
      ]);
      expect(result.findings, isEmpty);
      expect(analysis.asked, 0);
    });

    test('the reading is taken once however many checks and comments '
        'there are', () async {
      write('lib/a.dart', 'int a = 1; // appstein:ignore a.noisy — r\n');
      await run([
        _Reporting(const ['a.noisy'], const []),
        const DartDeprecatedCheck(),
      ]);
      expect(analysis.asked, 1);
    });
  });

  group('dart.deprecated', () {
    const message = 'is deprecated';
    CodeDiagnostic deprecatedAt(int line) => CodeDiagnostic(
      file: 'lib/a.dart',
      line: line,
      code: 'deprecated_member_use',
      message: message,
      level: DiagnosticLevel.info,
    );

    test('the comment hides the analyzer\'s diagnostic', () async {
      write('lib/a.dart', '''
void f() {
  // appstein:ignore dart.deprecated — migrated in the next release
  oldWay();
  oldWay();
}
''');
      analysis.found = [deprecatedAt(3), deprecatedAt(4)];
      final result = await run([const DartDeprecatedCheck()]);
      expect(shown(result), [('dart.deprecated', 'lib/a.dart', 4)]);
      expect(result.suppressed, 1);
      expect(result.activeSuppressions, 1);
    });

    test('the comment hides the // ignore: comment that hides a use, '
        'trailing the code or alone above it', () async {
      write('lib/a.dart', '''
void f() {
  // appstein:ignore dart.deprecated — reviewed
  oldWay(); // ignore: deprecated_member_use
  // appstein:ignore dart.deprecated — reviewed
  // ignore: deprecated_member_use
  oldWay();
  oldWay(); // ignore: deprecated_member_use
}
''');
      final result = await run([const DartDeprecatedCheck()]);
      // Only the last, with no comment of ours, is still reported.
      expect(shown(result), [('dart.deprecated', 'lib/a.dart', 7)]);
      expect(result.suppressed, 2);
      expect(result.activeSuppressions, 2);
    });

    test('an ignore-file comment hides the finding on an '
        'ignore_for_file comment, and that comment makes the analyzer '
        'report no diagnostic for the file', () async {
      write('lib/a.dart', '''
// appstein:ignore-file dart.deprecated — generated bindings
// ignore_for_file: deprecated_member_use
void f() {
  oldWay();
}
''');
      // What the real analyzer reports for this file: nothing.
      final result = await run([const DartDeprecatedCheck()]);
      expect(result.findings, isEmpty);
      expect(result.suppressed, 1);
      expect(result.activeSuppressions, 1);
    });

    test('an ignore-file comment hides the diagnostic where no '
        'ignore_for_file comment is', () async {
      write('lib/a.dart', '''
// appstein:ignore-file dart.deprecated — generated bindings
void f() {
  oldWay();
}
''');
      analysis.found = [deprecatedAt(3)];
      final result = await run([const DartDeprecatedCheck()]);
      expect(result.findings, isEmpty);
      expect(result.suppressed, 1);
      expect(result.activeSuppressions, 1);
    });

    for (final (comment, label) in [
      ('// ignore_for_file: deprecated_member_use', 'a deprecated-use code'),
      ('// ignore_for_file: type=hint', 'type=hint'),
    ]) {
      group('a one-line comment above an ignore_for_file comment naming '
          '$label', () {
        test('does not hide its finding, and is unused', () async {
          write('lib/a.dart', '''
// appstein:ignore dart.deprecated — r
$comment
void f() {}
''');
          final result = await run([const DartDeprecatedCheck()]);
          expect(shown(result), [
            ('dart.deprecated', 'lib/a.dart', 2),
            ('suppression.unused', 'lib/a.dart', 1),
          ]);
          expect(result.findings.last.message, contains('ignore_for_file'));
          expect(
            result.findings.last.fixHint,
            contains('appstein:ignore-file'),
          );
          expect(result.suppressed, 0);
          expect(result.activeSuppressions, 0);
        });

        test('is not reported unused in a fast run, and still hides '
            'nothing', () async {
          write('lib/a.dart', '''
// appstein:ignore dart.deprecated — r
$comment
void f() {}
''');
          final result = await run([
            const DartDeprecatedCheck(),
          ], mode: VerifyMode.fast);
          expect(shown(result), [('dart.deprecated', 'lib/a.dart', 2)]);
        });

        test('text after it on its line is part of it, so only an ignore-file '
            'comment or an appstein.yaml entry hides it', () async {
          write('lib/a.dart', '''
void f() {}
$comment // appstein:ignore dart.deprecated — r
''');
          // A comment runs to the end of its line, so the trailing text is
          // part of the `ignore_for_file` comment and no second one exists.
          expect(shown(await run([const DartDeprecatedCheck()])), [
            ('dart.deprecated', 'lib/a.dart', 2),
          ]);
          write('lib/b.dart', '''
// appstein:ignore-file dart.deprecated — r
$comment
void f() {}
''');
          write('lib/c.dart', '$comment\nvoid f() {}\n');
          final result = await run(
            [const DartDeprecatedCheck()],
            config: const AppsteinConfig(
              suppressions: [
                SuppressionEntry(
                  id: 'dart.deprecated',
                  path: 'lib/a.dart',
                  reason: 'r',
                  line: 3,
                ),
                SuppressionEntry(
                  id: 'dart.deprecated',
                  path: 'lib/c.dart',
                  reason: 'r',
                  line: 6,
                ),
              ],
            ),
          );
          expect(result.findings, isEmpty);
          expect(result.suppressed, 3);
          expect(result.activeSuppressions, 3);
        });
      });
    }

    test('a one-line comment still hides the finding on an // ignore: '
        'comment and the diagnostic under it, beside an ignore_for_file '
        'comment', () async {
      write('lib/a.dart', '''
// ignore_for_file: deprecated_member_use
// appstein:ignore dart.deprecated — r
// ignore: deprecated_member_use
oldWay();
''');
      analysis.found = [deprecatedAt(4)];
      final result = await run([const DartDeprecatedCheck()]);
      // Line 1 stays, lines 3 and 4 are hidden.
      expect(shown(result), [('dart.deprecated', 'lib/a.dart', 1)]);
      expect(result.suppressed, 2);
      expect(result.activeSuppressions, 1);
    });

    test('an appstein:ignore written after an // ignore: on one line is part '
        'of that comment, so its finding stays', () async {
      write('lib/a.dart', '''
void f() {
  oldWay(); // ignore: deprecated_member_use // appstein:ignore dart.deprecated — r
}
''');
      final result = await run([const DartDeprecatedCheck()]);
      expect(shown(result), [('dart.deprecated', 'lib/a.dart', 2)]);
      expect(result.suppressed, 0);
    });

    test(
      'a diagnostic on the line of an ignore_for_file comment is hidden by '
      'the comment above, and the finding about the comment is not',
      () async {
        write('lib/a.dart', '''
// appstein:ignore dart.deprecated — r
otherPkgOld(); // ignore_for_file: deprecated_member_use_from_same_package
''');
        // The analyzer reports the other package's deprecated member on the
        // same line, as a diagnostic of its own.
        analysis.found = [deprecatedAt(2)];
        final result = await run([const DartDeprecatedCheck()]);
        expect(shown(result), [('dart.deprecated', 'lib/a.dart', 2)]);
        expect(result.findings.single.message, contains('ignore_for_file'));
        expect(result.suppressed, 1);
        expect(result.activeSuppressions, 1);
      },
    );

    test(
      'a reason that quotes an // ignore: comment is not itself one',
      () async {
        write('lib/a.dart', '''
// appstein:ignore dart.deprecated — see ignore: deprecated_member_use
void f() {}
''');
        final result = await run([const DartDeprecatedCheck()]);
        expect(shown(result), [('suppression.unused', 'lib/a.dart', 1)]);
      },
    );
  });
}
