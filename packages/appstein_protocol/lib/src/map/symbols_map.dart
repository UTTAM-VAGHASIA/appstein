import '../json_fields.dart';

/// What kind of declaration a symbol is.
enum SymbolKind {
  /// A class, including a mixin application (`class A = B with C;`).
  classKind('class'),

  /// A mixin.
  mixinKind('mixin'),

  /// An enum.
  enumKind('enum'),

  /// A named extension.
  extension('extension'),

  /// An extension type.
  extensionType('extensionType'),

  /// A typedef.
  typedef('typedef'),

  /// A top-level function.
  function('function');

  const SymbolKind(this.jsonName);

  /// The kind's name in `symbols.json`.
  final String jsonName;
}

/// One public top-level declaration in `lib/` (spec §6.5).
final class MapSymbol {
  /// Creates a symbol.
  const MapSymbol({
    required this.name,
    required this.kind,
    required this.file,
    required this.line,
    this.layer,
    this.feature,
    this.summary,
  });

  factory MapSymbol._read(JsonFields fields) {
    final kindName = fields.string('kind');
    final kind = SymbolKind.values.where((k) => k.jsonName == kindName);
    if (kind.isEmpty) {
      throw FormatException('${fields.file}: unknown symbol kind "$kindName".');
    }
    return MapSymbol(
      name: fields.string('name'),
      kind: kind.single,
      file: fields.string('file'),
      line: fields.integer('line'),
      layer: fields.optionalString('layer'),
      feature: fields.optionalString('feature'),
      summary: fields.optionalString('summary'),
    );
  }

  /// The declared name.
  final String name;

  /// What kind of declaration it is.
  final SymbolKind kind;

  /// Its file, relative to the project, with `/`.
  final String file;

  /// The 1-based line of its name.
  final int line;

  /// Its file's layer tag, if the stack pack's rules give it one.
  final String? layer;

  /// The feature its file belongs to, if any.
  final String? feature;

  /// The first sentence of its doc comment, if it has one.
  final String? summary;

  /// The JSON form. Null fields are written as `null`, so every symbol has
  /// the same keys.
  Map<String, Object?> toJson() => {
    'name': name,
    'kind': kind.jsonName,
    'file': file,
    'line': line,
    'layer': layer,
    'feature': feature,
    'summary': summary,
  };
}

/// The contents of `map/symbols.json`.
final class SymbolsMap {
  /// Creates the map. [symbols] are sorted by file, then line, then name.
  const SymbolsMap({required this.symbols});

  /// Reads the map from its JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory SymbolsMap.fromJson(Map<String, Object?> json) => SymbolsMap(
    symbols: [
      for (final symbol in JsonFields('symbols.json', json).objects('symbols'))
        MapSymbol._read(symbol),
    ],
  );

  /// The symbols.
  final List<MapSymbol> symbols;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'symbols': [for (final symbol in symbols) symbol.toJson()],
  };
}
