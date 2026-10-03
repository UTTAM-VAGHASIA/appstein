import 'json_schema.dart';

/// The input schemas of Appstein's MCP tools and the schemas of their
/// results (spec §8). A tool's full output schema is its result schema
/// with `summary` and `freshness` added (`toolOutputSchema`).
abstract final class ToolSchemas {
  /// The input of a tool that takes no arguments.
  static final Map<String, Object?> noInput = jsonObject({});

  /// `where_is`'s input.
  static final Map<String, Object?> whereIsInput = jsonObject(
    {
      'query': jsonString(
        description:
            'Free text, such as "login screen" or "booking '
            'repository".',
      ),
    },
    required: ['query'],
  );

  /// `where_is`'s result.
  static final Map<String, Object?> whereIsResult = jsonObject(
    {
      'query': jsonString(),
      'total': jsonInteger(
        description: 'How many candidates matched; at most 10 are listed.',
      ),
      'matches': jsonList(
        jsonObject(
          {
            'kind': jsonString(values: ['symbol', 'route', 'feature', 'file']),
            'name': jsonString(),
            'score': jsonInteger(),
            'reasons': jsonList(jsonString()),
            'file': jsonString(),
            'line': jsonInteger(),
            'layer': jsonString(),
            'feature': jsonString(),
            'summary': jsonString(),
          },
          required: ['kind', 'name', 'score', 'reasons'],
        ),
      ),
    },
    required: ['query', 'total', 'matches'],
  );
}
