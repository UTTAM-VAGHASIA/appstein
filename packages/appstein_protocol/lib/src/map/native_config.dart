import '../json_fields.dart';

const _file = 'native.json';

/// What Appstein knows about one native value (spec §6.5).
enum NativeStatus {
  /// Read from a file, with where it is.
  found,

  /// Present, but not a plain value Appstein can read: computed in Gradle
  /// code, set more than once, set conditionally, or in a file that can't
  /// be read. Never guessed.
  unknown,

  /// Not set, or its file doesn't exist.
  absent,

  /// The platform pack failed (an Appstein bug). Only a whole section has
  /// this status.
  error,
}

/// A part of `map/native.json` (spec §6.5): a [NativeValue], a
/// [NativeGroup] of parts with names Appstein chose, or a [NativeList] of
/// entries the project names (flavors, permissions, Xcode configurations).
sealed class NativeNode {
  /// Lets subclasses be constant.
  const NativeNode();

  /// Reads a node from its JSON form: a list is a [NativeList], an object
  /// with a `status` key a [NativeValue], and any other object a
  /// [NativeGroup].
  ///
  /// Throws a [FormatException] when it is none of these.
  static NativeNode fromJson(Object? json) => switch (json) {
    final List<Object?> list => NativeList._read(list),
    final Map<String, Object?> map when map.containsKey('status') =>
      NativeValue._read(map),
    final Map<String, Object?> map => NativeGroup._read(map),
    _ => throw const FormatException(
      '$_file: a part must be an object or a list.',
    ),
  };

  /// The JSON form.
  Object toJson();
}

/// One native value and what Appstein knows about it.
final class NativeValue extends NativeNode {
  /// A value read from a file.
  ///
  /// [value] is a string, an integer, a boolean or a list of strings. [at]
  /// is where it is: `path` or `path:line`, relative to the project, with
  /// `/`. [expression] is how the file wrote it when that isn't the value
  /// itself, such as `flutter.minSdkVersion`. [resolvedFrom] says where the
  /// value of an expression or a setting came from, such as `flutter`,
  /// `notes`, `pubspec.yaml:19` or `default`. [note] is anything else a
  /// reader must know, such as `set at project level`.
  const NativeValue.found(
    Object this.value, {
    this.at,
    this.expression,
    this.resolvedFrom,
    this.note,
  }) : status = NativeStatus.found,
       reason = null,
       errorType = null;

  /// A value Appstein can't read plainly, and why.
  const NativeValue.unknown(String this.reason, {this.at})
    : status = NativeStatus.unknown,
      value = null,
      expression = null,
      resolvedFrom = null,
      note = null,
      errorType = null;

  /// A value that isn't set, or whose file doesn't exist, and why.
  const NativeValue.absent(String this.reason, {this.at})
    : status = NativeStatus.absent,
      value = null,
      expression = null,
      resolvedFrom = null,
      note = null,
      errorType = null;

  /// A section whose platform pack failed with an error of [errorType] (an
  /// Appstein bug). Only the type is kept: the message may hold a machine
  /// path.
  const NativeValue.error(String this.errorType)
    : status = NativeStatus.error,
      value = null,
      at = null,
      expression = null,
      resolvedFrom = null,
      note = null,
      reason = null;

  factory NativeValue._read(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    final at = fields.optionalString('at');
    return switch (NativeStatus.values.asNameMap()[fields.string('status')]) {
      NativeStatus.found => NativeValue.found(
        _readValue(json['value']),
        at: at,
        expression: fields.optionalString('expression'),
        resolvedFrom: fields.optionalString('resolvedFrom'),
        note: fields.optionalString('note'),
      ),
      NativeStatus.unknown => NativeValue.unknown(
        fields.string('reason'),
        at: at,
      ),
      NativeStatus.absent => NativeValue.absent(
        fields.string('reason'),
        at: at,
      ),
      NativeStatus.error => NativeValue.error(fields.string('errorType')),
      null => throw const FormatException(
        '$_file: "status" must be found, unknown, absent or error.',
      ),
    };
  }

  static Object _readValue(Object? value) => switch (value) {
    final String text => text,
    final int number => number,
    final bool flag => flag,
    final List<Object?> list when list.every((item) => item is String) =>
      List<String>.unmodifiable(list.cast<String>()),
    _ => throw const FormatException(
      '$_file: "value" must be a string, an integer, true or false, or a '
      'list of strings.',
    ),
  };

  /// What Appstein knows.
  final NativeStatus status;

  /// The value, when [status] is [NativeStatus.found]: a string, an
  /// integer, a boolean or a list of strings.
  final Object? value;

  /// Where it is: `path` or `path:line`, relative to the project.
  final String? at;

  /// How the file wrote it, when that isn't the value itself.
  final String? expression;

  /// Where the value of an expression or a setting came from.
  final String? resolvedFrom;

  /// Anything else a reader must know.
  final String? note;

  /// Why it is unknown or absent.
  final String? reason;

  /// The type of the error that stopped the pack, for an `error` section.
  final String? errorType;

  @override
  Map<String, Object?> toJson() => {
    'status': status.name,
    if (value != null) 'value': value,
    if (at != null) 'at': at,
    if (expression != null) 'expression': expression,
    if (resolvedFrom != null) 'resolvedFrom': resolvedFrom,
    if (note != null) 'note': note,
    if (reason != null) 'reason': reason,
    if (errorType != null) 'errorType': errorType,
  };
}

/// Parts with names Appstein chose, such as `app` or `minSdk`.
final class NativeGroup extends NativeNode {
  /// Creates the group. No part may be named `status`, the key that marks
  /// a value.
  NativeGroup(Map<String, NativeNode> children)
    : children = Map.unmodifiable(children) {
    if (children.containsKey('status')) {
      throw ArgumentError.value(
        'status',
        'children',
        'is the key that marks a value',
      );
    }
  }

  factory NativeGroup._read(Map<String, Object?> json) => NativeGroup({
    for (final MapEntry(:key, :value) in json.entries)
      key: NativeNode.fromJson(value),
  });

  /// The parts, by name.
  final Map<String, NativeNode> children;

  @override
  Map<String, Object?> toJson() => {
    for (final MapEntry(:key, :value) in children.entries) key: value.toJson(),
  };
}

/// One entry of a [NativeList]: something the project names, where it is,
/// and its parts.
final class NativeEntry {
  /// Creates the entry. No part may be named `name`, `at` or `status`,
  /// which its JSON form uses.
  NativeEntry(this.name, Map<String, NativeNode> children, {this.at})
    : children = Map.unmodifiable(children) {
    for (final key in const ['name', 'at', 'status']) {
      if (children.containsKey(key)) {
        throw ArgumentError.value(key, 'children', 'is used by the entry');
      }
    }
  }

  factory NativeEntry._read(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('$_file: a list entry must be an object.');
    }
    if (json.containsKey('status')) {
      throw const FormatException(
        '$_file: a list entry cannot have a part named "status".',
      );
    }
    final fields = JsonFields(_file, json);
    return NativeEntry(fields.string('name'), {
      for (final MapEntry(:key, :value) in json.entries)
        if (key != 'name' && key != 'at') key: NativeNode.fromJson(value),
    }, at: fields.optionalString('at'));
  }

  /// The name the project gave it, such as a flavor's.
  final String name;

  /// Where it is declared: `path:line`.
  final String? at;

  /// Its parts, by name.
  final Map<String, NativeNode> children;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'name': name,
    if (at != null) 'at': at,
    for (final MapEntry(:key, :value) in children.entries) key: value.toJson(),
  };
}

/// Entries the project names, sorted by name. The names are never JSON
/// keys, so no name can clash with a key Appstein uses.
final class NativeList extends NativeNode {
  /// Creates the list, sorted by name.
  NativeList(List<NativeEntry> entries)
    : entries = List.unmodifiable(
        <NativeEntry>[...entries]..sort((a, b) => a.name.compareTo(b.name)),
      );

  factory NativeList._read(List<Object?> json) =>
      NativeList([for (final item in json) NativeEntry._read(item)]);

  /// The entries, sorted by name.
  final List<NativeEntry> entries;

  @override
  List<Map<String, Object?>> toJson() => [
    for (final entry in entries) entry.toJson(),
  ];
}

/// The contents of `map/native.json` (spec §6.5): one section per platform
/// pack, such as `android` and `ios`.
final class NativeConfig {
  /// Creates the file's contents.
  NativeConfig(Map<String, NativeNode> sections)
    : sections = Map.unmodifiable(sections);

  /// Reads the file's JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a malformed part.
  factory NativeConfig.fromJson(Map<String, Object?> json) => NativeConfig({
    for (final MapEntry(:key, :value) in json.entries)
      if (key != 'meta') key: NativeNode.fromJson(value),
  });

  /// The sections, by pack: `android`, `ios`.
  final Map<String, NativeNode> sections;

  /// The part at [path], such as `['android', 'app', 'minSdk']`: a section,
  /// then parts of groups, or entries of lists by name. An entry comes back
  /// as a [NativeGroup] of its parts. Null when there is none.
  NativeNode? lookup(List<String> path) {
    if (path.isEmpty) return null;
    var node = sections[path.first];
    for (final name in path.skip(1)) {
      node = switch (node) {
        NativeGroup(:final children) => children[name],
        NativeList(:final entries) => switch (entries
            .where((entry) => entry.name == name)
            .firstOrNull) {
          final entry? => NativeGroup(entry.children),
          null => null,
        },
        _ => null,
      };
    }
    return node;
  }

  /// The JSON form, without `meta` (the store adds it).
  Map<String, Object?> toJson() => {
    for (final MapEntry(:key, :value) in sections.entries) key: value.toJson(),
  };
}
