import '../json_fields.dart';

/// One project file in `layers.json`.
final class MapFileEntry {
  /// Creates an entry.
  const MapFileEntry({this.layer, this.feature, required this.imports});

  factory MapFileEntry._read(JsonFields fields) => MapFileEntry(
    layer: fields.optionalString('layer'),
    feature: fields.optionalString('feature'),
    imports: fields.strings('imports'),
  );

  /// The file's layer tag, or null when no glob matches it.
  final String? layer;

  /// The feature the file belongs to, if any.
  final String? feature;

  /// The project files it imports or exports, sorted.
  final List<String> imports;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'layer': layer,
    'feature': feature,
    'imports': imports,
  };
}

/// An import that the layer rules forbid (spec §9.6).
final class LayerViolation {
  /// Creates a violation.
  const LayerViolation({
    required this.file,
    required this.line,
    required this.import,
    required this.from,
    required this.to,
  });

  factory LayerViolation._read(JsonFields fields) => LayerViolation(
    file: fields.string('file'),
    line: fields.integer('line'),
    import: fields.string('import'),
    from: fields.string('from'),
    to: fields.string('to'),
  );

  /// The importing file.
  final String file;

  /// The 1-based line of the import's URI.
  final int line;

  /// The imported file.
  final String import;

  /// The importing file's layer.
  final String from;

  /// The imported file's layer.
  final String to;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'file': file,
    'line': line,
    'import': import,
    'from': from,
    'to': to,
  };
}

/// The contents of `map/layers.json`.
final class LayersMap {
  /// Creates the map. [violations] are sorted by file, then line, then
  /// import.
  const LayersMap({required this.files, required this.violations});

  /// Reads the map from its JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory LayersMap.fromJson(Map<String, Object?> json) {
    final fields = JsonFields('layers.json', json);
    return LayersMap(
      files: {
        for (final MapEntry(:key, :value) in fields.objectMap('files').entries)
          key: MapFileEntry._read(value),
      },
      violations: [
        for (final v in fields.objects('violations')) LayerViolation._read(v),
      ],
    );
  }

  /// Every analyzed file, by its project-relative path.
  final Map<String, MapFileEntry> files;

  /// The forbidden imports.
  final List<LayerViolation> violations;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'files': {
      for (final MapEntry(:key, :value) in files.entries) key: value.toJson(),
    },
    'violations': [for (final v in violations) v.toJson()],
  };
}
