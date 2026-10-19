import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../knowledge/input_hash.dart';
import '../knowledge/knowledge_lock.dart';
import '../knowledge/knowledge_store.dart';
import '../knowledge/knowledge_write_exception.dart';

/// How long a session's record is kept without being written.
const _keepFor = Duration(days: 1);

/// How long a write waits for the records' lock, and for a reader to let go
/// of a record it is replacing. Short on purpose: a hook ends when its reply
/// is written and its record saved, so it never sits behind another session.
/// A record not saved only costs the next run a check.
const _lockWait = Duration(milliseconds: 200);

/// How long the Stop hook's save of its loop guard count waits for the
/// records' lock. Longer than [HookSessions]'s default wait: the after-edit
/// hook has a 5 s budget and keeps 200 ms, but the Stop hook has none, and a
/// count that fails to save is the one thing that can let the agent go before
/// the same errors have blocked it [loopGuardLimit] times (see
/// [HookSessions.saveGuard]).
const stopSaveLockWait = Duration(seconds: 2);

/// How many identical Stop runs in a row block the agent: the run after them
/// lets it go (spec "The loop guard"; the owner, 2026-10-19).
const loopGuardLimit = 3;

/// What the Stop hook's loop guard remembers of a session: which set of errors
/// blocked ([errorsKey], from [errorSetKey]) and how many runs in a row found
/// it ([count], up to [loopGuardLimit] plus one: the run that let the agent go
/// is the last one counted).
final class LoopGuard {
  /// Creates the count.
  const LoopGuard({required this.errorsKey, required this.count});

  /// The key of the set of errors.
  final String errorsKey;

  /// How many runs in a row found this set.
  final int count;
}

/// What the loop guard decides for a Stop run (see [decideLoopGuard]).
final class LoopGuardDecision {
  /// Creates the decision.
  const LoopGuardDecision({required this.letGo, required this.count});

  /// Whether the run lets the agent go instead of blocking it.
  final bool letGo;

  /// The count to save after the run; null removes the saved count.
  final LoopGuard? count;
}

/// The key of a set of errors for the loop guard: the same for the same set
/// of (check ID, file, message), whatever the order and whatever the lines.
/// An edit above an error moves its line without fixing it, so lines are left
/// out; the same finding twice counts once.
String errorSetKey(Iterable<Finding> errors) {
  final lines = {
    for (final error in errors)
      jsonEncode([error.id, error.file, error.message]),
  }.toList()..sort();
  return sha256Hex(utf8.encode(lines.join('\n')));
}

/// The loop guard's count for a Stop run that found the errors [errorsKey]
/// ([errorSetKey]) after [last] was saved: one more than the last count when
/// the agent is [continuing] because of a Stop hook and it is the same set,
/// else 1.
int nextBlockCount(
  LoopGuard? last,
  String errorsKey, {
  required bool continuing,
}) => continuing && last != null && last.errorsKey == errorsKey
    ? last.count + 1
    : 1;

/// What the loop guard decides for a Stop run that found [errors], after
/// [last] was saved, while the agent is or is not [continuing] because of a
/// Stop hook:
/// - no errors: block nothing, and remove the count;
/// - errors: count this run ([nextBlockCount]). The first [loopGuardLimit]
///   runs with the same errors block; the next one lets the agent go. The
///   count is saved up to one past the limit, so a further run with the same
///   errors keeps letting the agent go.
LoopGuardDecision decideLoopGuard(
  LoopGuard? last,
  List<Finding> errors, {
  required bool continuing,
}) {
  if (errors.isEmpty) return const LoopGuardDecision(letGo: false, count: null);
  final key = errorSetKey(errors);
  final count = nextBlockCount(last, key, continuing: continuing);
  return LoopGuardDecision(
    letGo: count > loopGuardLimit,
    count: LoopGuard(
      errorsKey: key,
      count: count > loopGuardLimit ? loopGuardLimit + 1 : count,
    ),
  );
}

/// The per-session records of a project's hook runs (slice 1d.7): for each
/// agent session, two things that two kinds of run keep apart.
///
/// - **The fingerprint** (spec "Nothing changed means no output"): the
///   fingerprint of the knowledge's inputs at the session's last completed
///   fast hook run. A fast hook run whose fingerprint equals its own session's
///   last one has nothing to check. The Stop hook neither reads nor writes it.
/// - **The loop guard** (spec "The loop guard"): which set of errors the Stop
///   hook blocked and how many times in a row ([LoopGuard]). Only the Stop
///   hook writes it, and an after-edit run keeps it: the agent edits between
///   two Stop runs.
///
/// A save of one part keeps the other, so each save reads the record under
/// the lock.
///
/// The records are per session, not part of `state.json`, because the shared
/// state is used up by whoever refreshes the knowledge first: another
/// session's `appstein mcp` can refresh it between this session's edit and
/// this session's hook, and a comparison against the shared state would then
/// find nothing changed.
///
/// They are one file per session under `.appstein/hook-sessions/records/`, so
/// the project's ignore of `.appstein/` covers them. A file is named by a
/// hash of the session ID, whatever characters the ID has. Each is replaced
/// whole ([replaceFile]: a temporary file renamed into place) under a lock of
/// its own, in `.appstein/hook-sessions/` beside the records, not the
/// knowledge lock, which a rebuild of the knowledge can hold for seconds; so
/// two hooks of one session writing at once leave it whole. **Readers take no
/// lock**: a record is replaced in one step, so a read sees the old record or
/// the new one, never half of one. On Windows a read that meets the moment of
/// the rename fails, and a record that can't be read counts as none, so the
/// run checks. A write also deletes the records not written for a day.
final class HookSessions {
  /// The records of the project at [projectRoot]. A record not written for
  /// [keepFor] is deleted by the next write; [lockTimeout] is how long a
  /// write waits for the records' lock.
  HookSessions(
    String projectRoot, {
    this.keepFor = _keepFor,
    this.lockTimeout = _lockWait,
  }) : _lockFolder = p.join(
         KnowledgeStore(projectRoot).folder,
         'hook-sessions',
       );

  /// The folder of the lock, which holds the folder of the records.
  final String _lockFolder;

  /// How long a record is kept without being written.
  final Duration keepFor;

  /// How long a write waits for the records' lock.
  final Duration lockTimeout;

  /// The folder of the records.
  String get folder => p.join(_lockFolder, 'records');

  /// The path of the record of [sessionId].
  String fileOf(String sessionId) => p.join(
    folder,
    '${sha256Hex(utf8.encode(sessionId)).substring(0, 32)}.json',
  );

  /// The record of [sessionId] as it can be read now, or null when there is
  /// none, it can't be read or it is not a JSON object.
  Map<String, Object?>? _readRecord(String sessionId) {
    try {
      final json = jsonDecode(File(fileOf(sessionId)).readAsStringSync());
      return json is Map<String, Object?> ? json : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// The fingerprint [sessionId]'s last completed hook run saw, or null when
  /// there is no record, it can't be read or it has no fingerprint.
  String? read(String sessionId) =>
      switch (_readRecord(sessionId)?['fingerprint']) {
        final String fingerprint => fingerprint,
        _ => null,
      };

  /// The loop guard's count for [sessionId] (what the Stop hook last saved),
  /// or null when there is none, the record can't be read or the count in it
  /// is not whole. A guard that can't be read counts as none, so the count
  /// starts again: the Stop hook then blocks, which is the safe direction.
  LoopGuard? readGuard(String sessionId) {
    final guard = _readRecord(sessionId)?['guard'];
    if (guard is! Map<String, Object?>) return null;
    return switch ((guard['errors'], guard['count'])) {
      (final String errorsKey, final int count) when count >= 1 => LoopGuard(
        errorsKey: errorsKey,
        count: count,
      ),
      _ => null,
    };
  }

  /// Records that [sessionId]'s last completed hook run saw [fingerprint],
  /// replacing the record whole but for the loop guard's count, which stays,
  /// and deletes the records not written for [keepFor]. Returns false when the
  /// record could not be written (the lock stayed busy, or the folder can't
  /// be written): the next run then simply checks, so a hook never fails over
  /// it.
  Future<bool> saveFingerprint(String sessionId, String fingerprint) =>
      _update(sessionId, (record) => {...record, 'fingerprint': fingerprint});

  /// Records [guard] as [sessionId]'s loop guard count, replacing the record
  /// whole but for the fingerprint, which stays; null removes the count (the
  /// errors are gone, or the agent is no longer continuing). Whether there is
  /// a count to remove is judged under the lock, like the rest: a read outside
  /// it can meet the moment of another write's rename, fail, and leave a stale
  /// count behind. Removing a count that is not there writes nothing.
  ///
  /// Returns false when the record could not be written (the lock stayed busy
  /// for [lockTimeout], or the folder can't be written): the count is then the
  /// one the record had before. That is normally a lower count than it should
  /// be (the loop runs longer, up to Claude Code's own limit on
  /// continuations), but a save that fails when the count *changes* (a new set
  /// of errors, or a removal) leaves the old, higher one, and a release can
  /// then come early. The Stop hook saves with [stopSaveLockWait] so that
  /// happens only when the lock stays busy that long.
  Future<bool> saveGuard(String sessionId, LoopGuard? guard) {
    return _update(sessionId, (record) {
      if (guard == null && !record.containsKey('guard')) return null;
      final next = {...record}..remove('guard');
      if (guard != null) {
        next['guard'] = {'errors': guard.errorsKey, 'count': guard.count};
      }
      return next;
    });
  }

  /// Replaces [sessionId]'s record with what [change] makes of the record
  /// read under the lock (an empty one when there is none or it is damaged),
  /// so a save of one part of the record keeps the other whole, and deletes
  /// the records not written for [keepFor]. When [change] gives null nothing
  /// is written. Returns false when the lock stayed busy or the record could
  /// not be written.
  Future<bool> _update(
    String sessionId,
    Map<String, Object?>? Function(Map<String, Object?> record) change,
  ) async {
    final KnowledgeLock lock;
    try {
      lock = await KnowledgeLock.acquire(
        _lockFolder,
        timeout: lockTimeout,
        pollInterval: const Duration(milliseconds: 20),
      );
    } on KnowledgeLockTimeout {
      return false;
    } on KnowledgeWriteException {
      return false;
    }
    try {
      _deleteOld();
      final record = change(_readRecord(sessionId) ?? const {});
      if (record == null) return true;
      await replaceFile(
        fileOf(sessionId),
        '${jsonEncode(record)}\n',
        retryFor: lockTimeout,
      );
      return true;
    } on KnowledgeWriteException {
      return false;
    } finally {
      lock.release();
    }
  }

  /// Deletes what was not written for [keepFor], temporary files of a write
  /// that died included.
  void _deleteOld() {
    final limit = DateTime.now().subtract(keepFor);
    try {
      for (final entry in Directory(folder).listSync(followLinks: false)) {
        if (entry is! File) continue;
        try {
          if (entry.lastModifiedSync().isBefore(limit)) entry.deleteSync();
        } on FileSystemException {
          // Gone or held open: the next write tries again.
        }
      }
    } on FileSystemException {
      // No folder yet.
    }
  }
}
