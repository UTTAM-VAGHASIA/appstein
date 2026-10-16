import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart'
    show
        ProcessGone,
        ProcessIdentity,
        ProcessRunning,
        ProcessSeen,
        ProcessUnknown;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/child_processes.dart';

// The turn the tests that start processes take (`withChildProcessesToItself`
// in `support/child_processes.dart`), tried on a turn file of its own, so
// these tests never touch the turn the other files' tests hold.
void main() {
  late File turn;

  setUp(() {
    final folder = Directory.systemTemp.createTempSync('appstein turn tëst ');
    addTearDown(() => folder.deleteSync(recursive: true));
    turn = File(p.join(folder.path, 'the turn'));
  });

  test('the real turn is a file in the temporary folder, named after this '
      'process', () {
    expect(p.dirname(turnFile().path), Directory.systemTemp.path);
    expect(p.basename(turnFile().path), contains('$pid'));
  });

  test('a second caller does not run while the first holds the turn, and a '
      'wait that reaches its limit fails with a message that names the '
      'turn', () async {
    final order = <String>[];
    await withChildProcessesToItself(() async {
      order.add('first begins');
      await expectLater(
        withChildProcessesToItself(
          () async => order.add('second ran'),
          wait: const Duration(milliseconds: 300),
          file: turn,
        ),
        throwsA(
          isA<TestFailure>().having(
            (failure) => failure.message,
            'message',
            allOf(
              contains('No turn among the tests that start processes'),
              contains(turn.path),
            ),
          ),
        ),
      );
      expect(turn.existsSync(), isTrue, reason: 'still held by the first');
      order.add('first ends');
    }, file: turn);
    expect(order, ['first begins', 'first ends']);
    expect(turn.existsSync(), isFalse);
    // Given back: the next caller runs.
    await withChildProcessesToItself(
      () async => order.add('third ran'),
      file: turn,
    );
    expect(order.last, 'third ran');
  });

  test('a turn left behind is taken away: by a process that has ended, by '
      'a process that had this one\'s ID, and one that names nobody and is '
      'old', () async {
    // A process this test started, which has ended. It is started in the
    // real turn, as every test that starts a process does.
    final ended = await withChildProcessesToItself(() async {
      final process = await Process.start(Platform.resolvedExecutable, [
        '--version',
      ]);
      await process.stdout.drain<void>();
      await process.exitCode;
      return process;
    });
    for (final (left, age) in [
      ('${ended.pid} 638000000000000000', Duration.zero),
      // This process's ID, with another start than its own.
      ('$pid 1', Duration.zero),
      ('', const Duration(minutes: 2)),
    ]) {
      turn
        ..writeAsStringSync(left)
        ..setLastModifiedSync(DateTime.now().subtract(age));
      var ran = false;
      await withChildProcessesToItself(
        () async => ran = true,
        wait: const Duration(seconds: 20),
        file: turn,
      );
      expect(ran, isTrue, reason: 'left behind as "$left"');
      expect(turn.existsSync(), isFalse);
    }
  });

  group('which processes are under a root (descendantsOf)', () {
    ListedProcess listed(int id, int parent, int? start) =>
        (id: id, parent: parent, start: start);

    test('children and their children count, by their parents', () {
      expect(
        descendantsOf(1, [
          listed(1, 0, 10),
          listed(2, 1, 20),
          listed(3, 2, 30),
          listed(4, 3, 30),
          listed(5, 99, 40),
        ]),
        {2, 3, 4},
      );
    });

    test('a process that started before its parent is not its child: it '
        'kept the ID of a parent that ended', () {
      expect(
        descendantsOf(1, [
          listed(1, 0, 100),
          // Its parent ended, and process 1 was given the ID later.
          listed(2, 1, 50),
          listed(3, 1, 150),
        ]),
        {3},
      );
    });

    test('the rule applies at every level, and the processes under a '
        'rejected one are not reached', () {
      expect(
        descendantsOf(1, [
          listed(1, 0, 100),
          listed(2, 1, 150),
          // Older than its parent 2, which is a real child of 1.
          listed(3, 2, 120),
          // Under the rejected 3: its own parent line is intact.
          listed(4, 3, 200),
        ]),
        {2},
      );
    });

    test('a process that started at the same time as its parent counts', () {
      expect(descendantsOf(1, [listed(1, 0, 7), listed(2, 1, 7)]), {2});
    });

    test('a start that is not known is no reason to leave a process out', () {
      expect(
        descendantsOf(1, [
          listed(1, 0, null),
          listed(2, 1, 5),
          listed(3, 2, null),
        ]),
        {2, 3},
      );
    });

    test('the root is never its own descendant, even in a loop', () {
      expect(descendantsOf(1, [listed(1, 2, 5), listed(2, 1, 6)]), {2});
    });

    test('ps lines become starts that order the processes the right way: a '
        'process that has run longer started earlier', () {
      final listing = [
        ' 10     1   01:00:00',
        ' 11    10      05:00', // run 5 minutes: a child of 10, started later
        ' 12    10   2-00:00:00', // run 2 days: older than 10, a stale child
        ' 13    11         ??', // an etime that cannot be read: no start
        ' 99     1       00:01', // the lister
        'junk',
      ].join('\n');
      final listed = listedProcesses(
        listing,
        windows: false,
        lookUp: (_) => throw StateError('only Windows asks'),
        lister: 99,
      );
      expect(listed, [
        (id: 10, parent: 1, start: -3600),
        (id: 11, parent: 10, start: -300),
        (id: 12, parent: 10, start: -2 * 86400),
        (id: 13, parent: 11, start: null),
      ]);
      // Were the sign wrong, every child would be dropped, or the stale one
      // kept.
      expect(descendantsOf(10, listed), {11, 13});
    });

    test('Windows lines take their starts from the lookup: one that is gone '
        'is left out, one it cannot tell about has no start', () {
      ProcessSeen seen(int id) => switch (id) {
        20 => const ProcessRunning(
          ProcessIdentity(id: 20, start: '1000', image: 'a.exe'),
        ),
        21 => const ProcessRunning(
          ProcessIdentity(id: 21, start: '2000', image: 'b.exe'),
        ),
        22 => const ProcessUnknown(),
        _ => const ProcessGone(),
      };
      final listed = listedProcesses(
        '20 1\r\n21 20\r\n22 21\r\n23 20\r\n',
        windows: true,
        lookUp: seen,
      );
      expect(listed, [
        (id: 20, parent: 1, start: 1000),
        (id: 21, parent: 20, start: 2000),
        (id: 22, parent: 21, start: null),
      ]);
    });

    test('the elapsed time of ps is read in its three forms', () {
      expect(elapsedSeconds('01:05'), 65);
      expect(elapsedSeconds('02:01:05'), 7265);
      expect(elapsedSeconds('3-02:01:05'), 3 * 86400 + 7265);
      expect(elapsedSeconds('soon'), isNull);
      expect(elapsedSeconds('1-2-03:04'), isNull);
    });
  });

  test('processesUnder finds a real child while it runs, and not after it '
      'ended', () async {
    final child = await Process.start(
      Platform.isWindows ? 'powershell' : 'sleep',
      Platform.isWindows
          ? ['-NoProfile', '-Command', 'Start-Sleep -Seconds 60']
          : ['60'],
    );
    addTearDown(child.kill);
    // The child is seen as soon as the system lists it.
    await expectLater(
      Future(() async {
        while (!(await processesUnder(pid)).contains(child.pid)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }),
      completes,
    );
    child.kill();
    await child.exitCode;
    expect(await processesUnder(pid), isNot(contains(child.pid)));
  });

  test('a turn file that names nobody and is new is waited for: its holder '
      'is about to write its name', () async {
    turn.writeAsStringSync('');
    await expectLater(
      withChildProcessesToItself(
        () async {},
        wait: const Duration(milliseconds: 300),
        file: turn,
      ),
      throwsA(isA<TestFailure>()),
    );
  });
}
