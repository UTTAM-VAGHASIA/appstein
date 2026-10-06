import 'freshness_report.dart';
import 'json_schema.dart';

/// [json] without null values: in maps, keys whose value is null are left
/// out; in lists, null items are. Applies at any depth. MCP replies use it,
/// so their schemas never allow null (spec §8).
Object? withoutNulls(Object? json) => switch (json) {
  final Map<String, Object?> map => <String, Object?>{
    for (final MapEntry(:key, :value) in map.entries)
      if (value != null) key: withoutNulls(value),
  },
  final List<Object?> list => [
    for (final item in list)
      if (item != null) withoutNulls(item),
  ],
  _ => json,
};

/// The output schema of a tool whose result has the schema [result]: the
/// result's fields plus `summary` and `freshness`, which every reply has
/// (spec §8). Claude Code shows the model only the structured result, so
/// the summary lives inside it.
///
/// A result that has a `summary` of its own keeps it: `verify`'s is its
/// counts (spec §9.3), and its sentence is in the reply's text only.
Map<String, Object?> toolOutputSchema(Map<String, Object?> result) {
  final properties = result['properties']! as Map<String, Object?>;
  final required = [...?(result['required'] as List<Object?>?)?.cast<String>()];
  return {
    ...result,
    'properties': {
      ...properties,
      if (!properties.containsKey('summary'))
        'summary': jsonString(description: 'The answer in a sentence or two.'),
      'freshness': FreshnessReport.schema,
    },
    'required': [
      ...required,
      if (!required.contains('summary')) 'summary',
      'freshness',
    ],
  };
}
