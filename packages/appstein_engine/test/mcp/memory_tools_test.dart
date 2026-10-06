import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../decisions/support/decision_files.dart';
import '../support/temp.dart';
import 'support/mcp_support.dart';

void main() {
  late String root;
  const today = '2026-10-06';

  setUp(() => root = tempDir().path);

  File current() => File(p.join(root, '.appstein', 'memory', 'current.md'));
  File lessons() => File(p.join(root, '.appstein', 'memory', 'lessons.md'));

  void put(File file, String text) => file
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  Future<ToolReply> write(String kind, String text) async {
    final answer = await memoryWrite(root, {
      'kind': kind,
      'text': text,
    }, today: today);
    expect(
      answer,
      isA<ToolReply>(),
      reason: answer is ToolRefusal ? answer.message : '',
    );
    final reply = answer as ToolReply;
    expectMatchesSchema(ToolSchemas.memoryWriteResult, reply.result);
    expect(withoutNulls(reply.result), reply.result);
    return reply;
  }

  /// The refusal for the call, after checking that no memory file changed.
  Future<String> refused(String kind, String text) async {
    final folder = p.join(root, '.appstein', 'memory');
    final before = snapshotOf(folder);
    final answer = await memoryWrite(root, {
      'kind': kind,
      'text': text,
    }, today: today);
    expect(answer, isA<ToolRefusal>());
    expect(snapshotOf(folder), before);
    return (answer as ToolRefusal).message;
  }

  ToolReply read({int newest = 50}) {
    final reply = memoryRead(root, newest: newest) as ToolReply;
    expectMatchesSchema(ToolSchemas.memoryReadResult, reply.result);
    expect(withoutNulls(reply.result), reply.result);
    return reply;
  }

  group('lesson text', () {
    test('a lesson is one dated list item on one line', () {
      expect(lessonLine('2026-10-06', ' a\n  b '), '- 2026-10-06: a b');
    });

    test('lessonsIn gives the lessons without their list marker, and skips '
        'blank lines and headings', () {
      expect(
        lessonsIn(
          '# Lessons\r\n\r\n- 2026-10-03: plugin X needs minSdk 26\r\n'
          '* 2026-10-04: starred\n2026-10-05: no marker\n\n',
        ),
        [
          '2026-10-03: plugin X needs minSdk 26',
          '2026-10-04: starred',
          '2026-10-05: no marker',
        ],
      );
      expect(lessonsIn(''), isEmpty);
    });

    test('withLesson appends a line and keeps every byte before it', () {
      const line = '- 2026-10-06: new';
      expect(utf8.decode(withLesson(null, line)!), '$line\n');
      expect(
        utf8.decode(withLesson(utf8.encode('- 2026-10-01: old\n'), line)!),
        '- 2026-10-01: old\n$line\n',
      );
      // A last line without a line break gets one first.
      expect(
        utf8.decode(withLesson(utf8.encode('- 2026-10-01: old'), line)!),
        '- 2026-10-01: old\n$line\n',
      );
      // A file with Windows line breaks keeps them, and its byte order mark.
      final windows = [
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('# Lessons\r\n- 2026-10-01: old'),
      ];
      final appended = withLesson(windows, line)!;
      expect(appended.take(windows.length), windows);
      expect(
        utf8.decode(appended.skip(windows.length).toList()),
        '\r\n$line\r\n',
      );
    });

    test('withLesson is null for a lesson the file already holds, whatever '
        'its date', () {
      final bytes = utf8.encode('- 2026-09-01: plugin X needs minSdk 26\n');
      expect(
        withLesson(bytes, '- 2026-10-06: plugin X needs minSdk 26'),
        isNull,
      );
      expect(withLesson(bytes, '- 2026-10-06: plugin Y'), isNotNull);
    });
  });

  group('memory_write', () {
    test('current replaces the task in progress', () async {
      final first = await write('current', '\n# Goal\nShip favorites.\n\n');
      expect(current().readAsStringSync(), '# Goal\nShip favorites.\n');
      expect(first.result, {
        'kind': 'current',
        'file': '.appstein/memory/current.md',
      });
      expect(
        first.summary,
        'The task in progress is saved in .appstein/memory/current.md '
        '(2 lines).',
      );
      await write('current', 'Another task.');
      expect(current().readAsStringSync(), 'Another task.\n');
    });

    test(
      'lesson appends one dated line, and not the same lesson twice',
      () async {
        put(lessons(), '# Lessons\n\n- 2026-10-01: old\n');
        final reply = await write('lesson', 'plugin X\nneeds minSdk 26');
        expect(
          lessons().readAsStringSync(),
          '# Lessons\n\n- 2026-10-01: old\n'
          '- 2026-10-06: plugin X needs minSdk 26\n',
        );
        expect(reply.result, {
          'kind': 'lesson',
          'file': '.appstein/memory/lessons.md',
          'lesson': '- 2026-10-06: plugin X needs minSdk 26',
          'added': true,
        });
        expect(
          reply.summary,
          'Added the lesson to .appstein/memory/lessons.md.',
        );
        final again = await write('lesson', 'plugin X needs minSdk 26');
        expect(again.result['added'], isFalse);
        expect(
          again.summary,
          'That lesson is already in .appstein/memory/lessons.md; nothing was '
          'added.',
        );
        expect('\n'.allMatches(lessons().readAsStringSync()).length, 4);
      },
    );

    test('two lessons written at once both land', () async {
      await Future.wait([write('lesson', 'one'), write('lesson', 'two')]);
      expect(lessonsIn(lessons().readAsStringSync()), hasLength(2));
    });

    test(
      'complete saves the summary as a lesson and deletes the task',
      () async {
        await write('current', '# Goal\nShip favorites.');
        final reply = await write(
          'complete',
          'Favorites shipped;\nhive works.',
        );
        expect(current().existsSync(), isFalse);
        expect(
          lessons().readAsStringSync(),
          '- 2026-10-06: Favorites shipped; hive works.\n',
        );
        expect(reply.result, {
          'kind': 'complete',
          'file': '.appstein/memory/lessons.md',
          'lesson': '- 2026-10-06: Favorites shipped; hive works.',
          'added': true,
          'cleared': '.appstein/memory/current.md',
        });
        expect(
          reply.summary,
          'The task is finished: its summary is a lesson in '
          '.appstein/memory/lessons.md, and .appstein/memory/current.md was '
          'deleted.',
        );
      },
    );

    test('complete after the lesson was already saved deletes the task and '
        'adds nothing twice', () async {
      put(current(), '# Goal\n');
      put(lessons(), '- 2026-10-05: Done.\n');
      final reply = await write('complete', 'Done.');
      expect(current().existsSync(), isFalse);
      expect(lessons().readAsStringSync(), '- 2026-10-05: Done.\n');
      expect(reply.result['added'], isFalse);
    });

    test('complete is refused without a task in progress or without a '
        'summary', () async {
      expect(
        await refused('complete', 'Done.'),
        'No task is in progress, so there is nothing to finish. Use kind: '
        'lesson to record a lesson.',
      );
      put(current(), ' \n\n');
      expect(
        await refused('complete', 'Done.'),
        startsWith('No task is in progress'),
      );
      put(current(), '# Goal\n');
      expect(
        await refused('complete', '  '),
        'Give your one-paragraph summary of the finished task as `text`. '
        'Nothing was cleared.',
      );
    });

    test('an empty text or an unknown kind is refused', () async {
      expect(
        await refused('current', ' \n'),
        '`text` is empty. For kind: current give the goal, plan, status and '
        'open questions.',
      );
      expect(
        await refused('lesson', ''),
        '`text` is empty. For kind: lesson give the lesson in one line.',
      );
      expect(
        await refused('note', 'x'),
        '`kind` is `current`, `lesson` or `complete`, not `note`.',
      );
    });
  });

  group('memory_read', () {
    test('an empty project has no task and no lessons', () {
      final reply = read();
      expect(reply.result, {
        'currentFile': '.appstein/memory/current.md',
        'lessons': <String>[],
        'olderLessons': 0,
        'lessonsFile': '.appstein/memory/lessons.md',
      });
      expect(reply.summary, 'No task is in progress; no lessons recorded yet.');
    });

    test('gives the whole task and the lessons', () {
      final bom = String.fromCharCode(0xFEFF);
      put(current(), '$bom# Goal\r\nShip it.\r\n');
      put(lessons(), '# Lessons\n- 2026-10-01: a\n- 2026-10-02: b\n');
      final reply = read();
      expect(reply.result['current'], '# Goal\r\nShip it.\r\n');
      expect(reply.result['lessons'], ['2026-10-01: a', '2026-10-02: b']);
      expect(
        reply.summary,
        'A task is in progress (2 lines); 2 lessons recorded.',
      );
    });

    test('lists the newest lessons and counts the older ones', () {
      put(
        lessons(),
        [for (var i = 1; i <= 60; i++) '- 2026-10-01: lesson $i'].join('\n'),
      );
      final reply = read();
      final listed = reply.result['lessons']! as List;
      expect(listed, hasLength(50));
      expect(listed.first, '2026-10-01: lesson 11');
      expect(listed.last, '2026-10-01: lesson 60');
      expect(reply.result['olderLessons'], 10);
      expect(
        reply.summary,
        'No task is in progress; 60 lessons recorded. The newest 50 are '
        'listed; the 10 older ones are in .appstein/memory/lessons.md.',
      );
      expect(read(newest: 1).result['lessons'], ['2026-10-01: lesson 60']);
    });

    test('a file that cannot be read is named, not thrown', () {
      Directory(lessons().path).createSync(recursive: true);
      final reply = read();
      expect(reply.result['lessons'], isEmpty);
      expect(reply.result['lessonsProblem'], isA<String>());
      expect(
        reply.summary,
        startsWith(
          'No task is in progress; no lessons recorded yet. '
          '`.appstein/memory/lessons.md` could not be read (',
        ),
      );
    });
  });
}
