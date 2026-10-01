import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import 'canonical_json.dart';
import 'knowledge_lock.dart';

/// Thrown when a `.appstein/` file can't be written.
final class KnowledgeWriteException implements Exception {
  /// Creates the exception for [path].
  const KnowledgeWriteException(this.path, this.reason);

  /// The file Appstein tried to write.
  final String path;

  /// Why it failed.
  final String reason;

  @override
  String toString() => 'Could not write $path: $reason';
}

/// A project's `.appstein/` folder (spec §6.2).
///
/// It writes generated files as canonical JSON with their metadata, skips a
/// file whose inputs haven't changed (so its bytes, `generatedAt`
/// included, stay the same), and replaces files in one step.
final class KnowledgeStore {
  /// The store of the project at [projectRoot]. [clock] gives the time to
  /// record (the real time by default).
  KnowledgeStore(String projectRoot, {DateTime Function()? clock})
    : folder = p.join(projectRoot, '.appstein'),
      _clock = clock ?? DateTime.now;

  /// The `.appstein/` folder.
  final String folder;

  final DateTime Function() _clock;

  /// The current time, in the `.appstein/` time format.
  String now() => formatKnowledgeTime(_clock());

  /// Runs [action] while holding the write lock, waiting up to [timeout]
  /// for it.
  Future<T> locked<T>(
    Future<T> Function() action, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final lock = await KnowledgeLock.acquire(folder, timeout: timeout);
    try {
      return await action();
    } finally {
      lock.release();
    }
  }

  /// Writes [body] to [path] (inside `.appstein/`, with `/` separators),
  /// adding a `meta` key with [inputHash], unless the file already carries
  /// that input hash. Returns whether it wrote.
  ///
  /// Throws an [ArgumentError] when [body] has its own `meta` key, and a
  /// [KnowledgeWriteException] when the file can't be written.
  Future<bool> writeGenerated(
    String path,
    Map<String, Object?> body, {
    required String inputHash,
    required String appsteinVersion,
    required String sdkVersion,
  }) async {
    if (body.containsKey('meta')) {
      throw ArgumentError.value(body, 'body', 'must not have a "meta" key');
    }
    final target = _pathOf(path);
    if (_storedHash(target) == inputHash) return false;
    final meta = KnowledgeMeta(
      generatedAt: now(),
      appsteinVersion: appsteinVersion,
      formatVersion: knowledgeFormatVersion,
      sdkVersion: sdkVersion,
      inputHash: inputHash,
    );
    await replaceFile(target, canonicalJson({...body, 'meta': meta.toJson()}));
    return true;
  }

  /// Writes `state.json`.
  Future<void> writeState(KnowledgeState state) =>
      replaceFile(_pathOf('state.json'), canonicalJson(state.toJson()));

  String _pathOf(String path) => p.joinAll([folder, ...path.split('/')]);

  /// The input hash in the `meta` of the file at [path], or null when the
  /// file is missing, unreadable or damaged.
  static String? _storedHash(String path) {
    try {
      final json = jsonDecode(File(path).readAsStringSync());
      if (json is! Map<String, Object?>) return null;
      final meta = json['meta'];
      if (meta is! Map<String, Object?>) return null;
      final hash = meta['inputHash'];
      return hash is String ? hash : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }
}

/// Replaces the file at [path] with [contents] in one step: it writes
/// `<path>.tmp` and renames it over [path], creating folders as needed, so
/// a reader sees either the old file or the new one, never half of one.
///
/// Windows refuses to rename over a file another program has open, so the
/// rename is retried every [retryEvery] for up to [retryFor]. Throws a
/// [KnowledgeWriteException] when it still fails.
Future<void> replaceFile(
  String path,
  String contents, {
  Duration retryFor = const Duration(seconds: 2),
  Duration retryEvery = const Duration(milliseconds: 20),
}) async {
  final temp = File('$path.tmp');
  try {
    File(path).parent.createSync(recursive: true);
    temp.writeAsStringSync(contents, flush: true);
  } on FileSystemException catch (error) {
    throw KnowledgeWriteException(path, fileErrorReason(error));
  }
  final waited = Stopwatch()..start();
  while (true) {
    try {
      temp.renameSync(path);
      return;
    } on FileSystemException catch (error) {
      if (waited.elapsed >= retryFor) {
        try {
          temp.deleteSync();
        } on FileSystemException {
          // Leave the temporary file; the next sync overwrites it.
        }
        throw KnowledgeWriteException(
          path,
          '${fileErrorReason(error)} Another program may have it open; '
          'close it and run `appstein sync` again.',
        );
      }
      await Future<void>.delayed(retryEvery);
    }
  }
}
