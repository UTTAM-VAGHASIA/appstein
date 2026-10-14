import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/process_memory.dart';

void main() {
  group('elapsedSeconds', () {
    test('reads mm:ss, hh:mm:ss and dd-hh:mm:ss', () {
      expect(elapsedSeconds('00:07'), 7);
      expect(elapsedSeconds('12:34'), 12 * 60 + 34);
      expect(elapsedSeconds('01:02:03'), 3600 + 120 + 3);
      expect(elapsedSeconds('2-01:00:00'), 2 * 86400 + 3600);
    });

    test('is null for anything else', () {
      expect(elapsedSeconds(''), isNull);
      expect(elapsedSeconds('12'), isNull);
      expect(elapsedSeconds('a:b'), isNull);
      expect(elapsedSeconds('1-2-03:04'), isNull);
      expect(elapsedSeconds('x-01:00'), isNull);
    });
  });

  group('parseWindowsProcessList', () {
    test('reads "<id> <parent> <bytes> <start>" lines, skips the rest', () {
      final rows = parseWindowsProcessList(
        '4 0 147456 1000\r\n'
        '100 4 1048576 -\r\n'
        // A line without the start is read, with no start.
        '150 4 2048\r\n'
        'not a process line\r\n'
        '200 100 x 5\r\n'
        '\r\n',
      );
      expect(rows.map((row) => (row.id, row.parent, row.bytes, row.start)), [
        (4, 0, 147456, 1000),
        (100, 4, 1048576, null),
        (150, 4, 2048, null),
      ]);
    });
  });

  group('parsePsProcessList', () {
    test('reads "pid ppid rss etime", memory in kilobytes, the start from '
        'the elapsed time', () {
      final rows = parsePsProcessList(
        '    1     0  10240 1-00:00:00\n'
        '  500     1   2048    00:10\n'
        '  600     1   1024\n'
        'garbage\n',
        now: 1000000000,
      );
      expect(rows.map((row) => (row.id, row.parent, row.bytes, row.start)), [
        (1, 0, 10240 * 1024, 1000000000 - 86400 * 1000),
        (500, 1, 2048 * 1024, 1000000000 - 10 * 1000),
        (600, 1, 1024 * 1024, null),
      ]);
    });
  });

  group('checkedProcessList', () {
    test('returns the rows of a good listing', () {
      final rows = checkedProcessList(
        0,
        '4242 1 100 00:01\n1 0 50 10:00\n',
        windows: false,
        now: 0,
        ownPid: 4242,
      );
      expect(rows, hasLength(2));
    });

    test('throws when the listing failed, whatever it printed', () {
      expect(
        () => checkedProcessList(
          1,
          '4242 1 100 00:01\n',
          windows: false,
          now: 0,
          ownPid: 4242,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('exit code 1'),
          ),
        ),
      );
    });

    test('throws on an empty list or one without this process: it would '
        'read as no memory and no leftover', () {
      for (final output in ['', '\n', '5 1 100 00:01\n']) {
        expect(
          () => checkedProcessList(
            0,
            output,
            windows: false,
            now: 0,
            ownPid: 4242,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('4242'),
            ),
          ),
          reason: 'output "$output"',
        );
      }
    });

    test('reads a Windows listing the same way', () {
      expect(
        checkedProcessList(
          0,
          '77 4 100 5000\r\n',
          windows: true,
          now: 0,
          ownPid: 77,
        ).single.start,
        5000,
      );
    });
  });

  group('processTree and treeMemory', () {
    // 10 -> 11 -> 12, 10 -> 13; 20 -> 21 is another tree.
    const rows = [
      ProcessRow(10, 1, 100),
      ProcessRow(11, 10, 200),
      ProcessRow(12, 11, 400),
      ProcessRow(13, 10, 800),
      ProcessRow(20, 1, 1600),
      ProcessRow(21, 20, 3200),
    ];

    test('the root and everything under it, at any depth', () {
      expect(processTree(rows, 10), {10, 11, 12, 13});
      expect(processTree(rows, 11), {11, 12});
      expect(processTree(rows, 21), {21});
    });

    test('a root that is not running is the tree of itself alone', () {
      expect(processTree(rows, 99), {99});
      expect(treeMemory(rows, 99), 0);
    });

    test('memory is the sum over the tree and no other process', () {
      expect(treeMemory(rows, 10), 100 + 200 + 400 + 800);
      expect(treeMemory(rows, 20), 1600 + 3200);
    });

    test('the order of the rows does not matter', () {
      expect(processTree(rows.reversed.toList(), 10), {10, 11, 12, 13});
    });

    test('a process that started before its named parent is not its child: '
        'the ID was given to a new process after the real parent ended', () {
      // 30 is the new process that was given the ID of a parent that
      // ended; 31 and 32 were started by that parent, long before.
      const orphans = [
        ProcessRow(30, 1, 100, 9000),
        ProcessRow(31, 30, 200, 1000),
        ProcessRow(32, 31, 400, 1500),
        ProcessRow(33, 30, 800, 9500),
      ];
      expect(processTree(orphans, 30), {30, 33});
      expect(treeMemory(orphans, 30), 100 + 800);
      // The rule holds at every level: 34 is older than its parent 33.
      expect(processTree([...orphans, const ProcessRow(34, 33, 1, 5000)], 30), {
        30,
        33,
      });
    });

    test('a child that started in the same moment as its parent, or whose '
        'start is not known, counts', () {
      const same = [
        ProcessRow(40, 1, 1, 5000),
        ProcessRow(41, 40, 2, 5000),
        ProcessRow(42, 40, 4),
        ProcessRow(43, 42, 8, 100),
      ];
      expect(processTree(same, 40), {40, 41, 42, 43});
    });
  });

  group('treeStarts', () {
    test('are the tree\'s IDs with the start each had in the listing', () {
      const rows = [
        ProcessRow(10, 1, 1, 1000),
        ProcessRow(11, 10, 1, 1500),
        ProcessRow(12, 11, 1),
        ProcessRow(77, 1, 1, 10),
      ];
      expect(treeStarts(rows, 10), {10: 1000, 11: 1500, 12: null});
    });
  });

  group('survivors', () {
    // The tree as listed: 10 started at 1,000,000, 11 at 1,001,000, and
    // nothing is known of the start of 12.
    const tree = {10: 1000000, 11: 1001000, 12: null};

    test('are the processes of the tree that still run, with their own '
        'start, within the listing\'s two seconds', () {
      expect(
        survivors(tree, const [
          ProcessRow(10, 1, 1, 1000000),
          ProcessRow(11, 10, 1, 1001000 + 1500),
          ProcessRow(77, 1, 1, 900000),
        ]),
        {10, 11},
      );
      expect(survivors(tree, const []), isEmpty);
    });

    test('are not a program that was given the ID of one that ended and '
        'started after the listing', () {
      expect(
        survivors(tree, const [ProcessRow(11, 1, 1, 1001000 + 60000)]),
        isEmpty,
      );
    });

    test('are not a program that was already running when a tree member '
        'ended and was given its ID: it started before', () {
      expect(
        survivors(tree, const [
          ProcessRow(10, 1, 1, 1000000 - 3600000),
          ProcessRow(11, 1, 1, 1001000 - 2500),
        ]),
        isEmpty,
      );
    });

    test('are counted when either start is not known: never missed for want '
        'of a time', () {
      expect(
        survivors(tree, const [ProcessRow(12, 1, 1, 5), ProcessRow(10, 1, 1)]),
        {10, 12},
      );
    });
  });

  group('exitAndPeak', () {
    test(
      'returns the exit code and the peak of a run that went well',
      () async {
        expect(await exitAndPeak(Future.value(0), Future.value(123)), (0, 123));
      },
    );

    test('a sampling that fails while the run goes on is a StateError at '
        'once, and nothing is left unhandled', () async {
      final exit = Completer<int>();
      final peak = Future<int>.error(StateError('the process list failed'));
      await expectLater(
        exitAndPeak(exit.future, peak),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('sampling'), contains('the process list failed')),
          ),
        ),
      );
      // The run ends later; its code has a listener, so no error escapes.
      exit.complete(0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('a run that fails is a StateError too', () async {
      await expectLater(
        exitAndPeak(
          Future.error(const ProcessException('x', [])),
          Future.value(1),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('the real process list', () {
    test(
      'holds this process, whose parent is not itself, with a start',
      () async {
        final rows = await listProcesses();
        final mine = rows.where((row) => row.id == pid);
        expect(mine, hasLength(1));
        expect(mine.single.bytes, greaterThan(1024 * 1024));
        expect(mine.single.parent, isNot(pid));
        final start = mine.single.start;
        expect(start, isNotNull);
        final now = DateTime.now().millisecondsSinceEpoch;
        expect(start, lessThanOrEqualTo(now + 2000));
        expect(
          start,
          greaterThan(now - const Duration(hours: 24).inMilliseconds),
        );
      },
    );

    test(
      "a child started here is in this process's tree, with memory",
      () async {
        final child = await Process.start(Platform.resolvedExecutable, [
          p.join('test', 'support', 'hold_open.dart'),
        ]);
        // Waits for input, so it stays until the test closes it.
        addTearDown(() async {
          await child.stdin.close();
          await child.exitCode;
        });
        // The child needs a moment before it has memory to count.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final rows = await listProcesses();
        expect(processTree(rows, pid), contains(child.pid));
        expect(treeMemory(rows, child.pid), greaterThan(1024 * 1024));
        // It started after this process did.
        final mine = rows.firstWhere((row) => row.id == pid).start!;
        final its = rows.firstWhere((row) => row.id == child.pid).start!;
        expect(its, greaterThanOrEqualTo(mine - 2000));
      },
    );

    test('peakTreeMemory samples until told to stop', () async {
      final stop = Completer<void>();
      final peak = peakTreeMemory(pid, stop.future);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      stop.complete();
      expect(await peak, greaterThan(1024 * 1024));
    });
  });
}
