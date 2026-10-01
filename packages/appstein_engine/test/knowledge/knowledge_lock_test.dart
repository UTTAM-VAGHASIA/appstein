import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

/// Starts a separate process that holds the lock on [folder] for [ms]
/// milliseconds, and waits until it has it.
Future<Process> holdLock(String folder, int ms) async {
  final holder = p.join(
    Directory.current.path,
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
  addTearDown(() async {
    process.kill();
    // Wait for it to exit, so the temp folder it locked can be deleted.
    await process.exitCode;
  });
  await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstWhere((line) => line == 'locked');
  return process;
}

void main() {
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
    final lock = await KnowledgeLock.acquire(
      folder,
      timeout: const Duration(seconds: 30),
    );
    lock.release();
    expect(await holder.exitCode, 0);
  });

  test('gives up after the timeout, naming the folder', () async {
    final folder = p.join(tempDir().path, '.appstein');
    await holdLock(folder, 20000);
    await expectLater(
      KnowledgeLock.acquire(folder, timeout: const Duration(milliseconds: 300)),
      throwsA(
        isA<KnowledgeLockTimeout>().having(
          (e) => e.toString(),
          'message',
          allOf(contains(folder), contains('still writing')),
        ),
      ),
    );
  });
}
