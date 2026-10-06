import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../decisions/support/decision_files.dart';
import '../../knowledge/support/sync_harness.dart';
import '../../support/fixture_app.dart';
import '../../support/temp.dart';
import '../support/verify_support.dart';

const _check = DecisionsCheck([PathsExistCheck()]);
const _folder = '.appstein/decisions';
const _driftFix =
    'Bring the code back in line, or replace the decision with a new one '
    '(`record_decision` with `supersedes`).';

/// A decision check for tests: it reports [sentences].
final class _FakeDecisionCheck implements DecisionCheck {
  _FakeDecisionCheck(this.id, this.sentences, {this.needsMap = false});

  @override
  final String id;

  @override
  final bool needsMap;

  final List<String> sentences;

  /// The decisions it was asked about.
  final asked = <String>[];

  @override
  List<String> problems(DecisionEntry decision, VerifyContext context) {
    asked.add(decision.record.file);
    return sentences;
  }
}

void main() {
  late String root;

  setUp(() => root = tempDir().path);

  VerifyContext context({DecisionSet? decisions}) => VerifyContext(
    projectRoot: root,
    config: const AppsteinConfig(),
    packs: const [],
    knowledge: KnowledgeSnapshot(root),
    decisions: decisions ?? readDecisions(root),
  );

  Future<List<Finding>> run([VerifyCheck check = _check]) =>
      check.run(context());

  void exists(String path) => File(p.joinAll([root, ...path.split('/')]))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('');

  test('it reports the three decision findings, in full mode, without the '
      'map', () {
    expect(_check.ids, [
      'decision.drift',
      'decision.unreadable',
      'decision.duplicate',
    ]);
    expect(_check.mode, VerifyMode.full);
    expect(_check.needsMap, isFalse);
  });

  test('no decisions folder: no finding', () async {
    expect(await run(), isEmpty);
  });

  group('decision.drift', () {
    test('an accepted decision whose paths exist holds', () async {
      exists('lib/ui/home/view_models/home_viewmodel.dart');
      handDecision(
        root,
        '0001-state.md',
        paths: ['lib/ui/**/view_models/**'],
        checks: ['paths.exist'],
      );
      expect(await run(), isEmpty);
    });

    test('a path that matches nothing is drift, on the decision file at its '
        '`paths:` line', () async {
      handDecision(
        root,
        '0001-state.md',
        paths: ['lib/ui/**/view_models/**', 'lib/gone.dart'],
        checks: ['paths.exist'],
      );
      final findings = await run();
      expect(findings, hasLength(2));
      for (final finding in findings) {
        expect(finding.id, 'decision.drift');
        expect(finding.severity, Severity.warning);
        expect(finding.file, '$_folder/0001-state.md');
        expect(finding.line, 5);
        expect(finding.fixHint, _driftFix);
        expect(finding.knowledgeRef, '$_folder/0001-state.md');
      }
      expect(findings.map((finding) => finding.message), [
        'The path `lib/ui/**/view_models/**` matches no file.',
        'The path `lib/gone.dart` matches no file.',
      ]);
    });

    test('the line is the same with CRLF line endings and a byte order '
        'mark', () async {
      final path = handDecision(
        root,
        '0001-state.md',
        supersedes: 'null',
        paths: ['lib/gone.dart'],
        checks: ['paths.exist'],
        eol: '\r\n',
      );
      final file = File(path);
      file.writeAsBytesSync([0xEF, 0xBB, 0xBF, ...file.readAsBytesSync()]);
      final finding = (await run()).single;
      expect(finding.message, 'The path `lib/gone.dart` matches no file.');
      expect(finding.line, 6);
    });

    test('a proposed decision is not checked', () async {
      handDecision(
        root,
        '0001-state.md',
        status: 'proposed',
        paths: ['lib/gone.dart'],
        checks: ['paths.exist'],
      );
      expect(await run(), isEmpty);
    });

    test('a decision another one replaces is not checked, whatever its own '
        'status line says', () async {
      handDecision(
        root,
        '0001-state.md',
        paths: ['lib/gone.dart'],
        checks: ['paths.exist'],
      );
      handDecision(root, '0002-state-again.md', supersedes: '1');
      expect(await run(), isEmpty);
    });

    test('a decision that names no check is not checked', () async {
      handDecision(root, '0001-state.md', paths: ['lib/gone.dart']);
      expect(await run(), isEmpty);
    });

    test('a check no pack provides is drift, at the `checks:` line', () async {
      exists('lib/main.dart');
      handDecision(
        root,
        '0001-state.md',
        paths: ['lib/main.dart'],
        checks: ['stack.provider', 'paths.exist'],
      );
      final finding = (await run()).single;
      expect(finding.id, 'decision.drift');
      expect(finding.severity, Severity.warning);
      expect(finding.file, '$_folder/0001-state.md');
      expect(finding.line, 6);
      expect(
        finding.message,
        'The decision names the check `stack.provider`, which no pack of '
        'this project provides.',
      );
      expect(finding.fixHint, isNotNull);
    });

    test('each sentence of a check is one finding, at the `checks:` line; a '
        'check named twice runs once', () async {
      final fake = _FakeDecisionCheck('stack.provider', ['One.', 'Two.']);
      handDecision(
        root,
        '0001-state.md',
        checks: ['stack.provider', 'stack.provider'],
      );
      handDecision(root, '0002-other.md');
      final findings = await run(DecisionsCheck([fake]));
      expect(fake.asked, ['0001-state.md']);
      expect(
        [for (final finding in findings) (finding.line, finding.message)],
        [(5, 'One.'), (5, 'Two.')],
      );
    });

    test('a check that reads the map is not asked while the map cannot be '
        'read', () async {
      final fake = _FakeDecisionCheck('stack.provider', [
        'One.',
      ], needsMap: true);
      handDecision(root, '0001-state.md', checks: ['stack.provider']);
      expect(await run(DecisionsCheck([fake])), isEmpty);
      expect(fake.asked, isEmpty);
    });
  });

  group('with the project map', () {
    late String app;
    late String sdk;
    const check = DecisionsCheck([PathsExistCheck(), StackProviderCheck()]);
    // A project always has a platform pack (`packs.platforms` can't be
    // empty), and `map/native.json` is written only with one.
    const packs = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];

    setUp(() {
      sdk = fakeFlutter();
      app = copyFixtureApp();
      handDecision(app, '0001-state.md', checks: ['stack.provider']);
    });

    test('`stack.provider` reports what the map shows', () async {
      // The fixture app does not depend on provider.
      final findings = await check.run(
        await contextFor(app, flutterRoot: sdk, packs: packs),
      );
      expect(findings.map((finding) => finding.message), [
        'The project does not depend on `provider`.',
      ]);
      expect(findings.single.id, 'decision.drift');
      expect(findings.single.line, 5);
    });

    test('and nothing when a map file is missing', () async {
      final context = await contextFor(app, flutterRoot: sdk, packs: packs);
      // Before: the map is whole, so the check reports.
      expect(await check.run(context), hasLength(1));
      File(p.join(app, '.appstein', 'map', 'routes.json')).deleteSync();
      expect(
        await check.run(
          VerifyContext(
            projectRoot: app,
            config: context.config,
            packs: context.packs,
            knowledge: KnowledgeSnapshot(app),
            decisions: context.decisions,
          ),
        ),
        isEmpty,
      );
    });
  });

  group('decision.unreadable', () {
    test('a file that cannot be read, with the reason', () async {
      File(p.join(root, '.appstein', 'decisions', '0001-broken.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('No front matter here.\n');
      final finding = (await run()).single;
      expect(finding.id, 'decision.unreadable');
      expect(finding.severity, Severity.warning);
      expect(finding.file, '$_folder/0001-broken.md');
      expect(finding.line, isNull);
      expect(
        finding.message,
        "The decision can't be read: it has no front matter.",
      );
      expect(
        finding.fixHint,
        'Fix its front matter (spec format: id, title, status, date, paths, '
        'checks), or delete the file.',
      );
    });

    test('decisions that supersede each other in a circle', () async {
      handDecision(root, '0001-a.md', supersedes: '2');
      handDecision(root, '0002-b.md', supersedes: '1');
      final finding = (await run()).single;
      expect(finding.id, 'decision.unreadable');
      expect(finding.file, _folder);
      expect(
        finding.message,
        'Decisions 0001 and 0002 supersede each other in a circle; 0002 is '
        'counted as the one in force.',
      );
    });

    test('a folder that cannot be listed', () async {
      final finding = (await _check.run(
        context(decisions: const DecisionSet(folderProblem: 'access denied')),
      )).single;
      expect(finding.id, 'decision.unreadable');
      expect(finding.file, _folder);
      expect(
        finding.message,
        'The decisions folder could not be listed (access denied).',
      );
    });
  });

  group('decision.duplicate', () {
    test('two files with one number: each names the other', () async {
      handDecision(root, '0001-first.md');
      handDecision(root, '0003-a.md');
      handDecision(root, '0003-b.md');
      final findings = await run();
      expect(
        [
          for (final finding in findings)
            (finding.id, finding.file, finding.message),
        ],
        [
          (
            'decision.duplicate',
            '$_folder/0003-a.md',
            'Decision 0003 is also `0003-b.md`.',
          ),
          (
            'decision.duplicate',
            '$_folder/0003-b.md',
            'Decision 0003 is also `0003-a.md`.',
          ),
        ],
      );
      for (final finding in findings) {
        expect(finding.severity, Severity.warning);
        expect(
          finding.fixHint,
          'Rename one of them to the next free number, 0004.',
        );
      }
    });

    test('three files with one number: each names both others', () async {
      for (final name in ['a', 'b', 'c']) {
        handDecision(root, '0002-$name.md');
      }
      expect((await run()).map((finding) => finding.message), [
        'Decision 0002 is also `0002-b.md` and `0002-c.md`.',
        'Decision 0002 is also `0002-a.md` and `0002-c.md`.',
        'Decision 0002 is also `0002-a.md` and `0002-b.md`.',
      ]);
    });
  });
}
