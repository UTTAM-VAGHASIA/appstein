import 'dart:async';
import 'dart:convert';
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

    test('reads the name after the start, spaces and all', () {
      final rows = parseWindowsProcessList(
        '0 0 8192 - System Idle Process\r\n'
        '4242 4 1048576 1000 dart.exe\r\n'
        '4300 4242 2048 1001 conhost.exe\r\n',
      );
      expect(rows.map((row) => (row.id, row.start, row.name)), [
        (0, null, 'System Idle Process'),
        (4242, 1000, 'dart.exe'),
        (4300, 1001, 'conhost.exe'),
      ]);
    });
  });

  group('programOf', () {
    test('is the program without its folder and .exe, in lower case', () {
      for (final (name, program) in [
        ('dart.exe', 'dart'),
        ('DartVM.EXE', 'dartvm'),
        ('dart', 'dart'),
        ('/Users/runner/flutter/bin/cache/dart-sdk/bin/dartvm', 'dartvm'),
        (r'C:\Program Files\dart sdk\bin\dartaotruntime.exe', 'dartaotruntime'),
        ('conhost.exe', 'conhost'),
        // Linux: the VM renames its process `dart:<script>`, cut to 15.
        ('dart:silent_gua', 'dart'),
        ('dart:analysis_s', 'dart'),
        ('dart:hold_chain', 'dart'),
      ]) {
        expect(
          programOf(ProcessRow(1, 0, 0, null, name)),
          program,
          reason: name,
        );
      }
      expect(programOf(const ProcessRow(1, 0, 0)), isNull);
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

    test('reads comm after the elapsed time: a name on Linux, a path with '
        'spaces on macOS', () {
      final rows = parsePsProcessList(
        '  700     1   2048    00:10 dart\n'
        '  701   700   4096    00:09 /Users/runner/my flutter/bin/cache/'
        'dart-sdk/bin/dartvm\n',
        now: 1000000000,
      );
      expect(rows.map((row) => (row.id, row.name)), [
        (700, 'dart'),
        (701, '/Users/runner/my flutter/bin/cache/dart-sdk/bin/dartvm'),
      ]);
      expect(programOf(rows.last), 'dartvm');
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

    test('passes on a sampling that never saw the run as null', () async {
      expect(await exitAndPeak(Future.value(0), Future.value(null)), (0, null));
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

  group('reachesServer', () {
    const run = 10;
    const guard = 11;
    const server = 12;

    test(
      'is true when a Dart program runs under the guard, on each system',
      () {
        for (final name in [
          'dart.exe', // Windows
          'dartvm.exe',
          'dart', // Linux
          'dart:analysis_s', // Linux: the VM's own name, cut to 15
          'dartaotruntime',
          '/Users/runner/flutter/bin/cache/dart-sdk/bin/dartvm', // macOS
          r'C:\Program Files\flutter sdk\bin\cache\dart-sdk\bin\dart.exe',
        ]) {
          expect(
            reachesServer([
              const ProcessRow(run, 1, 100, null, 'appstein.exe'),
              const ProcessRow(guard, run, 100, null, 'appstein.exe'),
              ProcessRow(server, guard, 100, null, name),
            ], run),
            isTrue,
            reason: name,
          );
        }
      },
    );

    test('is true for the server deeper under the guard: dart.exe hands it '
        'to a dartvm.exe', () {
      expect(
        reachesServer(const [
          ProcessRow(run, 1, 100, null, 'appstein.exe'),
          ProcessRow(guard, run, 100, null, 'appstein.exe'),
          ProcessRow(13, guard, 100, null, 'conhost.exe'),
          ProcessRow(server, guard, 100, null, 'cmd.exe'),
          ProcessRow(14, server, 100, null, 'dartvm.exe'),
        ], run),
        isTrue,
      );
    });

    test('is false when only a conhost.exe is under the guard: a console '
        "program's own child, not the server", () {
      expect(
        reachesServer(const [
          ProcessRow(run, 1, 100, null, 'appstein.exe'),
          ProcessRow(guard, run, 100, null, 'appstein.exe'),
          ProcessRow(server, guard, 100, null, 'conhost.exe'),
        ], run),
        isFalse,
      );
    });

    test('is false for a Dart program that is a child of the run, not of '
        'the guard', () {
      expect(
        reachesServer(const [
          ProcessRow(run, 1, 100, null, 'appstein'),
          ProcessRow(guard, run, 100, null, 'dart'),
        ], run),
        isFalse,
      );
    });

    test('is false when the program under the guard has no name', () {
      expect(
        reachesServer(const [
          ProcessRow(run, 1, 100),
          ProcessRow(guard, run, 100),
          ProcessRow(server, guard, 100),
        ], run),
        isFalse,
      );
    });

    test('is false for the run alone, or a server of another tree', () {
      expect(
        reachesServer(const [ProcessRow(run, 1, 100, null, 'appstein')], run),
        isFalse,
      );
      expect(
        reachesServer(const [
          ProcessRow(run, 1, 100, null, 'appstein'),
          ProcessRow(guard, run, 100, null, 'appstein'),
          ProcessRow(server, 99, 100, null, 'dart'),
        ], run),
        isFalse,
      );
    });

    test('is false when the run itself is not in the list', () {
      expect(
        reachesServer(const [
          ProcessRow(guard, run, 100, null, 'appstein'),
          ProcessRow(server, guard, 100, null, 'dart'),
        ], run),
        isFalse,
      );
    });

    test('is false when the "server" started before the "guard": another '
        'program given an old ID', () {
      expect(
        reachesServer(const [
          ProcessRow(run, 1, 100, 1000, 'appstein'),
          ProcessRow(guard, run, 100, 2000, 'appstein'),
          ProcessRow(server, guard, 100, 500, 'dart'),
        ], run),
        isFalse,
      );
    });
  });

  group('peakTreeMemory', () {
    const run = 10;
    const tool = 1;
    const guard = 11;
    const server = 12;

    test('is null, never 0, when no look found the run: it had ended before '
        'the first look', () async {
      var looks = 0;
      final peak = await peakTreeMemory(
        run,
        Future.value(),
        lister: () async {
          looks++;
          // Only the tool, and a child of the run that outlived it.
          return const [ProcessRow(tool, 0, 500), ProcessRow(11, run, 700)];
        },
      );
      expect(peak, isNull);
      expect(looks, 1);
    });

    test('is null when the looks found the run but never its guard and '
        'server: bare appstein is not its peak', () async {
      final ended = Completer<void>();
      final looks = [
        const [ProcessRow(tool, 0, 500), ProcessRow(run, tool, 20)],
        const [
          ProcessRow(tool, 0, 500),
          ProcessRow(run, tool, 20, null, 'appstein.exe'),
          ProcessRow(guard, run, 30, null, 'appstein.exe'),
          // A console program's own child, not a server.
          ProcessRow(13, guard, 8, null, 'conhost.exe'),
        ],
      ];
      var look = 0;
      final peak = await peakTreeMemory(
        run,
        ended.future,
        lister: () async {
          final rows = looks[look++];
          if (look == looks.length) ended.complete();
          return rows;
        },
      );
      expect(peak, isNull);
    });

    test('is the most the tree held in the looks that found the run, once '
        'one found its guard and server, and ignores the looks after it '
        'ended', () async {
      final ended = Completer<void>();
      final looks = [
        // Before the server started: only the console host is under the
        // guard.
        const [
          ProcessRow(run, tool, 100, null, 'appstein.exe'),
          ProcessRow(guard, run, 200, null, 'appstein.exe'),
          ProcessRow(13, guard, 10, null, 'conhost.exe'),
        ],
        const [
          ProcessRow(run, tool, 100, null, 'appstein.exe'),
          ProcessRow(guard, run, 200, null, 'appstein.exe'),
          ProcessRow(13, guard, 10, null, 'conhost.exe'),
          ProcessRow(server, guard, 900, null, 'dart.exe'),
        ],
        // The run has ended; a child it left is not its memory any more.
        const [ProcessRow(guard, run, 5000)],
      ];
      var look = 0;
      final peak = await peakTreeMemory(
        run,
        ended.future,
        lister: () async {
          final rows = looks[look++];
          if (look == looks.length) ended.complete();
          return rows;
        },
      );
      expect(peak, 100 + 200 + 10 + 900);
    });

    test('passes on a failed look as an error', () async {
      await expectLater(
        peakTreeMemory(
          run,
          Future.value(),
          lister: () async => throw StateError('the process list failed'),
        ),
        throwsStateError,
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

    test('names this process with a Dart program', () async {
      final rows = await listProcesses();
      expect(
        dartPrograms,
        contains(programOf(rows.firstWhere((row) => row.id == pid))),
      );
    });

    test('peakTreeMemory samples a chain of three processes (a run, its '
        '"guard" and a Dart "server" under it) until told to stop', () async {
      final run = await Process.start(Platform.resolvedExecutable, [
        p.join('test', 'support', 'hold_chain.dart'),
        '3',
      ]);
      addTearDown(() async {
        await run.stdin.close();
        await run.exitCode;
      });
      // It says so once the whole chain has started.
      await run.stdout
          .transform(utf8.decoder)
          .firstWhere((text) => text.contains('started'));
      final stop = Completer<void>();
      final peak = peakTreeMemory(run.pid, stop.future);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      stop.complete();
      expect(await peak, greaterThan(3 * 1024 * 1024));
    });
  });
}
