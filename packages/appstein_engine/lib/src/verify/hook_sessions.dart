import 'dart:convert';
import 'dart:io';

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

/// The per-session records of a project's hook runs (slice 1d.7, spec
/// "Nothing changed means no output"): for each agent session, the
/// fingerprint of the knowledge's inputs at its last completed hook run. A
/// fast hook run whose fingerprint equals its own session's last one has
/// nothing to check.
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

  /// The fingerprint [sessionId]'s last completed hook run saw, or null when
  /// there is no record, it can't be read or it has no fingerprint.
  String? read(String sessionId) {
    try {
      final json = jsonDecode(File(fileOf(sessionId)).readAsStringSync());
      if (json is! Map<String, Object?>) return null;
      return switch (json['fingerprint']) {
        final String fingerprint => fingerprint,
        _ => null,
      };
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Records that [sessionId]'s last completed hook run saw [fingerprint],
  /// replacing the record whole, and deletes the records not written for
  /// [keepFor]. Returns false when the record could not be written (the lock
  /// stayed busy, or the folder can't be written): the next run then simply
  /// checks, so a hook never fails over it.
  Future<bool> saveFingerprint(String sessionId, String fingerprint) async {
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
      await replaceFile(
        fileOf(sessionId),
        '${jsonEncode({'fingerprint': fingerprint})}\n',
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
