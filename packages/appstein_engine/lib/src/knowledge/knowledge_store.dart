import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import 'canonical_json.dart';
import 'generated_file.dart';
import 'knowledge_lock.dart';
import 'knowledge_write_exception.dart';
import 'markdown_front_matter.dart';

/// A project's `.appstein/` folder (spec §6.2).
///
/// It writes generated files, JSON with a `meta` key or Markdown with
/// front matter, skips a file whose content wouldn't change (so its bytes,
/// `generatedAt` included, stay the same; a hand-edited file is put back),
/// and replaces files in one step.
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
  /// adding a `meta` key with [inputHash], unless the file is already exactly
  /// what this would write. It rebuilds the text with the `generatedAt`
  /// already in the file and compares the bytes: unchanged inputs change no
  /// byte, and a hand-edited, reformatted or damaged file is rewritten (with
  /// the current time). Returns whether it wrote.
  ///
  /// Throws an [ArgumentError] when [body] has its own `meta` key, and a
  /// [KnowledgeWriteException] when the file can't be written.
  ///
  /// Call it inside [locked]: two unlocked writers would collide on the
  /// same temporary file.
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
    String textWith(String generatedAt) => canonicalJson({
      ...body,
      'meta': KnowledgeMeta(
        generatedAt: generatedAt,
        appsteinVersion: appsteinVersion,
        formatVersion: knowledgeFormatVersion,
        sdkVersion: sdkVersion,
        inputHash: inputHash,
      ).toJson(),
    });
    final stored = _storedGeneratedAt(target);
    if (stored != null && stored.text == textWith(stored.generatedAt)) {
      return false;
    }
    await replaceFile(target, textWith(now()));
    return true;
  }

  /// Writes the Markdown [markdown] to [path] (inside `.appstein/`, with `/`
  /// separators), after a front matter block with its metadata
  /// ([markdownWithFrontMatter]). It follows the same rule as
  /// [writeGenerated]: it rebuilds the text with the `generatedAt` already in
  /// the file and skips the write only when the bytes would be the same.
  /// Returns whether it wrote.
  ///
  /// Throws a [KnowledgeWriteException] when the file can't be written. Call
  /// it inside [locked].
  Future<bool> writeGeneratedMarkdown(
    String path,
    String markdown, {
    required String inputHash,
    required String appsteinVersion,
    required String sdkVersion,
  }) async {
    final target = _pathOf(path);
    String textWith(String generatedAt) => markdownWithFrontMatter(
      markdown,
      KnowledgeMeta(
        generatedAt: generatedAt,
        appsteinVersion: appsteinVersion,
        formatVersion: knowledgeFormatVersion,
        sdkVersion: sdkVersion,
        inputHash: inputHash,
      ),
    );
    final stored = _storedMarkdownGeneratedAt(target);
    if (stored != null && stored.text == textWith(stored.generatedAt)) {
      return false;
    }
    await replaceFile(target, textWith(now()));
    return true;
  }

  /// Writes `state.json`. Call it inside [locked], like [writeGenerated].
  Future<void> writeState(KnowledgeState state) =>
      replaceFile(_pathOf('state.json'), canonicalJson(state.toJson()));

  /// Writes each of [files] (JSON with [writeGenerated], Markdown with
  /// [writeGeneratedMarkdown]), then `state.json` listing
  /// exactly these files' input hashes. Returns whether each file was
  /// written, in the order given. Call it inside [locked].
  Future<Map<String, bool>> writeAll(
    List<GeneratedFile> files, {
    required String appsteinVersion,
    required String sdkVersion,
  }) async {
    final written = <String, bool>{};
    for (final file in files) {
      if (file.body case final body?) {
        written[file.path] = await writeGenerated(
          file.path,
          body,
          inputHash: file.inputHash,
          appsteinVersion: appsteinVersion,
          sdkVersion: sdkVersion,
        );
      } else {
        written[file.path] = await writeGeneratedMarkdown(
          file.path,
          file.markdown!,
          inputHash: file.inputHash,
          appsteinVersion: appsteinVersion,
          sdkVersion: sdkVersion,
        );
      }
    }
    await writeState(
      KnowledgeState(
        formatVersion: knowledgeFormatVersion,
        appsteinVersion: appsteinVersion,
        lastSync: now(),
        files: {for (final file in files) file.path: file.inputHash},
      ),
    );
    return written;
  }

  String _pathOf(String path) => p.joinAll([folder, ...path.split('/')]);

  /// The text of the file at [path] and the `generatedAt` in its `meta`, or
  /// null when the file is missing, unreadable or damaged.
  static ({String text, String generatedAt})? _storedGeneratedAt(String path) {
    try {
      final text = File(path).readAsStringSync();
      final json = jsonDecode(text);
      if (json is! Map<String, Object?>) return null;
      final meta = json['meta'];
      if (meta is! Map<String, Object?>) return null;
      final generatedAt = meta['generatedAt'];
      return generatedAt is String
          ? (text: text, generatedAt: generatedAt)
          : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// The text of the Markdown file at [path] and the `generatedAt` in its
  /// front matter, or null when the file is missing, unreadable or damaged.
  static ({String text, String generatedAt})? _storedMarkdownGeneratedAt(
    String path,
  ) {
    try {
      final text = File(path).readAsStringSync();
      final meta = readFrontMatter(text);
      return meta == null ? null : (text: text, generatedAt: meta.generatedAt);
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
}) => _replace(
  path,
  (temp) => temp.writeAsStringSync(contents, flush: true),
  retryFor: retryFor,
  retryEvery: retryEvery,
);

/// Replaces the file at [path] with [bytes] in one step, as [replaceFile]
/// does with text.
Future<void> replaceFileBytes(
  String path,
  List<int> bytes, {
  Duration retryFor = const Duration(seconds: 2),
  Duration retryEvery = const Duration(milliseconds: 20),
}) => _replace(
  path,
  (temp) => temp.writeAsBytesSync(bytes, flush: true),
  retryFor: retryFor,
  retryEvery: retryEvery,
);

Future<void> _replace(
  String path,
  void Function(File temp) write, {
  required Duration retryFor,
  required Duration retryEvery,
}) async {
  final temp = File('$path.tmp');
  try {
    File(path).parent.createSync(recursive: true);
    write(temp);
  } on FileSystemException catch (error) {
    try {
      if (temp.existsSync()) temp.deleteSync();
    } on FileSystemException {
      // Nothing more to do; the next write overwrites it.
    }
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
        final reason = fileErrorReason(error);
        throw KnowledgeWriteException(
          path,
          '$reason${reason.endsWith('.') ? '' : '.'} Another program may '
          'have it open; close it and run `appstein sync` again.',
        );
      }
      await Future<void>.delayed(retryEvery);
    }
  }
}
