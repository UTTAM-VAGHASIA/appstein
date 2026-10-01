import 'dart:io';

import 'package:path/path.dart' as p;

/// Thrown when another process holds the `.appstein/` write lock for longer
/// than the timeout.
final class KnowledgeLockTimeout implements Exception {
  /// Creates the exception for [folder].
  const KnowledgeLockTimeout(this.folder, this.timeout);

  /// The `.appstein/` folder.
  final String folder;

  /// How long Appstein waited.
  final Duration timeout;

  @override
  String toString() =>
      'Another Appstein process is still writing $folder after waiting '
      '${timeout.inMilliseconds / 1000} s. Try again when it has finished.';
}

/// The write lock on a `.appstein/` folder (spec §15): an operating-system
/// lock on its `.lock` file.
///
/// The operating system releases the lock when the process ends, even after
/// a crash, so a stale lock can never block later writers. Readers don't
/// take it: files are replaced in one step, so they never see a half-written
/// file (see `replaceFile`).
final class KnowledgeLock {
  KnowledgeLock._(this._file);

  final RandomAccessFile _file;

  /// Takes the lock on [folder], creating the folder and its `.lock` file
  /// when needed. Tries every [pollInterval] for up to [timeout], then
  /// throws [KnowledgeLockTimeout].
  static Future<KnowledgeLock> acquire(
    String folder, {
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 50),
  }) async {
    Directory(folder).createSync(recursive: true);
    final file = File(p.join(folder, '.lock')).openSync(mode: FileMode.append);
    final waited = Stopwatch()..start();
    while (true) {
      try {
        file.lockSync(FileLock.exclusive);
        return KnowledgeLock._(file);
      } on FileSystemException {
        if (waited.elapsed >= timeout) {
          file.closeSync();
          throw KnowledgeLockTimeout(folder, timeout);
        }
        await Future<void>.delayed(pollInterval);
      }
    }
  }

  /// Releases the lock.
  void release() {
    _file
      ..unlockSync()
      ..closeSync();
  }
}
