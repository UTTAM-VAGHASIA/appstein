import '../decisions/decision_record.dart';
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
            'redirectsTo': jsonObject(
              {
                'path': jsonString(),
                'screen': _codeRef,
                'feature': jsonString(),
                'redirect': jsonBoolean(
                  description:
                      'Present and true when the route at that path has a '
                      'redirect of its own.',
                ),
                'file': jsonString(),
                'line': jsonInteger(),
              },
              required: ['path'],
              description:
                  'Where the route redirects to, when the map knows: the '
                  'path, and the screen and feature of the route at that '
                  'path. When that route redirects too, `file` and `line` '
                  'say where to read it.',
            ),
            'redirectHint': jsonString(
              description:
                  'The file and line to read when the route redirects and '
                  'the map does not know where to.',
            ),
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
      'redirectNote': jsonString(
        description:
            'Present when a router has its own redirect: where to read it.',
      ),
    },
    required: ['path', 'match', 'routes', 'routerRedirects'],
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
          'list its deprecated, removed, changed and moved APIs in full.',
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

  static final Map<String, Object?> _decision = jsonObject(
    {
      'number': jsonString(description: 'Such as `0002`.'),
      'title': jsonString(),
      'status': jsonString(
        values: ['proposed', 'accepted', 'superseded'],
        description:
            'Only an accepted decision binds. A decision that a later one '
            'replaces is superseded, whatever its file says.',
      ),
      'statusInFile': jsonString(
        description:
            "Present when the file's own status line differs from `status`.",
      ),
      'date': jsonString(),
      'why': jsonString(description: 'The reason for the decision.'),
      'paths': jsonList(
        jsonString(),
        description: 'The path patterns it applies to; empty: everywhere.',
      ),
      'checks': jsonList(jsonString()),
      'file': jsonString(description: 'Its file, from the project folder.'),
      'supersedes': jsonString(),
      'supersededBy': jsonString(),
      'score': jsonInteger(),
    },
    required: ['title', 'status', 'why', 'paths', 'checks', 'file'],
  );

  /// `decisions`' input.
  static final Map<String, Object?> decisionsInput = jsonObject({
    'topic': jsonString(
      description:
          'Words, such as "state management", or the path of a project '
          'file, such as `lib/ui/home/widgets/home_screen.dart`. Leave it '
          'out for every decision in force.',
    ),
  });

  /// `decisions`' result.
  static final Map<String, Object?> decisionsResult = jsonObject(
    {
      'mode': jsonString(values: ['all', 'words', 'path']),
      'topic': jsonString(),
      'decisions': jsonList(_decision),
      'superseded': jsonInteger(
        description: 'How many decisions are superseded.',
      ),
      'withoutPaths': jsonInteger(
        description:
            'For a path: how many decisions in force list no paths, so '
            'apply everywhere.',
      ),
      'unreadable': jsonList(
        jsonObject(
          {'file': jsonString(), 'problem': jsonString()},
          required: ['file', 'problem'],
        ),
      ),
      'duplicates': jsonList(
        jsonObject(
          {'number': jsonString(), 'files': jsonList(jsonString())},
          required: ['number', 'files'],
        ),
        description: 'Numbers that more than one file uses.',
      ),
      'problems': jsonList(jsonString()),
    },
    required: [
      'mode',
      'decisions',
      'superseded',
      'unreadable',
      'duplicates',
      'problems',
    ],
  );

  /// `record_decision`'s input: the fields of a new decision, or `accept`
  /// alone.
  static final Map<String, Object?> recordDecisionInput = jsonObject({
    'title': jsonString(description: 'One line: what was decided.'),
    'why': jsonString(description: 'The reason.'),
    'status': jsonString(
      values: ['proposed', 'accepted'],
      description:
          '`proposed` when left out. `accepted` only when the user agreed '
          'to this decision in this conversation.',
    ),
    'paths': jsonList(
      jsonString(),
      description:
          'The path patterns it applies to, from the project folder, such '
          'as `lib/ui/**/view_models/**`.',
    ),
    'checks': jsonList(jsonString(values: decisionChecks)),
    // No `type`: agents write a number as `"0002"`, `"2"` or `2`, and a
    // type array is not something every client's schema checker handles.
    'supersedes': {
      'description':
          'The number of the decision this one replaces, such as "0002" '
          'or 2.',
    },
    'accept': {
      'description':
          'The number of a proposed decision the user now agrees to, such '
          'as "0003" or 3. Pass it alone.',
    },
  });

  /// `record_decision`'s result.
  static final Map<String, Object?> recordDecisionResult = jsonObject(
    {
      'action': jsonString(values: ['added', 'replaced', 'accepted']),
      'decision': _decision,
      'superseded': _decision,
      'warning': jsonString(),
    },
    required: ['action', 'decision'],
  );

  /// `memory_read`'s result.
  static final Map<String, Object?> memoryReadResult = jsonObject(
    {
      'current': jsonString(
        description: 'The task in progress; absent when there is none.',
      ),
      'currentFile': jsonString(),
      'currentProblem': jsonString(),
      'lessons': jsonList(
        jsonString(),
        description: 'The newest lessons, oldest first.',
      ),
      'olderLessons': jsonInteger(
        description: 'How many older lessons the file also holds.',
      ),
      'lessonsFile': jsonString(),
      'lessonsProblem': jsonString(),
    },
    required: ['currentFile', 'lessons', 'olderLessons', 'lessonsFile'],
  );

  /// `memory_write`'s input.
  static final Map<String, Object?> memoryWriteInput = jsonObject(
    {
      'kind': jsonString(
        values: ['current', 'lesson', 'complete'],
        description:
            '`current` replaces the task in progress; `lesson` adds one '
            'lesson; `complete` finishes the task.',
      ),
      'text': jsonString(
        description:
            'For `current`: the goal, plan, status and open questions. For '
            '`lesson`: the lesson. For `complete`: your one-paragraph '
            'summary of the finished task.',
      ),
    },
    required: ['kind', 'text'],
  );

  /// `memory_write`'s result.
  static final Map<String, Object?> memoryWriteResult = jsonObject(
    {
      'kind': jsonString(values: ['current', 'lesson', 'complete']),
      'file': jsonString(description: 'The file that was written.'),
      'lesson': jsonString(description: 'The lesson line.'),
      'added': jsonBoolean(
        description: 'False when the file already held this lesson.',
      ),
      'cleared': jsonString(description: 'The file that was deleted.'),
    },
    required: ['kind', 'file'],
  );

  /// `verify`'s input.
  static final Map<String, Object?> verifyInput = jsonObject(
    {
      'scope': jsonString(
        values: ['fast', 'full'],
        description:
            '`fast` after a change; `full` before you say the task is done.',
      ),
    },
    required: ['scope'],
  );

  /// `verify`'s result: what `appstein verify --format json` prints (spec
  /// §9.3). Its `summary` is the counts, so the tool's output keeps it
  /// (`toolOutputSchema`).
  static final Map<String, Object?> verifyResult = jsonObject(
    {
      'findings': jsonList(
        jsonObject(
          {
            'id': jsonString(description: 'The check, such as `docs.stale`.'),
            'severity': jsonString(
              values: ['error', 'warning', 'info'],
              description:
                  'An error blocks "done"; a warning or info is reported '
                  'only.',
            ),
            'file': jsonString(
              description:
                  'From the project folder; absent when the finding is '
                  'about the whole project.',
            ),
            'line': jsonInteger(),
            'message': jsonString(),
            'fixHint': jsonString(),
            'knowledgeRef': jsonString(),
            'pack': jsonString(),
            'docs': jsonString(),
          },
          required: ['id', 'severity', 'message'],
        ),
      ),
      'summary': jsonObject(
        {
          'errors': jsonInteger(),
          'warnings': jsonInteger(),
          'info': jsonInteger(),
        },
        required: ['errors', 'warnings', 'info'],
      ),
      'suppressed': jsonInteger(
        description: 'How many findings a suppression in appstein.yaml hid.',
      ),
      'activeSuppressions': jsonInteger(
        description: 'How many suppressions hid at least one finding.',
      ),
      'notRun': jsonList(
        jsonObject(
          {'id': jsonString(), 'reason': jsonString()},
          required: ['id', 'reason'],
        ),
        description: 'The checks that could not run, and why.',
      ),
    },
    required: [
      'findings',
      'summary',
      'suppressed',
      'activeSuppressions',
      'notRun',
    ],
  );
}
