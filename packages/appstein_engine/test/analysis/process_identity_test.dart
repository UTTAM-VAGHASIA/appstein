import 'dart:io';

import 'package:appstein_engine/src/analysis/process_identity.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/analysis_support.dart';

// `lookUpProcess` on real processes this test starts: the one way Appstein
// tells a process it started from a later one with the same ID.
void main() {
  /// A process of this test's own that waits until its input closes. It is
  /// returned once its Dart code runs: on Linux and macOS a `dart <script>`
  /// process execs `dartvm` in the same process ID, so an identity taken
  /// before that differs from one taken after it (the macOS failure of CI
  /// run 38721583522; see [untilItsDartRuns]).
  Future<Process> waiter() async {
    final process = await Process.start(Platform.resolvedExecutable, [
      analysisSupportFile('silent_guard.dart'),
    ]);
    process.stdout.drain<void>().ignore();
    final running = untilItsDartRuns(process);
    addTearDown(() async {
      await process.stdin.close();
      await process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    });
    await running;
    return process;
  }

  test('a running process has an identity that is the same each time it is '
      'asked, with its ID, a start and the program it runs', () async {
    final process = await waiter();
    final first = identityOf(process.pid);
    expect(first, isNotNull);
    expect(first!.id, process.pid);
    expect(first.start, isNotEmpty);
    expect(
      p.basenameWithoutExtension(first.image).toLowerCase(),
      startsWith('dart'),
    );
    for (var i = 0; i < 50; i++) {
      expect(identityOf(process.pid), first);
    }
    expect('$first', contains('${process.pid}'));
  });

  test('this process has one too, and two processes that run the same '
      'program differ', () async {
    expect(identityOf(pid), isNotNull);
    final one = await waiter();
    final other = await waiter();
    final a = identityOf(one.pid)!;
    final b = identityOf(other.pid)!;
    expect(a, isNot(b));
    expect(a.image, b.image);
    // The same ID with another start is another process. Not `b.start`: on
    // Linux and macOS `ps` gives a start to the second, so two processes
    // started in the same second have the same one.
    expect(
      ProcessIdentity(id: a.id, start: '${a.start} later', image: a.image),
      isNot(a),
    );
  });

  test('a process that has ended is gone, also while this process still '
      'holds its handle, and so is an ID nothing runs under', () async {
    final process = await Process.start(Platform.resolvedExecutable, [
      '--version',
    ]);
    await process.stdout.drain<void>();
    await process.exitCode;
    // The `Process` object is still held here.
    expect(lookUpProcess(process.pid), isA<ProcessGone>());
    // No process has an ID this large.
    expect(lookUpProcess(0x7ffffff0), isA<ProcessGone>());
    expect(lookUpProcess(-1), isNot(isA<ProcessRunning>()));
  });

  test('processHasEnded: not while a process runs, and once it has ended, '
      'also while its handle is held; an ID nothing runs under has '
      'ended', () async {
    final running = await waiter();
    expect(processHasEnded(running.pid), isFalse);
    await running.stdin.close();
    await running.exitCode;
    // The `Process` object is still held here.
    expect(processHasEnded(running.pid), isTrue);
    expect(processHasEnded(0x7ffffff0), isTrue);
    expect(processHasEnded(pid), isFalse);
  });

  test('asked many times, it leaves nothing open', () async {
    final process = await waiter();
    for (var i = 0; i < 20000; i++) {
      if (identityOf(process.pid) == null) fail('lost it at ask $i');
    }
  }, skip: Platform.isWindows ? null : 'each ask starts `ps` there');

  test('the command to end one by hand names its ID, and on Windows the '
      'program it must still be running when that is known; its switches '
      'start with `-`, so it works in cmd, PowerShell and Git Bash', () {
    expect(
      endByHandCommand(4711, image: r'C:\sdk\bin\dart.exe'),
      Platform.isWindows
          ? 'taskkill -PID 4711 -FI "IMAGENAME eq dart.exe" -F'
          : 'kill 4711',
    );
    expect(
      endByHandCommand(4711),
      Platform.isWindows ? 'taskkill -PID 4711 -F' : 'kill 4711',
    );
  });
}
