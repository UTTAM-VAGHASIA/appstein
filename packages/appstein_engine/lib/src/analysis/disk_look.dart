import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

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
/// them out. Links are not followed. A folder or file that can't be read
/// counts as not there.
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
  /// look, and those whose time lies so close to that look that a change
  /// could hide behind the same time and size ([diskClockStep]). In path
  /// order.
  List<String> dartChangedSince(DiskLook earlier) {
    final sure = earlier.at.subtract(diskClockStep);
    return [
      for (final MapEntry(key: path, value: now) in dart.entries)
        if (earlier.dart[path] != now || !now.$1.isBefore(sure)) path,
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
  /// files there too.
  Future<void> _walk(String folder, {required bool settings}) async {
    final List<FileSystemEntity> entries;
    try {
      entries = await Directory(folder).list(followLinks: false).toList();
    } on FileSystemException {
      return;
    }
    final waiting = <Future<void>>[];
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (entry is Directory) {
        if (!name.startsWith('.')) {
          waiting.add(_walk(entry.path, settings: settings));
        }
      } else if (entry is File) {
        if (name.endsWith('.dart')) {
          waiting.add(
            entry.stat().then((stat) {
              if (stat.type != FileSystemEntityType.notFound) {
                dart[entry.path] = (stat.modified, stat.size);
              }
            }),
          );
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
