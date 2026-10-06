import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../decisions/support/decision_files.dart';
import '../knowledge/support/hold_lock.dart';
import '../support/temp.dart';
import 'support/mcp_support.dart';

void main() {
  late String root;
  const today = '2026-10-06';

  setUp(() => root = tempDir().path);

  String folder() => p.join(root, '.appstein', 'decisions');

  String text(String name) => File(p.join(folder(), name)).readAsStringSync();

  Future<ToolReply> record(Map<String, Object?> arguments) async {
    final answer = await recordDecision(root, arguments, today: today);
    expect(
      answer,
      isA<ToolReply>(),
      reason: answer is ToolRefusal ? answer.message : '',
    );
    final reply = answer as ToolReply;
    expectMatchesSchema(ToolSchemas.recordDecisionResult, reply.result);
    expect(withoutNulls(reply.result), reply.result);
    return reply;
  }

  /// The refusal for [arguments], after checking that no decision file was
  /// written or changed.
  Future<String> refused(Map<String, Object?> arguments) async {
    final before = snapshotOf(folder());
    final answer = await recordDecision(root, arguments, today: today);
    expect(answer, isA<ToolRefusal>());
    expect(snapshotOf(folder()), before);
    return (answer as ToolRefusal).message;
  }

  group('add', () {
    test('the first decision creates the folder and file 0001, proposed, '
        'dated today', () async {
      final reply = await record({
        'title': 'State management with provider + ChangeNotifier',
        'why': 'One stack pack keeps checks exact.',
      });
      const name = '0001-state-management-with-provider-changenotifier.md';
      expect(Directory(folder()).listSync().map((e) => p.basename(e.path)), [
        name,
      ]);
      expect(
        text(name),
        '---\n'
        'id: 0001\n'
        'title: State management with provider + ChangeNotifier\n'
        'status: proposed\n'
        'date: 2026-10-06\n'
        'supersedes: null\n'
        'paths: []\n'
        'checks: []\n'
        '---\n'
        'Why: One stack pack keeps checks exact.\n',
      );
      expect(reply.result['action'], 'added');
      expect(reply.result['decision'], {
        'number': '0001',
        'title': 'State management with provider + ChangeNotifier',
        'status': 'proposed',
        'date': '2026-10-06',
        'why': 'One stack pack keeps checks exact.',
        'paths': <String>[],
        'checks': <String>[],
        'file': '.appstein/decisions/$name',
      });
      expect(
        reply.summary,
        'Recorded decision 0001 as proposed in .appstein/decisions/$name. It '
        'binds once the user agrees: then call record_decision with accept: '
        '"0001".',
      );
    });

    test(
      'accepted, with paths and checks; Windows separators become /',
      () async {
        final reply = await record({
          'title': 'Routing with go_router',
          'why': 'Why: deep links.',
          'status': 'accepted',
          'paths': [r'lib\routing\**', './lib/main.dart'],
          'checks': ['paths.exist'],
        });
        final decision = reply.result['decision']! as Map;
        expect(decision['status'], 'accepted');
        expect(decision['paths'], ['lib/routing/**', 'lib/main.dart']);
        expect(decision['checks'], ['paths.exist']);
        expect(decision['why'], 'deep links.');
        expect(
          reply.summary,
          'Recorded decision 0001 as accepted in '
          '.appstein/decisions/0001-routing-with-go-router.md.',
        );
      },
    );

    test('the next number follows the highest file, an unreadable one '
        'included', () async {
      handDecision(root, '0003-a.md');
      File(p.join(folder(), '0007-x.md')).writeAsStringSync('Just text.\n');
      final reply = await record({'title': 'B', 'why': 'because'});
      expect((reply.result['decision']! as Map)['number'], '0008');
      expect(File(p.join(folder(), '0008-b.md')).existsSync(), isTrue);
    });

    test('a title of several lines is written on one', () async {
      final reply = await record({'title': ' Two\n  lines ', 'why': 'x'});
      expect((reply.result['decision']! as Map)['title'], 'Two lines');
      expect(text('0001-two-lines.md'), contains('title: Two lines\n'));
    });

    test('the number is chosen after the lock is held: a decision another '
        'process wrote while this call waited is counted', () async {
      // The other process holds the lock for a while, and "writes" 0001.
      await holdLock(p.join(root, '.appstein'), 1500);
      final waiting = record({'title': 'Mine', 'why': 'x'});
      handDecision(root, '0001-theirs.md');
      final reply = await waiting;
      expect((reply.result['decision']! as Map)['number'], '0002');
      expect(readDecisions(root).duplicates, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
      'a hand-written file with the same name is never overwritten',
      () async {
        // .MD on Windows names the same file as .md; its number is counted.
        final theirs = handDecision(root, '0001-use-provider.MD', why: 'mine.');
        final reply = await record({'title': 'Use provider', 'why': 'x'});
        expect((reply.result['decision']! as Map)['number'], '0002');
        expect(File(theirs).readAsStringSync(), contains('Why: mine.'));
      },
    );

    test('a title a decision file cannot store is refused, and nothing is '
        'written', () async {
      expect(
        await refused({
          'title': 'bad ${String.fromCharCode(0xD800)} title',
          'why': 'x',
        }),
        'The title or a path holds characters a decision file cannot store. '
        'Reword it with plain text.',
      );
    });

    test('a reason that is only "why:" markers is empty', () async {
      expect(
        await refused({'title': 'x', 'why': 'why: Why:  '}),
        startsWith('The reason (`why`) is empty.'),
      );
    });

    test('a number may be given as a number', () async {
      handDecision(root, '0001-a.md', status: 'proposed');
      final reply = await record({'accept': 1});
      expect(reply.result['action'], 'accepted');
      final replaced = await record({
        'title': 'B',
        'why': 'x',
        'supersedes': 1,
      });
      expect(replaced.result['action'], 'replaced');
    });

    test('three decisions started together get different numbers', () async {
      final replies = await Future.wait([
        record({'title': 'One', 'why': 'x'}),
        record({'title': 'Two', 'why': 'x'}),
        record({'title': 'Three', 'why': 'x'}),
      ]);
      expect(
        {
          for (final reply in replies)
            (reply.result['decision']! as Map)['number'],
        },
        {'0001', '0002', '0003'},
      );
      expect(readDecisions(root).duplicates, isEmpty);
    });
  });

  group('replace', () {
    test(
      'writes the new decision and changes only the old status line',
      () async {
        final old = handDecision(root, '0002-state.md', title: 'Use provider');
        final before = File(old).readAsStringSync();
        final reply = await record({
          'title': 'Use riverpod',
          'why': 'Compile-safe providers.',
          'status': 'accepted',
          'supersedes': '2',
        });
        expect(
          File(old).readAsStringSync(),
          before.replaceFirst('status: accepted', 'status: superseded'),
        );
        expect(text('0003-use-riverpod.md'), contains('supersedes: 0002\n'));
        expect(reply.result['action'], 'replaced');
        expect((reply.result['decision']! as Map)['supersedes'], '0002');
        final superseded = reply.result['superseded']! as Map;
        expect(superseded['number'], '0002');
        expect(superseded['status'], 'superseded');
        expect(superseded['supersededBy'], '0003');
        expect(reply.result.containsKey('warning'), isFalse);
        expect(
          reply.summary,
          'Recorded decision 0003 as accepted in '
          '.appstein/decisions/0003-use-riverpod.md. It replaces 0002, which '
          'is now superseded.',
        );
      },
    );

    test('an old file whose status line is not plain is left as it is, with '
        'a warning; readers count it as superseded all the same', () async {
      final old = File(p.join(folder(), '0001-a.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('---\ntitle: A\nstatus: "accepted"\n---\nWhy: x\n');
      final before = old.readAsStringSync();
      final reply = await record({
        'title': 'B',
        'why': 'y',
        'supersedes': '0001',
      });
      expect(old.readAsStringSync(), before);
      expect(
        reply.result['warning'],
        "The status line of .appstein/decisions/0001-a.md isn't a plain "
        '`status: word` line, so it was left as it is. Change it to '
        '`superseded` by hand.',
      );
      final superseded = reply.result['superseded']! as Map;
      expect(superseded['status'], 'superseded');
      expect(superseded['statusInFile'], 'accepted');
      expect(reply.summary, endsWith(reply.result['warning']! as String));
    });

    test('a chain through the tool: each replaced decision stays '
        'superseded and says what replaced it', () async {
      await record({'title': 'One', 'why': 'x', 'status': 'accepted'});
      await record({
        'title': 'Two',
        'why': 'x',
        'status': 'accepted',
        'supersedes': '1',
      });
      await record({
        'title': 'Three',
        'why': 'x',
        'status': 'accepted',
        'supersedes': '2',
      });
      final set = readDecisions(root);
      expect([for (final one in set.active) one.record.number], [3]);
      expect(set.numbered(1)!.supersededBy?.number, 2);
      expect(set.numbered(2)!.supersededBy?.number, 3);
    });

    test('a replaced decision never comes back: its status line could not '
        'be changed, and its replacement is replaced too', () async {
      File(p.join(folder(), '0001-a.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('---\ntitle: A\nstatus: "accepted"\n---\nWhy: x\n');
      await record({'title': 'B', 'why': 'y', 'supersedes': '1'});
      await record({'title': 'C', 'why': 'z', 'supersedes': '2'});
      final set = readDecisions(root);
      expect([for (final one in set.active) one.record.number], [3]);
      expect(set.numbered(1)!.supersededBy?.number, 2);
    });

    test('when the old file cannot be written, the new decision stays, the '
        'reply says what was left undone, and readers count the old one as '
        'superseded', () async {
      final old = handDecision(root, '0001-a.md');
      final before = File(old).readAsStringSync();
      // The write goes through `<file>.tmp`: a folder there makes it fail
      // on every operating system.
      Directory('$old.tmp').createSync();
      final reply = await record({'title': 'B', 'why': 'y', 'supersedes': '1'});
      expect(File(old).readAsStringSync(), before);
      expect(reply.result['action'], 'replaced');
      final warning = reply.result['warning']! as String;
      expect(
        warning,
        startsWith(
          "The status line of .appstein/decisions/0001-a.md couldn't be "
          'changed to `superseded` (',
        ),
      );
      expect(warning, endsWith('). Change it by hand.'));
      expect(warning, isNot(contains('appstein sync')));
      expect((reply.result['superseded']! as Map)['status'], 'superseded');
    });

    test('is refused for a number that is missing, used twice, unreadable '
        'or already superseded', () async {
      handDecision(root, '0001-a.md', status: 'superseded');
      handDecision(root, '0002-b.md');
      handDecision(root, '0002-c.md');
      handDecision(root, '0003-d.md');
      handDecision(root, '0004-e.md', supersedes: '3');
      File(p.join(folder(), '0005-x.md')).writeAsStringSync('Just text.\n');
      Map<String, Object?> replacing(String number) => {
        'title': 'New',
        'why': 'x',
        'supersedes': number,
      };
      expect(await refused(replacing('9')), 'No decision is numbered 0009.');
      expect(
        await refused(replacing('2')),
        'Number 0002 is used by 2 files (0002-b.md, 0002-c.md); rename one '
        'first.',
      );
      expect(
        await refused(replacing('5')),
        "Decision 0005 can't be read (.appstein/decisions/0005-x.md: it has "
        'no front matter); fix the file first.',
      );
      expect(
        await refused(replacing('1')),
        'Decision 0001 is already superseded.',
      );
      expect(
        await refused(replacing('3')),
        'Decision 0003 is already superseded, by 0004.',
      );
    });
  });

  group('accept', () {
    test('changes the status word and keeps everything else', () async {
      final path = handDecision(
        root,
        '0003-x.md',
        status: 'proposed          # proposed | accepted | superseded',
        eol: '\r\n',
      );
      final before = File(path).readAsStringSync();
      final reply = await record({'accept': '0003'});
      expect(
        File(path).readAsStringSync(),
        before.replaceFirst('status: proposed', 'status: accepted'),
      );
      expect(reply.result['action'], 'accepted');
      expect((reply.result['decision']! as Map)['status'], 'accepted');
      expect(reply.summary, 'Decision 0003 is now accepted.');
    });

    test('keeps a byte order mark', () async {
      final path = handDecision(root, '0001-x.md', status: 'proposed');
      final file = File(path);
      file.writeAsBytesSync([0xEF, 0xBB, 0xBF, ...file.readAsBytesSync()]);
      await record({'accept': '1'});
      final bytes = file.readAsBytesSync();
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
      expect(String.fromCharCodes(bytes.skip(3)), contains('status: accepted'));
    });

    test('is refused unless the decision is proposed', () async {
      handDecision(root, '0001-a.md');
      handDecision(root, '0002-b.md', status: 'superseded');
      handDecision(root, '0003-c.md', status: 'proposed');
      handDecision(root, '0004-d.md', supersedes: '3');
      expect(
        await refused({'accept': '1'}),
        'Decision 0001 is accepted already.',
      );
      expect(
        await refused({'accept': '2'}),
        "Decision 0002 is superseded, so it can't be accepted.",
      );
      expect(
        await refused({'accept': '3'}),
        "Decision 0003 is superseded by 0004, so it can't be accepted.",
      );
      expect(await refused({'accept': '9'}), 'No decision is numbered 0009.');
    });

    test('is refused when the status line is not plain', () async {
      File(p.join(folder(), '0001-a.md'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync("---\ntitle: A\nstatus: 'proposed'\n---\n");
      expect(
        await refused({'accept': '1'}),
        "The status line of .appstein/decisions/0001-a.md isn't a plain "
        '`status: proposed` line; change it to `accepted` by hand.',
      );
    });
  });

  group('refuses, and writes nothing, for', () {
    test('accept together with other fields', () async {
      expect(
        await refused({'accept': '1', 'title': 'x'}),
        'Pass `accept` alone, or the fields of a new decision (`title`, '
        '`why`), not both.',
      );
    });

    test('neither shape', () async {
      expect(
        await refused({}),
        'Pass `title` and `why` to record a decision, or `accept` with the '
        'number of a proposed decision.',
      );
      expect(await refused({'why': 'x'}), startsWith('Pass `title` and `why`'));
    });

    test('an empty or too long title, an empty reason', () async {
      expect(
        await refused({'title': '  ', 'why': 'x'}),
        'The title is empty. Say in one line what was decided.',
      );
      expect(
        await refused({'title': 'x' * 121, 'why': 'x'}),
        'The title has 121 characters; keep it to 120 and put the detail in '
        '`why`.',
      );
      expect(
        await refused({'title': 'x', 'why': ' \n '}),
        'The reason (`why`) is empty. A decision is recorded with its '
        'reason.',
      );
      expect(
        await refused({'title': 'x', 'why': 'Why:  '}),
        startsWith('The reason (`why`) is empty.'),
      );
    });

    test('an unknown check or status', () async {
      expect(
        await refused({
          'title': 'x',
          'why': 'y',
          'checks': ['stack.riverpod'],
        }),
        '`stack.riverpod` is not a decision check. The checks are '
        '`stack.provider` and `paths.exist`.',
      );
      expect(
        await refused({'title': 'x', 'why': 'y', 'status': 'superseded'}),
        'The status of a new decision is `proposed` or `accepted`, not '
        '`superseded`.',
      );
    });

    test('a path that is empty, absolute, leaves the project or is not a '
        'valid pattern', () async {
      Future<String> path(String value) => refused({
        'title': 'x',
        'why': 'y',
        'paths': [value],
      });
      expect(await path(' '), 'A path in `paths` is empty.');
      for (final absolute in ['/etc/x', r'C:\app\lib', 'C:/app/lib']) {
        expect(
          await path(absolute),
          '`$absolute` is an absolute path. Give paths from the project '
          'folder, such as `lib/ui/**`.',
        );
      }
      expect(
        await path('lib/../../x'),
        '`lib/../../x` leaves the project folder. Give paths from the '
        'project folder, such as `lib/ui/**`.',
      );
      expect(
        await path('lib/{a'),
        startsWith('`lib/{a` is not a valid path pattern'),
      );
    });

    test('a number that is not one', () async {
      expect(
        await refused({'accept': 'two'}),
        '`two` is not a decision number. Give it as `0002` or `2`.',
      );
      expect(
        await refused({'title': 'x', 'why': 'y', 'supersedes': '0'}),
        '`0` is not a decision number. Give it as `0002` or `2`.',
      );
    });
  });

  test('while another process holds the write lock, the call is refused '
      'after the timeout and writes nothing', () async {
    await holdLock(p.join(root, '.appstein'), 20000);
    final answer = await recordDecision(
      root,
      {'title': 'x', 'why': 'y'},
      today: today,
      lockTimeout: const Duration(milliseconds: 200),
    );
    expect(
      (answer as ToolRefusal).message,
      startsWith('Another Appstein process is still writing'),
    );
    expect(Directory(folder()).existsSync(), isFalse);
  });
}
