import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';
import 'support/decision_files.dart';

void main() {
  late String root;

  setUp(() => root = tempDir().path);

  DecisionEntry entry(DecisionSet set, int number) =>
      set.entries.firstWhere((entry) => entry.record.number == number);

  test('a project without the folder has no decisions and starts at 1', () {
    final set = readDecisions(root);
    expect(set.entries, isEmpty);
    expect(set.unreadable, isEmpty);
    expect(set.duplicates, isEmpty);
    expect(set.problems, isEmpty);
    expect(set.folderProblem, isNull);
    expect(set.nextNumber, 1);
  });

  test('reads the files in file-name order, each with its status', () {
    handDecision(root, '0002-b.md', status: 'proposed');
    handDecision(root, '0001-a.md');
    handDecision(root, '0003-c.md', status: 'superseded');
    File(
      p.join(root, '.appstein', 'decisions', 'README.txt'),
    ).writeAsStringSync('not a decision');
    final set = readDecisions(root);
    expect(
      [for (final entry in set.entries) entry.record.file],
      ['0001-a.md', '0002-b.md', '0003-c.md'],
    );
    expect(
      [for (final entry in set.entries) entry.status],
      [
        DecisionStatus.accepted,
        DecisionStatus.proposed,
        DecisionStatus.superseded,
      ],
    );
    expect(
      [for (final entry in set.entries) entry.active],
      [true, true, false],
    );
    expect(set.active.length, 2);
    expect(set.nextNumber, 4);
    expect(set.bytes.keys, ['0001-a.md', '0002-b.md', '0003-c.md']);
  });

  test('a decision an active one names in supersedes counts as superseded, '
      'whatever its own status line says', () {
    handDecision(root, '0001-a.md');
    handDecision(root, '0003-c.md', supersedes: '0001');
    final set = readDecisions(root);
    final old = entry(set, 1);
    expect(old.record.status, DecisionStatus.accepted);
    expect(old.status, DecisionStatus.superseded);
    expect(old.supersededBy?.number, 3);
    expect(old.active, isFalse);
    expect(entry(set, 3).active, isTrue);
    expect(set.problems, isEmpty);
  });

  test('once replaced, always replaced: a decision stays superseded when '
      'the one that replaced it is superseded too', () {
    handDecision(root, '0001-a.md');
    handDecision(root, '0002-b.md', status: 'superseded', supersedes: '1');
    final set = readDecisions(root);
    expect(entry(set, 1).active, isFalse);
    expect(entry(set, 1).supersededBy?.number, 2);
  });

  test('a decision that names itself, or a number no file has, replaces '
      'nothing and is no circle', () {
    handDecision(root, '0001-a.md', supersedes: '1');
    handDecision(root, '0002-b.md', supersedes: '9');
    final set = readDecisions(root);
    expect(set.active, hasLength(2));
    expect(set.problems, isEmpty);
  });

  test('a file named .MD is a decision file too, so its number is taken', () {
    handDecision(root, '0001-use-provider.MD');
    final set = readDecisions(root);
    expect(set.entries.single.record.file, '0001-use-provider.MD');
    expect(set.nextNumber, 2);
  });

  test('a chain is followed: the newest stays, the others are superseded', () {
    handDecision(root, '0001-a.md');
    handDecision(root, '0002-b.md', supersedes: '1');
    handDecision(root, '0003-c.md', supersedes: '2');
    final set = readDecisions(root);
    expect(entry(set, 3).active, isTrue);
    expect(entry(set, 2).supersededBy?.number, 3);
    // 0002 is superseded itself, yet it did replace 0001.
    expect(entry(set, 1).status, DecisionStatus.superseded);
    expect(entry(set, 1).supersededBy?.number, 2);
  });

  test('two decisions that supersede each other: the higher number stays, '
      'and the set says so once', () {
    handDecision(root, '0001-a.md', supersedes: '2');
    handDecision(root, '0002-b.md', supersedes: '1');
    final set = readDecisions(root);
    expect(entry(set, 2).active, isTrue);
    expect(entry(set, 1).active, isFalse);
    expect(set.problems, [
      'Decisions 0001 and 0002 supersede each other in a circle; 0002 is '
          'counted as the one in force.',
    ]);
  });

  test('a superseded line records what replaced it when a decision says', () {
    handDecision(root, '0001-a.md', status: 'superseded');
    handDecision(root, '0002-b.md', supersedes: '1');
    expect(entry(readDecisions(root), 1).supersededBy?.number, 2);
  });

  test('a number two files use is a duplicate, and numbered() gives '
      'neither', () {
    handDecision(root, '0005-a.md');
    handDecision(root, '0005-b.md');
    handDecision(root, '0004-c.md');
    final set = readDecisions(root);
    expect(set.duplicates, {
      5: ['0005-a.md', '0005-b.md'],
    });
    expect(set.numbered(5), isNull);
    expect(set.numbered(4)!.record.file, '0004-c.md');
    expect(set.numbered(9), isNull);
    expect(set.nextNumber, 6);
  });

  test('an unreadable file is reported and its number is never reused', () {
    handDecision(root, '0001-a.md');
    File(
      p.join(root, '.appstein', 'decisions', '0009-x.md'),
    ).writeAsStringSync('Just text.\n');
    final set = readDecisions(root);
    expect(set.entries.single.record.number, 1);
    expect(set.unreadable.single.file, '0009-x.md');
    expect(set.unreadable.single.problem, 'it has no front matter');
    expect(set.nextNumber, 10);
    expect(set.numbered(9), isNull);
  });

  test('a decisions folder that cannot be listed is a folder problem', () {
    Directory(p.join(root, '.appstein')).createSync();
    File(p.join(root, '.appstein', 'decisions')).writeAsStringSync('x');
    final set = readDecisions(root);
    // A file where the folder should be: nothing to list, nothing read.
    expect(set.entries, isEmpty);
    expect(set.nextNumber, 1);
  });

  test('decisionPath is the file from the project folder', () {
    expect(decisionPath('0002-state.md'), '.appstein/decisions/0002-state.md');
  });
}
