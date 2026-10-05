import 'dart:async';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';
import 'support/hold_lock.dart';

void main() {
  // Each test starts a separate dart process, which can be slow to start
  // when the whole suite runs at once.
  const slow = Timeout(Duration(minutes: 2));

  test('creates the folder and its .lock file, and can be taken again '
      'after release', () async {
    final folder = p.join(tempDir().path, '.appstein');
    final lock = await KnowledgeLock.acquire(folder);
    expect(File(p.join(folder, '.lock')).existsSync(), isTrue);
    lock.release();
    final again = await KnowledgeLock.acquire(
      folder,
      timeout: const Duration(seconds: 1),
    );
    again.release();
  });

  test('waits for another process, and gets the lock when that process '
      'ends without releasing it', () async {
    final folder = p.join(tempDir().path, '.appstein');
    final holder = await holdLock(folder, 3000);
    final sinceLocked = Stopwatch()..start();
    final lock = await KnowledgeLock.acquire(
      folder,
      timeout: const Duration(seconds: 60),
    );
    // It really waited: the holder keeps the lock for 3000 ms,
    // so a "locked" line that arrives late still leaves 1000 ms of waiting.
    expect(sinceLocked.elapsedMilliseconds, greaterThanOrEqualTo(1000));
    lock.release();
    expect(await holder.exitCode, 0);
  }, timeout: slow);

  test('gives up after the timeout, naming the folder', () async {
    final folder = p.join(tempDir().path, '.appstein');
    await holdLock(folder, 20000);
    await expectLater(
      KnowledgeLock.acquire(folder, timeout: const Duration(milliseconds: 300)),
      throwsA(
        isA<KnowledgeLockTimeout>().having(
          (e) => e.toString(),
          'message',
          allOf(
            contains(folder),
            contains('still writing'),
            contains('0.3 s (last error: '),
          ),
        ),
      ),
    );
  }, timeout: slow);

  test('the timeout message does not double the reason\'s full stop', () {
    String message(String reason) => KnowledgeLockTimeout(
      'f',
      const Duration(seconds: 10),
      lastError: reason,
    ).toString();
    expect(
      message('Access is denied.'),
      contains('(last error: Access is denied). Try again'),
    );
    expect(
      message('Access is denied'),
      contains('(last error: Access is denied). Try again'),
    );
  });

  test('a second acquire in the same process waits for the first to be '
      'released, then gets the lock', () async {
    final folder = p.join(tempDir().path, '.appstein');
    final first = await KnowledgeLock.acquire(folder);
    KnowledgeLock? second;
    final pending = KnowledgeLock.acquire(
      folder,
      timeout: const Duration(seconds: 30),
    ).then((lock) => second = lock);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(second, isNull, reason: 'the first still holds it');
    first.release();
    await pending;
    expect(second, isNotNull);
    second!.release();
  });

  test('a waiter in the same process times out with '
      'KnowledgeLockTimeout, and the lock stays usable', () async {
    final folder = p.join(tempDir().path, '.appstein');
    final first = await KnowledgeLock.acquire(folder);
    await expectLater(
      KnowledgeLock.acquire(folder, timeout: const Duration(milliseconds: 200)),
      throwsA(isA<KnowledgeLockTimeout>()),
    );
    first.release();
    final again = await KnowledgeLock.acquire(
      folder,
      timeout: const Duration(seconds: 1),
    );
    again.release();
  });

  test('releasing twice does nothing', () async {
    final folder = p.join(tempDir().path, '.appstein');
    final first = await KnowledgeLock.acquire(folder);
    first.release();
    final second = await KnowledgeLock.acquire(folder);
    first.release(); // Must not free the second's mutex.
    await expectLater(
      KnowledgeLock.acquire(folder, timeout: const Duration(milliseconds: 200)),
      throwsA(isA<KnowledgeLockTimeout>()),
    );
    second.release();
  });

  test('reports a folder that cannot be created as a '
      'KnowledgeWriteException', () async {
    final blocker = File(p.join(tempDir().path, 'blocker'))..createSync();
    await expectLater(
      KnowledgeLock.acquire(p.join(blocker.path, '.appstein')),
      throwsA(isA<KnowledgeWriteException>()),
    );
  });
}
