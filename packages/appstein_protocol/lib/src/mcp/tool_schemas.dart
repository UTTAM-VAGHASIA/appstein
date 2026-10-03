import 'json_schema.dart';

/// The input schemas of Appstein's MCP tools and the schemas of their
/// results (spec §8). A tool's full output schema is its result schema
/// with `summary` and `freshness` added (`toolOutputSchema`).
abstract final class ToolSchemas {
  /// The input of a tool that takes no arguments.
  static final Map<String, Object?> noInput = jsonObject({});

  /// `overview`'s result.
  static final Map<String, Object?> overviewResult = jsonObject(
    {
      'index': jsonString(
        description: "The project's INDEX.md, without its front matter.",
      ),
      'generatedAt': jsonString(),
    },
    required: ['index', 'generatedAt'],
  );

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

  static final Map<String, Object?> _note = jsonObject(
    {
      'id': jsonString(),
      'since': jsonString(),
      'languageVersion': jsonString(),
      'priority': jsonInteger(),
      'area': jsonString(),
      'summary': jsonString(),
      'use': jsonString(),
      'avoid': jsonString(),
      'source': jsonString(),
    },
    required: [
      'id',
      'since',
      'priority',
      'area',
      'summary',
      'use',
      'avoid',
      'source',
    ],
  );

  /// `check_api`'s input.
  static final Map<String, Object?> checkApiInput = jsonObject(
    {
      'name': jsonString(
        description:
            'An API name: `WillPopScope`, `withOpacity`, '
            '`Color.withOpacity` or `Text.new(textScaleFactor)`.',
      ),
    },
    required: ['name'],
  );

  /// `check_api`'s result.
  static final Map<String, Object?> checkApiResult = jsonObject(
    {
      'name': jsonString(),
      'status': jsonString(values: ['ok', 'deprecated', 'removed']),
      'matches': jsonList(
        jsonObject(
          {
            'kind': jsonString(
              values: ['deprecated', 'removed', 'changed', 'moved', 'note'],
            ),
            'library': jsonString(),
            'name': jsonString(),
            'deprecationKind': jsonString(),
            'rule': jsonString(),
            'message': jsonString(),
            'migrations': jsonList(jsonString()),
            'migration': jsonString(),
            'to': jsonString(),
            'parameter': jsonBoolean(),
            'id': jsonString(),
            'summary': jsonString(),
            'use': jsonString(),
            'avoid': jsonString(),
            'source': jsonString(),
          },
          required: ['kind'],
        ),
      ),
      'meaning': jsonString(),
      'incomplete': jsonString(),
    },
    required: ['name', 'status', 'matches'],
  );

  /// `what_changed`'s input.
  static final Map<String, Object?> whatChangedInput = jsonObject({
    'since': jsonString(
      description: 'A Flutter version, such as `3.27`: only notes since it.',
    ),
    'library': jsonString(
      description:
          'A library, such as `package:go_router` or `dart:core`: '
          'list its deprecated, removed and moved APIs in full.',
    ),
  });

  /// `what_changed`'s result.
  static final Map<String, Object?> whatChangedResult = jsonObject(
    {
      'flutterVersion': jsonString(),
      'coverage': jsonString(values: ['complete', 'partial']),
      'notesFrom': jsonString(),
      'notes': jsonList(_note),
      'laterNotes': jsonList(_note),
      'libraries': jsonList(
        jsonObject(
          {
            'library': jsonString(),
            'deprecated': jsonInteger(),
            'removed': jsonInteger(),
            'changed': jsonInteger(),
            'moved': jsonInteger(),
          },
          required: ['library', 'deprecated', 'removed', 'changed', 'moved'],
        ),
      ),
      'library': jsonObject(
        {
          'library': jsonString(),
          'deprecated': jsonList(jsonObject({})),
          'migrated': jsonList(jsonObject({})),
          'moved': jsonList(jsonObject({})),
        },
        required: ['library', 'deprecated', 'migrated', 'moved'],
      ),
      'unread': jsonList(
        jsonObject(
          {'file': jsonString(), 'reason': jsonString()},
          required: ['file', 'reason'],
        ),
      ),
      'apiListsMissing': jsonString(),
    },
    required: [
      'flutterVersion',
      'coverage',
      'notesFrom',
      'notes',
      'laterNotes',
      'libraries',
      'unread',
    ],
  );

  /// `toolchain`'s result.
  static final Map<String, Object?> toolchainResult = jsonObject(
    {
      'valid': jsonObject(
        {},
        description:
            'The native versions that work with this Flutter: '
            '`toolchain.json` without its notes.',
      ),
      'notes': jsonList(_note),
      'current': jsonList(
        jsonObject(
          {
            'name': jsonString(),
            'status': jsonString(
              values: ['found', 'unknown', 'absent', 'error'],
            ),
            'value': jsonString(),
            'at': jsonString(),
            'expression': jsonString(),
            'reason': jsonString(),
          },
          required: ['name', 'status'],
        ),
      ),
      'mismatches': jsonList(
        jsonObject(
          {
            'name': jsonString(),
            'severity': jsonString(values: ['error', 'warning']),
            'value': jsonString(),
            'limit': jsonString(),
            'message': jsonString(),
            'at': jsonString(),
          },
          required: ['name', 'severity', 'value', 'limit', 'message'],
        ),
      ),
      'notComparable': jsonList(
        jsonObject(
          {'name': jsonString(), 'reason': jsonString()},
          required: ['name', 'reason'],
        ),
      ),
    },
    required: ['valid', 'notes', 'current', 'mismatches', 'notComparable'],
  );
}
