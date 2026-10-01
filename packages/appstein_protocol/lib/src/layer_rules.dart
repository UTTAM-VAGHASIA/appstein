/// Which layer may import which, as declared by a stack pack (spec §9.6).
///
/// It is written into a project's `analysis_options.yaml` as a top-level
/// `appstein_lints:` section and read by the `layer_imports` lint rule.
/// `appstein sync` applies the same rules to `.appstein/map/layers.json`.
///
/// ```yaml
/// appstein_lints:
///   layers:          # tag: path globs, relative to analysis_options.yaml
///     ui: [lib/ui/**]
///     domain: [lib/domain/**]
///     data.repository: [lib/data/repositories/**]
///   allow:           # tag: the other tags it may import
///     ui: [domain]
///     domain: []
///   interfaces:      # tag: the tags whose interface files it may import
///     ui: [data.repository]
/// ```
///
/// A file gets the first tag, in declaration order, whose globs match it. A
/// layer may always import itself. A tag with no `allow` entry is
/// unrestricted. An interface file is one whose classes are all abstract,
/// such as a repository's interface; its implementation is not one.
final class LayerRules {
  /// Creates layer rules. Prefer [LayerRules.fromJson], which validates.
  const LayerRules({
    required this.layers,
    required this.allow,
    this.interfaces = const {},
  });

  /// Parses and validates an `appstein_lints:` section.
  ///
  /// Throws a [FormatException] whose message is written for the person
  /// editing the file.
  factory LayerRules.fromJson(Object? json) {
    if (json is! Map<Object?, Object?>) {
      throw const FormatException(
        'appstein_lints must be a map with "layers" and "allow".',
      );
    }
    for (final key in json.keys) {
      if (key != 'layers' && key != 'allow' && key != 'interfaces') {
        throw FormatException(
          'Unknown key "$key" in appstein_lints. '
          'Allowed: layers, allow, interfaces.',
        );
      }
    }
    final layers = _stringListMap(json['layers'], 'layers');
    for (final MapEntry(key: tag, value: globs) in layers.entries) {
      if (!_tagPattern.hasMatch(tag)) {
        throw FormatException(
          'Layer tag "$tag" is not valid. Use lowercase '
          'words separated by dots, like "data.repository".',
        );
      }
      if (globs.isEmpty) {
        throw FormatException('Layer "$tag" needs at least one path glob.');
      }
    }
    return LayerRules(
      layers: layers,
      allow: _targets(json['allow'], 'allow', layers),
      interfaces: _targets(json['interfaces'], 'interfaces', layers),
    );
  }

  static final _tagPattern = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$');

  /// Reads an `allow`- or `interfaces`-shaped section: every key and every
  /// listed tag must be declared under [layers].
  static Map<String, List<String>> _targets(
    Object? value,
    String name,
    Map<String, List<String>> layers,
  ) {
    final targets = _stringListMap(value, name);
    for (final MapEntry(key: tag, value: listed) in targets.entries) {
      if (!layers.containsKey(tag)) {
        throw FormatException('$name: "$tag" is not declared under layers.');
      }
      for (final target in listed) {
        if (!layers.containsKey(target)) {
          throw FormatException(
            '$name: "$tag" lists "$target", which is '
            'not declared under layers.',
          );
        }
      }
    }
    return targets;
  }

  static Map<String, List<String>> _stringListMap(Object? value, String name) {
    if (value == null) return const {};
    if (value is! Map<Object?, Object?>) {
      throw FormatException('appstein_lints.$name must be a map.');
    }
    final result = <String, List<String>>{};
    for (final MapEntry(:key, value: list) in value.entries) {
      if (key is! String) {
        throw FormatException(
          'appstein_lints.$name: every key must be a string.',
        );
      }
      if (list is! List<Object?> ||
          list.any((item) => item is! String || item.isEmpty)) {
        throw FormatException(
          'appstein_lints.$name.$key must be a list of non-empty strings.',
        );
      }
      result[key] = List.unmodifiable(list.cast<String>());
    }
    return Map.unmodifiable(result);
  }

  /// Layer tag → path globs, in match order.
  final Map<String, List<String>> layers;

  /// Layer tag → the other tags it may import.
  final Map<String, List<String>> allow;

  /// Layer tag → the tags whose interface files it may import, though it
  /// may not import their other files.
  final Map<String, List<String>> interfaces;

  /// Whether code in [fromTag] may import a file in [toTag].
  /// [interfaceOnly] says whether that file is an interface file (all of
  /// its classes are abstract), which [interfaces] may allow.
  bool mayImport(String fromTag, String toTag, {bool interfaceOnly = false}) {
    if (fromTag == toTag) return true;
    final allowed = allow[fromTag];
    if (allowed == null || allowed.contains(toTag)) return true;
    return interfaceOnly && (interfaces[fromTag]?.contains(toTag) ?? false);
  }

  /// What [fromTag] may import, in words, for messages: "ui, domain, and
  /// the interfaces of data.repository", or "any layer".
  String describeAllowed(String fromTag) {
    final allowed = allow[fromTag];
    if (allowed == null) return 'any layer';
    final tags = [fromTag, ...allowed].join(', ');
    final viaInterfaces = interfaces[fromTag] ?? const [];
    return viaInterfaces.isEmpty
        ? tags
        : '$tags, and the interfaces of ${viaInterfaces.join(', ')}';
  }

  /// The JSON form, which is also the YAML form. An empty [interfaces]
  /// section is left out.
  Map<String, Object?> toJson() => {
    'layers': layers,
    'allow': allow,
    if (interfaces.isNotEmpty) 'interfaces': interfaces,
  };
}
