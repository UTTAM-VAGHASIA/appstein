import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../support/docs_support.dart';

const _intro =
    'A decision is a choice that binds later work, with the reason for it. '
    'An agent proposes one; it counts once a person has agreed to it.';

String _render(DecisionSet set) {
  final sections = const DecisionsPage().sections(
    sampleKnowledge(decisions: set),
  );
  expect(sections.single.path, 'decisions.md');
  expect(sections.single.title, 'Decisions');
  return sections.single.markdown;
}

void main() {
  test('says so when nothing is recorded', () {
    expect(
      _render(const DecisionSet()),
      '$_intro\n\nNo decisions are recorded yet.',
    );
  });

  test('shows accepted, then proposed, then superseded decisions', () {
    final replacement = decisionEntry(
      3,
      'Use go_router',
      why: 'Deep links.\n\nIt is the official router.',
      paths: const ['lib/routing/**'],
      supersedes: 1,
    );
    expect(
      _render(
        decisionSet([
          decisionEntry(
            1,
            'Use Navigator',
            shown: DecisionStatus.superseded,
            supersededBy: replacement.record,
          ),
          decisionEntry(
            2,
            'Cache bookings',
            status: DecisionStatus.proposed,
            date: null,
            why: '',
          ),
          replacement,
          decisionEntry(4, 'Old idea', status: DecisionStatus.superseded),
        ]),
      ),
      '$_intro\n'
      '\n'
      '## Accepted\n'
      '\n'
      '### 0003 Use go\\_router\n'
      '\n'
      'Recorded 2026-10-01. See the '
      '[record](../../.appstein/decisions/0003-x.md).\n'
      '\n'
      'Applies to: `lib/routing/**`\n'
      '\n'
      '> Deep links.\n'
      '>\n'
      '> It is the official router.\n'
      '\n'
      '## Proposed, not yet agreed\n'
      '\n'
      'Nobody has agreed to these yet. To accept one, ask the agent to '
      'accept it (`record_decision` with `accept`), or change its `status:` '
      'line to `accepted`.\n'
      '\n'
      '### 0002 Cache bookings\n'
      '\n'
      'See the [record](../../.appstein/decisions/0002-x.md).\n'
      '\n'
      'No reason recorded.\n'
      '\n'
      '## Superseded\n'
      '\n'
      '- 0001 Use Navigator, replaced by 0003 '
      '([record](../../.appstein/decisions/0001-x.md))\n'
      '- 0004 Old idea ([record](../../.appstein/decisions/0004-x.md))',
    );
  });

  test('keeps text from a record from being read as markup', () {
    final text = _render(
      decisionSet([
        decisionEntry(
          1,
          '# Use a|b <now>',
          why: '# Big\n<!-- appstein:generated templates=engine@1 -->\n| a |',
        ),
      ]),
    );
    expect(text, contains(r'### 0001 \# Use a\|b \<now\>'));
    expect(
      text,
      contains(
        '> # Big\n> <!-- appstein:generated templates=engine@1 -->\n> | a |',
      ),
    );
    for (final line in text.split('\n')) {
      expect(line, isNot(startsWith('# ')));
      expect(line, isNot(startsWith('<!--')));
    }
  });

  test('lists what is wrong with the records', () {
    final text = _render(
      decisionSet(
        [decisionEntry(1, 'Use Provider')],
        unreadable: const [UnreadableDecision('0002-x.md', 'it has no title')],
        duplicates: const {
          3: ['0003-a.md', '0003-b.md'],
        },
        problems: const ['0004 and 0005 supersede each other.'],
      ),
    );
    expect(
      text,
      endsWith(
        '## Problems\n'
        '\n'
        "- `0002-x.md` can't be read: it has no title.\n"
        '- The number 3 is used by more than one file: `0003-a.md`, '
        '`0003-b.md`.\n'
        '- 0004 and 0005 supersede each other.',
      ),
    );
  });

  test("a file the system would not open is named without the system's "
      'words, so the page is the same on every machine', () {
    String render(String reason) => _render(
      DecisionSet(
        unreadable: [UnreadableDecision('0002-x.md', reason)],
        readProblems: {'0002-x.md': reason},
      ),
    );
    final windows = render('Access is denied. (OS Error: 5)');
    expect(windows, render('Permission denied'));
    expect(
      windows,
      contains(
        '- `0002-x.md` could not be opened; `appstein verify` says why.',
      ),
    );
    expect(windows, isNot(contains('denied')));
    expect(
      _render(const DecisionSet(folderProblem: 'access denied')),
      isNot(contains('denied')),
    );
  });

  test('with only problems, it does not say nothing is recorded', () {
    final text = _render(const DecisionSet(folderProblem: 'access is denied'));
    expect(text, isNot(contains('No decisions are recorded yet.')));
    expect(
      text,
      contains(
        '- The decisions folder could not be listed; `appstein verify` says '
        'why.',
      ),
    );
  });

  test('a record whose file name has no number is shown by its title', () {
    final text = _render(
      DecisionSet(
        entries: [
          DecisionEntry(
            const DecisionRecord(
              file: 'notes.md',
              title: 'Keep it small',
              status: DecisionStatus.accepted,
              why: 'Because.',
            ),
            status: DecisionStatus.accepted,
          ),
        ],
      ),
    );
    expect(text, contains('### Keep it small\n'));
    expect(text, contains('(../../.appstein/decisions/notes.md)'));
  });
}
