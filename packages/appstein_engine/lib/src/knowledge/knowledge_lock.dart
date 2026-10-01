import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import 'knowledge_write_exception.dart';

/// Thrown when another writer holds the `.appstein/` write lock for longer
/// than the timeout.
final class KnowledgeLockTimeout implements Exception {
  /// Creates the exception for [folder]. [lastError] is the operating
  /// system's last reason for refusing the lock, when there was one.
  const KnowledgeLockTimeout(this.folder, this.timeout, {this.lastError});

  /// The `.appstein/` folder.
  final String folder;

  /// How long Appstein waited.
  final Duration timeout;

  /// The operating system's last reason for refusing the lock, if any.
  final String? lastError;

  @override
  String toString() {
    final ms = timeout.inMilliseconds;
    final seconds = ms % 1000 == 0 ? '${ms ~/ 1000}' : '${ms / 1000}';
    final reason = lastError == null ? '' : ' (last error: $lastError)';
    return 'Another Appstein process is still writing $folder after waiting '
        '$seconds s$reason. Try again when it has finished.';
  }
}

/// The write lock on a `.appstein/` folder (spec §15): an operating-system
/// lock on its `.lock` file, plus an in-process mutex so that one isolate
/// holds a folder's lock at most once at a time.
///
/// The mutex is a static, so it is per isolate. Two isolates of one process
/// must not both write the same folder: POSIX locks belong to the process, so
/// the second isolate would get the lock at once.
///
/// The mutex is needed because the operating systems disagree about two
/// handles in one process: POSIX locks belong to the process (a second
/// acquire would succeed at once, and either release would drop the lock
/// for both), while Windows locks belong to the handle (a second acquire
/// would wait for the first until it timed out).
///
/// The operating system releases the lock when the process ends, even after
/// a crash, so a stale lock can never block later writers. Readers don't
/// take it: files are replaced in one step, so they never see a half-written
/// file (see `replaceFile`).
final class KnowledgeLock {
  KnowledgeLock._(this._key, this._file);

  final String _key;
  final RandomAccessFile _file;
  bool _released = false;

  /// Folders this process holds the lock on (a key is present while held);
  /// each value queues the acquires waiting for it.
  static final Map<String, Queue<Completer<void>>> _held = {};

  /// Takes the lock on [folder], creating the folder and its `.lock` file
  /// when needed. Waits up to [timeout] in total (for other holders in this
  /// process, then for other processes, trying every [pollInterval]), then
  /// throws [KnowledgeLockTimeout]. Throws a [KnowledgeWriteException] when
  /// the folder or file can't be created.
  static Future<KnowledgeLock> acquire(
    String folder, {
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 50),
  }) async {
    final waited = Stopwatch()..start();
    var key = p.normalize(p.absolute(folder));
    if (Platform.isWindows) key = key.toLowerCase();

    await _enter(key, folder, timeout, waited);
    try {
      return await _lockFile(key, folder, timeout, pollInterval, waited);
    } catch (_) {
      _leave(key);
      rethrow;
    }
  }

  static Future<void> _enter(
    String key,
    String folder,
    Duration timeout,
    Stopwatch waited,
  ) async {
    final queue = _held[key];
    if (queue == null) {
      _held[key] = Queue();
      return;
    }
    final turn = Completer<void>();
    queue.add(turn);
    try {
      var remaining = timeout - waited.elapsed;
      if (remaining.isNegative) remaining = Duration.zero;
      await turn.future.timeout(remaining);
    } on TimeoutException {
      // If our turn was already handed over, we own the mutex: give it on.
      if (!queue.remove(turn)) _leave(key);
      throw KnowledgeLockTimeout(folder, timeout);
    }
  }

  static void _leave(String key) {
    final queue = _held[key];
    if (queue == null) return;
    if (queue.isEmpty) {
      _held.remove(key);
    } else {
      queue.removeFirst().complete();
    }
  }

  static Future<KnowledgeLock> _lockFile(
    String key,
    String folder,
    Duration timeout,
    Duration pollInterval,
    Stopwatch waited,
  ) async {
    final RandomAccessFile file;
    try {
      Directory(folder).createSync(recursive: true);
      file = File(p.join(folder, '.lock')).openSync(mode: FileMode.append);
    } on FileSystemException catch (error) {
      throw KnowledgeWriteException(folder, fileErrorReason(error));
    }
    String? lastError;
    while (true) {
      try {
        file.lockSync(FileLock.exclusive);
        return KnowledgeLock._(key, file);
      } on FileSystemException catch (error) {
        // Every refusal is retried: the codes for "someone else has it"
        // differ between Windows, Linux and macOS.
        lastError = fileErrorReason(error);
        if (waited.elapsed >= timeout) {
          file.closeSync();
          throw KnowledgeLockTimeout(folder, timeout, lastError: lastError);
        }
        await Future<void>.delayed(pollInterval);
      }
    }
  }

  /// Releases the lock. Calling it again does nothing.
  void release() {
    if (_released) return;
    _released = true;
    try {
      try {
        _file.unlockSync();
      } finally {
        _file.closeSync();
      }
    } finally {
      _leave(_key);
    }
  }
}
