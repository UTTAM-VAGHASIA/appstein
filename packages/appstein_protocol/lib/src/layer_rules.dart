/// Which layer may import which, as declared by a stack pack (spec §9.6).
///
/// It is written into a project's `analysis_options.yaml` as a top-level
/// `appstein_lints:` section, and read by the `layer_imports` lint rule:
///
/// ```yaml
/// appstein_lints:
///   layers:          # tag: path globs, relative to analysis_options.yaml
///     ui: [lib/ui/**]
///     domain: [lib/domain/**]
///   allow:           # tag: the other tags it may import
///     ui: [domain]
///     domain: []
/// ```
///
/// A file gets the first tag, in declaration order, whose globs match it. A
/// layer may always import itself. A tag with no `allow` entry is
/// unrestricted.
final class LayerRules {
  /// Creates layer rules. Prefer [LayerRules.fromJson], which validates.
  const LayerRules({required this.layers, required this.allow});

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
      if (key != 'layers' && key != 'allow') {
        throw FormatException(
          'Unknown key "$key" in appstein_lints. Allowed: layers, allow.',
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
    final allow = _stringListMap(json['allow'], 'allow');
    for (final MapEntry(key: tag, value: targets) in allow.entries) {
      if (!layers.containsKey(tag)) {
        throw FormatException('allow: "$tag" is not declared under layers.');
      }
      for (final target in targets) {
        if (!layers.containsKey(target)) {
          throw FormatException(
            'allow: "$tag" lists "$target", which is '
            'not declared under layers.',
          );
        }
      }
    }
    return LayerRules(layers: layers, allow: allow);
  }

  static final _tagPattern = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$');

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

  /// Whether code in [fromTag] may import code in [toTag].
  bool mayImport(String fromTag, String toTag) {
    if (fromTag == toTag) return true;
    final allowed = allow[fromTag];
    return allowed == null || allowed.contains(toTag);
  }

  /// The JSON form, which is also the YAML form.
  Map<String, Object?> toJson() => {'layers': layers, 'allow': allow};
}
