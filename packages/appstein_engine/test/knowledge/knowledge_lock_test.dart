import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

/// Starts a separate process that holds the lock on [folder] for [ms]
/// milliseconds, and waits until it has it.
Future<Process> holdLock(String folder, int ms) async {
  // Found from the package, not from Directory.current: other test files
  // change the working directory, which is shared by the whole process.
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:appstein_engine/appstein_engine.dart'),
  );
  final holder = p.join(
    p.dirname(p.dirname(library!.toFilePath())),
    'test',
    'knowledge',
    'support',
    'lock_holder.dart',
  );
  final process = await Process.start(Platform.resolvedExecutable, [
    holder,
    folder,
    '$ms',
  ]);
  // Keep what the holder prints on stderr, so a crashed holder is visible.
  final errors = StringBuffer();
  process.stderr.transform(utf8.decoder).listen(errors.write);
  addTearDown(() async {
    process.kill();
    // Wait for it to exit, so the temp folder it locked can be deleted.
    await process.exitCode;
  });
  try {
    await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line == 'locked')
        .timeout(const Duration(seconds: 60));
  } on Object catch (error) {
    throw StateError(
      'The lock holder never reported "locked" ($error). '
      'Its stderr: $errors',
    );
  }
  return process;
}

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
    final holder = await holdLock(folder, 1500);
    final sinceLocked = Stopwatch()..start();
    var holderExited = false;
    unawaited(holder.exitCode.then((_) => holderExited = true));
    final lock = await KnowledgeLock.acquire(
      folder,
      timeout: const Duration(seconds: 60),
    );
    // It really waited: it got the lock only after the holder had ended.
    expect(sinceLocked.elapsedMilliseconds, greaterThanOrEqualTo(1000));
    expect(holderExited, isTrue);
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
