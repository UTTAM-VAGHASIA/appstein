import 'package:yaml/yaml.dart';

/// The element kinds a `fix_data` migration can name, the keys of its
/// `element:` map that `dart fix` reads.
const fixDataElementKinds = {
  'class',
  'constant',
  'constructor',
  'enum',
  'extension',
  'field',
  'function',
  'getter',
  'method',
  'mixin',
  'setter',
  'typedef',
  'variable',
};

const _containerKeys = ['inClass', 'inEnum', 'inExtension', 'inMixin'];

/// Thrown when a `fix_data` file can't be read as `dart fix` migrations.
final class FixDataFormatException implements Exception {
  /// Creates the exception.
  const FixDataFormatException(this.file, this.line, this.problem);

  /// The file, as the caller named it.
  final String file;

  /// The 1-based line of the problem, or null when unknown.
  final int? line;

  /// What is wrong.
  final String problem;

  /// The problem with its line, such as `line 4: "uris" must be a list…`.
  String get reason => line == null ? problem : 'line $line: $problem';

  @override
  String toString() => '$file: $reason';
}

/// One migration in a `fix_data` file (a data-driven fix that `dart fix`
/// applies): either an element that was renamed, removed or changed, or a
/// library that moved.
final class FixDataTransform {
  /// Creates the migration.
  const FixDataTransform({
    required this.title,
    this.uris = const [],
    this.kind,
    this.name,
    this.container,
    this.oldParameters = const {},
    this.library,
    this.newLibrary,
  });

  /// The migration's title, such as `Migrate to 'clipBehavior'`.
  final String title;

  /// The libraries the element is reachable through, resolved
  /// (`material.dart` in Flutter's files is `package:flutter/material.dart`),
  /// each once. Empty for a library migration.
  final List<Uri> uris;

  /// The element's kind, one of [fixDataElementKinds]; null for a library
  /// migration.
  final String? kind;

  /// The element's name: '' for an unnamed constructor, null for a library
  /// migration.
  final String? name;

  /// The class, enum, extension or mixin that declares the element, or null
  /// for a top-level element.
  final String? container;

  /// The old names of the parameters the migration removes or renames.
  final Set<String> oldParameters;

  /// For a library migration, the library it moves away from.
  final Uri? library;

  /// For a library migration, where its `replacedBy` change moves it, or
  /// null.
  final Uri? newLibrary;
}

/// Reads the `fix_data` file [text], named [file] in errors. Relative URIs
/// resolve against [base], the package's `lib/` folder as a URI such as
/// `package:flutter/`. An empty file, or one without `transforms`, has no
/// migrations.
///
/// Throws a [FixDataFormatException] when the text isn't valid YAML, isn't a
/// map, or a migration lacks a title, an element or a library, or names no
/// known element kind.
List<FixDataTransform> parseFixData(
  String text, {
  required String file,
  required Uri base,
}) {
  final YamlNode root;
  try {
    root = loadYamlNode(text);
  } on YamlException catch (error) {
    final span = error.span;
    throw FixDataFormatException(
      file,
      span == null ? null : span.start.line + 1,
      'is not valid YAML: ${error.message}',
    );
  }
  if (root is YamlScalar && root.value == null) return const [];
  if (root is! YamlMap) {
    throw FixDataFormatException(
      file,
      _lineOf(root),
      'must be a map with a "transforms" list.',
    );
  }
  final transforms = root.nodes['transforms'];
  if (transforms == null ||
      (transforms is YamlScalar && transforms.value == null)) {
    return const [];
  }
  if (transforms is! YamlList) {
    throw FixDataFormatException(
      file,
      _lineOf(transforms),
      '"transforms" must be a list.',
    );
  }
  try {
    return [for (final node in transforms.nodes) _transform(node, file, base)];
  } on FormatException catch (error) {
    // A URI that Uri.parse rejects.
    throw FixDataFormatException(
      file,
      null,
      'has an invalid URI: ${error.message}',
    );
  }
}

FixDataTransform _transform(YamlNode node, String file, Uri base) {
  FixDataFormatException error(YamlNode at, String problem) =>
      FixDataFormatException(file, _lineOf(at), problem);
  if (node is! YamlMap) throw error(node, 'Each transform must be a map.');
  final title = node.nodes['title'];
  if (title is! YamlScalar || title.value is! String) {
    throw error(node, 'A transform needs a "title" string.');
  }
  final changes = _changes(node);
  final library = node.nodes['library'];
  if (library != null) {
    if (library is! YamlScalar || library.value is! String) {
      throw error(library, '"library" must be a URI string.');
    }
    Uri? newLibrary;
    for (final change in changes) {
      if (change['kind'] == 'replacedBy' && change['newLibrary'] is String) {
        newLibrary = _resolve(change['newLibrary'] as String, base);
      }
    }
    return FixDataTransform(
      title: title.value as String,
      library: _resolve(library.value as String, base),
      newLibrary: newLibrary,
    );
  }
  final element = node.nodes['element'];
  if (element is! YamlMap) {
    throw error(node, 'A transform needs an "element" map or a "library".');
  }
  final uris = element.nodes['uris'];
  if (uris is! YamlList ||
      uris.nodes.isEmpty ||
      uris.nodes.any((uri) => uri is! YamlScalar || uri.value is! String)) {
    throw error(element, '"uris" must be a list of URI strings.');
  }
  final kinds = [
    for (final key in element.keys)
      if (key is String && fixDataElementKinds.contains(key)) key,
  ];
  if (kinds.length != 1) {
    throw error(
      element,
      'The element must name exactly one of: '
      '${(fixDataElementKinds.toList()..sort()).join(', ')}.',
    );
  }
  final kind = kinds.single;
  final name = element[kind];
  if (name is! String) throw error(element, '"$kind" must be a string.');
  final containers = <String>[];
  for (final key in _containerKeys) {
    if (!element.containsKey(key)) continue;
    final value = element[key];
    if (value is! String) throw error(element, '"$key" must be a string.');
    containers.add(value);
  }
  if (containers.length > 1) {
    throw error(
      element,
      'The element may have only one of ${_containerKeys.join(', ')}.',
    );
  }
  return FixDataTransform(
    title: title.value as String,
    uris: {
      for (final uri in uris.nodes)
        _resolve((uri as YamlScalar).value as String, base),
    }.toList(),
    kind: kind,
    name: name,
    container: containers.firstOrNull,
    oldParameters: {
      for (final change in changes)
        if (change['kind'] == 'removeParameter' && change['name'] is String)
          change['name'] as String
        else if (change['kind'] == 'renameParameter' &&
            change['oldName'] is String)
          change['oldName'] as String,
    },
  );
}

/// The transform's changes, with those of each `oneOf` option.
List<YamlMap> _changes(YamlMap transform) => [
  ...?_maps(transform.nodes['changes']),
  if (transform.nodes['oneOf'] case final YamlList options)
    for (final option in options.nodes)
      if (option is YamlMap) ...?_maps(option.nodes['changes']),
];

List<YamlMap>? _maps(YamlNode? node) =>
    node is YamlList ? node.nodes.whereType<YamlMap>().toList() : null;

Uri _resolve(String uri, Uri base) =>
    uri.contains(':') ? Uri.parse(uri) : base.resolve(uri);

int _lineOf(YamlNode node) => node.span.start.line + 1;
