import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../knowledge/dart_files.dart' show fileKey;

/// How far back from a look a file's time may lie and the file still be
/// told to the server again at the next look. A file written twice within
/// one step of the file system's clock, to the same size, has the same time
/// and size both times; the coarsest clocks in use step by 2 s.
const diskClockStep = Duration(seconds: 2);

/// One look at the files a project's analysis depends on: what a later look
/// is compared with, to find what a kept analysis server must be told
/// (`AnalysisServer.read`).
///
/// It holds two kinds of file:
/// - **Dart files**, by their time of last change and size: every one under
///   the project folder, and the source of every package the package
///   configuration places outside pub's cache and the SDK (a path
///   dependency, at a relative or an absolute location, and a member of a
///   pub workspace). The server reads those too, and watches nothing
///   outside the project folder;
/// - **settings**, by their text: the files that set how the project is
///   analyzed. Every `analysis_options.yaml` and `pubspec.yaml` under the
///   project folder; the nearest `analysis_options.yaml` above a project
///   that has none of its own; every file one of those includes, by a path
///   or from a package, and what that includes in turn; and the package
///   configuration (`.dart_tool/package_config.json`) of the project, or
///   the nearest one above it, and of each `pubspec.yaml` below it.
///
/// Folders whose name starts with a dot are left out, as the server leaves
/// them out. A link to a folder (a Windows junction) is followed, as the
/// server follows it, and a file behind it is named by its path through the
/// link; a link back to a folder the walk is inside is not followed again.
/// A folder or a settings file that can't be read counts as not there; a
/// Dart file that can't be read is noted in [unreadable].
final class DiskLook {
  DiskLook._(this.root, this.at);

  /// Looks at the project in [root], an absolute, normalized path. It reads
  /// folders and file times without blocking: other work goes on meanwhile.
  ///
  /// The source of a package inside one of the folders [unchanging] (the
  /// pub cache, the SDKs: [unchangingFolders]) is not looked at: nothing
  /// edits it while a session runs, and it is large. Every other package
  /// is, wherever the configuration places it.
  static Future<DiskLook> of(
    String root, {
    List<String> unchanging = const [],
  }) async {
    final look = DiskLook._(root, DateTime.now());
    await look._walk(root, settings: true);

    // The package configuration the project uses: its own, or the nearest
    // above it (a pub workspace keeps one at its root).
    String? config;
    for (final folder in _selfAndAbove(root)) {
      final candidate = p.join(folder, '.dart_tool', 'package_config.json');
      if (await look._setting(candidate)) {
        config = candidate;
        break;
      }
    }
    final packages = config == null
        ? const <String, _Package>{}
        : _packagesOf(config, look.settings[config]!);

    // The source of the packages that can change while a session runs: a
    // path dependency, at a relative location or an absolute one (pub
    // writes an absolute one for a `path:` given as one, and for a package
    // on another drive), and a member of a pub workspace.
    for (final package in packages.values) {
      if (unchanging.any(
        (folder) =>
            p.isWithin(folder, package.source) ||
            p.equals(folder, package.source),
      )) {
        continue;
      }
      if (p.isWithin(root, package.source) || package.source == root) continue;
      // The project itself, seen from a configuration above it.
      if (p.isWithin(package.source, root)) continue;
      await look._walk(package.source, settings: false);
    }

    // The options of a project that has none of its own come from above.
    final own = p.join(root, 'analysis_options.yaml');
    if (!look.settings.containsKey(own)) {
      for (final folder in _selfAndAbove(root).skip(1)) {
        if (await look._setting(p.join(folder, 'analysis_options.yaml'))) {
          break;
        }
      }
    }
    // What the options files include, and what that includes.
    final followed = <String>{};
    var options = [
      for (final path in look.settings.keys)
        if (p.basename(path) == 'analysis_options.yaml') path,
    ];
    while (options.isNotEmpty) {
      final next = <String>[];
      for (final path in options) {
        if (!followed.add(path)) continue;
        for (final included in _includesOf(look.settings[path]!)) {
          final target = _includeTarget(included, from: path, packages);
          if (target == null || followed.contains(target)) continue;
          if (await look._setting(target)) next.add(target);
        }
      }
      options = next;
    }
    return look;
  }

  /// The project's folder.
  final String root;

  /// When the look was taken.
  final DateTime at;

  /// Each Dart file's time of last change and size, by absolute path.
  final dart = <String, (DateTime, int)>{};

  /// Each Dart file of [dart] that could not be opened and read, by
  /// absolute path, with the system's reason. Every Dart file is opened and
  /// its first byte read, in the same walk that takes its time and size: on
  /// Windows a file another program holds locked still has a time and a
  /// size, and the analysis server reads it as empty, with no diagnostic.
  final unreadable = <String, String>{};

  /// The text of each file that sets how the project is analyzed, by
  /// absolute path.
  final settings = <String, String>{};

  /// Whether the files that set how the project is analyzed are the same,
  /// with the same text, as in the [earlier] look.
  bool sameSettingsAs(DiskLook earlier) =>
      settings.length == earlier.settings.length &&
      settings.entries.every(
        (file) => earlier.settings[file.key] == file.value,
      );

  /// The Dart files that changed, appeared or are gone since the [earlier]
  /// look, those whose time lies so close to that look that a change could
  /// hide behind the same time and size ([diskClockStep]), and those that
  /// could not be read then: the server may have read one as empty, and it
  /// must read it again once it can. In path order.
  List<String> dartChangedSince(DiskLook earlier) {
    final sure = earlier.at.subtract(diskClockStep);
    return [
      for (final MapEntry(key: path, value: now) in dart.entries)
        if (earlier.dart[path] != now ||
            !now.$1.isBefore(sure) ||
            earlier.unreadable.containsKey(path))
          path,
      for (final path in earlier.dart.keys)
        if (!dart.containsKey(path)) path,
    ]..sort();
  }

  /// A Dart file inside the project folder that is there now: one of
  /// [among] when one is, else any. Null when the project has none.
  String? dartFileInProject(Iterable<String> among) {
    bool inProject(String path) =>
        dart.containsKey(path) && p.isWithin(root, path);
    return among.where(inProject).firstOrNull ??
        dart.keys.where(inProject).firstOrNull;
  }

  /// Reads the file at [path] into [settings]; false when it can't be read.
  Future<bool> _setting(String path) async {
    if (settings.containsKey(path)) return true;
    try {
      settings[path] = String.fromCharCodes(await File(path).readAsBytes());
      return true;
    } on FileSystemException {
      // Not there, or being written: a later look reads it.
      return false;
    }
  }

  /// Notes the Dart files under [folder], and with [settings] the settings
  /// files there too. A link to a folder (a Windows junction) is followed,
  /// as the analysis server follows it, and what is behind it is named by
  /// its path through the link; a link back to a folder the walk is already
  /// inside is not followed again.
  Future<void> _walk(String folder, {required bool settings}) async {
    final String resolved;
    try {
      resolved = await Directory(folder).resolveSymbolicLinks();
    } on FileSystemException {
      return;
    }
    // Like the analyzer's walk, the top folder is not among those the walk
    // is inside: a link back to it is walked once.
    await _walkIn(folder, resolved, const {}, settings: settings);
  }

  /// [_walk] inside [folder], whose path with every link resolved is
  /// [resolved], below the folders [inside] (resolved, as [fileKey]s).
  Future<void> _walkIn(
    String folder,
    String resolved,
    Set<String> inside, {
    required bool settings,
  }) async {
    final List<FileSystemEntity> entries;
    try {
      entries = await Directory(folder).list(followLinks: false).toList();
    } on FileSystemException {
      return;
    }
    final waiting = <Future<void>>[];
    // Notes the Dart file [file]: its time and size (through a link, the
    // target's), and whether its first byte can be read.
    Future<void> noteDart(File file) async {
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return;
      dart[file.path] = (stat.modified, stat.size);
      if (await _opens.run(() => _unreadable(file)) case final reason?) {
        unreadable[file.path] = reason;
      }
    }

    for (final entry in entries) {
      final name = p.basename(entry.path);
      // The server leaves out every name that starts with a dot, a file's
      // as well as a folder's (checked with a real server).
      if (name.startsWith('.')) continue;
      if (entry is Directory) {
        final here = p.join(resolved, name);
        // Through a link the walk can reach a folder it is already inside
        // (a link from `lib/up` to the project: `lib/up/lib`); the server
        // skips it, and so does the walk.
        if (inside.contains(fileKey(here))) continue;
        waiting.add(
          _walkIn(entry.path, here, {
            ...inside,
            fileKey(here),
          }, settings: settings),
        );
      } else if (entry is Link) {
        waiting.add(() async {
          final type = await FileSystemEntity.type(entry.path);
          if (type == FileSystemEntityType.file) {
            // A link to a file: a Dart file of the project, under the
            // link's name, as the analyzer's walk lists it.
            if (name.endsWith('.dart')) await noteDart(File(entry.path));
            return;
          }
          if (type != FileSystemEntityType.directory) return;
          final String target;
          try {
            target = await Directory(entry.path).resolveSymbolicLinks();
          } on FileSystemException {
            return;
          }
          if (inside.contains(fileKey(target))) return;
          await _walkIn(entry.path, target, {
            ...inside,
            fileKey(target),
          }, settings: settings);
        }());
      } else if (entry is File) {
        if (name.endsWith('.dart')) {
          waiting.add(noteDart(entry));
        } else if (!settings) {
          continue;
        } else if (name == 'analysis_options.yaml') {
          waiting.add(_setting(entry.path));
        } else if (name == 'pubspec.yaml') {
          waiting
            ..add(_setting(entry.path))
            ..add(
              _setting(p.join(folder, '.dart_tool', 'package_config.json')),
            );
        }
      }
    }
    await Future.wait(waiting);
  }

  /// The files this look has open at once, at most [openFilesAtOnce]: a
  /// project with more Dart files than the system lets a process open
  /// (256 in macOS's Terminal, 1,024 on Linux) would otherwise read as
  /// unreadable.
  final _opens = _OpenPool(openFilesAtOnce);

  /// The most files this look had open at once, for tests of the bound.
  int get mostOpenAtOnce => _opens.most;

  /// The text of each file [readWhole] read, by absolute path, as UTF-8
  /// (malformed bytes replaced, as the analysis server reads them).
  final texts = <String, String>{};

  /// Reads each of [paths] (Dart files of this look) whole, keeps its text
  /// in [texts], and notes in [unreadable] each that can't be read, or takes
  /// it out when it now can. The walk reads only a file's first byte, which
  /// a lock on bytes further in doesn't stop; the files the server is told
  /// to read again are read whole here, and the server is given that text.
  Future<void> readWhole(Iterable<String> paths) => Future.wait([
    for (final path in paths)
      if (dart.containsKey(path))
        _opens.run(() => _readText(path)).then((read) {
          switch (read) {
            case (text: final text?, reason: _):
              texts[path] = text;
              unreadable.remove(path);
            case (text: null, reason: final reason?):
              texts.remove(path);
              unreadable[path] = reason;
            case _:
              // Gone: the next look finds it gone.
              texts.remove(path);
              unreadable.remove(path);
          }
        }),
  ]);

  /// The text of the file at [path], or why it can't be read whole; both
  /// null when it is gone.
  static Future<({String? text, String? reason})> _readText(String path) async {
    final file = File(path);
    try {
      final bytes = await _retryingTooManyOpen(file.readAsBytes);
      if (bytes == null) return (text: null, reason: null);
      return (
        text: const Utf8Decoder(allowMalformed: true).convert(bytes),
        reason: null,
      );
    } on FileSystemException catch (error) {
      if (!await file.exists()) return (text: null, reason: null);
      return (
        text: null,
        reason: error.osError?.message.trim() ?? error.message,
      );
    }
  }

  /// Why [file] can't be opened and its first byte read; null when it can.
  /// Reading one byte also finds a lock on the file's bytes that starts at
  /// the first byte (on Windows, `LockFileEx`); opening finds a file another
  /// program opened without sharing it. A file that was deleted meanwhile is
  /// no reason: the next look finds it gone.
  static Future<String?> _unreadable(File file) async {
    try {
      await _retryingTooManyOpen(() async {
        final opened = await file.open();
        try {
          await opened.read(1);
        } finally {
          await opened.close();
        }
      });
      return null;
    } on FileSystemException catch (error) {
      if (!await file.exists()) return null;
      return error.osError?.message.trim() ?? error.message;
    }
  }

  /// Runs [action], and again while it fails because this process has too
  /// many files open (other work of Appstein may hold some): that says
  /// nothing about the file. When it still fails after a while, the answer
  /// is null: the file is not reported as unreadable for it.
  static Future<T?> _retryingTooManyOpen<T>(Future<T> Function() action) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await action();
      } on FileSystemException catch (error) {
        if (!_tooManyOpen(error)) rethrow;
        if (attempt >= 50) return null;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  /// Whether [error] says the process or the system has too many files open
  /// (`EMFILE` 24 and `ENFILE` 23 on Linux and macOS, error 4 on Windows).
  static bool _tooManyOpen(FileSystemException error) {
    final code = error.osError?.errorCode;
    return Platform.isWindows ? code == 4 : (code == 24 || code == 23);
  }

  /// [folder], then each folder above it up to the drive's or the file
  /// system's root.
  static Iterable<String> _selfAndAbove(String folder) sync* {
    var at = folder;
    while (true) {
      yield at;
      final above = p.dirname(at);
      if (above == at) return;
      at = above;
    }
  }

  /// The packages of the package configuration at [path] with the text
  /// [text], by name. A configuration that can't be read as one has none.
  static Map<String, _Package> _packagesOf(String path, String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return const {};
    }
    if (json is! Map<String, Object?>) return const {};
    final list = json['packages'];
    if (list is! List<Object?>) return const {};
    final found = <String, _Package>{};
    for (final entry in list) {
      if (entry case {
        'name': final String name,
        'rootUri': final String rootUri,
      }) {
        final Uri root;
        final Uri source;
        try {
          root = Uri.parse(rootUri.endsWith('/') ? rootUri : '$rootUri/');
          source = switch (entry['packageUri']) {
            final String packageUri => Uri.parse(
              packageUri.endsWith('/') ? packageUri : '$packageUri/',
            ),
            _ => Uri(),
          };
        } on FormatException {
          continue;
        }
        // A location is relative to the configuration file.
        final resolved = p.toUri(path).resolveUri(root).resolveUri(source);
        if (!resolved.isScheme('file')) continue;
        found[name] = _Package(p.normalize(resolved.toFilePath()));
      }
    }
    return found;
  }

  /// The values of `include:` in the analysis options [text]: one, or a
  /// list. Options that aren't YAML include nothing.
  static List<String> _includesOf(String text) {
    final Object? yaml;
    try {
      yaml = loadYaml(text);
    } on YamlException {
      return const [];
    }
    if (yaml is! YamlMap) return const [];
    return switch (yaml['include']) {
      final String one => [one],
      final YamlList many => [...many.whereType<String>()],
      _ => const [],
    };
  }

  /// The file an options file at [from] means with the include [included]:
  /// a `package:` include is found through [packages], any other is a path
  /// from the including file's folder. Null when it names no local file.
  static String? _includeTarget(
    String included,
    Map<String, _Package> packages, {
    required String from,
  }) {
    const scheme = 'package:';
    if (included.startsWith(scheme)) {
      final parts = included.substring(scheme.length).split('/');
      if (parts.length < 2) return null;
      final package = packages[parts.first];
      if (package == null) return null;
      return p.normalize(p.joinAll([package.source, ...parts.skip(1)]));
    }
    // Anything else is read as a path, as the analyzer reads it.
    return p.normalize(p.join(p.dirname(from), included));
  }
}

/// How many files one look at the disk opens at once (finding 1 of the
/// second review of ticket 06): far below the smallest limit in common use,
/// 256 open files in macOS's Terminal.
const openFilesAtOnce = 32;

/// Runs at most [limit] actions at once; the others wait their turn.
final class _OpenPool {
  _OpenPool(this.limit);

  final int limit;
  var _running = 0;
  final _waiting = <Completer<void>>[];

  /// The most actions that ran at once.
  var most = 0;

  Future<T> run<T>(Future<T> Function() action) async {
    if (_running >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    if (_running > most) most = _running;
    try {
      return await action();
    } finally {
      if (_waiting.isNotEmpty) {
        // The turn passes on: as many run as before.
        _waiting.removeAt(0).complete();
      } else {
        _running--;
      }
    }
  }
}

/// One package of a package configuration.
final class _Package {
  const _Package(this.source);

  /// The folder its `package:` files are in.
  final String source;
}

/// The folders whose packages don't change while a session runs, for
/// [DiskLook.of]: pub's cache, found as pub finds it (`PUB_CACHE`, else
/// `%LOCALAPPDATA%\Pub\Cache` on Windows, and the older
/// `%APPDATA%\Pub\Cache`, or `~/.pub-cache` elsewhere), and the SDK that
/// runs the analysis: the Dart SDK of [dartExecutable], and the Flutter SDK
/// around it when it is one's (`<flutter>/bin/cache/dart-sdk`).
List<String> unchangingFolders(
  String dartExecutable,
  Map<String, String> environment,
) {
  final dartSdk = p.dirname(p.dirname(dartExecutable));
  final folders = [dartSdk];
  final cache = p.dirname(dartSdk);
  if (p.basename(dartSdk) == 'dart-sdk' &&
      p.basename(cache) == 'cache' &&
      p.basename(p.dirname(cache)) == 'bin') {
    folders.add(p.dirname(p.dirname(cache)));
  }
  if (environment['PUB_CACHE'] case final pubCache? when pubCache.isNotEmpty) {
    folders.add(pubCache);
  } else if (Platform.isWindows) {
    for (final variable in ['LOCALAPPDATA', 'APPDATA']) {
      if (environment[variable] case final base? when base.isNotEmpty) {
        folders.add(p.join(base, 'Pub', 'Cache'));
      }
    }
  } else if (environment['HOME'] case final home? when home.isNotEmpty) {
    folders.add(p.join(home, '.pub-cache'));
  }
  return [for (final folder in folders) p.normalize(p.absolute(folder))];
}
