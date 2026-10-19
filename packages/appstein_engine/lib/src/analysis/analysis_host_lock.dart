import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_identity.dart';

/// How old a lock on an address file ([withAnalysisHostLock]) may be before
/// it is taken for one left by a process that died while it held it, or
/// that never finished making it. A lock is held for a few milliseconds, so
/// this is far above any real hold.
const _lockStale = Duration(seconds: 10);

/// How long [withAnalysisHostLock] waits for the lock before it gives up:
/// past [_lockStale], so a lock left behind is cleared first.
const _lockWait = Duration(seconds: 30);

/// The lock file beside the address file [addressFile]
/// ([withAnalysisHostLock]).
String analysisHostLockFile(String addressFile) =>
    '${p.withoutExtension(addressFile)}.lock';

/// Runs [body] while this process alone holds the lock on the address file
/// [addressFile], and returns what it returns. Every change to an address
/// file is made under it: a host writes its address only when no other
/// host's is there, and a client deletes a dead host's address only when it
/// is still that one. So two starters never both take the project, and
/// nobody deletes an address another has just written.
///
/// - **The lock is a file** ([analysisHostLockFile]) that is created only
///   when there is none (an exclusive create, which every system makes in
///   one step), holding the process ID of its holder. It is deleted when
///   [body] ends, normally or with an error.
/// - **A lock left behind is cleared**: one whose holder's process has
///   ended (at once), and any lock older than 10 s, whatever process it
///   names. A lock is held for milliseconds, so an old one was left by a
///   process that died, and the process ID it names may have been given to
///   another program since (Windows reuses IDs within seconds).
/// - **It is looked at again just before it is deleted**, its text and its
///   modified time: a lock a new holder has just made in its place, even an
///   empty one, is left.
/// - The folder must exist.
///
/// [stale] replaces the 10 s, and [beforeClear] is called between the two
/// looks at a lock that is to be cleared; both are for tests only.
///
/// Throws a [FileSystemException] when the lock can't be had within 30 s.
Future<T> withAnalysisHostLock<T>(
  String addressFile,
  Future<T> Function() body, {
  Duration stale = _lockStale,
  Future<void> Function()? beforeClear,
}) async {
  final lock = File(analysisHostLockFile(addressFile));
  final watch = Stopwatch()..start();
  while (true) {
    try {
      await lock.create(exclusive: true);
      break;
    } on FileSystemException catch (error) {
      // Not "there is one already": the folder is missing, or not the
      // user's.
      if (!await lock.exists()) {
        if (watch.elapsed > _lockWait || !await lock.parent.exists()) rethrow;
        // On Windows a lock being deleted can't be made for a moment.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        continue;
      }
      if (watch.elapsed > _lockWait) {
        throw FileSystemException(
          'the lock on the analysis host address file was not freed within '
          '${_lockWait.inSeconds} s (${error.message})',
          lock.path,
        );
      }
      await _clearIfAbandoned(lock, stale, beforeClear);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
  try {
    await lock.writeAsString('$pid', flush: true);
    return await body();
  } finally {
    try {
      await lock.delete();
    } on FileSystemException {
      // Gone already.
    }
  }
}

/// What a look at a lock saw.
typedef _LockSeen = ({String text, DateTime changed});

/// The text and the modified time of [lock].
///
/// Throws a [FileSystemException] when it is gone, or held open by its
/// maker this moment.
Future<_LockSeen> _look(File lock) async => (
  text: (await lock.readAsString()).trim(),
  changed: await lock.lastModified(),
);

/// Deletes [lock] when it was left behind ([withAnalysisHostLock]): its
/// holder has ended, or it is older than [stale].
Future<void> _clearIfAbandoned(
  File lock,
  Duration stale,
  Future<void> Function()? beforeClear,
) async {
  final _LockSeen seen;
  try {
    seen = await _look(lock);
  } on FileSystemException {
    // Freed meanwhile, or held open by its maker this moment.
    return;
  }
  final holder = int.tryParse(seen.text);
  final abandoned =
      (holder != null && lookUpProcess(holder) is ProcessGone) ||
      DateTime.now().difference(seen.changed) > stale;
  if (!abandoned) return;
  await beforeClear?.call();
  try {
    // Still the same lock: a new holder's has another ID or time.
    final now = await _look(lock);
    if (now.text != seen.text || now.changed != seen.changed) return;
    await lock.delete();
  } on FileSystemException {
    // Freed meanwhile.
  }
}
