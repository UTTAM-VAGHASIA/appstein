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

  static final Map<String, Object?> _codeRef = jsonObject(
    {'name': jsonString(), 'file': jsonString()},
    required: ['name', 'file'],
  );

  /// `feature`'s input.
  static final Map<String, Object?> featureInput = jsonObject(
    {
      'name': jsonString(
        description:
            'The feature: its folder below lib/ui/, such as '
            '`auth/login`.',
      ),
    },
    required: ['name'],
  );

  /// `feature`'s result.
  static final Map<String, Object?> featureResult = jsonObject(
    {
      'name': jsonString(),
      'folder': jsonString(),
      'viewModels': jsonList(_codeRef),
      'screens': jsonList(_codeRef),
      'repositories': jsonList(_codeRef),
      'services': jsonList(_codeRef),
      'models': jsonList(_codeRef),
      'tests': jsonList(jsonString()),
      'files': jsonList(jsonString()),
      'routes': jsonList(
        jsonObject(
          {
            'path': jsonString(),
            'file': jsonString(),
            'line': jsonInteger(),
            'screen': jsonString(),
            'unresolved': jsonBoolean(),
            'reason': jsonString(),
          },
          required: ['file', 'line', 'screen'],
        ),
      ),
    },
    required: [
      'name',
      'folder',
      'viewModels',
      'screens',
      'repositories',
      'services',
      'models',
      'tests',
      'files',
      'routes',
    ],
  );

  /// `route`'s input.
  static final Map<String, Object?> routeInput = jsonObject(
    {
      'path': jsonString(
        description:
            'A path, such as `/booking/42`; it may match a pattern '
            'such as `/booking/:id`.',
      ),
    },
    required: ['path'],
  );

  /// `route`'s result.
  static final Map<String, Object?> routeResult = jsonObject(
    {
      'path': jsonString(),
      'match': jsonString(values: ['exact', 'pattern']),
      'routes': jsonList(
        jsonObject(
          {
            'path': jsonString(),
            'name': jsonString(),
            'screen': _codeRef,
            'feature': jsonString(),
            'parent': jsonString(),
            'children': jsonList(jsonString()),
            'unresolvedChildren': jsonInteger(),
            'redirect': jsonBoolean(),
            'file': jsonString(),
            'line': jsonInteger(),
            'unresolved': jsonBoolean(),
            'reason': jsonString(),
          },
          required: [
            'path',
            'children',
            'unresolvedChildren',
            'redirect',
            'file',
            'line',
          ],
        ),
      ),
      'routerRedirects': jsonBoolean(),
      'redirectNote': jsonString(),
    },
    required: ['path', 'match', 'routes', 'routerRedirects', 'redirectNote'],
  );
}
