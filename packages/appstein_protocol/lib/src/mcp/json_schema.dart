/// Builders for the JSON Schema of the MCP tools' input and output
/// (spec §8). They return plain maps, so the protocol package needs no MCP
/// library; the engine wraps them for `package:dart_mcp`.
///
/// No schema allows null: a reply leaves an absent value out
/// ([withoutNulls] in `tool_output.dart`), so optional fields are simply not
/// [jsonObject]'s `required`.
library;

/// An object with [properties], of which [required] must be present.
Map<String, Object?> jsonObject(
  Map<String, Map<String, Object?>> properties, {
  List<String> required = const [],
  String? description,
}) => {
  'type': 'object',
  'description': ?description,
  'properties': properties,
  if (required.isNotEmpty) 'required': required,
};

/// A string, one of [values] when they are given.
Map<String, Object?> jsonString({String? description, List<String>? values}) =>
    {'type': 'string', 'description': ?description, 'enum': ?values};

/// An integer.
Map<String, Object?> jsonInteger({String? description}) => {
  'type': 'integer',
  'description': ?description,
};

/// A boolean.
Map<String, Object?> jsonBoolean({String? description}) => {
  'type': 'boolean',
  'description': ?description,
};

/// A list of [items].
Map<String, Object?> jsonList(
  Map<String, Object?> items, {
  String? description,
}) => {'type': 'array', 'description': ?description, 'items': items};
