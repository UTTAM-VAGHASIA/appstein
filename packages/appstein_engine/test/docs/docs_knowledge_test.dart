import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/docs_support.dart';

void main() {
  test('a fresh view has read nothing', () {
    expect(sampleKnowledge().view().read, isEmpty);
  });

  test('a view records exactly the parts that were read', () {
    final view = sampleKnowledge().view();
    view.features;
    view.symbols;
    view.features;
    view.docsPath;
    expect(view.read, {'features', 'symbols'});
  });

  test('every part has a name and a digest', () {
    final knowledge = sampleKnowledge();
    final view = knowledge.view();
    view
      ..projectName
      ..platforms
      ..stack
      ..sdk
      ..features
      ..symbols
      ..routes
      ..layers
      ..deps
      ..native
      ..decisions
      ..teamNotes;
    expect(view.read, DocsKnowledge.partNames.toSet());
    for (final name in view.read) {
      expect(knowledge.digestOf(name), hasLength(64), reason: name);
    }
    expect(() => knowledge.digestOf('nope'), throwsArgumentError);
  });

  test('equal content has equal digests', () {
    final a = sampleKnowledge();
    final b = sampleKnowledge();
    for (final name in DocsKnowledge.partNames) {
      expect(a.digestOf(name), b.digestOf(name), reason: name);
    }
  });

  test('a changed part changes only its own digest', () {
    final a = sampleKnowledge();
    final b = sampleKnowledge(
      symbols: SymbolsMap(
        symbols: [
          for (final symbol in sampleSymbols.symbols)
            symbol.name == 'Booking'
                ? MapSymbol(
                    name: symbol.name,
                    kind: symbol.kind,
                    file: symbol.file,
                    line: symbol.line,
                    layer: symbol.layer,
                    summary: 'A booking of one room.',
                  )
                : symbol,
        ],
      ),
    );
    for (final name in DocsKnowledge.partNames) {
      expect(
        a.digestOf(name) == b.digestOf(name),
        name != 'symbols',
        reason: name,
      );
    }
  });

  test('the decisions digest follows the files and the problems', () {
    final one = sampleKnowledge(
      decisions: decisionSet([decisionEntry(1, 'Use Provider')]),
    );
    final other = sampleKnowledge(
      decisions: decisionSet([decisionEntry(1, 'Use Riverpod')]),
    );
    final withProblem = sampleKnowledge(
      decisions: decisionSet(
        [decisionEntry(1, 'Use Provider')],
        problems: ['0001 and 0002 supersede each other.'],
      ),
    );
    final unreadable = sampleKnowledge(
      decisions: decisionSet(
        [decisionEntry(1, 'Use Provider')],
        unreadable: [const UnreadableDecision('0002-x.md', 'no front matter')],
      ),
    );
    final digests = {
      for (final knowledge in [one, other, withProblem, unreadable])
        knowledge.digestOf('decisions'),
    };
    expect(digests, hasLength(4));
  });

  test('the team notes digest follows their paths and titles', () {
    final a = sampleKnowledge(
      teamNotes: const [TeamNote(path: 'onboarding.md', title: 'Onboarding')],
    );
    final b = sampleKnowledge(
      teamNotes: const [TeamNote(path: 'onboarding.md', title: 'Start here')],
    );
    expect(a.digestOf('teamNotes'), isNot(b.digestOf('teamNotes')));
    expect(
      a.digestOf('teamNotes'),
      isNot(sampleKnowledge().digestOf('teamNotes')),
    );
  });
}
