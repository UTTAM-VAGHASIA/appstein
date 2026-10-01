import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'flutter_minor.dart';

/// Thrown when a curated notes file isn't in the format of spec §6.4.
final class NotesFormatException implements Exception {
  /// Creates the exception for [file], at [line] (1-based) when known.
  const NotesFormatException(this.file, this.line, this.message);

  /// The notes file, such as `3.47.yaml`.
  final String file;

  /// The line of the problem, or null when it is about the whole file.
  final int? line;

  /// What is wrong.
  final String message;

  @override
  String toString() =>
      line == null ? '$file: $message' : '$file:$line: $message';
}

/// One curated notes file, `notes/<flutter-minor>.yaml` (spec §6.4).
final class NotesFile {
  /// Creates the file's contents.
  const NotesFile({
    required this.flutter,
    required this.released,
    required this.dart,
    required this.android,
    required this.ios,
    required this.macos,
    required this.notes,
  });

  /// The stable Flutter minor version it covers, such as `3.47`.
  final String flutter;

  /// The date of that minor's first stable release, `YYYY-MM-DD`.
  final String released;

  /// The Dart minor version that release bundles, such as `3.13`.
  final String dart;

  /// The Android toolchain matrix, used when the SDK's files can't be read.
  final AndroidToolchain android;

  /// The iOS minimums, used when the SDK's template can't be read.
  final AppleToolchain ios;

  /// The macOS minimums, used when the SDK's template can't be read.
  final AppleToolchain macos;

  /// The notes.
  final List<CuratedNote> notes;
}

final _minorPattern = RegExp(r'^\d+\.\d+$');
final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _sincePattern = RegExp(r'^\d{4}-\d{2}(-\d{2})?$');
final _idPattern = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

/// Reads the notes file named [file] (such as `3.47.yaml`) from [text].
///
/// Throws [NotesFormatException], naming the line, when the file isn't in
/// the format of spec §6.4.
NotesFile parseNotesFile(String file, String text) {
  final reader = _Reader(file);
  final root = reader.map(reader.load(text), 'The file');
  reader.keys(
    root,
    'The file',
    required: const {'flutter', 'released', 'dart', 'toolchain', 'notes'},
  );
  final fields = reader.fields(root);
  final flutter = reader.string(
    root,
    'flutter',
    'The file',
    pattern: _minorPattern,
    example: '"3.47"',
  );
  final named = p.basenameWithoutExtension(file);
  if (flutter != named) {
    throw reader.error(
      fields['flutter']!,
      '"flutter" is $flutter, but the file is named ${p.basename(file)}.',
    );
  }
  final released = reader.string(
    root,
    'released',
    'The file',
    pattern: _datePattern,
    example: '2026-08-12',
  );
  final dart = reader.string(
    root,
    'dart',
    'The file',
    pattern: _minorPattern,
    example: '"3.13"',
  );

  final toolchainNode = fields['toolchain']!;
  final toolchain = reader.map(toolchainNode, '"toolchain"');
  reader.keys(
    toolchain,
    '"toolchain"',
    required: const {'android', 'ios', 'macos'},
  );
  T part<T>(String key, T Function(Map<String, Object?> json) parse) {
    final node = reader.fields(toolchain)[key]!;
    final plain = _plain(node);
    if (plain is! Map<String, Object?>) {
      throw reader.error(node, '"toolchain.$key" must be a map.');
    }
    try {
      return parse(plain);
    } on FormatException catch (error) {
      throw reader.error(
        node,
        '"toolchain.$key": '
        '${error.message.replaceFirst('toolchain.json: ', '')}',
      );
    }
  }

  final fileMinor = flutterMinorOf(flutter)!;
  final ids = <String>{};
  return NotesFile(
    flutter: flutter,
    released: released,
    dart: dart,
    android: part('android', AndroidToolchain.fromJson),
    ios: part('ios', AppleToolchain.fromJson),
    macos: part('macos', AppleToolchain.fromJson),
    notes: [
      for (final node in reader.list(fields['notes']!, '"notes"').nodes)
        _note(reader, node, flutter, fileMinor, ids),
    ],
  );
}

CuratedNote _note(
  _Reader reader,
  YamlNode node,
  String fileFlutter,
  FlutterMinor fileMinor,
  Set<String> ids,
) {
  final map = reader.map(node, 'A note');
  final fields = reader.fields(map);
  final idValue = fields['id']?.value;
  final what = idValue is String ? 'Note "$idValue"' : 'A note';
  reader.keys(
    map,
    what,
    required: const {
      'id',
      'since',
      'priority',
      'area',
      'summary',
      'use',
      'avoid',
      'source',
    },
    optional: const {'languageVersion'},
  );
  final id = reader.string(
    map,
    'id',
    what,
    pattern: _idPattern,
    example: 'dot-shorthands',
  );
  if (!ids.add(id)) {
    throw reader.error(fields['id']!, 'Note "$id" appears twice.');
  }
  final since = reader.string(
    map,
    'since',
    what,
    pattern: _minorPattern,
    example: '"3.38"',
  );
  if (compareFlutterMinors(flutterMinorOf(since)!, fileMinor) > 0) {
    throw reader.error(
      fields['since']!,
      "$what is since $since, after this file's Flutter $fileFlutter.",
    );
  }
  final languageVersion = fields.containsKey('languageVersion')
      ? reader.string(
          map,
          'languageVersion',
          what,
          pattern: _minorPattern,
          example: '"3.10"',
        )
      : null;
  final priorityNode = fields['priority']!;
  final priority = priorityNode.value;
  if (priority is! int || priority < 1 || priority > 3) {
    throw reader.error(priorityNode, '$what "priority" must be 1, 2 or 3.');
  }
  final areaNode = fields['area']!;
  final area = NoteArea.values.asNameMap()[areaNode.value];
  if (area == null) {
    throw reader.error(
      areaNode,
      '$what "area" must be one of '
      '${NoteArea.values.map((a) => a.name).join(', ')}.',
    );
  }
  return CuratedNote(
    id: id,
    since: since,
    languageVersion: languageVersion,
    priority: priority,
    area: area,
    summary: reader.string(map, 'summary', what),
    use: reader.string(map, 'use', what),
    avoid: reader.string(map, 'avoid', what),
    source: reader.url(map, 'source', what),
  );
}

/// Reads `notes/stores.yaml`, named [file], from [text] (spec §6.4, §12).
///
/// Throws [NotesFormatException], naming the line, when it isn't in the
/// format described in that file's header.
StoreRequirements parseStoreRequirements(String file, String text) {
  final reader = _Reader(file);
  final root = reader.map(reader.load(text), 'The file');
  reader.keys(root, 'The file', required: const {'play', 'appStore'});
  Map<String, List<StoreRequirement>> store(String name) {
    final byKind = reader.map(reader.fields(root)[name]!, '"$name"');
    return {
      for (final entry in reader.fields(byKind).entries)
        entry.key: _requirements(reader, '$name.${entry.key}', entry.value),
    };
  }

  return StoreRequirements(play: store('play'), appStore: store('appStore'));
}

List<StoreRequirement> _requirements(
  _Reader reader,
  String kind,
  YamlNode node,
) {
  final result = <StoreRequirement>[];
  final what = 'An entry of "$kind"';
  for (final item in reader.list(node, '"$kind"').nodes) {
    final map = reader.map(item, what);
    reader.keys(
      map,
      what,
      required: const {'since', 'summary', 'source'},
      optional: const {'value', 'formFactor'},
    );
    final fields = reader.fields(map);
    String? value;
    final valueNode = fields['value'];
    if (valueNode != null) {
      final raw = valueNode.value;
      if (raw is int) {
        value = '$raw';
      } else if (raw is String && raw.isNotEmpty) {
        value = raw;
      } else {
        throw reader.error(
          valueNode,
          '$what "value" must be a whole number or a quoted string such as '
          '"14.1".',
        );
      }
    }
    final since = reader.string(
      map,
      'since',
      what,
      pattern: _sincePattern,
      example: '2026-08-31 or 2027-04',
    );
    if (result.isNotEmpty && since.compareTo(result.last.since) < 0) {
      throw reader.error(
        fields['since']!,
        '"$kind" must be oldest first, but $since comes after '
        '${result.last.since}.',
      );
    }
    result.add(
      StoreRequirement(
        value: value,
        since: since,
        formFactor: fields.containsKey('formFactor')
            ? reader.string(map, 'formFactor', what)
            : null,
        summary: reader.string(map, 'summary', what),
        source: reader.url(map, 'source', what),
      ),
    );
  }
  return result;
}

/// Converts a YAML node to plain maps, lists and values.
Object? _plain(YamlNode node) => switch (node) {
  YamlMap() => {
    for (final entry in node.nodes.entries)
      '${(entry.key as YamlNode).value}': _plain(entry.value),
  },
  YamlList() => [for (final item in node.nodes) _plain(item)],
  _ => node.value,
};

/// Reads YAML nodes with errors that name the file and line.
final class _Reader {
  _Reader(this.file);

  final String file;

  NotesFormatException error(YamlNode node, String message) =>
      NotesFormatException(file, node.span.start.line + 1, message);

  YamlNode load(String text) {
    try {
      return loadYamlNode(text.startsWith('﻿') ? text.substring(1) : text);
    } on YamlException catch (error) {
      final line = error.span?.start.line;
      throw NotesFormatException(
        file,
        line == null ? null : line + 1,
        error.message,
      );
    }
  }

  YamlMap map(YamlNode node, String what) =>
      node is YamlMap ? node : throw error(node, '$what must be a map.');

  YamlList list(YamlNode node, String what) =>
      node is YamlList ? node : throw error(node, '$what must be a list.');

  /// The entries of [map], by key name.
  Map<String, YamlNode> fields(YamlMap map) => {
    for (final entry in map.nodes.entries)
      '${(entry.key as YamlNode).value}': entry.value,
  };

  void keys(
    YamlMap map,
    String what, {
    required Set<String> required,
    Set<String> optional = const {},
  }) {
    for (final key in map.nodes.keys) {
      final node = key as YamlNode;
      final name = '${node.value}';
      if (!required.contains(name) && !optional.contains(name)) {
        throw error(node, '$what has an unknown key "$name".');
      }
    }
    final present = fields(map).keys.toSet();
    for (final name in required) {
      if (!present.contains(name)) {
        throw error(map, '$what is missing "$name".');
      }
    }
  }

  String string(
    YamlMap map,
    String key,
    String what, {
    RegExp? pattern,
    String? example,
  }) {
    final node = fields(map)[key]!;
    final value = node.value;
    if (value is! String || value.trim().isEmpty) {
      throw error(
        node,
        example == null
            ? '$what "$key" must be text.'
            : '$what "$key" must be a quoted string such as $example.',
      );
    }
    if (pattern != null && !pattern.hasMatch(value)) {
      throw error(node, '$what "$key" must look like $example, not "$value".');
    }
    return value;
  }

  String url(YamlMap map, String key, String what) {
    final value = string(map, key, what);
    if (!value.startsWith('https://')) {
      throw error(
        fields(map)[key]!,
        '$what "$key" must be an https:// URL to official docs.',
      );
    }
    return value;
  }
}
