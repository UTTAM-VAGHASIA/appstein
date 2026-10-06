import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

/// The example in spec §6.7.
const specExample = '''
---
id: 0002
title: State management with provider + ChangeNotifier
status: accepted          # proposed | accepted | superseded
date: 2026-10-02
supersedes: null
paths: [lib/ui/**/view_models/**, lib/config/dependencies.dart]
checks: [stack.provider]  # optional: verifier checks that confirm this decision
---
Why: Flutter's architecture guide recommends it; one stack pack keeps checks exact.
''';

/// A byte order mark, as Windows PowerShell 5.1 writes one.
final bom = String.fromCharCode(0xFEFF);

String file({
  String title = 'title: A choice',
  String status = 'status: accepted',
  String extra = '',
  String body = 'Why: because.',
}) => '---\n$title\n$status\n$extra---\n$body\n';

DecisionRecord read(String text, [String name = '0002-state.md']) =>
    (parseDecisionFile(name, text) as ReadDecision).record;

String problem(String text, [String name = '0002-state.md']) =>
    (parseDecisionFile(name, text) as UnreadableDecision).problem;

void main() {
  group('decisionFileNumber', () {
    test('is the number the file name starts with', () {
      expect(decisionFileNumber('0002-state.md'), 2);
      expect(decisionFileNumber('12345-x.md'), 12345);
      expect(decisionFileNumber('notes.md'), isNull);
      expect(decisionFileNumber('0002.md'), isNull);
    });
  });

  group('parseDecisionFile', () {
    test("reads the spec's example", () {
      final record = read(specExample);
      expect(record.file, '0002-state.md');
      expect(record.number, 2);
      expect(record.title, 'State management with provider + ChangeNotifier');
      expect(record.status, DecisionStatus.accepted);
      expect(record.date, '2026-10-02');
      expect(record.supersedes, isNull);
      expect(record.paths, [
        'lib/ui/**/view_models/**',
        'lib/config/dependencies.dart',
      ]);
      expect(record.checks, ['stack.provider']);
      expect(
        record.why,
        "Flutter's architecture guide recommends it; one stack pack keeps "
        'checks exact.',
      );
    });

    test('says why a file cannot be read', () {
      expect(problem('Why: x\n'), 'it has no front matter');
      expect(problem(''), 'it has no front matter');
      expect(problem('---\ntitle: A\n'), 'its front matter has no closing ---');
      expect(
        problem('---\ntitle: [\n---\n'),
        'its front matter is not valid YAML',
      );
      expect(problem('---\n- a\n---\n'), 'its front matter is not a map');
      expect(problem(file(title: 'id: 1')), 'it has no title');
      expect(problem(file(title: 'title: "  "')), 'it has no title');
      expect(
        problem(file(status: 'status: done')),
        'its status is not accepted, proposed or superseded',
      );
      expect(
        problem(file(status: 'id: 1')),
        'its status is not accepted, proposed or superseded',
      );
    });

    test('reads the number a decision supersedes, however it is written', () {
      expect(read(file(extra: 'supersedes: 2\n')).supersedes, 2);
      expect(read(file(extra: 'supersedes: 0002\n')).supersedes, 2);
      expect(read(file(extra: "supersedes: '0002'\n")).supersedes, 2);
      expect(read(file(extra: 'supersedes: null\n')).supersedes, isNull);
      expect(read(file(extra: 'supersedes:\n')).supersedes, isNull);
      expect(
        problem(file(extra: 'supersedes: yes\n')),
        'its supersedes is not a decision number',
      );
    });

    test('reads paths and checks as lists, and one string as one item', () {
      final record = read(
        file(extra: 'paths: lib/ui/**\nchecks:\n  - paths.exist\n'),
      );
      expect(record.paths, ['lib/ui/**']);
      expect(record.checks, ['paths.exist']);
      expect(
        problem(file(extra: 'paths: {a: b}\n')),
        'its paths are not a list',
      );
      expect(
        problem(file(extra: 'checks: {a: b}\n')),
        'its checks are not a list',
      );
    });

    test('reads a file with a byte order mark and Windows line breaks', () {
      final windows = '$bom${specExample.replaceAll('\n', '\r\n')}';
      final record = read(windows);
      expect(record.title, read(specExample).title);
      expect(record.why, read(specExample).why);
      expect(record.status, DecisionStatus.accepted);
    });

    test('keeps a reason of several lines, without the leading Why:', () {
      expect(read(file(body: 'why: first\n\nsecond')).why, 'first\n\nsecond');
      expect(read(file(body: 'No marker here.')).why, 'No marker here.');
      expect(read(file(body: '')).why, '');
    });

    test('puts the title on one line of at most 120 characters', () {
      expect(read(file(title: 'title: "a\\n  b"')).title, 'a b');
      final long = read(file(title: 'title: ${'x' * 200}')).title;
      expect(long.runes.length, 120);
      expect(long, endsWith('…'));
    });
  });

  group('renderDecision', () {
    test("writes the spec's layout", () {
      expect(
        renderDecision(
          number: 2,
          title: 'State management with provider + ChangeNotifier',
          status: DecisionStatus.accepted,
          date: '2026-10-02',
          paths: const [
            'lib/ui/**/view_models/**',
            'lib/config/dependencies.dart',
          ],
          checks: const ['stack.provider'],
          why: 'One stack pack keeps checks exact.',
        ),
        '---\n'
        'id: 0002\n'
        'title: State management with provider + ChangeNotifier\n'
        'status: accepted\n'
        'date: 2026-10-02\n'
        'supersedes: null\n'
        'paths: [lib/ui/**/view_models/**, lib/config/dependencies.dart]\n'
        'checks: [stack.provider]\n'
        '---\n'
        'Why: One stack pack keeps checks exact.\n',
      );
    });

    test('writes the decision it replaces, and empty lists', () {
      final text = renderDecision(
        number: 12,
        title: 'A',
        status: DecisionStatus.proposed,
        date: '2026-10-06',
        supersedes: 3,
        why: 'Why: because.',
      );
      expect(text, contains('id: 0012\n'));
      expect(text, contains('supersedes: 0003\n'));
      expect(text, contains('paths: []\nchecks: []\n'));
      expect(text, endsWith('---\nWhy: because.\n'));
      expect(read(text, '0012-a.md').supersedes, 3);
    });

    test('a title or path YAML would misread still reads back', () {
      const titles = [
        'true',
        '123',
        'null',
        'a: b',
        '# x',
        '*star',
        'say "hi"',
        "it's",
        'naïve café',
        '- dash',
        '[list]',
        'trailing ',
        '2026-10-06',
      ];
      const paths = ['**/x.dart', 'lib/ui/**', 'a, b/c.dart', '{a,b}/*.dart'];
      for (final title in titles) {
        final record = read(
          renderDecision(
            number: 1,
            title: title,
            status: DecisionStatus.proposed,
            date: '2026-10-06',
            paths: paths,
            why: 'because',
          ),
          '0001-x.md',
        );
        expect(record.title, title.trim(), reason: title);
        expect(record.paths, paths, reason: title);
      }
    });
  });

  group('withDecisionStatus', () {
    test('changes the status word and nothing else', () {
      final changed = withDecisionStatus(
        specExample,
        DecisionStatus.superseded,
      )!;
      expect(
        changed,
        specExample.replaceFirst(
          'status: accepted          # proposed',
          'status: superseded          # proposed',
        ),
      );
    });

    test('keeps Windows line breaks and a byte order mark', () {
      final windows = '$bom${specExample.replaceAll('\n', '\r\n')}';
      final changed = withDecisionStatus(windows, DecisionStatus.proposed)!;
      expect(
        changed,
        windows.replaceFirst('status: accepted', 'status: proposed'),
      );
      expect(changed, startsWith('$bom---\r\n'));
    });

    test('leaves a status: line below the front matter alone', () {
      final text = file(body: 'Why: x\nstatus: accepted');
      final changed = withDecisionStatus(text, DecisionStatus.superseded)!;
      expect(
        changed,
        file(status: 'status: superseded', body: 'Why: x\nstatus: accepted'),
      );
    });

    test('is null when the status line is not a plain word', () {
      expect(
        withDecisionStatus(
          file(status: 'status: "accepted"'),
          DecisionStatus.superseded,
        ),
        isNull,
      );
      expect(
        withDecisionStatus(file(status: 'id: 1'), DecisionStatus.superseded),
        isNull,
      );
      expect(
        withDecisionStatus('no front matter', DecisionStatus.accepted),
        isNull,
      );
    });
  });

  group('decisionSlug', () {
    test('is lowercase letters, digits and hyphens', () {
      expect(
        decisionSlug('State management with provider + ChangeNotifier'),
        'state-management-with-provider-changenotifier',
      );
      expect(decisionSlug('  Use go_router 18  '), 'use-go-router-18');
    });

    test('is at most 50 characters, cut at a word', () {
      final slug = decisionSlug(
        'one two three four five six seven eight nine ten eleven twelve '
        'thirteen fourteen',
      );
      expect(slug.length, lessThanOrEqualTo(50));
      expect(slug, 'one-two-three-four-five-six-seven-eight-nine-ten');
      expect(decisionSlug('x' * 90), 'x' * 50);
    });

    test('is "decision" when nothing is left', () {
      expect(decisionSlug('!!!'), 'decision');
      expect(decisionSlug('日本語'), 'decision');
    });
  });
}
