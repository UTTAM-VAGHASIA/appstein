// The analyzer keeps its on-disk cache (`ByteStore`) and the collection that
// takes one (`AnalysisContextCollectionImpl`) in its `src/` folder, with no
// public way to use them. The owner chose to use them (slice 1b.7): every
// such use is in this file, and pubspec.yaml pins analyzer exactly, so an
// analyzer upgrade is a deliberate step that starts here. The canary test in
// analyzer_cache_test.dart fails if the analyzer stops using the cache.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../knowledge/knowledge_store.dart';

/// The analyzer version the cache's entries belong to: the exact version
/// `pubspec.yaml` pins. A test checks that they agree.
const analyzerVersion = '14.4.0';

/// The layout of the cache file; raise it when [encodeAnalyzerCache]
/// changes.
const analyzerCacheFormat = 1;

const _magic = 'APPSTEIN ANALYZER CACHE\n';

/// Where the analyzer cache of the project at [projectRoot] lives (spec
/// §6.2): in `.dart_tool/`, beside other Dart tools' caches, which Flutter's
/// template git-ignores and `flutter clean` deletes.
String analyzerCachePath(String projectRoot) =>
    p.join(projectRoot, '.dart_tool', 'appstein', 'analyzer_cache.bin');

/// The bytes of a cache file holding [entries]:
/// - the line `APPSTEIN ANALYZER CACHE`;
/// - [format] (4 bytes), then [analyzer] (2 bytes of length, then ASCII);
/// - each entry, sorted by key: the key (2 bytes of length, then ASCII),
///   then its bytes (4 bytes of length, then the bytes).
///
/// Numbers are big-endian. [analyzer] and [format] differ from the defaults
/// only in tests.
Uint8List encodeAnalyzerCache(
  Map<String, Uint8List> entries, {
  String analyzer = analyzerVersion,
  int format = analyzerCacheFormat,
}) {
  final out = BytesBuilder(copy: false)..add(ascii.encode(_magic));
  void number(int value, int length) {
    final data = ByteData(length);
    if (length == 2) {
      data.setUint16(0, value);
    } else {
      data.setUint32(0, value);
    }
    out.add(data.buffer.asUint8List());
  }

  number(format, 4);
  final version = ascii.encode(analyzer);
  number(version.length, 2);
  out.add(version);
  for (final key in entries.keys.toList()..sort()) {
    final name = ascii.encode(key);
    number(name.length, 2);
    out.add(name);
    final value = entries[key]!;
    number(value.length, 4);
    out.add(value);
  }
  return out.takeBytes();
}

/// The entries of a cache file's [bytes], as views into [bytes].
///
/// Throws a [FormatException] whose message says why, in words that follow
/// "the cache was not used because", when [bytes] isn't a cache file of
/// this format and analyzer version, or is cut short.
Map<String, Uint8List> decodeAnalyzerCache(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var at = 0;
  void need(int count) {
    if (at + count > bytes.length) {
      throw const FormatException('it is cut short');
    }
  }

  String text(int length) {
    need(length);
    final value = latin1.decode(Uint8List.sublistView(bytes, at, at + length));
    at += length;
    return value;
  }

  final magic = ascii.encode(_magic);
  if (bytes.length < magic.length ||
      latin1.decode(Uint8List.sublistView(bytes, 0, magic.length)) != _magic) {
    throw const FormatException('it is not an Appstein analyzer cache');
  }
  at = magic.length;
  need(4);
  final format = data.getUint32(at);
  at += 4;
  if (format != analyzerCacheFormat) {
    throw FormatException(
      'it was written in cache format $format, not $analyzerCacheFormat',
    );
  }
  need(2);
  final versionLength = data.getUint16(at);
  at += 2;
  final version = text(versionLength);
  if (version != analyzerVersion) {
    throw FormatException(
      'it was written by analyzer $version, not $analyzerVersion',
    );
  }
  final entries = <String, Uint8List>{};
  while (at < bytes.length) {
    need(2);
    final keyLength = data.getUint16(at);
    at += 2;
    final key = text(keyLength);
    need(4);
    final length = data.getUint32(at);
    at += 4;
    need(length);
    entries[key] = Uint8List.sublistView(bytes, at, at + length);
    at += length;
  }
  return entries;
}

/// How an [AnalyzerCache] opened.
enum AnalyzerCacheLoad {
  /// There was no cache file: the first sync, or after `flutter clean`.
  missing,

  /// The cache file was read.
  loaded,

  /// The cache file couldn't be used ([AnalyzerCache.damage] says why), so
  /// the cache starts empty.
  damaged,
}

/// The Dart analyzer's on-disk cache for one project (spec §6.2): what it
/// worked out about each library, so the next sync doesn't redo it.
///
/// It only makes syncs faster. The knowledge is the same with it, without
/// it, or with a damaged one.
final class AnalyzerCache {
  AnalyzerCache._(this.path, this.load, this.damage, this._loaded);

  /// An empty cache that saves to [path].
  AnalyzerCache.empty(this.path)
    : load = AnalyzerCacheLoad.missing,
      damage = null,
      _loaded = const {};

  /// Opens the cache file at [path]. A missing file gives an empty cache.
  /// So does a damaged or unreadable one, or one of another format or
  /// analyzer version, with [damage] saying why. It never throws.
  factory AnalyzerCache.open(String path) {
    final file = File(path);
    final Uint8List bytes;
    try {
      bytes = file.readAsBytesSync();
    } on FileSystemException catch (error) {
      if (!file.existsSync()) return AnalyzerCache.empty(path);
      return AnalyzerCache._(
        path,
        AnalyzerCacheLoad.damaged,
        'it could not be read (${fileErrorReason(error)})',
        const {},
      );
    }
    try {
      return AnalyzerCache._(
        path,
        AnalyzerCacheLoad.loaded,
        null,
        decodeAnalyzerCache(bytes),
      );
    } on FormatException catch (error) {
      return AnalyzerCache._(
        path,
        AnalyzerCacheLoad.damaged,
        error.message,
        const {},
      );
    }
  }

  /// The cache file.
  final String path;

  /// How it opened.
  final AnalyzerCacheLoad load;

  /// Why the file couldn't be used, when [load] is
  /// [AnalyzerCacheLoad.damaged].
  final String? damage;

  final Map<String, Uint8List> _loaded;
  final _used = <String, Uint8List>{};
  var _added = 0;
  late final ByteStore _store = _Store(this);

  /// How many entries were read from the file.
  int get loadedEntries => _loaded.length;

  /// How many entries the analyzer added since the cache was opened.
  int get addedEntries => _added;

  /// Whether [save] would write something different: an entry was added,
  /// or one that was read went unused.
  bool get changed => _added > 0 || _used.length != _loaded.length;

  /// The bytes stored for [key], or null. The entry counts as used.
  Uint8List? get(String key) {
    final bytes = _used[key] ?? _loaded[key];
    if (bytes != null) _used[key] = bytes;
    return bytes;
  }

  /// Stores [bytes] for [key], unless bytes are already stored for it, and
  /// returns the stored bytes. The entry counts as used.
  Uint8List putGet(String key, Uint8List bytes) {
    if (_used[key] ?? _loaded[key] case final existing?) {
      return _used[key] = existing;
    }
    _added++;
    return _used[key] = bytes;
  }

  /// Writes the entries used since the cache was opened to [path], in one
  /// step, so the file never holds entries no run needs.
  ///
  /// It doesn't wait for the disk to have the file (`flush: false`): waiting
  /// cost about 0.6 s of a 2 s budget on Windows CI's disks, for a file that
  /// only saves time. A copy a power cut damaged is caught when it is read
  /// (a bad header or length makes it empty, garbage in an entry makes the
  /// analysis run again without it), so the worst case is one slower sync.
  ///
  /// Throws a `KnowledgeWriteException` when it can't be written. [onTimed]
  /// hears how long writing and renaming the file took.
  Future<void> save({void Function(ReplaceTiming timing)? onTimed}) =>
      replaceFileBytes(
        path,
        encodeAnalyzerCache(_used),
        onTimed: onTimed,
        flush: false,
      );
}

/// The analyzer's view of an [AnalyzerCache].
final class _Store implements ByteStore {
  _Store(this._cache);

  final AnalyzerCache _cache;

  @override
  Uint8List? get(String key) => _cache.get(key);

  @override
  Uint8List putGet(String key, Uint8List bytes) => _cache.putGet(key, bytes);

  @override
  void release(Iterable<String> keys) {}
}

/// The analyzer's view of the folders [includedPaths], reading `dart:`
/// libraries from the Dart SDK at [sdkPath]. With a [cache], the analyzer
/// keeps its work there.
AnalysisContextCollection analysisCollection({
  required List<String> includedPaths,
  required String sdkPath,
  AnalyzerCache? cache,
}) => cache == null
    ? AnalysisContextCollection(includedPaths: includedPaths, sdkPath: sdkPath)
    : AnalysisContextCollectionImpl(
        includedPaths: includedPaths,
        sdkPath: sdkPath,
        byteStore: cache._store,
      );

/// Runs [body] and returns its result.
///
/// The analyzer does its work in a scheduler of its own. An error there,
/// such as one from a cache entry holding garbage, isn't an error of
/// [body]'s futures: it ends the process (seen in the 1b.7 probe). Here it
/// becomes the returned future's error. An error after [body] finished is
/// ignored.
Future<T> catchAnalyzerErrors<T>(Future<T> Function() body) {
  final done = Completer<T>();
  runZonedGuarded(
    () async {
      final value = await body();
      if (!done.isCompleted) done.complete(value);
    },
    (error, stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    },
  );
  return done.future;
}

/// What a sync did with the analyzer cache.
final class AnalyzerCacheReport {
  /// Creates the report.
  const AnalyzerCacheReport({
    required this.load,
    this.damage,
    this.retried,
    this.saveError,
  });

  /// How the cache opened.
  final AnalyzerCacheLoad load;

  /// Why the cache file couldn't be used, when it was damaged.
  final String? damage;

  /// The analyzer's error, in one line, that made the sync analyze again
  /// with an empty cache; null when it didn't.
  final String? retried;

  /// Why the cache couldn't be saved. The sync still succeeded; the next one
  /// is slower.
  final String? saveError;
}
