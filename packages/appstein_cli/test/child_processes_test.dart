import 'dart:io';

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
