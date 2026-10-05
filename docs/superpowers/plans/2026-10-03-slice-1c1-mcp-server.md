# Slice 1c.1: MCP Server and Read Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `appstein mcp` serves seven read tools over stdio (`overview`, `where_is`, `feature`, `route`, `check_api`, `what_changed`, `toolchain`), each checking that the knowledge is fresh before it answers, and it works from Claude Code on a fixture.

**Architecture:** `sync` also writes `.appstein/platform/delta.json`, the delta as data. A new engine folder `packages/appstein_engine/lib/src/mcp/` holds a lazy reader of the knowledge files (`KnowledgeSnapshot`), one pure query function per tool (no MCP code, so 1d can reuse them), and `AppsteinMcpServer`, a `package:dart_mcp` server that answers one call at a time: it runs `KnowledgeSync.detect` in process (package skills off, analyzer cache kept in memory), runs the query, and returns structured JSON whose `summary` and `freshness` fields say what happened. The output schemas live in `appstein_protocol`. The CLI adds `appstein mcp`, which re-reads `appstein.yaml` on every call and chooses the packs.

**Tech Stack:** Dart 3.13 (Flutter 3.47.5 via FVM), `package:dart_mcp` 0.5.2 (pinned exactly), `package:stream_channel`, `package:test`, the engine's `KnowledgeSync`, `KnowledgeLock` and protocol models.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md` §8 (as edited in `9e311bf`, plus the `what_changed` row edited with this plan), §6.2 (`delta.json`), §6.4 (deprecation kinds), §15 (MCP responses under 1 s from fresh knowledge, measured in CI).

## Global Constraints

- Every Dart command goes through FVM: `fvm dart …`, `fvm flutter …`. Run each package's suite from inside its folder (`cd packages/appstein_engine && fvm dart test`), never `fvm dart test packages/x` from the root.
- `dart_mcp` is pinned exactly: `dart_mcp: 0.5.2`, like `analyzer: 14.4.0`.
- Boundaries (spec §5.1): `appstein_protocol` depends on nothing internal and gets no `dart_mcp` dependency (its schemas are plain `Map<String, Object?>` JSON Schema). The engine core never imports a pack; the CLI chooses the packs.
- stdout carries MCP protocol messages only. Nothing in the server path may `print` or write to `stdout`.
- Every tool reply is a `CallToolResult` with `structuredContent` that matches the tool's `outputSchema` and holds `summary` and `freshness`, plus two text blocks (the summary, then the JSON). A refusal (bad input, missing knowledge) is `isError: true` with one text block and no `structuredContent`. Structured content never holds `null`: absent values are absent keys (`withoutNulls`).
- Tool calls are answered one at a time (an in-process queue), so two calls never sync at once in the same process.
- The server's sync never runs package skills (`KnowledgeSync(packageSkills: false)`).
- `what_changed` without `library` lists notes and per-library counts only, never the API entries (a real app has ~700 entries, ~35–45k tokens; Claude Code's default MCP limit is 25k).
- Every public API gets a `///` comment (`public_member_api_docs` is on).
- Windows is first-class: test paths contain a space and a non-ASCII letter (`tempDir()`, `copyFixtureApp()`).
- Before every commit, the BOM gate must print nothing: `LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test`.
- Commit trailers: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW`. Code commits also carry `Docs-Checked: <page>.md - <reason>` for each guide page that covers a changed file and is still right, until Task 11 updates the pages. New files under `lib/src/mcp/` have no page until Task 11; the guide check runs there.
- Never put a "Notes from execution" heading in this plan until the slice is finished: the guide check reads it as "slice done".

## Facts this plan relies on (verified 2026-10-03)

- **`dart_mcp` 0.5.2** (publisher labs.dart.dev, 150/160 points, `runtime:native-aot`), read from its source:
  - A server is `final class X extends MCPServer with ToolsSupport`, built with `super.fromStreamChannel(channel, implementation: Implementation(name:, version:), instructions:)`; tools are registered in the constructor with `registerTool(Tool(name:, description:, inputSchema:, outputSchema:), handler)`.
  - `registerTool` validates the arguments against `inputSchema` by default and answers `isError: true` with the validation errors.
  - A handler that throws becomes `isError: true` with `'$e\n$s'` (a stack trace), so our handler catches everything itself.
  - `CallToolResult(content:, structuredContent:, isError:)`; `TextContent(text:)`.
  - `Schema.fromMap(json).validate(data)` returns `List<ValidationError>` (`toErrorString()`); `ObjectSchema.fromMap(json)` wraps a plain JSON Schema map.
  - `stdioChannel(input:, output:)` (`package:dart_mcp/stdio.dart`) is a newline-delimited `StreamChannel<String>`.
  - Client side: `MCPClient(Implementation(...)).connectServer(channel)` gives a `ServerConnection` with `initialize(InitializeRequest(protocolVersion: ProtocolVersion.latestSupported, capabilities: client.capabilities, clientInfo: client.implementation))`, `notifyInitialized()`, `listTools()`, `callTool(CallToolRequest(name:, arguments:))`, `shutdown()`, `done`.
  - The newest protocol version it speaks is `2025-11-25`.
  - Its schema type getter reads `type` as a single string, so schemas never use type arrays such as `["string", "null"]`.
- **Claude Code shows the model only `structuredContent`** when a result has it, dropping the text blocks ([anthropics/claude-code#55677](https://github.com/anthropics/claude-code/issues/55677), [futuresearch.ai](https://futuresearch.ai/blog/mcp-results-widget/)). Hence `summary` inside the structured content.
- **Delta size** (slice 1b.5 measurements): a material-only app sees 354 deprecated elements, Flutter's `fix_data` has 383 entries (about 355 already removed), and go_router 18.0.2 has 13.
- **`KnowledgeSync.detect`** with nothing changed costs 20–110 ms (1b.7), and rebuilds everything when `state.json` is missing (`no sync has run here yet`), so the server always calls `detect`.
- **The analyzer cache** (`AnalyzerCache`) saves only the entries used since it was opened (`_used`), so a cache kept in memory must be "settled" after each sync: its loaded entries become the used ones, exactly what reopening the saved file would give.
- **`KnowledgeLock`** is an operating-system file lock; within one process its exclusivity differs by OS, which is why the server queues calls instead of relying on it.
- **The fixture app** (`test/fixtures/apps/mvvm_app`, name `fixture_app`) has the features `auth/login`, `booking`, `home`, `profile`, `settings`; symbols such as `LoginScreen`, `LoginViewModel`, `BookingScreen`, `AuthRepository`; and routes `/login`, `/`, `/booking`, `/booking/:id` (redirects, no screen), an unresolved route under `/` (screen `SettingsScreen`), `/settings` (unresolved), `/profile`, `/about` (unresolved). Its router has a top-level `redirect:`.

## Review Focus

1. **A knowledge file that is missing or damaged** (the map was skipped, a hand-edited JSON file): the tool refuses with the file's name and what to do, and never crashes or prints a stack trace. Task 3 tests the reader; Task 8 tests a damaged `features.json` through the server.
2. **Two tool calls at once** (agents call tools in parallel): both are answered, one after the other, and neither times out on its own server's lock. Task 8 fires three calls together.
3. **A hook syncing while the server answers** (the lock is held by another process): the server waits up to its lock timeout, then answers from the files on disk marked `stale`, not as an error. Task 8 holds the lock in the test.
4. **Input forms an agent will send:** a route without a leading slash, with a trailing slash or a query string; `check_api` with `()`, a setter, a parameter or a member name; `what_changed` with `library: go_router` (no `package:`). Tasks 5 and 6 test each.
5. **Replies that would be huge:** the freshness `changed` list is capped at 20 names (Task 3), and `what_changed` without `library` returns counts, never entries (Task 6).

---

### Task 1: `delta.json`

**Files:**
- Create: `packages/appstein_protocol/lib/src/knowledge/delta_knowledge.dart`
- Modify: `packages/appstein_protocol/lib/appstein_protocol.dart` (export it, after `curated_note.dart`)
- Create: `packages/appstein_engine/lib/src/delta/delta_json.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (export it, after `delta_facts.dart`)
- Modify: `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart`
- Test: `packages/appstein_protocol/test/knowledge/delta_knowledge_test.dart`
- Test: `packages/appstein_engine/test/delta/delta_json_test.dart`
- Test: `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart`, `knowledge_sync_detect_test.dart` (new tests, and every file list gains `platform/delta.json`)
- Golden: `packages/appstein_engine/test/fixtures/apps/goldens/delta.json.golden`

**Interfaces:**
- Produces (later tasks rely on these exact names):
  - protocol: `final class DeltaKnowledge` with `const DeltaKnowledge({required String flutterVersion, String? languageVersion, required String baseline, required String coverage, required String newestNotes, required List<CuratedNote> notes, required List<CuratedNote> laterNotes, DeltaApis? apis, String? missing})`, `factory DeltaKnowledge.fromJson(Map<String, Object?> json)`, `Map<String, Object?> toJson()`.
  - protocol: `final class DeltaApis({required List<DeltaDeprecatedApi> deprecated, required List<DeltaMigratedApi> migrated, required List<DeltaMovedLibrary> moved, required List<DeltaUnreadFile> unread})`.
  - protocol: `DeltaDeprecatedApi({required String library, required String name, required String kind, String? rule, String? message, List<String> migrations})`, `DeltaMigratedApi({required String library, required String name, required String status, required String title})`, `DeltaMovedLibrary({required String from, String? to, required String title})`, `DeltaUnreadFile({required String file, required String reason})`, each with `toJson()`.
  - engine: `const deltaJsonPath = 'platform/delta.json';`, `Map<String, Object?> deltaJsonBody(DeltaInputs inputs)`.

- [ ] **Step 1: Write the failing protocol test**

Create `packages/appstein_protocol/test/knowledge/delta_knowledge_test.dart`:

```dart
import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  const note = CuratedNote(
    id: 'popscope-not-willpopscope',
    since: '3.16',
    priority: 1,
    area: NoteArea.framework,
    summary: 'PopScope replaces WillPopScope.',
    use: '`PopScope`.',
    avoid: '`WillPopScope`.',
    source: 'https://docs.flutter.dev/release/breaking-changes/android-predictive-back',
  );
  const knowledge = DeltaKnowledge(
    flutterVersion: '3.47.5',
    languageVersion: '3.12',
    baseline: '3.16',
    coverage: 'complete',
    newestNotes: '3.47',
    notes: [note],
    laterNotes: [],
    apis: DeltaApis(
      deprecated: [
        DeltaDeprecatedApi(
          library: 'dart:core',
          name: 'RegExp',
          kind: 'implement',
          rule: "don't implement it.",
          message: "This class will become 'final' in a future release.",
        ),
        DeltaDeprecatedApi(
          library: 'package:flutter',
          name: 'WillPopScope',
          kind: 'use',
          message: 'Use PopScope instead.',
          migrations: ["Migrate to 'PopScope'"],
        ),
      ],
      migrated: [
        DeltaMigratedApi(
          library: 'package:flutter',
          name: 'Stack.overflow',
          status: 'removed',
          title: "Migrate to 'clipBehavior'",
        ),
      ],
      moved: [
        DeltaMovedLibrary(
          from: 'package:flutter/material.dart',
          to: 'package:material_ui/material_ui.dart',
          title: 'Migrate to material_ui.',
        ),
      ],
      unread: [DeltaUnreadFile(file: 'package:kit/fix_data.yaml', reason: 'bad')],
    ),
  );

  test('round-trips through JSON, ignoring meta', () {
    final json = jsonDecode(jsonEncode(knowledge.toJson())) as Map<String, Object?>;
    final read = DeltaKnowledge.fromJson({...json, 'meta': {'inputHash': 'x'}});
    expect(jsonEncode(read.toJson()), jsonEncode(knowledge.toJson()));
  });

  test('a delta without API lists says why', () {
    const missing = DeltaKnowledge(
      flutterVersion: '3.47.5',
      baseline: '3.16',
      coverage: 'partial',
      newestNotes: '3.47',
      notes: [],
      laterNotes: [],
      missing: 'the packages could not be fetched',
    );
    final read = DeltaKnowledge.fromJson(
      jsonDecode(jsonEncode(missing.toJson())) as Map<String, Object?>,
    );
    expect(read.apis, isNull);
    expect(read.missing, 'the packages could not be fetched');
    expect(read.languageVersion, isNull);
  });

  test('a missing field names the file', () {
    expect(
      () => DeltaKnowledge.fromJson({'flutterVersion': '3.47.5'}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('delta.json'),
        ),
      ),
    );
  });
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd packages/appstein_protocol && fvm dart test test/knowledge/delta_knowledge_test.dart`
Expected: FAIL to compile: `DeltaKnowledge` isn't defined.

- [ ] **Step 3: Write the protocol model**

Create `packages/appstein_protocol/lib/src/knowledge/delta_knowledge.dart`:

```dart
import '../json_fields.dart';
import 'curated_note.dart';

const _file = 'delta.json';

/// A deprecated API in `delta.json` (spec §6.4).
final class DeltaDeprecatedApi {
  /// Creates the entry.
  const DeltaDeprecatedApi({
    required this.library,
    required this.name,
    required this.kind,
    this.rule,
    this.message,
    this.migrations = const [],
  });

  factory DeltaDeprecatedApi._read(JsonFields fields) => DeltaDeprecatedApi(
    library: fields.string('library'),
    name: fields.string('name'),
    kind: fields.string('kind'),
    rule: fields.optionalString('rule'),
    message: fields.optionalString('message'),
    migrations: fields.strings('migrations'),
  );

  /// The library or package that declares it, such as `package:flutter`.
  final String library;

  /// Its name as code writes it: `Color.withOpacity`, or
  /// `Text.new(textScaleFactor)` for a parameter.
  final String name;

  /// What the deprecation forbids, named after Dart's `Deprecated`
  /// constructors: `use`, `implement`, `extend`, `subclass`, `instantiate`,
  /// `mixin` or `optional`.
  final String kind;

  /// What not to do for a [kind] other than `use`, such as "don't implement
  /// it."; null for `use`.
  final String? rule;

  /// The library's own deprecation message on one line; null when it has
  /// none.
  final String? message;

  /// The titles of the `fix_data` migrations that migrate it.
  final List<String> migrations;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'library': library,
    'name': name,
    'kind': kind,
    'rule': rule,
    'message': message,
    'migrations': migrations,
  };
}

/// An API a `fix_data` migration says is removed or changed.
final class DeltaMigratedApi {
  /// Creates the entry.
  const DeltaMigratedApi({
    required this.library,
    required this.name,
    required this.status,
    required this.title,
  });

  factory DeltaMigratedApi._read(JsonFields fields) => DeltaMigratedApi(
    library: fields.string('library'),
    name: fields.string('name'),
    status: fields.string('status'),
    title: fields.string('title'),
  );

  /// The library or package, as in [DeltaDeprecatedApi.library].
  final String library;

  /// Its name as code writes it, as in [DeltaDeprecatedApi.name].
  final String name;

  /// `removed` (code that uses it doesn't compile) or `changed` (it still
  /// exists and `dart fix` changes how it's used).
  final String status;

  /// The migration's title.
  final String title;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'library': library,
    'name': name,
    'status': status,
    'title': title,
  };
}

/// A library a `fix_data` migration moves elsewhere.
final class DeltaMovedLibrary {
  /// Creates the entry.
  const DeltaMovedLibrary({required this.from, this.to, required this.title});

  factory DeltaMovedLibrary._read(JsonFields fields) => DeltaMovedLibrary(
    from: fields.string('from'),
    to: fields.optionalString('to'),
    title: fields.string('title'),
  );

  /// The library's URI, such as `package:flutter/material.dart`.
  final String from;

  /// Where it moves, or null when the migration doesn't say.
  final String? to;

  /// The migration's title.
  final String title;

  /// The JSON form.
  Map<String, Object?> toJson() => {'from': from, 'to': to, 'title': title};
}

/// A migration file that couldn't be read.
final class DeltaUnreadFile {
  /// Creates the entry.
  const DeltaUnreadFile({required this.file, required this.reason});

  factory DeltaUnreadFile._read(JsonFields fields) => DeltaUnreadFile(
    file: fields.string('file'),
    reason: fields.string('reason'),
  );

  /// The file, named without any machine path.
  final String file;

  /// Why it couldn't be read.
  final String reason;

  /// The JSON form.
  Map<String, Object?> toJson() => {'file': file, 'reason': reason};
}

/// The deprecated, removed, changed and moved APIs of a delta, each list
/// sorted by library, then name.
final class DeltaApis {
  /// Creates the lists.
  const DeltaApis({
    required this.deprecated,
    required this.migrated,
    required this.moved,
    required this.unread,
  });

  factory DeltaApis._read(JsonFields fields) => DeltaApis(
    deprecated: [
      for (final api in fields.objects('deprecated'))
        DeltaDeprecatedApi._read(api),
    ],
    migrated: [
      for (final api in fields.objects('migrated')) DeltaMigratedApi._read(api),
    ],
    moved: [
      for (final moved in fields.objects('moved')) DeltaMovedLibrary._read(moved),
    ],
    unread: [
      for (final unread in fields.objects('unread'))
        DeltaUnreadFile._read(unread),
    ],
  );

  /// The deprecated APIs the project's imports expose.
  final List<DeltaDeprecatedApi> deprecated;

  /// The removed and changed APIs from the migrations in scope.
  final List<DeltaMigratedApi> migrated;

  /// The libraries the migrations in scope move.
  final List<DeltaMovedLibrary> moved;

  /// The migration files that couldn't be read.
  final List<DeltaUnreadFile> unread;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'deprecated': [for (final api in deprecated) api.toJson()],
    'migrated': [for (final api in migrated) api.toJson()],
    'moved': [for (final moved in moved) moved.toJson()],
    'unread': [for (final unread in unread) unread.toJson()],
  };
}

/// The contents of `.appstein/platform/delta.json` (spec §6.2, §6.4): the
/// same delta as `delta.md`, as data, for the MCP tools `check_api` and
/// `what_changed` (spec §8).
final class DeltaKnowledge {
  /// Creates the delta.
  const DeltaKnowledge({
    required this.flutterVersion,
    this.languageVersion,
    required this.baseline,
    required this.coverage,
    required this.newestNotes,
    required this.notes,
    required this.laterNotes,
    this.apis,
    this.missing,
  });

  /// Reads the file's JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory DeltaKnowledge.fromJson(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    final apis = fields.optionalObject('apis');
    List<CuratedNote> notes(String key) => [
      for (final note in fields.objects(key)) CuratedNote.fromJson(note.json),
    ];
    return DeltaKnowledge(
      flutterVersion: fields.string('flutterVersion'),
      languageVersion: fields.optionalString('languageVersion'),
      baseline: fields.string('baseline'),
      coverage: fields.string('coverage'),
      newestNotes: fields.string('newestNotes'),
      notes: notes('notes'),
      laterNotes: notes('laterNotes'),
      apis: apis == null ? null : DeltaApis._read(apis),
      missing: fields.optionalString('missing'),
    );
  }

  /// The installed Flutter version, such as `3.47.5`.
  final String flutterVersion;

  /// The project's Dart language version, or null when unknown.
  final String? languageVersion;

  /// How far back the notes reach (`delta.baseline`, spec §7).
  final String baseline;

  /// How well the curated notes cover this Flutter: `complete` or
  /// `partial`.
  final String coverage;

  /// The newest Flutter minor version the curated notes cover.
  final String newestNotes;

  /// The notes the project can use, most important first.
  final List<CuratedNote> notes;

  /// The notes that need a newer language version than the project's.
  final List<CuratedNote> laterNotes;

  /// The API lists; null when they couldn't be collected ([missing] says
  /// why).
  final DeltaApis? apis;

  /// Why [apis] is null; null otherwise.
  final String? missing;

  /// The JSON form, without `meta` (the store adds it).
  Map<String, Object?> toJson() => {
    'flutterVersion': flutterVersion,
    'languageVersion': languageVersion,
    'baseline': baseline,
    'coverage': coverage,
    'newestNotes': newestNotes,
    'notes': [for (final note in notes) note.toJson()],
    'laterNotes': [for (final note in laterNotes) note.toJson()],
    'apis': apis?.toJson(),
    'missing': missing,
  };
}
```

Add `export 'src/knowledge/delta_knowledge.dart';` to `packages/appstein_protocol/lib/appstein_protocol.dart`, after `export 'src/knowledge/curated_note.dart';`.

- [ ] **Step 4: Run the protocol test to see it pass**

Run: `cd packages/appstein_protocol && fvm dart test test/knowledge/delta_knowledge_test.dart`
Expected: PASS, 3 tests.

- [ ] **Step 5: Write the failing engine test for the body**

Create `packages/appstein_engine/test/delta/delta_json_test.dart`. It uses the same notes and facts as `delta_document_test.dart` (copy the three notes, `facts` and `inputs()` from that file's lines 8–136 verbatim) and then:

```dart
  test('holds the same notes and facts as delta.md, matching the golden', () {
    expectGolden('delta.json', deltaJsonBody(inputs()));
  });

  test('splits the notes the project can use from those that need a newer '
      'language version', () {
    final body = DeltaKnowledge.fromJson(deltaJsonBody(inputs()));
    expect([for (final n in body.notes) n.id], [
      'popscope-not-willpopscope',
      'dot-shorthands',
    ]);
    expect([for (final n in body.laterNotes) n.id], [
      'dart-primary-constructors',
    ]);
  });

  test('names the library, kind and rule of each deprecation', () {
    final apis = DeltaKnowledge.fromJson(deltaJsonBody(inputs())).apis!;
    final regExp = apis.deprecated.first;
    expect(regExp.library, 'dart:core');
    expect(regExp.kind, 'implement');
    expect(regExp.rule, "don't implement it.");
    expect(apis.migrated.map((m) => m.status), everyElement('removed'));
    expect(apis.moved.single.to, 'package:material_ui/material_ui.dart');
  });

  test('without facts, the API lists are missing with the skip reason', () {
    final body = DeltaKnowledge.fromJson(
      deltaJsonBody(
        inputs(facts: null, skipped: 'the packages could not be fetched'),
      ),
    );
    expect(body.apis, isNull);
    expect(body.missing, 'the packages could not be fetched');
  });

  test('an internal error names only its type', () {
    final body = DeltaKnowledge.fromJson(
      deltaJsonBody(inputs(facts: null, internalError: 'StateError')),
    );
    expect(
      body.missing,
      'Appstein could not collect them because of an internal error '
      '(StateError)',
    );
  });
```

with imports `package:appstein_engine/appstein_engine.dart`, `package:appstein_protocol/appstein_protocol.dart`, `package:test/test.dart` and `'../support/fixture_app.dart'`.

- [ ] **Step 6: Run it to see it fail**

Run: `cd packages/appstein_engine && fvm dart test test/delta/delta_json_test.dart`
Expected: FAIL to compile: `deltaJsonBody` isn't defined.

- [ ] **Step 7: Write the body builder**

Create `packages/appstein_engine/lib/src/delta/delta_json.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import 'delta_document.dart';

/// Where the version delta's structured form lives inside `.appstein/`
/// (spec §6.2).
const deltaJsonPath = 'platform/delta.json';

/// The body of `delta.json` (spec §6.2, §8): the notes and facts
/// [renderDelta] writes into `delta.md`, as data, for the MCP tools
/// `check_api` and `what_changed`. The store adds its `meta`.
///
/// The notes are split as `delta.md` splits them ([needsNewerLanguage]).
/// Without facts, the API lists are null and `missing` says why: the
/// internal error's type when collecting them failed, otherwise the map's
/// skip reason.
Map<String, Object?> deltaJsonBody(DeltaInputs inputs) {
  final facts = inputs.facts;
  final languageVersion = inputs.languageVersion;
  return DeltaKnowledge(
    flutterVersion: inputs.flutterVersion,
    languageVersion: languageVersion,
    baseline: inputs.baseline,
    coverage: inputs.coverage.name,
    newestNotes: inputs.newestNotes,
    notes: [
      for (final note in inputs.notes)
        if (!needsNewerLanguage(note, languageVersion)) note,
    ],
    laterNotes: [
      for (final note in inputs.notes)
        if (needsNewerLanguage(note, languageVersion)) note,
    ],
    apis: facts == null
        ? null
        : DeltaApis(
            deprecated: [
              for (final api in facts.deprecated)
                DeltaDeprecatedApi(
                  library: api.group,
                  name: api.name,
                  kind: api.kind.name,
                  rule: api.kind.rule,
                  message: api.message,
                  migrations: api.migrations,
                ),
            ],
            migrated: [
              for (final api in facts.migrated)
                DeltaMigratedApi(
                  library: api.group,
                  name: api.name,
                  status: api.status.name,
                  title: api.title,
                ),
            ],
            moved: [
              for (final moved in facts.moved)
                DeltaMovedLibrary(
                  from: moved.from,
                  to: moved.to,
                  title: moved.title,
                ),
            ],
            unread: [
              for (final unread in facts.unread)
                DeltaUnreadFile(file: unread.file, reason: unread.reason),
            ],
          ),
    missing: facts != null
        ? null
        : switch (inputs.internalError) {
            final error? =>
              'Appstein could not collect them because of an internal error '
                  '($error)',
            null => inputs.skipped ?? 'no reason was given',
          },
  ).toJson();
}
```

`NotesCoverage` is an enum with `complete` and `partial` (`notes_coverage.dart`), so `.name` gives the strings the protocol stores.

Add `export 'src/delta/delta_json.dart';` to `packages/appstein_engine/lib/appstein_engine.dart` after `export 'src/delta/delta_facts.dart';`.

- [ ] **Step 8: Create the golden and review it**

Run: `cd packages/appstein_engine && APPSTEIN_UPDATE_GOLDENS=1 fvm dart test test/delta/delta_json_test.dart --name "matching the golden"`, then read `test/fixtures/apps/goldens/delta.json.golden`.
Expected: sorted keys `apis`, `baseline` (`3.16`), `coverage` (`complete`), `flutterVersion` (`3.47.5`), `languageVersion` (`3.12`), `laterNotes` (only `dart-primary-constructors`), `missing` (`null`), `newestNotes` (`3.47`), `notes` (`popscope-not-willpopscope`, then `dot-shorthands`); `apis.deprecated` has 4 entries in the order `RegExp`, `Text.new(textScaleFactor)`, `WillPopScope`, `GoRouter.new(label)` with libraries `dart:core`, `package:flutter`, `package:flutter`, `package:go_router`; `apis.migrated` has 3, `apis.moved` 1, `apis.unread` 1.

- [ ] **Step 9: Run the engine test to see it pass**

Run: `cd packages/appstein_engine && fvm dart test test/delta/delta_json_test.dart`
Expected: PASS, 5 tests.

- [ ] **Step 10: Write the failing sync tests**

Add to `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart`, inside `main()`:

```dart
  test('the sync writes delta.json beside delta.md, with the same input '
      'hash and the same APIs', () async {
    final app = copyFixtureApp();
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.files['platform/delta.json'], isTrue);
    final json =
        jsonDecode(
              File(
                p.join(app, '.appstein', 'platform', 'delta.json'),
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final meta = KnowledgeMeta.fromJson(json['meta']! as Map<String, Object?>);
    final markdownMeta = readFrontMatter(delta(app))!;
    expect(meta.inputHash, markdownMeta.inputHash);
    final knowledge = DeltaKnowledge.fromJson(json);
    for (final api in knowledge.apis!.deprecated) {
      expect(delta(app), contains('`${api.name}`'), reason: api.name);
    }
    for (final note in knowledge.notes) {
      expect(delta(app), contains('**${note.id}**'), reason: note.id);
    }
  });
```

Add to `knowledge_sync_detect_test.dart`, inside `main()`:

```dart
  test('a deleted delta.json makes detect rebuild', () async {
    await full();
    await detect();
    fileOf('.appstein/platform/delta.json').deleteSync();
    final report = await detect();
    expect(report.current, isFalse);
    expect(report.rebuiltBecause, contains('platform/delta.json is missing'));
    expect(fileOf('.appstein/platform/delta.json').existsSync(), isTrue);
  });
```

- [ ] **Step 11: Run them to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/knowledge/knowledge_sync_test.dart test/knowledge/knowledge_sync_detect_test.dart`
Expected: FAIL: the two new tests (no `platform/delta.json`).

- [ ] **Step 12: Write delta.json in the sync**

In `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart`:

1. Add `import '../delta/delta_json.dart';` after `import '../delta/delta_document.dart';`.
2. In the class comment, change "the version delta," to "the version delta (`delta.md` and `delta.json`),".
3. In `_rebuild`, replace

```dart
    final delta = timings.time('delta', () => _delta(platform, map));
    // Last: it summarizes the other files.
    final index = timings.time(
      'INDEX.md',
      () => _index(platform, map, native, delta, prepared.sources),
    );
```

with

```dart
    final (delta, deltaJson) = timings.time(
      'delta',
      () => _delta(platform, map),
    );
    // Last: it summarizes the other files.
    final index = timings.time(
      'INDEX.md',
      () => _index(platform, map, native, [delta, deltaJson], prepared.sources),
    );
```

and in the `writeAll` call replace `[...platform.files, delta, ...map.files, ?native.file, index]` with `[...platform.files, delta, deltaJson, ...map.files, ?native.file, index]`.
4. In `_freshness`, after the line `deltaPath: _deltaHash(platform.sdk, mapHash),` add `deltaJsonPath: _deltaHash(platform.sdk, mapHash),`.
5. Replace `_delta` with:

```dart
  /// `delta.md` and `delta.json`: the notes, and the delta facts when they
  /// were collected, as Markdown and as data. Both have one input hash,
  /// covering the map's own hash (so the project's code, packages and
  /// Flutter version) or, with no facts, the reason they are missing, plus
  /// the notes, the baseline and the language version.
  (GeneratedFile, GeneratedFile) _delta(PlatformBuild platform, MapBuild map) {
    final sdk = platform.sdk;
    final internalError = map.report.deltaErrorType;
    // With no facts, the hashed reason is what delta.md says: the map's skip
    // reason, or only the error's type, never its message, which may hold
    // a machine path or differ from run to run.
    final skipped =
        map.report.skipped ??
        (internalError == null ? null : 'internal error ($internalError)');
    final facts = map.delta;
    final inputs = DeltaInputs(
      flutterVersion: sdk.flutterVersion,
      languageVersion: sdk.languageVersion,
      baseline: baseline,
      coverage: sdk.notesCoverage ?? NotesCoverage.partial,
      newestNotes: platform.newestNotes,
      notes: deltaNotes(
        notes,
        flutterVersion: sdk.flutterVersion,
        baseline: baseline,
      ),
      facts: facts,
      skipped: map.report.skipped,
      internalError: map.report.skipped == null ? internalError : null,
    );
    final hash = _deltaHash(
      sdk,
      // Facts exist only when the map ran, so then its hash is there.
      facts == null ? 'skipped: $skipped' : map.inputHash!,
    );
    return (
      GeneratedFile.markdown(
        path: deltaPath,
        markdown: renderDelta(inputs),
        inputHash: hash,
      ),
      GeneratedFile(
        path: deltaJsonPath,
        body: deltaJsonBody(inputs),
        inputHash: hash,
      ),
    );
  }
```

and change the doc comment of `_deltaHash` to start "The input hash of `delta.md` and `delta.json`:".
6. In `_index`, replace the parameter `GeneratedFile delta,` with `List<GeneratedFile> deltaFiles,` and the hash loop's `[...platform.files, delta, ...map.files, ?native.file]` with `[...platform.files, ...deltaFiles, ...map.files, ?native.file]`.

- [ ] **Step 13: Run the sync tests and fix the file lists**

Run: `cd packages/appstein_engine && fvm dart test test/knowledge/`
Expected: the two new tests PASS. Tests that list every file now fail; in each, add `'platform/delta.json'`:
- in `report.files` maps and ordered `report.files.keys` lists, right after `'platform/delta.md'`;
- in sorted `state.json` key lists, right before `'platform/delta.md'` (`delta.json` sorts before `delta.md`);
- in `unorderedEquals` lists, anywhere.

Then run `fvm dart test` in `packages/appstein_engine` and `packages/appstein_cli` and fix any other list the same way (the CLI's `sync_command_test.dart` checks rows with `contains`, so it should pass unchanged; if a test compares the whole report text, add the `platform/delta.json` row after `platform/delta.md`).
Expected: both suites PASS.

- [ ] **Step 14: Commit**

```bash
git add packages/appstein_protocol packages/appstein_engine
git commit -m "feat(engine): sync writes delta.json, the delta as data

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW
Docs-Checked: knowledge-store.md - updated in Task 11
Docs-Checked: version-delta.md - updated in Task 11
Docs-Checked: architecture.md - updated in Task 11"
```

---

### Task 2: A sync for a long-running server

**Files:**
- Modify: `packages/appstein_engine/lib/src/map/analyzer_cache.dart`
- Modify: `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart`
- Modify: `packages/appstein_engine/test/knowledge/support/sync_harness.dart`
- Test: `packages/appstein_engine/test/map/analyzer_cache_test.dart`
- Test: `packages/appstein_engine/test/knowledge/knowledge_sync_server_test.dart` (new)

**Interfaces:**
- Consumes: `AnalyzerCache` (`open`, `empty`, `get`, `putGet`, `changed`, `load`, `path`).
- Produces:
  - `AnalyzerCache settled()` on `AnalyzerCache`.
  - `final class HeldAnalyzerCache` with `AnalyzerCache take(String path)` and `void keep(AnalyzerCache cache)`.
  - `KnowledgeSync({…, bool packageSkills = true, HeldAnalyzerCache? heldCache})` with fields `final bool packageSkills;` and `final HeldAnalyzerCache? heldCache;`.
  - test harness: `knowledgeSync({…, bool packageSkills = true, HeldAnalyzerCache? heldCache})`.

- [ ] **Step 1: Write the failing cache tests**

Add to `packages/appstein_engine/test/map/analyzer_cache_test.dart`, inside `main()` (it already imports `dart:typed_data`, the engine and `../support/temp.dart`; add any of these that are missing):

```dart
  group('settled', () {
    test('keeps only the entries used since it was opened, as reopening the '
        'saved file would', () async {
      final path = p.join(tempDir().path, 'cache.bin');
      final first = AnalyzerCache.empty(path)
        ..putGet('a', Uint8List.fromList([1]))
        ..putGet('b', Uint8List.fromList([2]));
      await first.save();
      final reopened = AnalyzerCache.open(path)..get('a');
      final settled = reopened.settled();
      expect(settled.load, AnalyzerCacheLoad.loaded);
      expect(settled.loadedEntries, 1);
      expect(settled.get('a'), [1]);
      expect(settled.get('b'), isNull);
      expect(settled.path, path);
    });

    test('an unused cache settles to itself', () {
      final cache = AnalyzerCache.empty(p.join(tempDir().path, 'cache.bin'));
      expect(identical(cache.settled(), cache), isTrue);
    });
  });

  group('HeldAnalyzerCache', () {
    test('gives back the cache it keeps, settled, without reading the '
        'file', () {
      final path = p.join(tempDir().path, 'cache.bin');
      final held = HeldAnalyzerCache();
      final cache = held.take(path)..putGet('k', Uint8List.fromList([7]));
      held.keep(cache);
      File(path).writeAsStringSync('damaged');
      final again = held.take(path);
      expect(again.load, AnalyzerCacheLoad.loaded);
      expect(again.get('k'), [7]);
    });

    test('opens the file when it keeps nothing, or a cache of another '
        'path', () {
      final dir = tempDir().path;
      final held = HeldAnalyzerCache();
      expect(held.take(p.join(dir, 'a.bin')).load, AnalyzerCacheLoad.missing);
      held.keep(
        AnalyzerCache.empty(p.join(dir, 'b.bin'))
          ..putGet('k', Uint8List.fromList([1])),
      );
      expect(held.take(p.join(dir, 'a.bin')).get('k'), isNull);
    });
  });
```

Before writing it, check the names in `analyzer_cache.dart`: the `AnalyzerCacheLoad` values (the plan assumes `missing`, `loaded` and `damaged`, from the comments at lines 138–146) and whether `save()` takes only named arguments (`onTimed`). Use the real names.

- [ ] **Step 2: Run them to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/map/analyzer_cache_test.dart`
Expected: FAIL to compile: `settled` and `HeldAnalyzerCache` aren't defined.

- [ ] **Step 3: Write `settled` and `HeldAnalyzerCache`**

In `analyzer_cache.dart`, add to `AnalyzerCache`, after `changed`:

```dart
  /// This cache as the next sync would read it back from the file [save]
  /// writes: only the entries used since it was opened, as loaded entries.
  /// The MCP server keeps it in memory between syncs this way (spec §8).
  /// A cache nobody used settles to itself, so a sync that skipped the
  /// analysis keeps every entry.
  AnalyzerCache settled() => _used.isEmpty && _added == 0
      ? this
      : AnalyzerCache._(path, AnalyzerCacheLoad.loaded, null, Map.of(_used));
```

and at the end of the file (before `AnalyzerCacheReport`, or after it, matching the file's order of declarations):

```dart
/// Keeps one project's analyzer cache in memory between syncs, for the MCP
/// server, which syncs before every answer (spec §8).
///
/// A sync [take]s the cache and [keep]s it back after saving it. A cache
/// file another process wrote in between is not read; that costs only
/// cache misses, never wrong knowledge.
final class HeldAnalyzerCache {
  AnalyzerCache? _cache;

  /// The cache for a sync whose cache file is [path]: the one kept from the
  /// last sync when it is for [path], otherwise the file opened
  /// ([AnalyzerCache.open]).
  AnalyzerCache take(String path) {
    final kept = _cache;
    _cache = null;
    return kept != null && kept.path == path ? kept : AnalyzerCache.open(path);
  }

  /// Keeps [cache] for the next sync, [AnalyzerCache.settled].
  void keep(AnalyzerCache cache) => _cache = cache.settled();
}
```

- [ ] **Step 4: Run the cache tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/map/analyzer_cache_test.dart`
Expected: PASS.

- [ ] **Step 5: Write the failing sync tests**

In `packages/appstein_engine/test/knowledge/support/sync_harness.dart`, add the parameters `bool packageSkills = true,` and `HeldAnalyzerCache? heldCache,` to `knowledgeSync` and pass them on as `packageSkills: packageSkills, heldCache: heldCache,`.

Create `packages/appstein_engine/test/knowledge/knowledge_sync_server_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import 'support/sync_harness.dart';

void main() {
  late String sdk;
  late FakeProcessRunner runner;
  late String app;

  setUp(() {
    sdk = fakeFlutter();
    runner = FakeProcessRunner();
    app = copyFixtureApp();
  });

  test('with packageSkills off, a sync never runs package:skills, even with '
      'an agent set up', () async {
    Directory(p.join(app, '.claude')).createSync();
    final sync = knowledgeSync(
      flutterRoot: sdk,
      runner: runner,
      packageSkills: false,
    );
    final report = await sync.run(app, dartSdkPath: testDartSdk);
    expect(report.packageSkills, isNull);
    expect(runner.calls.where((call) => call.contains('skills@')), isEmpty);
    expect(PackageSkillsRecord.read(app), isNull);
  });

  test('a held cache is used from memory by the next sync, and the '
      'knowledge is the same as without it', () async {
    final held = HeldAnalyzerCache();
    KnowledgeSync sync() => knowledgeSync(
      flutterRoot: sdk,
      runner: runner,
      packageSkills: false,
      heldCache: held,
    );
    await sync().run(app, dartSdkPath: testDartSdk);
    // The file is gone, so a cache that loads must come from memory.
    File(analyzerCachePath(app)).deleteSync();
    final view = File(
      p.join(app, 'lib', 'ui', 'home', 'widgets', 'home_screen.dart'),
    );
    view.writeAsStringSync('${view.readAsStringSync()}\n/// Extra.\nint extra = 1;\n');
    final report = await sync().detect(app, dartSdkPath: testDartSdk);
    expect(report.current, isFalse);
    expect(report.analyzerCache!.load, AnalyzerCacheLoad.loaded);
    final withHeld = knowledgeFiles(app);

    final plain = copyFixtureApp();
    File(
      p.join(plain, 'lib', 'ui', 'home', 'widgets', 'home_screen.dart'),
    ).writeAsStringSync(view.readAsStringSync());
    await knowledgeSync(
      flutterRoot: sdk,
      runner: runner,
    ).run(plain, dartSdkPath: testDartSdk);
    final withoutHeld = knowledgeFiles(plain);
    for (final path in withHeld.keys.where((path) => path != 'state.json')) {
      expect(withHeld[path], withoutHeld[path], reason: path);
    }
  });
}
```

The `OfficialMvvmPack` import is for the harness default; remove it if the analyzer reports it unused. `knowledgeFiles` comes from `sync_harness.dart`. `state.json` is left out because it records `lastSync` and the change list.

- [ ] **Step 6: Run them to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/knowledge/knowledge_sync_server_test.dart`
Expected: FAIL to compile: `packageSkills` and `heldCache` aren't parameters of `KnowledgeSync`.

- [ ] **Step 7: Add the two options to `KnowledgeSync`**

In `knowledge_sync.dart`:

1. Add constructor parameters `this.packageSkills = true,` and `this.heldCache,` after `this.agents = const ['claude', 'codex'],`, and extend the constructor's doc comment with: "[packageSkills] false skips package skills (spec §8: the MCP server leaves them to the next `appstein sync`), and [heldCache] keeps the analyzer cache in memory between syncs (spec §8)."
2. Add the fields:

```dart
  /// Whether a sync runs package skills when they are due (spec §6.6).
  /// The MCP server turns it off (spec §8): a run can take up to 120 s,
  /// and the next `appstein sync` runs them, since their record is left
  /// alone.
  final bool packageSkills;

  /// Keeps the analyzer cache in memory between syncs (spec §8); null
  /// reads the cache file on every rebuild.
  final HeldAnalyzerCache? heldCache;
```

3. In `_rebuild`, replace the cache opening

```dart
    final cache = analyzerCache
        ? timings.time(
            'analyzer cache load',
            () => AnalyzerCache.open(analyzerCachePath(projectRoot)),
          )
        : null;
```

with

```dart
    final cache = analyzerCache
        ? timings.time('analyzer cache load', () {
            final path = analyzerCachePath(projectRoot);
            return heldCache?.take(path) ?? AnalyzerCache.open(path);
          })
        : null;
```

and right after the `store.locked(…)` call that returns `(files, saveError)`, add:

```dart
    // The cache the analysis used (a retry uses a new one), kept for the
    // next sync as reading back the saved file would give it.
    if (map.cache ?? cache case final kept?) heldCache?.keep(kept);
```

4. Make `_packageSkills` return null when the option is off: change its body to

```dart
  }) async {
    if (!packageSkills) return null;
    return timings.timeAsync(
      'package skills',
      () => PackageSkills(runner: runner, os: environment.os).refresh(
        projectRoot,
        flutterRoot: platform.location.root,
        configuredAgents: agents,
        pubspecHash: sources['pubspec.yaml'],
        lockHash: sources['pubspec.lock'],
        packagesReady: packagesReady,
        retryFailure: retryFailure,
      ),
    );
  }
```

(it becomes `async`; keep its doc comment and add "Returns null at once when [packageSkills] is false.").

- [ ] **Step 8: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/knowledge/ test/map/analyzer_cache_test.dart`
Expected: PASS.

- [ ] **Step 9: Run the engine suite**

Run: `cd packages/appstein_engine && fvm dart test`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add packages/appstein_engine
git commit -m "feat(engine): KnowledgeSync can skip package skills and keep its analyzer cache in memory

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW
Docs-Checked: knowledge-store.md - updated in Task 11
Docs-Checked: incremental-sync.md - updated in Task 11"
```

---

### Task 3: Shared MCP pieces: schemas, freshness, the knowledge reader

**Files:**
- Modify: `packages/appstein_engine/pubspec.yaml` (dependencies `dart_mcp: 0.5.2`, `stream_channel: ^2.1.4`)
- Create: `packages/appstein_protocol/lib/src/mcp/json_schema.dart`
- Create: `packages/appstein_protocol/lib/src/mcp/freshness_report.dart`
- Create: `packages/appstein_protocol/lib/src/mcp/tool_output.dart`
- Create: `packages/appstein_protocol/lib/src/mcp/tool_schemas.dart`
- Modify: `packages/appstein_protocol/lib/appstein_protocol.dart` (export the four, after `src/map/symbols_map.dart`, as `src/mcp/freshness_report.dart`, `src/mcp/json_schema.dart`, `src/mcp/tool_output.dart`, `src/mcp/tool_schemas.dart`)
- Create: `packages/appstein_engine/lib/src/mcp/knowledge_snapshot.dart`
- Create: `packages/appstein_engine/lib/src/mcp/tool_answer.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (export both, after `src/map/symbols.dart`)
- Test: `packages/appstein_protocol/test/mcp/freshness_report_test.dart`, `packages/appstein_protocol/test/mcp/tool_output_test.dart`
- Test: `packages/appstein_engine/test/mcp/knowledge_snapshot_test.dart`
- Create (test support): `packages/appstein_engine/test/mcp/support/mcp_support.dart`

**Interfaces:**
- Produces:
  - protocol: `Map<String, Object?> jsonObject(Map<String, Map<String, Object?>> properties, {List<String> required = const [], String? description})`, `jsonString({String? description, List<String>? values})`, `jsonInteger({String? description})`, `jsonBoolean({String? description})`, `jsonList(Map<String, Object?> items, {String? description})`.
  - protocol: `enum FreshnessState { current, rebuilt, stale }`; `final class FreshnessReport` with `const FreshnessReport.current()`, `const FreshnessReport.rebuilt({required List<String> because, required List<String> changed, String? mapSkipped})`, `const FreshnessReport.stale({required String problem, String? fixHint})`, `Map<String, Object?> toJson()`, `String get sentence`, `static final Map<String, Object?> schema`, `static const changedLimit = 20`.
  - protocol: `Object? withoutNulls(Object? json)`; `Map<String, Object?> toolOutputSchema(Map<String, Object?> result)`.
  - protocol: `abstract final class ToolSchemas` with `static final Map<String, Object?> noInput` (Tasks 4–8 add the tool schemas).
  - engine: `final class KnowledgeRead<T>` (`value`, `problem`); `final class KnowledgeSnapshot` with `KnowledgeSnapshot(String projectRoot)`, lazy fields `index` (`KnowledgeRead<IndexText>`), `toolchain`, `delta`, `features`, `symbols`, `routes`, `layers`, `native`, and `ToolRefusal? refusalFor(List<KnowledgeRead<Object>> reads)`; `typedef IndexText = ({String body, String generatedAt});`.
  - engine: `sealed class ToolAnswer`; `final class ToolReply extends ToolAnswer { const ToolReply(Map<String, Object?> result, String summary) }`; `final class ToolRefusal extends ToolAnswer { const ToolRefusal(String message) }`.
  - test support: `void expectMatchesSchema(Map<String, Object?> schema, Object? json)`; `Map<String, Object?> golden(String name)`.

- [ ] **Step 1: Add the dependencies**

In `packages/appstein_engine/pubspec.yaml`, under `dependencies:`, add (keeping alphabetical order) `dart_mcp: 0.5.2` and `stream_channel: ^2.1.4`.
Run: `fvm dart pub get` from the repo root.
Expected: "Changed N dependencies!" with `dart_mcp 0.5.2` and `json_rpc_2` added, no version conflict.

- [ ] **Step 2: Write the failing protocol tests**

Create `packages/appstein_protocol/test/mcp/freshness_report_test.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('current is just its state', () {
    expect(const FreshnessReport.current().toJson(), {'state': 'current'});
    expect(
      const FreshnessReport.current().sentence,
      'The knowledge was current.',
    );
  });

  test('rebuilt lists why and what changed, at most 20 names', () {
    final report = FreshnessReport.rebuilt(
      because: const ['lib/a.dart changed'],
      changed: [for (var i = 0; i < 25; i++) 'lib/f$i.dart'],
      mapSkipped: 'the packages could not be fetched',
    );
    final json = report.toJson();
    expect(json['state'], 'rebuilt');
    expect(json['because'], ['lib/a.dart changed']);
    expect((json['changed']! as List).length, 20);
    expect(json['moreChanged'], 5);
    expect(json['mapSkipped'], 'the packages could not be fetched');
    expect(
      report.sentence,
      'The knowledge was rebuilt first (lib/a.dart changed). The project map '
      'was skipped: the packages could not be fetched.',
    );
  });

  test('stale says the problem and the fix, each as a sentence', () {
    const report = FreshnessReport.stale(
      problem: 'No Flutter SDK was found.',
      fixHint: 'Run `appstein doctor`',
    );
    expect(report.toJson(), {
      'state': 'stale',
      'problem': 'No Flutter SDK was found.',
      'fixHint': 'Run `appstein doctor`',
    });
    expect(
      report.sentence,
      'The knowledge may be stale: No Flutter SDK was found. Run `appstein '
      'doctor`.',
    );
  });
}
```

Create `packages/appstein_protocol/test/mcp/tool_output_test.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('withoutNulls drops null values and list items, at any depth', () {
    expect(
      withoutNulls({
        'a': null,
        'b': 1,
        'c': {'d': null, 'e': 'x'},
        'f': [null, 2, {'g': null}],
      }),
      {
        'b': 1,
        'c': {'e': 'x'},
        'f': [2, <String, Object?>{}],
      },
    );
  });

  test('toolOutputSchema adds summary and freshness as required', () {
    final schema = toolOutputSchema(
      jsonObject({'index': jsonString()}, required: ['index']),
    );
    expect((schema['properties']! as Map).keys, [
      'index',
      'summary',
      'freshness',
    ]);
    expect(schema['required'], ['index', 'summary', 'freshness']);
    expect(schema['type'], 'object');
  });
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd packages/appstein_protocol && fvm dart test test/mcp/`
Expected: FAIL to compile.

- [ ] **Step 4: Write the protocol pieces**

Create `packages/appstein_protocol/lib/src/mcp/json_schema.dart`:

```dart
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
```

(`'key': ?value` is Dart 3.8+ null-aware map entry syntax, already used in this repo, e.g. `?api.kind.rule` in `delta_document.dart`. If the analyzer rejects it inside a map literal, use `if (description != null) 'description': description` instead.)

Create `packages/appstein_protocol/lib/src/mcp/freshness_report.dart`:

```dart
import 'json_schema.dart';

/// Whether the knowledge an MCP reply was built from is current (spec §8).
enum FreshnessState {
  /// Nothing the knowledge reads had changed.
  current,

  /// Something had changed, and the server rebuilt the knowledge first.
  rebuilt,

  /// The server couldn't sync, so the reply comes from the files on disk.
  stale,
}

/// The `freshness` field of every MCP reply (spec §8).
final class FreshnessReport {
  /// Nothing had changed.
  const FreshnessReport.current()
    : state = FreshnessState.current,
      because = const [],
      changed = const [],
      mapSkipped = null,
      problem = null,
      fixHint = null;

  /// The knowledge was rebuilt first, [because] of these reasons, after the
  /// [changed] input files changed. [mapSkipped] is why the project map
  /// was skipped, if it was.
  const FreshnessReport.rebuilt({
    required this.because,
    required this.changed,
    this.mapSkipped,
  }) : state = FreshnessState.rebuilt,
       problem = null,
       fixHint = null;

  /// The sync failed with [problem]; [fixHint] says what to do.
  const FreshnessReport.stale({required String this.problem, this.fixHint})
    : state = FreshnessState.stale,
      because = const [],
      changed = const [],
      mapSkipped = null;

  /// The most changed files a reply names; the rest are counted.
  static const changedLimit = 20;

  /// What happened.
  final FreshnessState state;

  /// Why it rebuilt (`SyncReport.rebuiltBecause`).
  final List<String> because;

  /// The input files that changed (`SyncReport.changed`).
  final List<String> changed;

  /// Why the project map was skipped when it rebuilt; null otherwise.
  final String? mapSkipped;

  /// Why it couldn't sync; null unless [state] is stale.
  final String? problem;

  /// What to do about [problem].
  final String? fixHint;

  /// The JSON form, with no null values and at most [changedLimit] changed
  /// files (`moreChanged` counts the rest).
  Map<String, Object?> toJson() => {
    'state': state.name,
    if (because.isNotEmpty) 'because': because,
    if (changed.isNotEmpty) 'changed': changed.take(changedLimit).toList(),
    if (changed.length > changedLimit)
      'moreChanged': changed.length - changedLimit,
    'mapSkipped': ?mapSkipped,
    'problem': ?problem,
    'fixHint': ?fixHint,
  };

  /// One or two sentences for a reply's text.
  String get sentence => switch (state) {
    FreshnessState.current => 'The knowledge was current.',
    FreshnessState.rebuilt =>
      'The knowledge was rebuilt first'
          '${because.isEmpty ? '' : ' (${because.first})'}.'
          '${mapSkipped == null ? '' : ' The project map was skipped: ${_withFullStop(mapSkipped!)}'}',
    FreshnessState.stale =>
      'The knowledge may be stale: ${_withFullStop(problem!)}'
          '${fixHint == null ? '' : ' ${_withFullStop(fixHint!)}'}',
  };

  /// The schema of [toJson].
  static final Map<String, Object?> schema = jsonObject(
    {
      'state': jsonString(values: [for (final s in FreshnessState.values) s.name]),
      'because': jsonList(jsonString()),
      'changed': jsonList(jsonString()),
      'moreChanged': jsonInteger(),
      'mapSkipped': jsonString(),
      'problem': jsonString(),
      'fixHint': jsonString(),
    },
    required: ['state'],
    description: 'Whether the knowledge was current, rebuilt first, or may '
        'be stale.',
  );
}

String _withFullStop(String text) {
  final trimmed = text.trim();
  return trimmed.endsWith('.') || trimmed.endsWith('!') || trimmed.endsWith('?')
      ? trimmed
      : '$trimmed.';
}
```

Create `packages/appstein_protocol/lib/src/mcp/tool_output.dart`:

```dart
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
Map<String, Object?> toolOutputSchema(Map<String, Object?> result) => {
  ...result,
  'properties': {
    ...(result['properties']! as Map<String, Object?>),
    'summary': jsonString(description: 'The answer in a sentence or two.'),
    'freshness': FreshnessReport.schema,
  },
  'required': [
    ...?(result['required'] as List<Object?>?)?.cast<String>(),
    'summary',
    'freshness',
  ],
};
```

Create `packages/appstein_protocol/lib/src/mcp/tool_schemas.dart`:

```dart
import 'json_schema.dart';

/// The input schemas of Appstein's MCP tools and the schemas of their
/// results (spec §8). A tool's full output schema is its result schema
/// with `summary` and `freshness` added (`toolOutputSchema`).
abstract final class ToolSchemas {
  /// The input of a tool that takes no arguments.
  static final Map<String, Object?> noInput = jsonObject({});
}
```

Add the four exports to `appstein_protocol.dart`.

- [ ] **Step 5: Run the protocol tests to see them pass**

Run: `cd packages/appstein_protocol && fvm dart test`
Expected: PASS.

- [ ] **Step 6: Write the failing reader tests**

Create `packages/appstein_engine/test/mcp/support/mcp_support.dart`:

```dart
import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:test/test.dart';

import '../../support/fixture_app.dart';

/// Checks [json] against the JSON Schema [schema] with `package:dart_mcp`'s
/// validator, the one the server's inputs go through.
void expectMatchesSchema(Map<String, Object?> schema, Object? json) {
  final errors = Schema.fromMap(schema).validate(json);
  expect(
    errors,
    isEmpty,
    reason: errors.map((error) => error.toErrorString()).join('\n'),
  );
}

/// The body of the map golden `<name>` (such as `features.json`), as the
/// map file holds it without its `meta`.
Map<String, Object?> golden(String name) =>
    jsonDecode(goldenText(name)) as Map<String, Object?>;
```

Create `packages/appstein_engine/test/mcp/knowledge_snapshot_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  late String root;

  setUp(() => root = tempDir().path);

  void write(String path, String text) =>
      File(p.joinAll([root, '.appstein', ...path.split('/')]))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(text);

  test('reads INDEX.md without its front matter, with its generatedAt', () {
    write(
      'INDEX.md',
      '---\nappsteinVersion: "0.1.0-dev"\nformatVersion: 1\n'
      'generatedAt: "2026-10-01T09:00:00Z"\ninputHash: "h"\n'
      'sdkVersion: "3.47.5"\n---\n\n# fixture_app\n\nText.\n',
    );
    final index = KnowledgeSnapshot(root).index.value!;
    expect(index.body, '# fixture_app\n\nText.\n');
    expect(index.generatedAt, '2026-10-01T09:00:00Z');
  });

  test('a missing file is a problem that names it', () {
    final read = KnowledgeSnapshot(root).features;
    expect(read.value, isNull);
    expect(read.problem, '`.appstein/map/features.json` is missing');
  });

  test('a damaged file is a problem that says why', () {
    write('map/features.json', '{"features": 3}');
    expect(
      KnowledgeSnapshot(root).features.problem,
      startsWith('`.appstein/map/features.json` is damaged ('),
    );
    write('map/routes.json', 'not json');
    expect(
      KnowledgeSnapshot(root).routes.problem,
      startsWith('`.appstein/map/routes.json` is damaged ('),
    );
  });

  test('INDEX.md without front matter is damaged', () {
    write('INDEX.md', '# Hand-written\n');
    expect(
      KnowledgeSnapshot(root).index.problem,
      '`.appstein/INDEX.md` is damaged (it has no front matter)',
    );
  });

  test('refusalFor gives the first problem, with what to do', () {
    write('map/symbols.json', '{"symbols": []}');
    final snapshot = KnowledgeSnapshot(root);
    expect(snapshot.refusalFor([snapshot.symbols]), isNull);
    expect(
      snapshot.refusalFor([snapshot.symbols, snapshot.routes])?.message,
      '`.appstein/map/routes.json` is missing, so this can\'t be answered '
      'yet. Run `appstein sync` in the project to see why.',
    );
  });
}
```

The front matter keys must match what `KnowledgeMeta.fromJson` requires; check `knowledge_meta.dart` and adjust the test's front matter to its exact fields before running.

- [ ] **Step 7: Run them to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/mcp/knowledge_snapshot_test.dart`
Expected: FAIL to compile: `KnowledgeSnapshot` isn't defined.

- [ ] **Step 8: Write the answer types and the reader**

Create `packages/appstein_engine/lib/src/mcp/tool_answer.dart`:

```dart
/// What an MCP tool's query gives the server (spec §8): a [ToolReply] or a
/// [ToolRefusal].
sealed class ToolAnswer {
  /// Lets subclasses be constant.
  const ToolAnswer();
}

/// An answer: the structured [result], which matches the tool's result
/// schema, and a one- or two-sentence [summary].
final class ToolReply extends ToolAnswer {
  /// Creates the reply.
  const ToolReply(this.result, this.summary);

  /// The structured result, without `summary` and `freshness` (the server
  /// adds them).
  final Map<String, Object?> result;

  /// What the answer says, for the agent.
  final String summary;
}

/// A question the tool can't answer, such as an unknown feature or missing
/// knowledge, and why. The server sends it as an error result, so the agent
/// sees the [message] and can correct itself.
final class ToolRefusal extends ToolAnswer {
  /// Creates the refusal.
  const ToolRefusal(this.message);

  /// Why, and what to do instead.
  final String message;
}
```

Create `packages/appstein_engine/lib/src/mcp/knowledge_snapshot.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../delta/delta_json.dart';
import '../host/file_errors.dart';
import '../knowledge/markdown_front_matter.dart';
import 'tool_answer.dart';

/// `INDEX.md`'s text without its front matter, and when it was generated.
typedef IndexText = ({String body, String generatedAt});

/// One knowledge file as an MCP tool reads it: its contents, or why it
/// can't be used.
final class KnowledgeRead<T> {
  /// A file that was read.
  const KnowledgeRead.loaded(T this.value) : problem = null;

  /// A file that is missing, unreadable or damaged.
  const KnowledgeRead.missing(String this.problem) : value = null;

  /// The contents; null when [problem] is set.
  final T? value;

  /// Why the file can't be used, naming it; null when it was read.
  final String? problem;
}

/// The knowledge files of a project's `.appstein/` (spec §6.2), each read
/// on first use, for one MCP tool call (spec §8).
///
/// Writers replace each file in one step, so a reader sees a whole file:
/// the old one or the new one.
final class KnowledgeSnapshot {
  /// The snapshot of the project at [projectRoot].
  KnowledgeSnapshot(this.projectRoot);

  /// The project's folder.
  final String projectRoot;

  /// `INDEX.md`.
  late final KnowledgeRead<IndexText> index = _read('INDEX.md', (text) {
    final meta = readFrontMatter(text);
    if (meta == null) throw const FormatException('it has no front matter');
    final end = text.indexOf('\n---\n', 3);
    return (
      body: text.substring(end + 5).replaceFirst(RegExp('^\n'), ''),
      generatedAt: meta.generatedAt,
    );
  });

  /// `platform/toolchain.json`.
  late final KnowledgeRead<Toolchain> toolchain = _json(
    'platform/toolchain.json',
    Toolchain.fromJson,
  );

  /// `platform/delta.json`.
  late final KnowledgeRead<DeltaKnowledge> delta = _json(
    deltaJsonPath,
    DeltaKnowledge.fromJson,
  );

  /// `map/features.json`.
  late final KnowledgeRead<FeaturesMap> features = _json(
    MapFiles.features,
    FeaturesMap.fromJson,
  );

  /// `map/symbols.json`.
  late final KnowledgeRead<SymbolsMap> symbols = _json(
    MapFiles.symbols,
    SymbolsMap.fromJson,
  );

  /// `map/routes.json`.
  late final KnowledgeRead<RoutesMap> routes = _json(
    MapFiles.routes,
    RoutesMap.fromJson,
  );

  /// `map/layers.json`.
  late final KnowledgeRead<LayersMap> layers = _json(
    MapFiles.layers,
    LayersMap.fromJson,
  );

  /// `map/native.json`.
  late final KnowledgeRead<NativeConfig> native = _json(
    MapFiles.native,
    NativeConfig.fromJson,
  );

  /// A refusal naming the first of [reads] that can't be used, with what
  /// to do; null when all of them were read.
  ToolRefusal? refusalFor(List<KnowledgeRead<Object>> reads) {
    for (final read in reads) {
      if (read.problem case final problem?) {
        return ToolRefusal(
          "$problem, so this can't be answered yet. Run `appstein sync` in "
          'the project to see why.',
        );
      }
    }
    return null;
  }

  KnowledgeRead<T> _json<T extends Object>(
    String path,
    T Function(Map<String, Object?> json) parse,
  ) => _read(path, (text) {
    final json = jsonDecode(text);
    if (json is! Map<String, Object?>) {
      throw const FormatException('it is not a JSON object');
    }
    return parse(json);
  });

  KnowledgeRead<T> _read<T extends Object>(
    String path,
    T Function(String text) parse,
  ) {
    final name = '`.appstein/$path`';
    final file = File(p.joinAll([projectRoot, '.appstein', ...path.split('/')]));
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException catch (error) {
      return KnowledgeRead.missing(
        file.existsSync()
            ? '$name could not be read (${fileErrorReason(error)})'
            : '$name is missing',
      );
    }
    try {
      return KnowledgeRead.loaded(parse(text));
    } on FormatException catch (error) {
      return KnowledgeRead.missing('$name is damaged (${error.message})');
    }
  }
}
```

`fileErrorReason` is in `lib/src/host/file_errors.dart` (used by `knowledge_store.dart`). `refusalFor` takes `List<KnowledgeRead<Object>>`; `KnowledgeRead<FeaturesMap>` is a subtype since `T` is covariant.

Add `export 'src/mcp/knowledge_snapshot.dart';` and `export 'src/mcp/tool_answer.dart';` to `appstein_engine.dart` after `export 'src/map/symbols.dart';`.

- [ ] **Step 9: Run the reader tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/mcp/knowledge_snapshot_test.dart`
Expected: PASS, 5 tests.

- [ ] **Step 10: Analyze and commit**

Run: `fvm dart analyze --fatal-infos` from the repo root.
Expected: No issues found.

```bash
git add pubspec.lock packages/appstein_protocol packages/appstein_engine
git commit -m "feat: MCP schema builders, freshness report and the knowledge reader

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW
Docs-Checked: architecture.md - updated in Task 11"
```

---

### Task 4: `where_is`

**Files:**
- Create: `packages/appstein_engine/lib/src/mcp/where_is.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (export it, keeping `src/mcp/` exports alphabetical)
- Modify: `packages/appstein_protocol/lib/src/mcp/tool_schemas.dart`
- Test: `packages/appstein_engine/test/mcp/where_is_test.dart`

**Interfaces:**
- Consumes: `SymbolsMap`, `RoutesMap`, `FeaturesMap`, `LayersMap` (protocol), `editDistance` (`lib/src/text/edit_distance.dart`), `ToolAnswer`.
- Produces:
  - `const whereIsLimit = 10;`
  - `List<String> searchWords(String text)`
  - `ToolAnswer whereIs(String query, {required SymbolsMap symbols, required RoutesMap routes, required FeaturesMap features, required LayersMap layers})`
  - `ToolSchemas.whereIsInput`, `ToolSchemas.whereIsResult`.

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/mcp/where_is_test.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/mcp_support.dart';

void main() {
  final symbols = SymbolsMap.fromJson(golden('symbols.json'));
  final routes = RoutesMap.fromJson(golden('routes.json'));
  final features = FeaturesMap.fromJson(golden('features.json'));
  final layers = LayersMap.fromJson(golden('layers.json'));

  ToolAnswer ask(String query) => whereIs(
    query,
    symbols: symbols,
    routes: routes,
    features: features,
    layers: layers,
  );

  List<Map<String, Object?>> matches(String query) =>
      ((ask(query) as ToolReply).result['matches']! as List)
          .cast<Map<String, Object?>>();

  test('searchWords splits camelCase, snake_case and paths', () {
    expect(searchWords('LoginScreen'), ['login', 'screen']);
    expect(searchWords('login_screen'), ['login', 'screen']);
    expect(searchWords('lib/ui/auth/login/widgets/login_screen.dart'), [
      'lib', 'ui', 'auth', 'login', 'widgets', 'login', 'screen', 'dart',
    ]);
    expect(searchWords('HTTPClient'), ['http', 'client']);
    expect(searchWords('/booking/:id'), ['booking', 'id']);
  });

  test('"login screen": the symbol first, then the route, with reasons', () {
    final found = matches('login screen');
    expect(found.first, containsPair('kind', 'symbol'));
    expect(found.first, containsPair('name', 'LoginScreen'));
    expect(found.first['score'], 10);
    expect(found.first['file'], 'lib/ui/auth/login/widgets/login_screen.dart');
    expect(found.first['feature'], 'auth/login');
    expect(found.first['layer'], 'ui');
    expect(found.first['reasons'], [
      '`login` is a word of the symbol name `LoginScreen`',
      '`screen` is a word of the symbol name `LoginScreen`',
    ]);
    expect(found[1], containsPair('kind', 'route'));
    expect(found[1], containsPair('name', '/login'));
    expect(found[1]['score'], 8);
  });

  test('scores tiers: symbol 5 > route 4 > feature 3 > path 2', () {
    final found = matches('booking');
    int score(String kind, String name) => found.firstWhere(
      (m) => m['kind'] == kind && m['name'] == name,
    )['score']! as int;
    expect(score('symbol', 'BookingScreen'), 5);
    expect(score('route', '/booking'), 4);
    expect(score('feature', 'booking'), 3);
    expect(score('file', 'lib/ui/booking/widgets/booking_screen.dart'), 2);
  });

  test('a typo of four or more letters matches within two edits, for 1', () {
    final found = matches('bookng');
    expect(found, isNotEmpty);
    expect(found.every((m) => m['score'] == 1), isTrue);
    expect(
      (found.first['reasons']! as List).single,
      contains('`bookng` is close to `booking`'),
    );
  });

  test('ties go to the name, then the file, and at most 10 are listed', () {
    final reply = ask('screen') as ToolReply;
    final found = (reply.result['matches']! as List).cast<Map<String, Object?>>();
    expect(found.length, whereIsLimit);
    expect(reply.result['total'], greaterThan(whereIsLimit));
    final symbolsFound = [
      for (final m in found)
        if (m['kind'] == 'symbol') m['name'],
    ];
    expect(symbolsFound, [...symbolsFound]..sort());
  });

  test('nothing matched is a reply with no matches', () {
    final reply = ask('zebra') as ToolReply;
    expect(reply.result['matches'], isEmpty);
    expect(reply.summary, 'Nothing in the project map matches "zebra".');
  });

  test('a query with no letters or digits is refused', () {
    expect(
      (ask('!!!') as ToolRefusal).message,
      'The query "!!!" has no letters or digits to match.',
    );
  });

  test('the result matches its schema', () {
    final reply = ask('login screen') as ToolReply;
    expectMatchesSchema(
      ToolSchemas.whereIsResult,
      withoutNulls(reply.result),
    );
  });
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/mcp/where_is_test.dart`
Expected: FAIL to compile: `whereIs` isn't defined.

- [ ] **Step 3: Add the schemas**

In `tool_schemas.dart`, add to `ToolSchemas`:

```dart
  /// `where_is`'s input.
  static final Map<String, Object?> whereIsInput = jsonObject(
    {
      'query': jsonString(
        description: 'Free text, such as "login screen" or "booking '
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
```

- [ ] **Step 4: Write `where_is`**

Create `packages/appstein_engine/lib/src/mcp/where_is.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import '../text/edit_distance.dart';
import 'tool_answer.dart';

/// How many matches `where_is` lists (spec §8).
const whereIsLimit = 10;

/// The lowercase words of [text], split at camelCase humps and at every
/// character that isn't a letter or a digit: `LoginScreen`, `login_screen`
/// and `login_screen.dart` all give `login`, `screen`.
List<String> searchWords(String text) {
  final spaced = text
      .replaceAllMapped(
        RegExp('([a-z0-9])([A-Z])'),
        (match) => '${match[1]} ${match[2]}',
      )
      .replaceAllMapped(
        RegExp('([A-Z]+)([A-Z][a-z])'),
        (match) => '${match[1]} ${match[2]}',
      );
  return [
    for (final word in spaced.toLowerCase().split(RegExp('[^a-z0-9]+')))
      if (word.isNotEmpty) word,
  ];
}

/// `where_is` (spec §8): the files and symbols of the project map that
/// match the free text [query], best first, deterministically.
///
/// The query is split into words ([searchWords]) and matched against four
/// kinds of candidate, each worth its tier for a word that matches:
/// - a symbol (5): a word of its name, or its whole name;
/// - a route (4): a word of its path or of its screen's name;
/// - a feature (3): a word of its name;
/// - a file (2): a word of its path.
///
/// A word of four or more letters that matches no word of a candidate
/// exactly scores 1 when it is at most two edits from one (a typo). A
/// candidate's score is the sum of each word's best score; ties go to the
/// name, then the file. It lists the top [whereIsLimit], each with the
/// reason for each word that matched.
ToolAnswer whereIs(
  String query, {
  required SymbolsMap symbols,
  required RoutesMap routes,
  required FeaturesMap features,
  required LayersMap layers,
}) {
  final words = searchWords(query);
  if (words.isEmpty) {
    return ToolRefusal(
      'The query "$query" has no letters or digits to match.',
    );
  }
  final candidates = [
    for (final symbol in symbols.symbols)
      _Candidate(
        kind: 'symbol',
        name: symbol.name,
        tier: 5,
        groups: [
          (
            {...searchWords(symbol.name), symbol.name.toLowerCase()},
            'the symbol name `${symbol.name}`',
          ),
        ],
        file: symbol.file,
        line: symbol.line,
        layer: symbol.layer,
        feature: symbol.feature,
        summary: symbol.summary,
      ),
    for (final route in routes.routes)
      if (route.path case final path?)
        _Candidate(
          kind: 'route',
          name: path,
          tier: 4,
          groups: [
            (searchWords(path).toSet(), 'the route path `$path`'),
            if (route.screen case final screen?)
              (searchWords(screen.name).toSet(), 'its screen `${screen.name}`'),
          ],
          file: route.file,
          line: route.line,
          feature: switch (route.screen) {
            final screen? => features.featureOf(screen.file),
            null => null,
          },
        ),
    for (final MapEntry(key: name, value: feature) in features.features.entries)
      _Candidate(
        kind: 'feature',
        name: name,
        tier: 3,
        groups: [(searchWords(name).toSet(), 'the feature name `$name`')],
        file: feature.folder,
      ),
    for (final MapEntry(key: path, value: entry) in layers.files.entries)
      _Candidate(
        kind: 'file',
        name: path,
        tier: 2,
        groups: [(searchWords(path).toSet(), 'the path `$path`')],
        file: path,
        layer: entry.layer,
        feature: entry.feature,
      ),
  ];
  final scored = [
    for (final candidate in candidates)
      if (candidate.score(words) case final match?) match,
  ]..sort(_compare);
  final listed = scored.take(whereIsLimit).toList();
  return ToolReply(
    {
      'query': query,
      'total': scored.length,
      'matches': [for (final match in listed) match.toJson()],
    },
    switch (listed) {
      [] => 'Nothing in the project map matches "$query".',
      [final best, ...] =>
        'Best match for "$query": ${best.candidate.kind} '
            '`${best.candidate.name}`'
            '${best.candidate.file == null ? '' : ' in ${best.candidate.file}${best.candidate.line == null ? '' : ':${best.candidate.line}'}'}'
            '; ${scored.length} '
            '${scored.length == 1 ? 'candidate' : 'candidates'} matched.',
    },
  );
}

int _compare(_Match a, _Match b) {
  if (a.score != b.score) return b.score.compareTo(a.score);
  final byName = a.candidate.name.compareTo(b.candidate.name);
  if (byName != 0) return byName;
  return (a.candidate.file ?? '').compareTo(b.candidate.file ?? '');
}

/// Something `where_is` can find, with the word groups it is matched on;
/// every group scores [tier].
final class _Candidate {
  _Candidate({
    required this.kind,
    required this.name,
    required this.tier,
    required this.groups,
    this.file,
    this.line,
    this.layer,
    this.feature,
    this.summary,
  });

  final String kind;
  final String name;
  final int tier;
  final List<(Set<String>, String)> groups;
  final String? file;
  final int? line;
  final String? layer;
  final String? feature;
  final String? summary;

  /// How this candidate matches [words], or null when no word matches.
  _Match? score(List<String> words) {
    var total = 0;
    final reasons = <String>[];
    for (final word in words) {
      final exact = groups.where((group) => group.$1.contains(word)).firstOrNull;
      if (exact != null) {
        total += tier;
        reasons.add('`$word` is a word of ${exact.$2}');
        continue;
      }
      if (word.length < 4) continue;
      found:
      for (final (groupWords, what) in groups) {
        for (final candidateWord in groupWords) {
          if (editDistance(word, candidateWord) <= 2) {
            total += 1;
            reasons.add('`$word` is close to `$candidateWord` in $what');
            break found;
          }
        }
      }
    }
    return total == 0 ? null : _Match(this, total, reasons);
  }
}

final class _Match {
  _Match(this.candidate, this.score, this.reasons);

  final _Candidate candidate;
  final int score;
  final List<String> reasons;

  Map<String, Object?> toJson() => {
    'kind': candidate.kind,
    'name': candidate.name,
    'score': score,
    'reasons': reasons,
    'file': candidate.file,
    'line': candidate.line,
    'layer': candidate.layer,
    'feature': candidate.feature,
    'summary': candidate.summary,
  };
}
```

The test's expected reason text for a symbol word is "`login` is a word of the symbol name `LoginScreen`", which is what `'`$word` is a word of ${exact.$2}'` gives. `editDistance` is imported from `edit_distance.dart`; `MapFileEntry` has `layer` and `feature` (`layers_map.dart` lines 15–18).

Export it from `appstein_engine.dart`.

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/mcp/where_is_test.dart`
Expected: PASS, 8 tests. If "ties go to the name" fails because files and symbols interleave, read the actual order and check it is by score, then name, then file; the test asserts only that symbols among the listed matches are in name order within equal scores, so a failure there is a real ordering bug.

- [ ] **Step 6: Commit**

```bash
git add packages/appstein_protocol packages/appstein_engine
git commit -m "feat(engine): the where_is query

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW"
```

---

### Task 5: `feature` and `route`

**Files:**
- Create: `packages/appstein_engine/lib/src/mcp/feature_query.dart`
- Create: `packages/appstein_engine/lib/src/mcp/route_query.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (export both)
- Modify: `packages/appstein_protocol/lib/src/mcp/tool_schemas.dart`
- Test: `packages/appstein_engine/test/mcp/feature_query_test.dart`, `route_query_test.dart`

**Interfaces:**
- Consumes: `FeaturesMap`, `RoutesMap`, `CodeRef`, `closestMatch` (`edit_distance.dart`), `ToolAnswer`.
- Produces:
  - `ToolAnswer featureInfo(String name, {required FeaturesMap features, required RoutesMap routes})`
  - `ToolAnswer routeInfo(String path, {required RoutesMap routes, required FeaturesMap features})`
  - `ToolSchemas.featureInput`, `featureResult`, `routeInput`, `routeResult`.

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/mcp/feature_query_test.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/mcp_support.dart';

void main() {
  final features = FeaturesMap.fromJson(golden('features.json'));
  final routes = RoutesMap.fromJson(golden('routes.json'));

  ToolAnswer ask(String name) =>
      featureInfo(name, features: features, routes: routes);

  test('a feature with its screens, view models and routes', () {
    final reply = ask('auth/login') as ToolReply;
    expect(reply.result['name'], 'auth/login');
    expect(reply.result['folder'], 'lib/ui/auth/login');
    expect(reply.result['screens'], [
      {'name': 'LoginScreen', 'file': 'lib/ui/auth/login/widgets/login_screen.dart'},
    ]);
    expect(reply.result['routes'], [
      {
        'path': '/login',
        'file': 'lib/routing/router.dart',
        'line': 22,
        'screen': 'LoginScreen',
      },
    ]);
    expect(
      reply.summary,
      'Feature `auth/login` (lib/ui/auth/login): 1 screen, 1 view model, 1 '
      'repository, 0 services, 0 models, 1 route, 0 tests.',
    );
    expectMatchesSchema(ToolSchemas.featureResult, withoutNulls(reply.result));
  });

  test('a route whose path is unresolved is listed with its reason', () {
    final reply = ask('settings') as ToolReply;
    final listed = (reply.result['routes']! as List).cast<Map<String, Object?>>();
    expect(listed.single['unresolved'], isTrue);
    expect(listed.single['reason'], 'the path is not a constant string');
    expect(listed.single['screen'], 'SettingsScreen');
    expect(listed.single.containsKey('path'), isFalse);
  });

  test('the folder or a slash-wrapped name finds the feature', () {
    expect((ask('lib/ui/booking') as ToolReply).result['name'], 'booking');
    expect((ask('/home/') as ToolReply).result['name'], 'home');
  });

  test('an unknown name suggests the closest and lists the features', () {
    expect(
      (ask('bookng') as ToolRefusal).message,
      'No feature is named "bookng". Did you mean "booking"? The project '
      'has 5 features: auth/login, booking, home, profile, settings.',
    );
  });
}
```

Create `packages/appstein_engine/test/mcp/route_query_test.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/mcp_support.dart';

void main() {
  final routes = RoutesMap.fromJson(golden('routes.json'));
  final features = FeaturesMap.fromJson(golden('features.json'));

  ToolReply ask(String path) =>
      routeInfo(path, routes: routes, features: features) as ToolReply;

  Map<String, Object?> only(ToolReply reply) =>
      (reply.result['routes']! as List).single as Map<String, Object?>;

  test('an exact path: screen, feature and parent', () {
    final reply = ask('/login');
    expect(reply.result['match'], 'exact');
    final route = only(reply);
    expect(route['screen'], {
      'name': 'LoginScreen',
      'file': 'lib/ui/auth/login/widgets/login_screen.dart',
    });
    expect(route['feature'], 'auth/login');
    expect(route['redirect'], isFalse);
    expect(reply.result['routerRedirects'], isTrue);
    expectMatchesSchema(ToolSchemas.routeResult, withoutNulls(reply.result));
  });

  test('a concrete path matches a pattern', () {
    final reply = ask('/booking/42');
    expect(reply.result['match'], 'pattern');
    final route = only(reply);
    expect(route['path'], '/booking/:id');
    expect(route['redirect'], isTrue);
    expect(route['screen'], isNull);
    expect(route['parent'], '/booking');
    expect(
      reply.result['redirectNote'],
      'The map records that a route or its router redirects, not where to.',
    );
  });

  test('nested routes, counting children whose path is unresolved', () {
    expect(only(ask('/booking'))['children'], ['/booking/:id']);
    final root = only(ask('/'));
    expect(root['children'], ['/booking']);
    expect(root['unresolvedChildren'], 1);
  });

  test('the forms an agent sends: no slash, a trailing slash, a query', () {
    expect(only(ask('login'))['path'], '/login');
    expect(only(ask('/profile/'))['path'], '/profile');
    expect(only(ask('/booking/7?tab=2#top'))['path'], '/booking/:id');
  });

  test('an unknown path lists the known ones', () {
    expect(
      (routeInfo('/nope', routes: routes, features: features) as ToolRefusal)
          .message,
      'No route matches "/nope". Routes with a known path: /, /about, '
      '/booking, /booking/:id, /login, /profile, /settings. 1 route has a '
      'path Appstein could not resolve; see `.appstein/map/routes.json`.',
    );
  });
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/mcp/feature_query_test.dart test/mcp/route_query_test.dart`
Expected: FAIL to compile.

- [ ] **Step 3: Add the schemas**

In `tool_schemas.dart`, add a private code-reference schema at the top of the class and the four schemas:

```dart
  static final Map<String, Object?> _codeRef = jsonObject(
    {'name': jsonString(), 'file': jsonString()},
    required: ['name', 'file'],
  );

  /// `feature`'s input.
  static final Map<String, Object?> featureInput = jsonObject(
    {
      'name': jsonString(
        description: 'The feature: its folder below lib/ui/, such as '
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
      'name', 'folder', 'viewModels', 'screens', 'repositories', 'services',
      'models', 'tests', 'files', 'routes',
    ],
  );

  /// `route`'s input.
  static final Map<String, Object?> routeInput = jsonObject(
    {
      'path': jsonString(
        description: 'A path, such as `/booking/42`; it may match a pattern '
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
            'path', 'children', 'unresolvedChildren', 'redirect', 'file',
            'line',
          ],
        ),
      ),
      'routerRedirects': jsonBoolean(),
      'redirectNote': jsonString(),
    },
    required: ['path', 'match', 'routes', 'routerRedirects', 'redirectNote'],
  );
```

Dart initializes `static final` fields lazily, on first read, so `_codeRef` may be declared anywhere in the class.

- [ ] **Step 4: Write `feature`**

Create `packages/appstein_engine/lib/src/mcp/feature_query.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import '../text/edit_distance.dart';
import 'tool_answer.dart';

/// `feature` (spec §8): everything in the feature [name] (its folder below
/// `lib/ui/`, such as `auth/login`; the folder itself, or the name wrapped
/// in slashes, works too), with the routes that build its screens.
///
/// An unknown name is refused, with the closest name and the list of
/// features.
ToolAnswer featureInfo(
  String name, {
  required FeaturesMap features,
  required RoutesMap routes,
}) {
  var wanted = name.trim().replaceAll(RegExp(r'^/+|/+$'), '');
  if (wanted.startsWith('lib/ui/')) wanted = wanted.substring('lib/ui/'.length);
  final feature = features.features[wanted];
  if (feature == null) {
    final names = features.features.keys.toList()..sort();
    final closest = closestMatch(wanted, names);
    return ToolRefusal(
      [
        'No feature is named "$name".',
        if (closest != null) 'Did you mean "$closest"?',
        if (names.isEmpty)
          'The project has no features.'
        else
          'The project has ${names.length} features: '
              '${names.take(20).join(', ')}${names.length > 20 ? ', …' : ''}.',
      ].join(' '),
    );
  }
  bool isScreen(CodeRef ref) => feature.screens.any(
    (screen) => screen.name == ref.name && screen.file == ref.file,
  );
  final featureRoutes = [
    for (final route in routes.routes)
      if (route.screen case final screen? when isScreen(screen))
        {
          'path': ?route.path,
          'file': route.file,
          'line': route.line,
          'screen': screen.name,
          if (route.unresolved) 'unresolved': true,
          'reason': ?route.reason,
        },
  ];
  String count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
  return ToolReply(
    {'name': wanted, ...feature.toJson(), 'routes': featureRoutes},
    'Feature `$wanted` (${feature.folder}): '
    '${count(feature.screens.length, 'screen', 'screens')}, '
    '${count(feature.viewModels.length, 'view model', 'view models')}, '
    '${count(feature.repositories.length, 'repository', 'repositories')}, '
    '${count(feature.services.length, 'service', 'services')}, '
    '${count(feature.models.length, 'model', 'models')}, '
    '${count(featureRoutes.length, 'route', 'routes')}, '
    '${count(feature.tests.length, 'test', 'tests')}.',
  );
}
```

The route entries use null-aware entries (`'path': ?route.path`), so a resolved route has no `reason` key and an unresolved path has no `path` key; the tests compare whole maps and rely on that.

- [ ] **Step 5: Write `route`**

Create `packages/appstein_engine/lib/src/mcp/route_query.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import 'tool_answer.dart';

/// `route` (spec §8): the go_router route for [path], with its screen,
/// feature, parent, nested routes and whether it redirects.
///
/// [path] may come without its leading slash, with a trailing slash, or
/// with a query or fragment, which are ignored. An exact path wins;
/// otherwise a concrete path matches a pattern (`/booking/42` matches
/// `/booking/:id`). Routes whose path couldn't be resolved are never
/// matched. The map records that a route or its router redirects, not
/// where to, and the reply says so.
ToolAnswer routeInfo(
  String path, {
  required RoutesMap routes,
  required FeaturesMap features,
}) {
  var wanted = path.trim();
  final cut = wanted.indexOf(RegExp('[?#]'));
  if (cut >= 0) wanted = wanted.substring(0, cut);
  if (!wanted.startsWith('/')) wanted = '/$wanted';
  if (wanted.length > 1 && wanted.endsWith('/')) {
    wanted = wanted.substring(0, wanted.length - 1);
  }
  final known = [
    for (final route in routes.routes)
      if (route.path != null) route,
  ];
  var match = 'exact';
  var matched = [
    for (final route in known)
      if (route.path == wanted) route,
  ];
  if (matched.isEmpty) {
    match = 'pattern';
    matched = [
      for (final route in known)
        if (_matchesPattern(route.path!, wanted)) route,
    ];
  }
  if (matched.isEmpty) {
    final paths = {for (final route in known) route.path!}.toList()..sort();
    final unresolved = routes.routes.where((r) => r.path == null).length;
    return ToolRefusal(
      [
        'No route matches "$path".',
        if (paths.isEmpty)
          'No route has a known path.'
        else
          'Routes with a known path: ${paths.take(20).join(', ')}'
              '${paths.length > 20 ? ', …' : ''}.',
        if (unresolved > 0)
          '$unresolved ${unresolved == 1 ? 'route has a path' : 'routes have paths'} '
              'Appstein could not resolve; see `.appstein/map/routes.json`.',
      ].join(' '),
    );
  }
  Map<String, Object?> describe(MapRoute route) {
    final children = [
      for (final child in routes.routes)
        if (child.parent == route.path) child,
    ];
    return {
      'path': route.path,
      'name': ?route.name,
      'screen': ?route.screen?.toJson(),
      'feature': ?switch (route.screen) {
        final screen? => features.featureOf(screen.file),
        null => null,
      },
      'parent': ?route.parent,
      'children': [
        for (final child in children)
          if (child.path case final childPath?) childPath,
      ]..sort(),
      'unresolvedChildren': children.where((c) => c.path == null).length,
      'redirect': route.redirect,
      'file': route.file,
      'line': route.line,
      if (route.unresolved) 'unresolved': true,
      'reason': ?route.reason,
    };
  }

  final first = matched.first;
  return ToolReply(
    {
      'path': wanted,
      'match': match,
      'routes': [for (final route in matched) describe(route)],
      'routerRedirects': routes.routers.any((router) => router.redirect),
      'redirectNote':
          'The map records that a route or its router redirects, not where '
          'to.',
    },
    [
      'Route `${first.path}`'
          '${match == 'pattern' ? ' (a pattern matching `$wanted`)' : ''}:',
      switch (first.screen) {
        final screen? =>
          'screen `${screen.name}`'
              '${features.featureOf(screen.file) case final f? ? ' in feature `$f`' : ''}.',
        null =>
          'no screen recorded${first.reason == null ? '' : ' (${first.reason})'}.',
      },
      if (first.redirect) 'It redirects.',
      if (matched.length > 1) '${matched.length} routes match.',
    ].join(' '),
  );
}

/// Whether [path] matches the go_router [pattern]: the same number of
/// segments, each equal or matched by a `:parameter` segment.
bool _matchesPattern(String pattern, String path) {
  final expected = pattern.split('/');
  final actual = path.split('/');
  if (expected.length != actual.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (expected[i].startsWith(':')) {
      if (actual[i].isEmpty) return false;
    } else if (expected[i] != actual[i]) {
      return false;
    }
  }
  return true;
}
```

The `?switch …` and `${… case final f? ? … : ''}` forms may not parse; if the analyzer rejects either, compute the feature into a local `final feature = …;` first and use `'feature': ?feature` and a plain conditional. The route-test expectation `route['screen'], isNull` holds because the key is absent.

Export both files from `appstein_engine.dart`.

- [ ] **Step 6: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/mcp/feature_query_test.dart test/mcp/route_query_test.dart`
Expected: PASS, 9 tests.

- [ ] **Step 7: Commit**

```bash
git add packages/appstein_protocol packages/appstein_engine
git commit -m "feat(engine): the feature and route queries

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW"
```

---

### Task 6: `check_api` and `what_changed`

**Files:**
- Create: `packages/appstein_engine/lib/src/mcp/check_api.dart`
- Create: `packages/appstein_engine/lib/src/mcp/what_changed.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (export both)
- Modify: `packages/appstein_protocol/lib/src/mcp/tool_schemas.dart`
- Test: `packages/appstein_engine/test/mcp/check_api_test.dart`, `what_changed_test.dart`
- Create (test support): `packages/appstein_engine/test/mcp/support/sample_delta.dart`

**Interfaces:**
- Consumes: `DeltaKnowledge` and its entry classes (Task 1), `flutterMinorOf`, `compareFlutterMinors` (`notes/flutter_minor.dart`), `ToolAnswer`.
- Produces:
  - `ToolAnswer checkApi(String name, DeltaKnowledge delta)`
  - `ToolAnswer whatChanged(DeltaKnowledge delta, {String? since, String? library})`
  - `ToolSchemas.checkApiInput`, `checkApiResult`, `whatChangedInput`, `whatChangedResult`.

- [ ] **Step 1: Write the sample delta**

Create `packages/appstein_engine/test/mcp/support/sample_delta.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

const _popScope = CuratedNote(
  id: 'popscope-not-willpopscope',
  since: '3.16',
  priority: 1,
  area: NoteArea.framework,
  summary: 'PopScope replaces WillPopScope.',
  use: '`PopScope` with `canPop`.',
  avoid: '`WillPopScope`.',
  source: 'https://docs.flutter.dev/release/breaking-changes/android-predictive-back',
);

const _dotShorthands = CuratedNote(
  id: 'dot-shorthands',
  since: '3.38',
  languageVersion: '3.10',
  priority: 2,
  area: NoteArea.dart,
  summary: 'Dot shorthands omit the type name.',
  use: '`mainAxisAlignment: .center`.',
  avoid: 'Shorthands below language version 3.10.',
  source: 'https://dart.dev/language/dot-shorthands',
);

const _primaryConstructors = CuratedNote(
  id: 'dart-primary-constructors',
  since: '3.47',
  languageVersion: '3.13',
  priority: 2,
  area: NoteArea.dart,
  summary: 'Primary constructors declare fields in the class header.',
  use: '`class Point(final int x, final int y);`.',
  avoid: 'Primary constructors below language version 3.13.',
  source: 'https://dart.dev/language/constructors',
);

/// A delta like a small app's: deprecations of each kind, removed and
/// changed APIs, a moved library and an unread migration file.
const sampleDelta = DeltaKnowledge(
  flutterVersion: '3.47.5',
  languageVersion: '3.12',
  baseline: '3.16',
  coverage: 'complete',
  newestNotes: '3.47',
  notes: [_popScope, _dotShorthands],
  laterNotes: [_primaryConstructors],
  apis: DeltaApis(
    deprecated: [
      DeltaDeprecatedApi(
        library: 'dart:core',
        name: 'RegExp',
        kind: 'implement',
        rule: "don't implement it.",
        message: "This class will become 'final' in a future release.",
      ),
      DeltaDeprecatedApi(
        library: 'package:flutter',
        name: 'Color.withOpacity',
        kind: 'use',
        message: 'Use .withValues() to avoid precision loss.',
      ),
      DeltaDeprecatedApi(
        library: 'package:flutter',
        name: 'NewBox.colour=',
        kind: 'use',
        message: 'Use color.',
      ),
      DeltaDeprecatedApi(
        library: 'package:flutter',
        name: 'Text.new(textScaleFactor)',
        kind: 'use',
        message: 'Use textScaler instead.',
      ),
      DeltaDeprecatedApi(
        library: 'package:flutter',
        name: 'WillPopScope',
        kind: 'use',
        message: 'Use PopScope instead.',
        migrations: ["Migrate to 'PopScope'"],
      ),
      DeltaDeprecatedApi(
        library: 'package:go_router',
        name: 'GoRouter.new(label)',
        kind: 'optional',
        rule: 'always pass this argument: it will become required.',
      ),
    ],
    migrated: [
      DeltaMigratedApi(
        library: 'package:flutter',
        name: 'Stack.new(overflow)',
        status: 'removed',
        title: "Migrate to 'clipBehavior'",
      ),
      DeltaMigratedApi(
        library: 'package:flutter',
        name: 'Stack.overflow',
        status: 'removed',
        title: "Migrate to 'clipBehavior'",
      ),
      DeltaMigratedApi(
        library: 'package:flutter',
        name: 'ThemeData.toggleableActiveColor',
        status: 'changed',
        title: 'Move to colorScheme.secondary',
      ),
      DeltaMigratedApi(
        library: 'package:go_router',
        name: 'GoRouterState.location',
        status: 'removed',
        title: "Replaces 'location' with `uri.toString()`",
      ),
    ],
    moved: [
      DeltaMovedLibrary(
        from: 'package:flutter/material.dart',
        to: 'package:material_ui/material_ui.dart',
        title: 'Migrate from flutter/material.dart to material_ui.',
      ),
    ],
    unread: [
      DeltaUnreadFile(
        file: 'package:delta_kit/fix_data/fix_broken.yaml',
        reason: 'line 2: A transform needs an "element" map.',
      ),
    ],
  ),
);

/// [sampleDelta] without its API lists, as after a skipped map.
const sampleDeltaWithoutApis = DeltaKnowledge(
  flutterVersion: '3.47.5',
  languageVersion: '3.12',
  baseline: '3.16',
  coverage: 'complete',
  newestNotes: '3.47',
  notes: [_popScope, _dotShorthands],
  laterNotes: [_primaryConstructors],
  missing: 'the packages could not be fetched',
);
```

- [ ] **Step 2: Write the failing tests**

Create `packages/appstein_engine/test/mcp/check_api_test.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/mcp_support.dart';
import 'support/sample_delta.dart';

void main() {
  ToolReply ask(String name, [DeltaKnowledge delta = sampleDelta]) =>
      checkApi(name, delta) as ToolReply;

  List<Map<String, Object?>> matches(ToolReply reply) =>
      (reply.result['matches']! as List).cast<Map<String, Object?>>();

  test('a deprecated class: its message, migration and the note', () {
    final reply = ask('WillPopScope');
    expect(reply.result['status'], 'deprecated');
    final found = matches(reply);
    expect(found.first, {
      'kind': 'deprecated',
      'library': 'package:flutter',
      'name': 'WillPopScope',
      'deprecationKind': 'use',
      'message': 'Use PopScope instead.',
      'migrations': ["Migrate to 'PopScope'"],
    });
    expect(found.last['kind'], 'note');
    expect(found.last['id'], 'popscope-not-willpopscope');
    expect(
      reply.summary,
      '`WillPopScope` is deprecated: Use PopScope instead. 1 curated note '
      'mentions it.',
    );
    expectMatchesSchema(ToolSchemas.checkApiResult, withoutNulls(reply.result));
  });

  test('a member by its own name or with its class', () {
    expect(ask('withOpacity').result['status'], 'deprecated');
    expect(ask('Color.withOpacity').result['status'], 'deprecated');
    expect(ask('withOpacity()').result['status'], 'deprecated');
    expect(ask('colour').result['status'], 'deprecated');
  });

  test('a removed member, and a removed parameter of the same name', () {
    final reply = ask('overflow');
    expect(reply.result['status'], 'removed');
    final found = matches(reply);
    expect(found.map((m) => m['name']), [
      'Stack.new(overflow)',
      'Stack.overflow',
    ]);
    expect(found.first['parameter'], isTrue);
    expect(reply.summary, startsWith("`overflow` is removed: Migrate to "
        "'clipBehavior'."));
  });

  test("a constructor whose parameter is deprecated is itself ok", () {
    final reply = ask('Text.new');
    expect(reply.result['status'], 'ok');
    expect(matches(reply).single['parameter'], isTrue);
    expect(reply.summary, contains('Some of its parameters are deprecated or '
        'removed; see `matches`.'));
    expect(ask('Text.new(textScaleFactor)').result['status'], 'deprecated');
  });

  test('a deprecation of another kind forbids only that use', () {
    final reply = ask('RegExp');
    expect(reply.result['status'], 'ok');
    expect(matches(reply).single['rule'], "don't implement it.");
    expect(reply.summary, contains("Its deprecation forbids only this: don't "
        'implement it.'));
  });

  test('changed and moved APIs are listed without changing the status', () {
    expect(ask('toggleableActiveColor').result['status'], 'ok');
    expect(matches(ask('toggleableActiveColor')).single['kind'], 'changed');
    final moved = ask('package:flutter/material.dart');
    expect(moved.result['status'], 'ok');
    expect(matches(moved).single['to'], 'package:material_ui/material_ui.dart');
  });

  test('a name nothing lists is ok, and says what that means', () {
    final reply = ask('Container');
    expect(reply.result['status'], 'ok');
    expect(matches(reply), isEmpty);
    expect(
      reply.result['meaning'],
      "Nothing the project imports deprecates or removes `Container`. "
      "Whether it exists isn't checked here; the Dart MCP server's analyzer "
      'does that.',
    );
    expect(
      reply.summary,
      '`Container` is ok: nothing the project imports deprecates or removes '
      'it.',
    );
  });

  test('without API lists, only the notes are checked, and it says so', () {
    final reply = ask('WillPopScope', sampleDeltaWithoutApis);
    expect(reply.result['status'], 'ok');
    expect(matches(reply).single['kind'], 'note');
    expect(
      reply.result['incomplete'],
      'Only the curated notes were checked: the API lists are missing (the '
      'packages could not be fetched).',
    );
    expect(reply.summary, startsWith('Only the curated notes were checked'));
  });

  test('an empty name is refused', () {
    expect(
      (checkApi('  ', sampleDelta) as ToolRefusal).message,
      'Give the name of an API, such as `WillPopScope` or '
      '`Color.withOpacity`.',
    );
  });
}
```

Create `packages/appstein_engine/test/mcp/what_changed_test.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/mcp_support.dart';
import 'support/sample_delta.dart';

void main() {
  ToolAnswer ask({String? since, String? library}) =>
      whatChanged(sampleDelta, since: since, library: library);

  List<String> ids(Object? notes) => [
    for (final note in (notes! as List).cast<Map<String, Object?>>())
      note['id']! as String,
  ];

  test('without arguments: every note and per-library counts, no entries',
      () {
    final reply = ask() as ToolReply;
    expect(reply.result['notesFrom'], '3.16');
    expect(ids(reply.result['notes']), [
      'popscope-not-willpopscope',
      'dot-shorthands',
    ]);
    expect(ids(reply.result['laterNotes']), ['dart-primary-constructors']);
    expect(reply.result['libraries'], [
      {'library': 'dart:core', 'deprecated': 1, 'removed': 0, 'changed': 0, 'moved': 0},
      {'library': 'package:flutter', 'deprecated': 4, 'removed': 2, 'changed': 1, 'moved': 1},
      {'library': 'package:go_router', 'deprecated': 1, 'removed': 1, 'changed': 0, 'moved': 0},
    ]);
    expect(reply.result.containsKey('library'), isFalse);
    expect(
      reply.summary,
      '2 curated notes since 3.16 (1 more needs a newer language version); '
      '6 deprecated, 3 removed, 1 changed and 1 moved APIs in 3 libraries. '
      'Ask `check_api` about one name, or pass `library` for a library\'s '
      'list.',
    );
    expectMatchesSchema(
      ToolSchemas.whatChangedResult,
      withoutNulls(reply.result),
    );
  });

  test('since narrows the notes only', () {
    final reply = ask(since: '3.38') as ToolReply;
    expect(reply.result['notesFrom'], '3.38');
    expect(ids(reply.result['notes']), ['dot-shorthands']);
    expect(ids(reply.result['laterNotes']), ['dart-primary-constructors']);
    expect((reply.result['libraries']! as List).length, 3);
  });

  test('a since older than the baseline starts at the baseline', () {
    final reply = ask(since: '3.10') as ToolReply;
    expect(reply.result['notesFrom'], '3.16');
    expect(reply.summary, contains('the notes start at the baseline, 3.16'));
  });

  test('a library lists its entries in full; package: may be left out', () {
    final reply = ask(library: 'go_router') as ToolReply;
    final entries = reply.result['library']! as Map<String, Object?>;
    expect(entries['library'], 'package:go_router');
    expect(
      (entries['deprecated']! as List).single,
      containsPair('name', 'GoRouter.new(label)'),
    );
    expect(
      (entries['migrated']! as List).single,
      containsPair('name', 'GoRouterState.location'),
    );
    expect(entries['moved'], isEmpty);
    expect(
      reply.summary,
      endsWith('`package:go_router`: 1 deprecated, 1 removed or changed and '
          '0 moved APIs listed.'),
    );
    expectMatchesSchema(
      ToolSchemas.whatChangedResult,
      withoutNulls(reply.result),
    );
  });

  test('a moved library counts under its package', () {
    final reply = ask(library: 'package:flutter') as ToolReply;
    final entries = reply.result['library']! as Map<String, Object?>;
    expect((entries['moved']! as List).single,
        containsPair('from', 'package:flutter/material.dart'));
  });

  test('a library with no entries is refused, listing those that have', () {
    expect(
      (ask(library: 'package:nope') as ToolRefusal).message,
      'No library "package:nope" has deprecated, removed or moved APIs in '
      'the delta. Libraries that do: dart:core, package:flutter, '
      'package:go_router.',
    );
  });

  test('a since that is not a version is refused', () {
    expect(
      (ask(since: 'latest') as ToolRefusal).message,
      '"latest" is not a Flutter version; give one such as `3.27`.',
    );
  });

  test('without API lists: the notes, and why the counts are missing', () {
    final reply = whatChanged(sampleDeltaWithoutApis) as ToolReply;
    expect(reply.result['libraries'], isEmpty);
    expect(reply.result['apiListsMissing'], 'the packages could not be fetched');
    expect(
      (whatChanged(sampleDeltaWithoutApis, library: 'go_router') as ToolRefusal)
          .message,
      'The API lists are missing: the packages could not be fetched.',
    );
  });
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/mcp/check_api_test.dart test/mcp/what_changed_test.dart`
Expected: FAIL to compile.

- [ ] **Step 4: Add the schemas**

In `tool_schemas.dart`, add:

```dart
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
    required: ['id', 'since', 'priority', 'area', 'summary', 'use', 'avoid',
        'source'],
  );

  /// `check_api`'s input.
  static final Map<String, Object?> checkApiInput = jsonObject(
    {
      'name': jsonString(
        description: 'An API name: `WillPopScope`, `withOpacity`, '
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
      description: 'A library, such as `package:go_router` or `dart:core`: '
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
    required: ['flutterVersion', 'coverage', 'notesFrom', 'notes',
        'laterNotes', 'libraries', 'unread'],
  );
```

- [ ] **Step 5: Write `check_api`**

Create `packages/appstein_engine/lib/src/mcp/check_api.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import 'tool_answer.dart';

/// `check_api` (spec §8): whether the API [name] is deprecated or removed
/// for the project, from [delta] (`delta.json`).
///
/// [name] may be a class or function (`WillPopScope`), a member alone or
/// with its class (`withOpacity`, `Color.withOpacity`), a setter without
/// its `=` (`colour`), a parameter (`Text.new(textScaleFactor)`), a library
/// URI, or any of these followed by `()`. It matches:
/// - the deprecated and the removed or changed APIs: by full name; by a
///   member's own name when [name] has no `.`; and the parameters of the
///   member [name] (or a parameter of that name);
/// - the moved libraries, by URI;
/// - the curated notes whose `avoid` names it as a whole word.
///
/// The status is `removed` when a removed API matches, otherwise
/// `deprecated` when an API deprecated for any use matches, otherwise `ok`
/// (spec §6.4: another deprecation kind forbids only that one use).
/// Parameters, changed APIs, moved libraries and notes are listed without
/// changing the status. `ok` means nothing the project imports deprecates
/// or removes the name; whether it exists isn't checked.
ToolAnswer checkApi(String name, DeltaKnowledge delta) {
  final input = name.trim().replaceFirst(RegExp(r'\(\)$'), '');
  if (input.isEmpty) {
    return const ToolRefusal(
      'Give the name of an API, such as `WillPopScope` or '
      '`Color.withOpacity`.',
    );
  }
  final apis = delta.apis;
  final matches = <Map<String, Object?>>[];
  var removed = false;
  var deprecated = false;
  final removals = <String>[];
  final deprecations = <String>[];
  final rules = <String>[];
  var parameters = false;
  if (apis != null) {
    for (final api in apis.deprecated) {
      final match = _match(api.name, input);
      if (match == null) continue;
      final parameter = match == _Match.parameter;
      parameters |= parameter;
      if (!parameter) {
        if (api.kind == 'use') {
          deprecated = true;
          deprecations.add(api.message ?? 'deprecated, with no message');
        } else if (api.rule case final rule?) {
          rules.add(rule);
        }
      }
      matches.add({
        'kind': 'deprecated',
        'library': api.library,
        'name': api.name,
        'deprecationKind': api.kind,
        'rule': ?api.rule,
        'message': ?api.message,
        if (api.migrations.isNotEmpty) 'migrations': api.migrations,
        if (parameter) 'parameter': true,
      });
    }
    for (final api in apis.migrated) {
      final match = _match(api.name, input);
      if (match == null) continue;
      final parameter = match == _Match.parameter;
      parameters |= parameter;
      if (!parameter && api.status == 'removed') {
        removed = true;
        removals.add(api.title);
      }
      matches.add({
        'kind': api.status,
        'library': api.library,
        'name': api.name,
        'migration': api.title,
        if (parameter) 'parameter': true,
      });
    }
    for (final moved in apis.moved) {
      if (moved.from != input) continue;
      matches.add({
        'kind': 'moved',
        'name': moved.from,
        'to': ?moved.to,
        'migration': moved.title,
      });
    }
  }
  final terms = {input, if (input.contains('.')) input.split('.').last};
  var notes = 0;
  for (final note in [...delta.notes, ...delta.laterNotes]) {
    if (!terms.any((term) => _namesWord(note.avoid, term))) continue;
    notes++;
    matches.add({
      'kind': 'note',
      'id': note.id,
      'summary': note.summary,
      'use': note.use,
      'avoid': note.avoid,
      'source': note.source,
    });
  }
  final status = removed
      ? 'removed'
      : deprecated
      ? 'deprecated'
      : 'ok';
  final incomplete = apis == null
      ? 'Only the curated notes were checked: the API lists are missing '
            '(${delta.missing}).'
      : null;
  final summary = [
    ?incomplete,
    switch (status) {
      'removed' => '`$input` is removed: ${_withFullStop(removals.first)}',
      'deprecated' =>
        '`$input` is deprecated: ${_withFullStop(deprecations.first)}',
      _ =>
        '`$input` is ok: nothing the project imports deprecates or removes '
            'it.',
    },
    if (status == 'ok' && rules.isNotEmpty)
      'Its deprecation forbids only this: ${rules.first}',
    if (status == 'ok' && parameters)
      'Some of its parameters are deprecated or removed; see `matches`.',
    if (notes > 0)
      '$notes curated ${notes == 1 ? 'note mentions' : 'notes mention'} it.',
  ].join(' ');
  return ToolReply({
    'name': input,
    'status': status,
    'matches': matches,
    if (status == 'ok')
      'meaning':
          'Nothing the project imports deprecates or removes `$input`. '
          "Whether it exists isn't checked here; the Dart MCP server's "
          'analyzer does that.',
    'incomplete': ?incomplete,
  }, summary);
}

enum _Match { exact, member, parameter }

/// How the API named [entry] in the delta matches [input], or null.
_Match? _match(String entry, String input) {
  if (entry == input) return _Match.exact;
  if (input.contains('(')) return null;
  final paren = entry.indexOf('(');
  if (paren >= 0) {
    final member = entry.substring(0, paren);
    final parameter = entry.substring(paren + 1, entry.length - 1);
    return member == input || parameter == input ? _Match.parameter : null;
  }
  if (input.contains('.')) return null;
  final member = entry.endsWith('=')
      ? entry.substring(0, entry.length - 1)
      : entry;
  return member.split('.').last == input ? _Match.member : null;
}

/// Whether [text] has [term] as a whole word: not inside a longer name.
bool _namesWord(String text, String term) => RegExp(
  '(?<![A-Za-z0-9_])${RegExp.escape(term)}(?![A-Za-z0-9_])',
).hasMatch(text);

String _withFullStop(String text) {
  final trimmed = text.trim();
  return trimmed.endsWith('.') ? trimmed : '$trimmed.';
}
```

Check against the tests: `overflow` → `Stack.new(overflow)` is a parameter match (its parameter is `overflow`), `Stack.overflow` a member match (removed), so the status is `removed` and the order follows the delta's order (parameter first). `Text.new` → parameter match only, status `ok`. `colour` → `NewBox.colour=` member match. `toggleableActiveColor` → changed. The `WillPopScope` deprecated entry has no `rule` and its JSON has no `rule` key, matching the test's whole-map expectation.

- [ ] **Step 6: Write `what_changed`**

Create `packages/appstein_engine/lib/src/mcp/what_changed.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import '../notes/flutter_minor.dart';
import 'tool_answer.dart';

/// `what_changed` (spec §8): the curated notes since [since] (by default
/// the baseline; `since` narrows only the notes), and, per library, how
/// many deprecated, removed, changed and moved APIs [delta] lists. With
/// [library] (`package:go_router`; `go_router` works too), that library's
/// entries in full. Without it, no entry is listed: a real app's delta has
/// hundreds, too many for an agent's context; `check_api` answers for one
/// name.
///
/// A moved library counts under its package (`package:flutter/material.dart`
/// under `package:flutter`).
ToolAnswer whatChanged(DeltaKnowledge delta, {String? since, String? library}) {
  FlutterMinor? from;
  if (since != null) {
    from = flutterMinorOf(since.trim());
    if (from == null) {
      return ToolRefusal(
        '"$since" is not a Flutter version; give one such as `3.27`.',
      );
    }
  }
  final baseline = flutterMinorOf(delta.baseline);
  final beforeBaseline =
      from != null && baseline != null && compareFlutterMinors(from, baseline) < 0;
  final notesFrom = from == null || beforeBaseline
      ? delta.baseline
      : '${from.major}.${from.minor}';
  bool keep(CuratedNote note) {
    if (from == null) return true;
    final noteMinor = flutterMinorOf(note.since);
    return noteMinor == null || compareFlutterMinors(noteMinor, from) >= 0;
  }

  final notes = [for (final note in delta.notes) if (keep(note)) note];
  final laterNotes = [for (final note in delta.laterNotes) if (keep(note)) note];
  final apis = delta.apis;
  final counts = <String, Map<String, int>>{};
  Map<String, int> countsOf(String name) => counts.putIfAbsent(
    name,
    () => {'deprecated': 0, 'removed': 0, 'changed': 0, 'moved': 0},
  );
  if (apis != null) {
    for (final api in apis.deprecated) {
      countsOf(api.library).update('deprecated', (n) => n + 1);
    }
    for (final api in apis.migrated) {
      countsOf(api.library).update(api.status, (n) => n + 1, ifAbsent: () => 1);
    }
    for (final moved in apis.moved) {
      countsOf(_libraryOf(moved.from)).update('moved', (n) => n + 1);
    }
  }
  final names = counts.keys.toList()..sort();
  final libraries = [
    for (final name in names) {'library': name, ...counts[name]!},
  ];
  Map<String, Object?>? entries;
  String? wanted;
  if (library != null) {
    wanted = library.trim();
    if (!wanted.contains(':')) wanted = 'package:$wanted';
    if (apis == null) {
      return ToolRefusal('The API lists are missing: ${delta.missing}.');
    }
    if (!counts.containsKey(wanted)) {
      return ToolRefusal(
        'No library "$wanted" has deprecated, removed or moved APIs in the '
        'delta. Libraries that do: ${names.join(', ')}.',
      );
    }
    entries = {
      'library': wanted,
      'deprecated': [
        for (final api in apis.deprecated)
          if (api.library == wanted) api.toJson(),
      ],
      'migrated': [
        for (final api in apis.migrated)
          if (api.library == wanted) api.toJson(),
      ],
      'moved': [
        for (final moved in apis.moved)
          if (_libraryOf(moved.from) == wanted) moved.toJson(),
      ],
    };
  }
  int total(String key) =>
      libraries.fold(0, (sum, row) => sum + (row[key]! as int));
  final summary = [
    '${notes.length} curated ${notes.length == 1 ? 'note' : 'notes'} since '
        '$notesFrom'
        '${laterNotes.isEmpty ? '' : ' (${laterNotes.length} more '
            '${laterNotes.length == 1 ? 'needs' : 'need'} a newer language '
            'version)'}'
        '${beforeBaseline ? '; the notes start at the baseline, ${delta.baseline}' : ''};',
    if (apis == null)
      'the API lists are missing (${delta.missing}).'
    else
      '${total('deprecated')} deprecated, ${total('removed')} removed, '
          '${total('changed')} changed and ${total('moved')} moved APIs in '
          '${libraries.length} ${libraries.length == 1 ? 'library' : 'libraries'}.',
    if (entries == null && apis != null)
      "Ask `check_api` about one name, or pass `library` for a library's "
          'list.',
    if (entries != null)
      '`$wanted`: ${(entries['deprecated']! as List).length} deprecated, '
          '${(entries['migrated']! as List).length} removed or changed and '
          '${(entries['moved']! as List).length} moved APIs listed.',
  ].join(' ');
  return ToolReply({
    'flutterVersion': delta.flutterVersion,
    'coverage': delta.coverage,
    'notesFrom': notesFrom,
    'notes': [for (final note in notes) note.toJson()],
    'laterNotes': [for (final note in laterNotes) note.toJson()],
    'libraries': libraries,
    'library': ?entries,
    'unread': [for (final unread in apis?.unread ?? const <DeltaUnreadFile>[]) unread.toJson()],
    'apiListsMissing': ?(apis == null ? delta.missing : null),
  }, summary);
}

/// The library a URI belongs to: `package:<name>` for a package URI, the
/// URI itself otherwise (`dart:core`).
String _libraryOf(String uri) => uri.startsWith('package:')
    ? 'package:${uri.substring('package:'.length).split('/').first}'
    : uri;
```

The summary test with no arguments expects exactly: `2 curated notes since 3.16 (1 more needs a newer language version); 6 deprecated, 3 removed, 1 changed and 1 moved APIs in 3 libraries. Ask `check_api` about one name, or pass `library` for a library's list.` Run the test and adjust the string building, not the expectation, if spacing differs.

Export both files from `appstein_engine.dart`.

- [ ] **Step 7: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/mcp/check_api_test.dart test/mcp/what_changed_test.dart`
Expected: PASS, 17 tests.

- [ ] **Step 8: Commit**

```bash
git add packages/appstein_protocol packages/appstein_engine
git commit -m "feat(engine): the check_api and what_changed queries

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW"
```

---

### Task 7: `toolchain`

**Files:**
- Create: `packages/appstein_engine/lib/src/mcp/toolchain_report.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (export it)
- Modify: `packages/appstein_protocol/lib/src/mcp/tool_schemas.dart`
- Test: `packages/appstein_engine/test/mcp/toolchain_report_test.dart`

**Interfaces:**
- Consumes: `Toolchain`, `AndroidToolchain`, `VersionThreshold`, `NativeConfig`, `NativeValue`, `NativeList`, `NativeStatus` (protocol), `ToolAnswer`.
- Produces:
  - `ToolAnswer toolchainInfo(Toolchain toolchain, NativeConfig? native)`
  - `int? compareVersions(String a, String b)` (null when either isn't a version number)
  - `ToolSchemas.toolchainResult`.

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/mcp/toolchain_report_test.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/mcp_support.dart';

void main() {
  const android = AndroidToolchain(
    template: AndroidTemplate(
      gradle: '8.14',
      agp: '8.11.1',
      kgp: '2.2.20',
      ndk: '28.2.13676358',
      compileSdk: 36,
      targetSdk: 36,
      minSdk: 24,
    ),
    flutterMinimums: AndroidMinimums(
      compileSdk: 34,
      buildTools: '34.0.0',
      java: VersionThreshold(warnBelow: '17', errorBelow: '11'),
    ),
    buildChecks: AndroidBuildChecks(
      gradle: VersionThreshold(warnBelow: '8.7.0', errorBelow: '8.3.0'),
      agp: VersionThreshold(warnBelow: '8.6.0', errorBelow: '8.1.1'),
      kgp: VersionThreshold(warnBelow: '2.1.0', errorBelow: '1.8.10'),
      java: VersionThreshold(warnBelow: '17', errorBelow: '11'),
      minSdk: VersionThreshold(warnBelow: '24', errorBelow: '21'),
    ),
    maxKnown: AndroidMaxKnown(
      gradle: '9.3.1',
      kgp: '2.4.0',
      agp: '9.1.0',
      agpWithFullKotlinSupport: '9.0.0',
    ),
    javaGradle: [],
    javaAgp: [],
  );
  const toolchain = Toolchain(
    android: Sourced(android, ToolchainSource.sdk),
    ios: Sourced(AppleToolchain(deploymentTarget: '15.0'), ToolchainSource.sdk),
    fallbacks: [],
    stores: StoreRequirements(play: {}, appStore: {}),
    notes: [],
  );
  final native = NativeConfig({
    'android': NativeGroup({
      'gradle': NativeGroup({
        'version': const NativeValue.found(
          '8.2',
          at: 'android/gradle/wrapper/gradle-wrapper.properties:5',
        ),
      }),
      'settings': NativeGroup({
        'agp': const NativeValue.found('8.5.0', at: 'android/settings.gradle.kts:22'),
        'kgp': const NativeValue.found('2.5.0', at: 'android/settings.gradle.kts:23'),
      }),
      'app': NativeGroup({
        'compileSdk': const NativeValue.found(33, at: 'android/app/build.gradle.kts:9'),
        'targetSdk': const NativeValue.found(36, at: 'android/app/build.gradle.kts:23'),
        'minSdk': const NativeValue.unknown('set conditionally'),
        'ndkVersion': const NativeValue.absent('not set'),
      }),
    }),
    'ios': NativeGroup({
      'xcode': NativeGroup({
        'configurations': NativeList([
          NativeEntry('Debug', {'deploymentTarget': const NativeValue.found('13.0')}),
          NativeEntry('Release', {'deploymentTarget': const NativeValue.found('15.0')}),
        ]),
      }),
    }),
  });

  test('compareVersions pads missing parts and ignores suffixes', () {
    expect(compareVersions('8.13', '8.13.0'), 0);
    expect(compareVersions('8.2', '8.13'), lessThan(0));
    expect(compareVersions('9.0.0-rc1', '9.0.0'), 0);
    expect(compareVersions('24', '21'), greaterThan(0));
    expect(compareVersions('JavaVersion.VERSION_17', '17'), isNull);
  });

  test("each mismatch against Flutter's own thresholds", () {
    final reply = toolchainInfo(toolchain, native) as ToolReply;
    final mismatches = (reply.result['mismatches']! as List)
        .cast<Map<String, Object?>>();
    expect([for (final m in mismatches) (m['name'], m['severity'], m['limit'])], [
      ('Gradle', 'error', '8.3.0'),
      ('AGP', 'warning', '8.6.0'),
      ('KGP', 'warning', '2.4.0'),
      ('compileSdk', 'warning', '34'),
      ('iOS deployment target (Debug)', 'warning', '15.0'),
    ]);
    expect(
      mismatches.first['message'],
      "Gradle 8.2 is below 8.3.0, where Flutter's Gradle plugin fails the "
      'build.',
    );
    expect(mismatches.first['at'], 'android/gradle/wrapper/gradle-wrapper.properties:5');
    expect(
      mismatches[2]['message'],
      'KGP 2.5.0 is newer than 2.4.0, the newest this Flutter knows.',
    );
    expect(reply.result['notComparable'], [
      {'name': 'minSdk', 'reason': 'set conditionally'},
    ]);
    expect(
      reply.summary,
      "5 mismatches between the project's native config and this Flutter's "
      'toolchain: 1 error, 4 warnings. 1 value could not be compared.',
    );
    expectMatchesSchema(ToolSchemas.toolchainResult, withoutNulls(reply.result));
  });

  test('the current values are listed with where they were found', () {
    final reply = toolchainInfo(toolchain, native) as ToolReply;
    final current = (reply.result['current']! as List).cast<Map<String, Object?>>();
    expect([for (final c in current) c['name']], [
      'Gradle', 'AGP', 'KGP', 'compileSdk', 'targetSdk', 'minSdk',
      'ndkVersion', 'iOS deployment target (Debug)',
      'iOS deployment target (Release)',
    ]);
    expect(current[3], {
      'name': 'compileSdk',
      'status': 'found',
      'value': '33',
      'at': 'android/app/build.gradle.kts:9',
    });
    expect(current[6]['status'], 'absent');
  });

  test('no native config: only the valid set, and the summary says why', () {
    final reply = toolchainInfo(toolchain, null) as ToolReply;
    expect(reply.result['current'], isEmpty);
    expect(reply.result['mismatches'], isEmpty);
    expect((reply.result['valid']! as Map).containsKey('android'), isTrue);
    expect(
      reply.summary,
      "`map/native.json` is missing, so only the versions that work with "
      'this Flutter are listed.',
    );
  });

  test('values within range are no mismatch', () {
    final fine = NativeConfig({
      'android': NativeGroup({
        'gradle': NativeGroup({'version': const NativeValue.found('8.14')}),
      }),
    });
    final reply = toolchainInfo(toolchain, fine) as ToolReply;
    expect(reply.result['mismatches'], isEmpty);
    expect(
      reply.summary,
      "The project's native values are within what this Flutter accepts.",
    );
  });
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/mcp/toolchain_report_test.dart`
Expected: FAIL to compile.

- [ ] **Step 3: Add the schema**

In `tool_schemas.dart`, add:

```dart
  /// `toolchain`'s result.
  static final Map<String, Object?> toolchainResult = jsonObject(
    {
      'valid': jsonObject(
        {},
        description: 'The native versions that work with this Flutter: '
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
```

- [ ] **Step 4: Write `toolchain`**

Create `packages/appstein_engine/lib/src/mcp/toolchain_report.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import 'tool_answer.dart';

/// Compares two dotted version numbers, padding missing parts with 0 and
/// ignoring a `-` or `+` suffix (`9.0.0-rc1` counts as `9.0.0`). Null when
/// either isn't a version number.
int? compareVersions(String a, String b) {
  final left = _parts(a);
  final right = _parts(b);
  if (left == null || right == null) return null;
  for (var i = 0; i < left.length || i < right.length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

List<int>? _parts(String version) {
  final core = version.trim().split(RegExp('[-+]')).first;
  final parts = [for (final part in core.split('.')) int.tryParse(part)];
  return parts.isEmpty || parts.contains(null) ? null : parts.cast<int>();
}

/// `toolchain` (spec §8): the native versions that work with this Flutter
/// ([toolchain]), the project's current values from [native]
/// (`map/native.json`; null when it is missing), and the mismatches, using
/// only thresholds Flutter itself applies (spec §8, §12):
/// - Gradle, AGP and KGP below the version at which Flutter's Gradle plugin
///   fails the build: an error; below the one at which it warns: a warning;
///   above the newest this Flutter knows: a warning;
/// - minSdk below the build-check thresholds: an error or a warning;
/// - compileSdk below Flutter's minimum, and an iOS deployment target below
///   the SDK template's: a warning;
/// - a value `native.json` records as `unknown` is not comparable, with its
///   reason.
///
/// targetSdk and the NDK version are shown but have no Flutter threshold;
/// store minimums are in the valid set as the curated notes give them.
ToolAnswer toolchainInfo(Toolchain toolchain, NativeConfig? native) {
  final android = toolchain.android?.value;
  final ios = toolchain.ios?.value;
  final current = <Map<String, Object?>>[];
  final mismatches = <Map<String, Object?>>[];
  final notComparable = <Map<String, Object?>>[];

  void value(
    String name,
    List<String> path, {
    VersionThreshold? checks,
    String? maxKnown,
    String? minimum,
    String? minimumIs,
  }) {
    final node = native?.lookup(path);
    if (node is! NativeValue) return;
    final text = switch (node.value) {
      final List<String> list => list.join(', '),
      null => null,
      final other => '$other',
    };
    current.add({
      'name': name,
      'status': node.status.name,
      'value': ?text,
      'at': ?node.at,
      'expression': ?node.expression,
      'reason': ?node.reason,
    });
    switch (node.status) {
      case NativeStatus.absent:
        return;
      case NativeStatus.unknown:
      case NativeStatus.error:
        notComparable.add({
          'name': name,
          'reason': node.reason ?? 'its platform pack failed (${node.errorType})',
        });
        return;
      case NativeStatus.found:
        break;
    }
    void mismatch(String severity, String limit, String message) =>
        mismatches.add({
          'name': name,
          'severity': severity,
          'value': text!,
          'limit': limit,
          'message': message,
          'at': ?node.at,
        });
    final comparable = [?checks?.errorBelow, ?maxKnown, ?minimum];
    if (comparable.isNotEmpty && compareVersions(text!, comparable.first) == null) {
      notComparable.add({'name': name, 'reason': '"$text" is not a version number'});
      return;
    }
    if (checks != null) {
      if (compareVersions(text!, checks.errorBelow)! < 0) {
        mismatch(
          'error',
          checks.errorBelow,
          "$name $text is below ${checks.errorBelow}, where Flutter's Gradle "
              'plugin fails the build.',
        );
      } else if (compareVersions(text, checks.warnBelow)! < 0) {
        mismatch(
          'warning',
          checks.warnBelow,
          "$name $text is below ${checks.warnBelow}, where Flutter's Gradle "
              'plugin warns.',
        );
      }
    }
    if (maxKnown != null && compareVersions(text!, maxKnown)! > 0) {
      mismatch(
        'warning',
        maxKnown,
        '$name $text is newer than $maxKnown, the newest this Flutter knows.',
      );
    }
    if (minimum != null && compareVersions(text!, minimum)! < 0) {
      mismatch('warning', minimum, '$name $text is below $minimum, $minimumIs.');
    }
  }

  value(
    'Gradle',
    ['android', 'gradle', 'version'],
    checks: android?.buildChecks.gradle,
    maxKnown: android?.maxKnown.gradle,
  );
  value(
    'AGP',
    ['android', 'settings', 'agp'],
    checks: android?.buildChecks.agp,
    maxKnown: android?.maxKnown.agp,
  );
  value(
    'KGP',
    ['android', 'settings', 'kgp'],
    checks: android?.buildChecks.kgp,
    maxKnown: android?.maxKnown.kgp,
  );
  value(
    'compileSdk',
    ['android', 'app', 'compileSdk'],
    minimum: android == null ? null : '${android.flutterMinimums.compileSdk}',
    minimumIs: "Flutter's minimum",
  );
  value('targetSdk', ['android', 'app', 'targetSdk']);
  value(
    'minSdk',
    ['android', 'app', 'minSdk'],
    checks: android?.buildChecks.minSdk,
  );
  value('ndkVersion', ['android', 'app', 'ndkVersion']);
  if (native?.lookup(['ios', 'xcode', 'configurations']) case NativeList(
    :final entries,
  )) {
    for (final entry in entries) {
      value(
        'iOS deployment target (${entry.name})',
        ['ios', 'xcode', 'configurations', entry.name, 'deploymentTarget'],
        minimum: ios?.deploymentTarget,
        minimumIs: "the SDK template's",
      );
    }
  }

  final valid = toolchain.toJson()..remove('notes');
  final errors = mismatches.where((m) => m['severity'] == 'error').length;
  final warnings = mismatches.length - errors;
  String plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';
  final summary = native == null
      ? "`map/native.json` is missing, so only the versions that work with "
            'this Flutter are listed.'
      : [
          if (mismatches.isEmpty)
            "The project's native values are within what this Flutter "
                'accepts.'
          else
            '${plural(mismatches.length, 'mismatch', 'mismatches')} between '
                "the project's native config and this Flutter's toolchain: "
                '${plural(errors, 'error', 'errors')}, '
                '${plural(warnings, 'warning', 'warnings')}.',
          if (notComparable.isNotEmpty)
            '${plural(notComparable.length, 'value', 'values')} could not be '
                'compared.',
        ].join(' ');
  return ToolReply({
    'valid': valid,
    'notes': [for (final note in toolchain.notes) note.toJson()],
    'current': current,
    'mismatches': mismatches,
    'notComparable': notComparable,
  }, summary);
}
```

`valid` keeps `toolchain.toJson()`'s nulls (`ios: null` when absent); the server strips them. Check that the "values within range" test's `Gradle 8.14` is within `8.7.0`..`9.3.1`: yes.

Export it from `appstein_engine.dart`.

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/mcp/toolchain_report_test.dart`
Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
git add packages/appstein_protocol packages/appstein_engine
git commit -m "feat(engine): the toolchain query with Flutter's own thresholds

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW"
```

---

### Task 8: The MCP server

**Files:**
- Create: `packages/appstein_engine/lib/src/mcp/appstein_mcp_server.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (export it)
- Modify: `packages/appstein_engine/pubspec.yaml` (dev dependency for the tests: none needed beyond `stream_channel`, already a dependency)
- Modify: `packages/appstein_protocol/lib/src/mcp/tool_schemas.dart` (`overviewResult`)
- Test: `packages/appstein_engine/test/mcp/appstein_mcp_server_test.dart`
- Test: `packages/appstein_engine/test/mcp/mcp_stdio_test.dart`
- Create (test support): `packages/appstein_engine/test/mcp/support/stdio_server.dart`, `packages/appstein_engine/test/mcp/support/mcp_client.dart`
- Move (test support): `holdLock` from `packages/appstein_engine/test/knowledge/knowledge_lock_test.dart` into `packages/appstein_engine/test/knowledge/support/hold_lock.dart`

**Interfaces:**
- Consumes: everything from Tasks 2–7.
- Produces:
  - `typedef McpChannel = StreamChannel<String>;`
  - `McpChannel stdioMcpChannel(Stream<List<int>> input, StreamSink<List<int>> output)`
  - `const mcpToolNames = ['overview', 'where_is', 'feature', 'route', 'check_api', 'what_changed', 'toolchain'];`
  - `final class AppsteinMcpServer extends MCPServer with ToolsSupport` with `AppsteinMcpServer(McpChannel channel, {required String projectRoot, required KnowledgeSync Function() syncFor, required String appsteinVersion, String? dartSdkPath})`; `done` (from `MCPServer`).
  - `ToolSchemas.overviewResult`.
  - test support: `Future<ServerConnection> connectTo(McpChannel channel)`; `Future<CallToolResult> call(ServerConnection server, String tool, [Map<String, Object?> arguments])`.

- [ ] **Step 1: Write the test client helper**

Create `packages/appstein_engine/test/mcp/support/mcp_client.dart`:

```dart
import 'package:dart_mcp/client.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

/// A client connected to the server on the other end of [channel], after
/// the MCP initialization handshake. It is shut down after the test.
Future<ServerConnection> connectTo(StreamChannel<String> channel) async {
  final client = MCPClient(Implementation(name: 'appstein-test', version: '1'));
  final server = client.connectServer(channel);
  addTearDown(server.shutdown);
  final result = await server.initialize(
    InitializeRequest(
      protocolVersion: ProtocolVersion.latestSupported,
      capabilities: client.capabilities,
      clientInfo: client.implementation,
    ),
  );
  expect(result.capabilities.tools, isNotNull);
  server.notifyInitialized();
  return server;
}

/// Calls [tool] with [arguments].
Future<CallToolResult> call(
  ServerConnection server,
  String tool, [
  Map<String, Object?> arguments = const {},
]) => server.callTool(CallToolRequest(name: tool, arguments: arguments));

/// The text of [result]'s first content block.
String textOf(CallToolResult result) => (result.content.first as TextContent).text;
```

Check that `package:dart_mcp/client.dart` exports `TextContent` (it exports `src/api/api.dart`, like `server.dart`); if not, also import `package:dart_mcp/server.dart` for the API types.

- [ ] **Step 2: Write the failing server tests**

Create `packages/appstein_engine/test/mcp/appstein_mcp_server_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:dart_mcp/client.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../knowledge/support/sync_harness.dart';
import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import 'support/mcp_client.dart';
import 'support/mcp_support.dart';

void main() {
  late String sdk;
  late String app;
  late FakeProcessRunner runner;
  late KnowledgeSync Function() syncFor;

  setUp(() {
    sdk = fakeFlutter();
    app = copyFixtureApp();
    runner = FakeProcessRunner();
    syncFor = () => knowledgeSync(
      flutterRoot: sdk,
      runner: runner,
      packs: const [OfficialMvvmPack(), AndroidPack(), IosPack()],
      packageSkills: false,
    );
  });

  Future<ServerConnection> serve() async {
    final controller = StreamChannelController<String>();
    final server = AppsteinMcpServer(
      controller.local,
      projectRoot: app,
      syncFor: () => syncFor(),
      appsteinVersion: '0.1.0-dev',
      dartSdkPath: testDartSdk,
    );
    addTearDown(server.shutdown);
    return connectTo(controller.foreign);
  }

  Map<String, Object?> structured(CallToolResult result) {
    expect(result.isError, isNot(isTrue), reason: textOf(result));
    return result.structuredContent!;
  }

  test('lists the seven tools, each with an output schema', () async {
    final server = await serve();
    final tools = (await server.listTools()).tools;
    expect([for (final tool in tools) tool.name], mcpToolNames);
    for (final tool in tools) {
      expect(tool.outputSchema, isNotNull, reason: tool.name);
      expect(tool.description, isNotEmpty, reason: tool.name);
    }
  });

  test('the first call syncs a project never synced, the second finds it '
      'current', () async {
    final server = await serve();
    final first = structured(await call(server, 'overview'));
    expect(first['index'], startsWith('# fixture_app\n'));
    final freshness = first['freshness']! as Map<String, Object?>;
    expect(freshness['state'], 'rebuilt');
    expect(freshness['because'], contains('no sync has run here yet'));
    final second = structured(await call(server, 'overview'));
    expect(second['freshness'], {'state': 'current'});
    expect(second['summary'], isA<String>());
  });

  test('every tool answers and matches its output schema', () async {
    final server = await serve();
    final tools = {
      for (final tool in (await server.listTools()).tools) tool.name: tool,
    };
    const calls = {
      'overview': <String, Object?>{},
      'where_is': {'query': 'login screen'},
      'feature': {'name': 'auth/login'},
      'route': {'path': '/booking/42'},
      'check_api': {'name': 'WillPopScope'},
      'what_changed': <String, Object?>{},
      'toolchain': <String, Object?>{},
    };
    for (final MapEntry(key: tool, value: arguments) in calls.entries) {
      final result = await call(server, tool, arguments);
      final json = structured(result);
      // ObjectSchema is an extension type over the schema's JSON map.
      expectMatchesSchema(
        tools[tool]!.outputSchema! as Map<String, Object?>,
        json,
      );
      expect(result.content, hasLength(2), reason: tool);
      expect(textOf(result), startsWith(json['summary']! as String));
    }
    final whereIs = structured(
      await call(server, 'where_is', {'query': 'login screen'}),
    );
    expect(
      ((whereIs['matches']! as List).first as Map)['name'],
      'LoginScreen',
    );
  });

  test('an edit is picked up before the next answer', () async {
    final server = await serve();
    await call(server, 'overview');
    File(p.join(app, 'lib', 'ui', 'home', 'widgets', 'extra_panel.dart'))
        .writeAsStringSync(
          "/// A panel.\nclass ExtraPanel {}\n",
        );
    final json = structured(
      await call(server, 'where_is', {'query': 'extra panel'}),
    );
    expect(((json['matches']! as List).first as Map)['name'], 'ExtraPanel');
    final freshness = json['freshness']! as Map<String, Object?>;
    expect(freshness['state'], 'rebuilt');
    expect(
      freshness['changed'],
      contains('lib/ui/home/widgets/extra_panel.dart'),
    );
  });

  test('bad input is an error result the agent can read', () async {
    final server = await serve();
    final unknown = await call(server, 'feature', {'name': 'nope'});
    expect(unknown.isError, isTrue);
    expect(unknown.structuredContent, isNull);
    expect(textOf(unknown), startsWith('No feature is named "nope".'));
    final missing = await call(server, 'where_is');
    expect(missing.isError, isTrue);
  });

  test('three calls at once are answered one after the other', () async {
    final server = await serve();
    final results = await Future.wait([
      call(server, 'overview'),
      call(server, 'where_is', {'query': 'booking'}),
      call(server, 'feature', {'name': 'home'}),
    ]);
    for (final result in results) {
      final freshness = structured(result)['freshness']! as Map;
      expect(freshness['state'], isNot('stale'));
    }
  });

  test('a lock held by another process: it answers from disk, marked '
      'stale', () async {
    final server = await serve();
    await call(server, 'overview');
    syncFor = () => knowledgeSync(
      flutterRoot: sdk,
      runner: runner,
      packs: const [OfficialMvvmPack(), AndroidPack(), IosPack()],
      packageSkills: false,
      lockTimeout: const Duration(milliseconds: 500),
    );
    File(p.join(app, 'lib', 'extra.dart')).writeAsStringSync('int x = 1;\n');
    await holdLock(p.join(app, '.appstein'), 60000);
    final json = structured(await call(server, 'overview'));
    expect(json['freshness'], {
      'state': 'stale',
      'problem': 'another sync is running and holds the lock',
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('no Flutter SDK and no knowledge: an error that says what to '
      'do', () async {
    syncFor = () => knowledgeSync(
      flutterRoot: p.join(app, 'no flutter here'),
      runner: runner,
      packageSkills: false,
    );
    final server = await serve();
    final result = await call(server, 'overview');
    expect(result.isError, isTrue);
    expect(textOf(result), contains('`.appstein/INDEX.md` is missing'));
    expect(textOf(result), contains('The knowledge may be stale:'));
  });

  test('a failing sync after a good one: answers from disk, marked '
      'stale', () async {
    final server = await serve();
    await call(server, 'overview');
    syncFor = () => throw StateError('boom');
    final json = structured(await call(server, 'feature', {'name': 'home'}));
    expect(json['freshness'], containsPair('state', 'stale'));
    expect(
      (json['freshness']! as Map)['problem'],
      'the sync failed unexpectedly: Bad state: boom',
    );
  });

  test('a damaged map file is refused with its name', () async {
    final server = await serve();
    await call(server, 'overview');
    syncFor = () => throw StateError('no sync');
    File(p.join(app, '.appstein', 'map', 'features.json'))
        .writeAsStringSync('{"features": 3}');
    final result = await call(server, 'feature', {'name': 'home'});
    expect(result.isError, isTrue);
    expect(
      textOf(result),
      startsWith('`.appstein/map/features.json` is damaged ('),
    );
  });

  test('package skills never run from the server', () async {
    Directory(p.join(app, '.claude')).createSync();
    final server = await serve();
    await call(server, 'overview');
    expect(runner.calls.where((call) => call.contains('skills@')), isEmpty);
  });
}
```

The lock must be held by **another process**: on Linux and macOS an operating-system file lock doesn't block the process that holds it, so a lock taken in the test's own process would never make the server wait. Before writing this test, move `holdLock` (lines 14–67 of `test/knowledge/knowledge_lock_test.dart`, with its imports `dart:convert`, `dart:io`, `dart:isolate`, `package:path/path.dart` and `package:test/test.dart`) unchanged into a new `test/knowledge/support/hold_lock.dart`, import it from `knowledge_lock_test.dart` and from this test (`import '../knowledge/support/hold_lock.dart';`), and run `knowledge_lock_test.dart` to confirm the move broke nothing. `holdLock` starts `lock_holder.dart`, waits for its `locked` line, and releases it in teardown.

- [ ] **Step 3: Run them to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/mcp/appstein_mcp_server_test.dart`
Expected: FAIL to compile: `AppsteinMcpServer` isn't defined.

- [ ] **Step 4: Add the overview schema**

In `tool_schemas.dart`, add:

```dart
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
```

- [ ] **Step 5: Write the server**

Create `packages/appstein_engine/lib/src/mcp/appstein_mcp_server.dart`:

```dart
import 'dart:async';
import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:stream_channel/stream_channel.dart';

import '../config/config_loader.dart';
import '../knowledge/knowledge_lock.dart';
import '../knowledge/knowledge_sync.dart';
import '../knowledge/knowledge_write_exception.dart';
import '../knowledge/platform_sync.dart';
import 'check_api.dart';
import 'feature_query.dart';
import 'knowledge_snapshot.dart';
import 'route_query.dart';
import 'tool_answer.dart';
import 'toolchain_report.dart';
import 'what_changed.dart';
import 'where_is.dart';

/// A channel an MCP server talks over: one JSON-RPC message per string.
typedef McpChannel = StreamChannel<String>;

/// The MCP channel over [input] and [output] (stdin and stdout for
/// `appstein mcp`, spec §8): one message per line.
McpChannel stdioMcpChannel(
  Stream<List<int>> input,
  StreamSink<List<int>> output,
) => stdioChannel(input: input, output: output);

/// The tools `appstein mcp` serves in slice 1c.1, in the order it lists
/// them (spec §8). `verify` and `package_check` come with slice 1d.
const mcpToolNames = [
  'overview',
  'where_is',
  'feature',
  'route',
  'check_api',
  'what_changed',
  'toolchain',
];

const _doctor = 'Run `appstein doctor` to see what is wrong.';

/// Appstein's MCP server (spec §8): read tools over the project's
/// knowledge, each answered from fresh knowledge.
///
/// Before each answer it syncs as `appstein sync --detect` does, with
/// [syncFor]'s `KnowledgeSync` (the CLI builds one from `appstein.yaml` on
/// every call, with package skills off and a held analyzer cache). Calls
/// are answered one at a time. A sync that fails leaves the reply marked
/// `stale`, from the files on disk; with no file to answer from, the reply
/// is an error. Nothing is ever written to stdout but protocol messages.
final class AppsteinMcpServer extends MCPServer with ToolsSupport {
  /// Serves the project at [projectRoot] over [channel]. [dartSdkPath]
  /// overrides where `dart:` libraries are read from, for tests.
  AppsteinMcpServer(
    McpChannel channel, {
    required this.projectRoot,
    required this.syncFor,
    required String appsteinVersion,
    this.dartSdkPath,
  }) : super.fromStreamChannel(
         channel,
         implementation: Implementation(
           name: 'appstein',
           version: appsteinVersion,
         ),
         instructions:
             'Appstein knows this Flutter project: its SDK, the version '
             'delta, the native toolchain and the project map. Call '
             '`overview` first. Ask `where_is` before searching files, '
             '`check_api` before using an API you are unsure of, and '
             '`toolchain` before changing native versions.',
       ) {
    _tool(
      'overview',
      "The project's INDEX.md: what the app is, the rules that matter most, "
          'its features, where things live, version notes, decisions and '
          'current work, plus whether the knowledge is fresh. Call it first.',
      input: ToolSchemas.noInput,
      result: ToolSchemas.overviewResult,
      answer: (knowledge, _) =>
          knowledge.refusalFor([knowledge.index]) ??
          ToolReply(
            {
              'index': knowledge.index.value!.body,
              'generatedAt': knowledge.index.value!.generatedAt,
            },
            "Read `index` first: it is the project's INDEX.md, generated "
            '${knowledge.index.value!.generatedAt}.',
          ),
    );
    _tool(
      'where_is',
      'Find files and symbols for free text, such as "login screen" or '
          '"booking repository", ranked by symbol names, routes and '
          'screens, features, then file paths, with the reason for each '
          'match. Use it before searching files.',
      input: ToolSchemas.whereIsInput,
      result: ToolSchemas.whereIsResult,
      answer: (knowledge, arguments) =>
          knowledge.refusalFor([
            knowledge.symbols,
            knowledge.routes,
            knowledge.features,
            knowledge.layers,
          ]) ??
          whereIs(
            arguments['query']! as String,
            symbols: knowledge.symbols.value!,
            routes: knowledge.routes.value!,
            features: knowledge.features.value!,
            layers: knowledge.layers.value!,
          ),
    );
    _tool(
      'feature',
      'Everything in one feature (a folder under lib/ui/, such as '
          '`auth/login`): screens, view models, repositories, services, '
          'models, routes, tests and files.',
      input: ToolSchemas.featureInput,
      result: ToolSchemas.featureResult,
      answer: (knowledge, arguments) =>
          knowledge.refusalFor([knowledge.features, knowledge.routes]) ??
          featureInfo(
            arguments['name']! as String,
            features: knowledge.features.value!,
            routes: knowledge.routes.value!,
          ),
    );
    _tool(
      'route',
      'The go_router route for a path, such as `/booking/42`: its screen, '
          'feature, parent, nested routes and whether it redirects.',
      input: ToolSchemas.routeInput,
      result: ToolSchemas.routeResult,
      answer: (knowledge, arguments) =>
          knowledge.refusalFor([knowledge.routes, knowledge.features]) ??
          routeInfo(
            arguments['path']! as String,
            routes: knowledge.routes.value!,
            features: knowledge.features.value!,
          ),
    );
    _tool(
      'check_api',
      "Is an API deprecated or removed for this project's Flutter, Dart and "
          'packages? Give a name such as `WillPopScope`, `withOpacity` or '
          "`Color.withOpacity`. Returns the library's own deprecation text, "
          'the migration and the curated notes that mention it.',
      input: ToolSchemas.checkApiInput,
      result: ToolSchemas.checkApiResult,
      answer: (knowledge, arguments) =>
          knowledge.refusalFor([knowledge.delta]) ??
          checkApi(arguments['name']! as String, knowledge.delta.value!),
    );
    _tool(
      'what_changed',
      'The curated notes about what changed in Flutter and Dart, and how '
          'many deprecated, removed and moved APIs each library has. '
          '`since` (a Flutter version such as `3.27`) narrows the notes; '
          '`library` (such as `package:go_router`) lists that library\'s '
          'APIs.',
      input: ToolSchemas.whatChangedInput,
      result: ToolSchemas.whatChangedResult,
      answer: (knowledge, arguments) =>
          knowledge.refusalFor([knowledge.delta]) ??
          whatChanged(
            knowledge.delta.value!,
            since: arguments['since'] as String?,
            library: arguments['library'] as String?,
          ),
    );
    _tool(
      'toolchain',
      'The native versions that work with this Flutter (Gradle, AGP, KGP, '
          'SDK levels, NDK, iOS deployment target), the project\'s current '
          'values, and every mismatch. Check it before changing native '
          'versions.',
      input: ToolSchemas.noInput,
      result: ToolSchemas.toolchainResult,
      answer: (knowledge, _) =>
          knowledge.refusalFor([knowledge.toolchain]) ??
          toolchainInfo(knowledge.toolchain.value!, knowledge.native.value),
    );
  }

  /// The project's folder.
  final String projectRoot;

  /// The sync to run before each answer; called once per answer.
  final KnowledgeSync Function() syncFor;

  /// Where `dart:` libraries are read from; null for the Flutter SDK's.
  final String? dartSdkPath;

  Future<void> _last = Future.value();

  void _tool(
    String name,
    String description, {
    required Map<String, Object?> input,
    required Map<String, Object?> result,
    required ToolAnswer Function(
      KnowledgeSnapshot knowledge,
      Map<String, Object?> arguments,
    )
    answer,
  }) => registerTool(
    Tool(
      name: name,
      description: description,
      inputSchema: ObjectSchema.fromMap(input),
      outputSchema: ObjectSchema.fromMap(toolOutputSchema(result)),
    ),
    (request) => _oneAtATime(() => _call(request, answer)),
  );

  /// Runs [action] after every call before it finished.
  Future<T> _oneAtATime<T>(Future<T> Function() action) {
    final result = _last.then((_) => action());
    _last = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<CallToolResult> _call(
    CallToolRequest request,
    ToolAnswer Function(KnowledgeSnapshot, Map<String, Object?>) answer,
  ) async {
    final freshness = await _freshen();
    try {
      return switch (answer(
        KnowledgeSnapshot(projectRoot),
        request.arguments ?? const {},
      )) {
        ToolReply(:final result, :final summary) => _reply(
          result,
          summary,
          freshness,
        ),
        ToolRefusal(:final message) => _refuse(message, freshness),
      };
    } on Object catch (error) {
      return _refuse(
        'Appstein failed to answer: $error. $_doctor If this keeps '
        'happening, please report it.',
        freshness,
      );
    }
  }

  /// Syncs as `sync --detect` does and says how fresh the knowledge is.
  Future<FreshnessReport> _freshen() async {
    try {
      final report = await syncFor().detect(
        projectRoot,
        dartSdkPath: dartSdkPath,
      );
      if (report.current) return const FreshnessReport.current();
      return FreshnessReport.rebuilt(
        because: report.rebuiltBecause,
        changed: report.changed,
        mapSkipped: report.map?.skipped,
      );
    } on KnowledgeLockTimeout {
      return const FreshnessReport.stale(
        problem: 'another sync is running and holds the lock',
      );
    } on SyncException catch (error) {
      return FreshnessReport.stale(
        problem: error.problem,
        fixHint: error.fixHint,
      );
    } on ConfigException catch (error) {
      return FreshnessReport.stale(
        problem: 'appstein.yaml is invalid: $error',
        fixHint: 'Fix appstein.yaml; the next call syncs again.',
      );
    } on KnowledgeWriteException catch (error) {
      return FreshnessReport.stale(problem: '$error', fixHint: _doctor);
    } on Object catch (error) {
      return FreshnessReport.stale(
        problem: 'the sync failed unexpectedly: $error',
        fixHint: _doctor,
      );
    }
  }

  CallToolResult _reply(
    Map<String, Object?> result,
    String summary,
    FreshnessReport freshness,
  ) {
    final structured =
        withoutNulls({
              ...result,
              'summary': summary,
              'freshness': freshness.toJson(),
            })!
            as Map<String, Object?>;
    return CallToolResult(
      content: [
        TextContent(text: '$summary ${freshness.sentence}'),
        TextContent(text: jsonEncode(structured)),
      ],
      structuredContent: structured,
    );
  }

  CallToolResult _refuse(String message, FreshnessReport freshness) =>
      CallToolResult(
        isError: true,
        content: [
          TextContent(
            text: freshness.state == FreshnessState.stale
                ? '$message ${freshness.sentence}'
                : message,
          ),
        ],
      );
}
```

Notes for the implementer:
- `SyncException` is in `knowledge/platform_sync.dart`; `ConfigException` in `config/config_loader.dart`; `KnowledgeLockTimeout` in `knowledge/knowledge_lock.dart`.
- The `summary` field matches what the test checks: `textOf(result)` starts with `json['summary']`.
- `withoutNulls(...)!` is non-null for a map.
- The no-SDK test's first call: `syncFor().detect` throws `SyncException`, the snapshot has no `INDEX.md`, so `refusalFor` gives "`.appstein/INDEX.md` is missing, so this can't be answered yet. …", and `_refuse` appends the stale sentence.

Export it from `appstein_engine.dart`.

- [ ] **Step 6: Run the server tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/mcp/appstein_mcp_server_test.dart`
Expected: PASS, 11 tests.

- [ ] **Step 7: Write the failing real-stdio test**

Create `packages/appstein_engine/test/mcp/support/stdio_server.dart`:

```dart
// Run by mcp_stdio_test.dart as a separate process: serves the project in
// its first argument over this process's real stdin and stdout, with the
// Flutter SDK in its second argument and the Dart SDK in its third (for
// the analysis), as `appstein mcp` would with the official_mvvm, android
// and ios packs.

import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';

Future<void> main(List<String> arguments) async {
  final [projectRoot, flutterRoot, dartSdk] = arguments;
  final held = HeldAnalyzerCache();
  final server = AppsteinMcpServer(
    stdioMcpChannel(stdin, stdout),
    projectRoot: projectRoot,
    appsteinVersion: '0.1.0-dev',
    dartSdkPath: dartSdk,
    syncFor: () => KnowledgeSync(
      environment: HostEnvironment(
        os: HostOs.current,
        variables: {'FLUTTER_ROOT': flutterRoot},
        workingDirectory: projectRoot,
      ),
      appsteinVersion: '0.1.0-dev',
      packs: const [OfficialMvvmPack(), AndroidPack(), IosPack()],
      packageSkills: false,
      heldCache: held,
    ),
  );
  await server.done;
}
```

Create `packages/appstein_engine/test/mcp/mcp_stdio_test.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../knowledge/support/sync_harness.dart';
import '../support/fixture_app.dart';
import 'support/mcp_client.dart';

void main() {
  test('over real stdio in a new process, in a folder with a space and an '
      'umlaut: every tool answers and stdout holds only protocol '
      'messages', () async {
    final sdk = fakeFlutter();
    final app = copyFixtureApp();
    final engine = p.dirname(p.dirname(p.dirname(fixtureAppsDir)));
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      p.join('test', 'mcp', 'support', 'stdio_server.dart'),
      app,
      sdk,
      testDartSdk,
    ], workingDirectory: engine);
    final errors = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(errors.write);
    final lines = <String>[];
    final incoming = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map((line) {
          lines.add(line);
          return line;
        });
    final outgoing = StreamController<String>();
    unawaited(
      outgoing.stream
          .map((message) => utf8.encode('$message\n'))
          .pipe(process.stdin),
    );
    final server = await connectTo(StreamChannel(incoming, outgoing.sink));

    final tools = (await server.listTools()).tools;
    expect(tools, hasLength(7), reason: '$errors');
    const calls = {
      'overview': <String, Object?>{},
      'where_is': {'query': 'login screen'},
      'feature': {'name': 'booking'},
      'route': {'path': '/booking/42'},
      'check_api': {'name': 'WillPopScope'},
      'what_changed': <String, Object?>{},
      'toolchain': <String, Object?>{},
    };
    for (final MapEntry(key: tool, value: arguments) in calls.entries) {
      final result = await call(server, tool, arguments);
      expect(result.isError, isNot(isTrue), reason: '$tool: ${textOf(result)}\n$errors');
    }
    await server.shutdown();
    await outgoing.close();
    expect(
      await process.exitCode.timeout(const Duration(seconds: 30)),
      0,
      reason: '$errors',
    );
    for (final line in lines) {
      final message = jsonDecode(line);
      expect(message, isA<Map<String, Object?>>(), reason: line);
      expect((message as Map)['jsonrpc'], '2.0', reason: line);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
```

`fixtureAppsDir` is `<engine>/test/fixtures/apps`, so three `dirname`s give the engine package folder.

- [ ] **Step 8: Run it to see it pass**

Run: `cd packages/appstein_engine && fvm dart test test/mcp/mcp_stdio_test.dart`
Expected: PASS (the first run compiles the script, about 10–20 s). If it fails, read the `reason` (stderr of the server process) first. A non-protocol line on stdout is a bug to find, never to filter out.

- [ ] **Step 9: Run the engine suite and analyze**

Run: `cd packages/appstein_engine && fvm dart test`, then `fvm dart analyze --fatal-infos` from the repo root.
Expected: PASS; No issues found.

- [ ] **Step 10: Commit**

```bash
git add packages/appstein_protocol packages/appstein_engine
git commit -m "feat(engine): the Appstein MCP server with seven read tools

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW
Docs-Checked: architecture.md - updated in Task 11"
```

---

### Task 9: `appstein mcp`

**Files:**
- Create: `packages/appstein_cli/lib/src/mcp_command.dart`
- Modify: `packages/appstein_cli/lib/src/runner.dart`
- Modify: `packages/appstein_cli/lib/appstein_cli.dart` (export it, after `src/exit_codes.dart`)
- Modify: `packages/appstein_cli/pubspec.yaml` (dev dependencies `dart_mcp: 0.5.2`, `stream_channel: ^2.1.4`)
- Test: `packages/appstein_cli/test/mcp_command_test.dart`

**Interfaces:**
- Consumes: `AppsteinMcpServer`, `McpChannel`, `stdioMcpChannel`, `HeldAnalyzerCache`, `KnowledgeSync`, `loadConfig`, `packsFor`, `resolveProjectRoot`, `appsteinVersion`.
- Produces:
  - `final class McpCommand extends Command<int>` with `McpCommand({required StringSink err, required HostEnvironment environment, required McpChannel Function() channel})`.
  - `runAppstein(…, McpChannel Function()? mcpChannel)`: a new optional parameter, defaulting to `() => stdioMcpChannel(stdin, stdout)`.

- [ ] **Step 1: Add the dev dependencies**

In `packages/appstein_cli/pubspec.yaml`, add under `dev_dependencies:` `dart_mcp: 0.5.2` and `stream_channel: ^2.1.4`. Run `fvm dart pub get` from the repo root.
Expected: resolves with no change to the lock's versions.

- [ ] **Step 2: Write the failing tests**

Create `packages/appstein_cli/test/mcp_command_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:dart_mcp/client.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/fake_flutter_sdk.dart';

void main() {
  late StringBuffer out;
  late StringBuffer err;
  late String project;
  late String sdk;

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
    final work = Directory.systemTemp.createTempSync('appstein cli tëst ');
    addTearDown(() => work.deleteSync(recursive: true));
    project = p.join(work.path, 'my app');
    Directory(project).createSync();
    File(
      p.join(project, 'pubspec.yaml'),
    ).writeAsStringSync('name: my_app\nenvironment:\n  sdk: ^3.12.0\n');
    sdk = createFakeFlutterSdk(p.join(work.path, 'flutter'));
  });

  Future<int> run(List<String> args, McpChannel channel, {String? cwd}) =>
      runAppstein(
        args,
        out: out,
        err: err,
        environment: HostEnvironment(
          os: HostOs.current,
          variables: {'FLUTTER_ROOT': sdk},
          workingDirectory: cwd ?? project,
        ),
        mcpChannel: () => channel,
      );

  test('serves the tools until the client closes, writing nothing to the '
      'output sink', () async {
    final controller = StreamChannelController<String>();
    final exit = run(['mcp'], controller.local);
    final client = MCPClient(Implementation(name: 'test', version: '1'));
    final server = client.connectServer(controller.foreign);
    await server.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    server.notifyInitialized();
    final tools = (await server.listTools()).tools;
    expect([for (final tool in tools) tool.name], mcpToolNames);
    final overview = await server.callTool(
      CallToolRequest(name: 'overview', arguments: const {}),
    );
    expect(overview.isError, isNot(isTrue), reason: '${overview.content}');
    expect(overview.structuredContent!['index'], startsWith('# my_app\n'));
    await server.shutdown();
    expect(await exit, ExitCodes.ok);
    expect(out.toString(), isEmpty);
  });

  test('re-reads appstein.yaml on every call', () async {
    final controller = StreamChannelController<String>();
    final exit = run(['mcp'], controller.local);
    final client = MCPClient(Implementation(name: 'test', version: '1'));
    final server = client.connectServer(controller.foreign);
    await server.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    server.notifyInitialized();
    await server.callTool(CallToolRequest(name: 'overview', arguments: const {}));
    File(p.join(project, 'appstein.yaml')).writeAsStringSync('nonsense: 1\n');
    final result = await server.callTool(
      CallToolRequest(name: 'overview', arguments: const {}),
    );
    final freshness = result.structuredContent!['freshness']! as Map;
    expect(freshness['state'], 'stale');
    expect(freshness['problem'], startsWith('appstein.yaml is invalid: '));
    await server.shutdown();
    expect(await exit, ExitCodes.ok);
  });

  test('outside a project it exits 3 with a message', () async {
    final elsewhere = Directory.systemTemp.createTempSync('appstein no prj ');
    addTearDown(() => elsewhere.deleteSync(recursive: true));
    final controller = StreamChannelController<String>();
    expect(
      await run(['mcp'], controller.local, cwd: elsewhere.path),
      ExitCodes.appsteinFailed,
    );
    expect(err.toString(), contains('appstein mcp needs a Flutter project'));
  });
}
```

`createFakeFlutterSdk` (the CLI's own test support) has no Dart SDK inside, so the map is skipped; `INDEX.md` is still written, which is all these tests need. Confirm that `INDEX.md`'s first line uses the pubspec name (`# my_app`).

- [ ] **Step 3: Run them to see them fail**

Run: `cd packages/appstein_cli && fvm dart test test/mcp_command_test.dart`
Expected: FAIL to compile: `mcpChannel` isn't a parameter of `runAppstein`.

- [ ] **Step 4: Write the command**

Create `packages/appstein_cli/lib/src/mcp_command.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:args/command_runner.dart';

import 'exit_codes.dart';
import 'packs.dart';
import 'project_option.dart';
import 'version.dart';

/// `appstein mcp`: serves Appstein's MCP tools over stdio until the agent
/// closes the connection (spec §5.3, §8).
///
/// Before each answer the server syncs like `sync --detect`. It re-reads
/// `appstein.yaml` for every call, so a changed config takes effect at
/// once, and an invalid one marks replies stale instead of stopping the
/// server. Package skills are left to `appstein sync`, and the analyzer
/// cache stays in memory between calls.
final class McpCommand extends Command<int> {
  /// Creates the command. [channel] gives the connection to serve: stdin
  /// and stdout, or a test's channel.
  McpCommand({
    required this.err,
    required this.environment,
    required this.channel,
  });

  /// Where startup problems go. stdout belongs to the protocol.
  final StringSink err;

  /// The machine, used to find the project and the Flutter SDK.
  final HostEnvironment environment;

  /// Gives the connection to serve.
  final McpChannel Function() channel;

  @override
  String get name => 'mcp';

  @override
  String get description =>
      "Serve Appstein's MCP tools over stdio (started by agents).";

  @override
  Future<int> run() async {
    final projectRoot = resolveProjectRoot(globalResults, environment);
    if (projectRoot == null) {
      err
        ..writeln(
          'appstein mcp needs a Flutter project, but there is no pubspec.yaml '
          'in ${environment.workingDirectory} or any folder above it.',
        )
        ..writeln(
          'Start it inside the project, or pass --project <path> (in the '
          "agent's MCP config).",
        );
      return ExitCodes.appsteinFailed;
    }
    final held = HeldAnalyzerCache();
    KnowledgeSync syncFor() {
      final config = loadConfig(projectRoot) ?? const AppsteinConfig();
      return KnowledgeSync(
        environment: environment,
        appsteinVersion: appsteinVersion,
        packs: packsFor(config),
        baseline: config.delta.baseline,
        agents: config.integrations.agents,
        packageSkills: false,
        heldCache: held,
      );
    }

    final server = AppsteinMcpServer(
      channel(),
      projectRoot: projectRoot,
      syncFor: syncFor,
      appsteinVersion: appsteinVersion,
    );
    await server.done;
    return ExitCodes.ok;
  }
}
```

`loadConfig` throws `ConfigException` for an invalid file; the server's `_freshen` turns that into a stale reply (Task 8).

In `runner.dart`:
1. Add `import 'mcp_command.dart';`.
2. Add the parameter `McpChannel Function()? mcpChannel,` to `runAppstein`, documented in its comment: "[mcpChannel] (also for tests) gives the connection `appstein mcp` serves; by default stdin and stdout."
3. After `..addCommand(SyncCommand(out: output, err: errors, environment: machine));` add:

```dart
      ..addCommand(
        McpCommand(
          err: errors,
          environment: machine,
          channel: mcpChannel ?? () => stdioMcpChannel(stdin, stdout),
        ),
      );
```

(adjusting the cascade so the statement still ends with `;` once).

Export `src/mcp_command.dart` from `appstein_cli.dart`.

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd packages/appstein_cli && fvm dart test`
Expected: PASS.

- [ ] **Step 6: Check the real binary by hand**

Run from the repo root:

```bash
fvm dart compile exe packages/appstein_cli/bin/appstein.dart -o "$TMPDIR/appstein-mcp-check.exe" && printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}' | "$TMPDIR/appstein-mcp-check.exe" --project packages/appstein_engine/test/fixtures/apps/mvvm_app mcp
```

(use the scratchpad folder for the output if `$TMPDIR` is unset).
Expected: one line of JSON with `"result"`, `"serverInfo":{"name":"appstein"…}` and `"tools"` in `capabilities`, then the process exits when stdin closes. Nothing else on stdout.

- [ ] **Step 7: Commit**

```bash
git add pubspec.lock packages/appstein_cli
git commit -m "feat(cli): appstein mcp serves the MCP tools over stdio

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW
Docs-Checked: cli.md - updated in Task 11"
```

---

### Task 10: Measure the MCP answers in CI (spec §15)

**Files:**
- Modify: `tool/measure_sync.dart`

**Interfaces:**
- Consumes: the compiled `appstein` executable (`_compile`), the 200-file app (`_generateApp`), `appstein mcp`.
- Produces: a second Markdown table "MCP answers on the 200-file app" and a §15 miss when a tool's median is 1 s or more.

- [ ] **Step 1: Add the session and the calls**

In `tool/measure_sync.dart`, add `import 'dart:async';` and `import 'dart:convert';` at the top, and at the end of the file:

```dart
/// The tool calls timed on the 200-file app, each three times (spec §15:
/// MCP answers under 1 s from fresh knowledge).
const _mcpCalls = [
  ('overview', <String, Object?>{}),
  ('where_is', <String, Object?>{'query': 'feature 5 view model'}),
  ('feature', <String, Object?>{'name': 'feature_5'}),
  ('route', <String, Object?>{'path': '/feature-7'}),
  ('check_api', <String, Object?>{'name': 'withOpacity'}),
  ('what_changed', <String, Object?>{}),
  ('toolchain', <String, Object?>{}),
];

/// One `appstein mcp` process and a minimal JSON-RPC client over its stdin
/// and stdout: enough to time tool calls as an agent makes them.
final class _McpSession {
  _McpSession._(this._process, this._lines);

  final Process _process;
  final StreamIterator<String> _lines;
  var _id = 0;

  static Future<_McpSession> start(
    String exe,
    String app,
    String flutterRoot,
  ) async {
    final process = await Process.start(exe, [
      '--project',
      app,
      'mcp',
    ], environment: {'FLUTTER_ROOT': flutterRoot});
    unawaited(process.stderr.drain<void>());
    final session = _McpSession._(
      process,
      StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
    );
    await session._request('initialize', {
      'protocolVersion': '2025-11-25',
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'measure_sync', 'version': '1'},
    });
    session._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    return session;
  }

  void _send(Map<String, Object?> message) =>
      _process.stdin.writeln(jsonEncode(message));

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) async {
    final id = ++_id;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    while (await _lines.moveNext()) {
      final message = jsonDecode(_lines.current) as Map<String, Object?>;
      if (message['id'] != id) continue;
      if (message['error'] case final error?) {
        throw StateError('$method failed: $error');
      }
      return message['result']! as Map<String, Object?>;
    }
    throw StateError('appstein mcp exited before answering $method');
  }

  /// How long [tool] took to answer; throws when it answered with an error.
  Future<Duration> call(String tool, Map<String, Object?> arguments) async {
    final watch = Stopwatch()..start();
    final result = await _request('tools/call', {
      'name': tool,
      'arguments': arguments,
    });
    watch.stop();
    if (result['isError'] == true) {
      throw StateError(
        '$tool answered with an error: ${jsonEncode(result['content'])}',
      );
    }
    return watch.elapsed;
  }

  Future<void> close() async {
    await _process.stdin.close();
    await _process.exitCode;
  }
}
```

- [ ] **Step 2: Time the tools after the router edits**

In `main`, declare `final mcp = <String, List<Duration>>{};` next to `var missed = <String>[];`. Inside the size loop, right after `broken['router edit (median), $files'] = _median(router);` and before `if (held) {`, add:

```dart
      if (held) {
        // The knowledge is fresh after the last detect, so these measure
        // spec §15's "MCP tool responses < 1 s from fresh knowledge". The
        // first call starts the server; it is not counted.
        final session = await _McpSession.start(exe, app, flutterRoot);
        try {
          await session.call('overview', const {});
          for (final (tool, arguments) in _mcpCalls) {
            final three = <Duration>[];
            for (var i = 0; i < 3; i++) {
              three.add(await session.call(tool, arguments));
            }
            mcp[tool] = three;
          }
        } on StateError catch (error) {
          stderr.writeln('appstein mcp: ${error.message}');
          exitCode = 1;
          return;
        } finally {
          await session.close();
        }
      }
```

Then extend the `missed` list inside the existing `if (held) {` block with, after the detect rows:

```dart
          for (final MapEntry(key: tool, value: three) in mcp.entries)
            if ((three.toList()..sort())[1] >= const Duration(seconds: 1))
              'the MCP tool $tool took ${(three.toList()..sort())[1].inMilliseconds} ms, '
                  'the median of three (under 1 s)',
```

And after `stdout.writeln(_breakdown(broken));` print the MCP table:

```dart
    stdout.writeln('''
| MCP answer on the 200-file app (one `appstein mcp` process) | median of 3 (target under 1 s) |
|---|---|
${[for (final MapEntry(key: tool, value: three) in mcp.entries) '| `$tool` | ${(three.toList()..sort())[1].inMilliseconds} ms (${three.map((d) => d.inMilliseconds).join(', ')}) |'].join('\n')}
''');
```

Update the tool's top doc comment: add a bullet "- each MCP tool's answer on that app, from fresh knowledge, in one `appstein mcp` process: under 1 s, as the median of three;" after the detect bullet.

- [ ] **Step 3: Run it locally**

Run: `fvm dart run tool/measure_sync.dart` from the repo root (it needs the network for go_router; it takes a few minutes).
Expected: the existing tables, then the MCP table with seven rows, each well under 1 s, and exit code 0. Record the numbers for the plan's notes from execution.

- [ ] **Step 4: Commit**

```bash
git add tool/measure_sync.dart
git commit -m "ci: measure each MCP tool's answer on the 200-file app (spec §15)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW
Docs-Checked: ci.md - updated in Task 11"
```

---

### Task 11: Docs and the graph

**Files:**
- Create: `docs/guide/mcp-server.md`
- Modify: `docs/guide/README.md` (index row), `docs/guide/cli.md` (`appstein mcp`), `docs/guide/architecture.md` (`mcp/` row and bullet; protocol `mcp/`), `docs/guide/knowledge-store.md` (`delta.json` row; `packageSkills` and `heldCache` in the sync steps), `docs/guide/version-delta.md` (`delta.json` section; add `packages/appstein_protocol/lib/src/knowledge/delta_knowledge.dart` to its covers), `docs/guide/incremental-sync.md` (the held cache), `docs/guide/ci.md` (the MCP table in `measure`)
- Generated: whatever `tool/gen_docs.dart` rewrites

- [ ] **Step 1: Write the guide page**

Create `docs/guide/mcp-server.md` starting with

```
<!-- covers:
packages/appstein_engine/lib/src/mcp/**
packages/appstein_protocol/lib/src/mcp/**
-->
```

and sections, written for a human who is learning (short paragraphs, what and why):
1. **What it is:** `appstein mcp`, stdio, started by the agent; the seven tools and why `verify` and `package_check` come in 1d.
2. **One call, step by step:** queue → `detect` (package skills off, held cache) → `KnowledgeSnapshot` → the pure query → `withoutNulls`, `summary`, `freshness` → two text blocks. A Mermaid sequence diagram.
3. **Freshness:** the three states and when each happens (no state, an edit, a busy lock, a failed sync, an invalid `appstein.yaml`); why the server always calls `detect`.
4. **Each tool:** input, what it returns, and its rules: the `where_is` tiers and the four-letter typo rule; `feature` name forms; `route` path forms and pattern matching; `check_api` match rules, statuses and deprecation kinds; `what_changed` counts versus `library` and why (the token numbers); `toolchain`'s thresholds.
5. **Replies for Claude Code:** why `summary` is inside the structured content (the issue link), and why replies never hold null.
6. **Testing it:** the query tests on goldens, the in-process client test, the real-stdio test, the CI timing table, and how to try it by hand (the Task 9 Step 6 command).

- [ ] **Step 2: Update the other pages**

Make the changes listed under **Files**, citing code with relative links as the existing pages do. In `cli.md`, add an `appstein mcp` section: startup, the exit code 3 case, config re-read per call, stdout belongs to the protocol. In `README.md`, add the row `| [mcp-server](mcp-server.md) | How \`appstein mcp\` answers agents: the seven read tools, freshness on every call, and the reply format |`.

- [ ] **Step 3: Regenerate and check**

Run from the repo root:

```bash
fvm dart run tool/gen_docs.dart
fvm dart run tool/check_guide.dart --since main
```

Expected: "Guide check passed." If it names an uncovered file or a stale page, fix the page, never the check.

- [ ] **Step 4: Name the plan in progress.yaml (if not done yet) and commit**

`docs/superpowers/progress.yaml`'s 1c.1 entry already has `plan: 2026-10-03-slice-1c1-mcp-server.md` from the plan commit; confirm it.

```bash
git add docs
git commit -m "docs(guide): the MCP server page; cli, sync, delta, architecture and CI updates

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW"
```

- [ ] **Step 5: Update the knowledge graph**

Follow the graph update runbook (memory `reference_graph_update_runbook.md`): run `tool/check_graph.py` with graphify's Python; extract the new and changed docs (at most 3 subagents at once, never `python -` heredocs), merge, rewrite `.graphify_uncached.txt` after `make_cached.py` empties it, re-export the HTML with `graphify export html --node-limit 10000`, and repeat until `tool/check_graph.py` reports nothing. Commit `graphify-out/` changes only through that update.

---

### Task 12: Proof from Claude Code (§18 exit criterion)

**Files:**
- Modify: this plan (Notes from execution, after the final review)

- [ ] **Step 1: Ask the owner**

This runs `claude -p` on the owner's subscription a few times. Ask in chat and wait for a yes before Step 2.

- [ ] **Step 2: Prepare a real fixture project**

In the scratchpad folder (never inside the repo):
1. Copy `packages/appstein_engine/test/fixtures/apps/mvvm_app` to `<scratch>/claude proof/app` with `copyFixtureTree`'s rule (drop the `.fixture` suffix), so the path has a space.
2. Run `fvm flutter pub get` in it (the real SDK, so the map is built).
3. Compile the CLI: `fvm dart compile exe packages/appstein_cli/bin/appstein.dart -o "<scratch>/claude proof/appstein.exe"`.
4. Write `<scratch>/claude proof/app/.mcp.json`: `{"mcpServers": {"appstein": {"command": "<scratch>/claude proof/appstein.exe", "args": ["mcp"]}}}`, with the path written as JSON requires (forward slashes work on Windows).

- [ ] **Step 3: Ask Claude Code real questions**

From `<scratch>/claude proof/app`, run each, with only the Appstein tools allowed:

```bash
claude -p "Using only the appstein MCP tools, where is the login screen, and which feature is it in?" --mcp-config .mcp.json --strict-mcp-config --allowedTools "mcp__appstein__*" --output-format json
claude -p "Using only the appstein MCP tools: may I use WillPopScope in this project? What should I use instead?" --mcp-config .mcp.json --strict-mcp-config --allowedTools "mcp__appstein__*" --output-format json
claude -p "Using only the appstein MCP tools: what does the route /booking/42 show, and does it redirect?" --mcp-config .mcp.json --strict-mcp-config --allowedTools "mcp__appstein__*" --output-format json
```

Expected: each answer is correct for the fixture (`lib/ui/auth/login/widgets/login_screen.dart`, feature `auth/login`; `WillPopScope` → `PopScope`, or "ok" if the real Flutter stub-free delta says so, quoting the delta; `/booking/:id`, no screen recorded, redirects). The JSON shows `mcp__appstein__…` tool calls. If a reply suggests the model saw only the text blocks or nothing at all, that contradicts the Claude Code fact this plan relies on: investigate before going on.

- [ ] **Step 4: Record it**

Write the three questions, the tools Claude Code called, and a one-line summary of each answer in the plan's notes from execution (Finish step), with the Claude Code version (`claude --version`).

---

## Finish

After Task 12: the final whole-branch review (most capable model), the one fix pass, then the plan's "Notes from execution" (rulings, deferred minors, the measured MCP times, the Claude Code proof), `progress.yaml` (1c.1 done with its PR, 1c.2 next) and `gen_docs`, and the pull request.

## Notes from execution

Built subagent-driven on `slice-1c1`, 2026-10-03 to 2026-10-05: one implementer per task, a fresh reviewer per task (Opus for Tasks 2, 6 and 8), then one whole-branch review on Opus and one fix wave. Subagents never committed; the controller committed each task. PR #4.

**Commits:** `9e311bf` spec; `bc5dec1` this plan; `df9313a` + `a49beea` Task 1; `8546b9d` Task 2; `32df552` + `b1dc565` Task 3; `fbc9f34` Task 4; `289d906` Task 5; `7648af6` + `eff357d` Task 6; `d84e33f` Task 7; `65face1` + `b19a757` Task 8; `e9318c8` Task 9; `1d850dd` Task 10; `cda176b` Task 11 (guide); `3a3e699` final-review fixes.

**Owner decisions (brainstorming):**
1. 1c is split in three, MCP first; `verify` and `package_check` move to 1d with their engines.
2. `sync` writes `platform/delta.json`; `check_api`'s "ok" means nothing the project imports deprecates or removes the name, and existence isn't checked.
3. Freshness: `detect` runs in process before every call.
4. `what_changed` returns notes and per-library counts; `library` lists one library in full.

**What the reviews caught (all fixed):**
- Task 1: four files weren't `dart format` clean, which CI checks.
- Task 3: a knowledge file that isn't UTF-8 crashed the reader; it is now reported as damaged.
- Task 6 (Opus): `check_api` answered a false "ok" for `Owner.member` forms with no exact entry (a setter without `=`, an inherited member, an instance receiver, a leading dot), for `Foo()`, `Owner(param)` and a bare parameter name, and for names with arguments; note matching pulled in unrelated notes through `new` and `dart`.
- Task 8 (Opus): the test "package skills never run from the server" could never fail.
- Final review (Opus): `check_api` answered a false "ok" for a member or constructor of a deprecated class (`MaterialStateProperty.all`, `WillPopScope.new`) and for names with type arguments; `appstein help mcp` printed to the real stdout, so the guide's generated help block was empty.

**Rulings:**
- Task 3: `dependency_validator` flagged `dart_mcp` and `stream_channel` until Task 8 imported them in `lib/`. Left as it was; clean since Task 8. Cost if wrong: one CI failure.
- Task 4: the plan's "scores tiers" test queried `booking`, but ten symbols hold that word and fill the top 10, so the test now queries `settings`. The spec's scoring is binding. Cost if wrong: a test rewrite.
- Task 4 (owner question): with the spec's scoring, a word in 10 or more symbol names hides the matching feature, route and file. The code follows spec §8; changing it needs the owner. Cost if wrong: `where_is booking` lists only symbols until the spec changes.
- Task 6: when nothing matches exactly, `check_api` falls back to a looser match and names the delta entry it matched, instead of answering "ok". It has no type information, so an inherited or instance form can only match by member name. Cost if wrong: an occasional "deprecated" for a same-named member of another class, with the entry named so the agent can judge.
- Task 8: the vacuous server test was dropped. The guarantee is tested where the sync is built, in the CLI's `mcpSyncFactory` test, which was mutation-checked. Cost if wrong: none.
- Task 12: `claude -p` ran with the plan's prompts plus `--tools ""` (built-in tools off), `--output-format stream-json --verbose` (plain `json` doesn't list tool calls) and `--setting-sources project --no-session-persistence` (the owner's personal hooks and plugins don't fire). Cost if wrong: none; a read-only run in a scratch folder.

**Measured (spec §15, limit 1 s):** on the 200-file app, locally, each tool's median is 62–68 ms (`overview` 62, `where_is` 68, `feature` 62, `route` 62, `check_api` 65, `what_changed` 65, `toolchain` 65). On the fixture app with the real SDK, the first call rebuilt everything in 20.4 s; later calls took 27–102 ms.

**Proof from Claude Code (§18 exit criterion):** Claude Code 2.1.289, model `claude-opus-4-8`, on a copy of the fixture app with Flutter 3.47.5; `appstein` connected and the model's only tools were the seven `mcp__appstein__*`.
1. "Where is the login screen, and which feature is it in?" → `where_is` → `LoginScreen`, `lib/ui/auth/login/widgets/login_screen.dart:6`, feature `auth/login`. Correct.
2. "May I use WillPopScope in this project? What should I use instead?" → `check_api` → deprecated; use `PopScope`, with the curated note and its source. Correct.
3. "What does the route /booking/42 show, and does it redirect?" → `route` → matches `/booking/:id`, no screen recorded, redirects, and the map doesn't record where to. Correct.

The model saw only the structured content, with `summary` and `freshness` in it, and never the text blocks. The fact this plan relies on holds.

**Environment notes:**
- Windows Defender once quarantined a freshly compiled `appstein.exe` in a temp folder (a false positive on an unsigned Dart executable). Nothing in Defender was changed; `fvm dart packages/appstein_cli/bin/appstein.dart --project <app> mcp` serves the same way.
- `fvm` in a folder without `.fvmrc` falls back to the PATH SDK (Dart 3.10.7 on the owner's machine), so the scratch app needed its own `.fvmrc`.
- A pipe that closes stdin at once ends the server before queued calls are answered. Claude Code keeps stdin open.

**Carried to later slices:**
- **Owner questions (spec §8 wording):** the `booking` case above; and the typo rule compares a 4+ letter query word with path words of any length, so `list` matches `lib` and `dart` in every file path.
- **1d:** on an analyzer retry, `map_sync.dart` abandons the first analysis without disposing it. In the server that is at most one leak per lifetime; revisit when warm analysis runs in the same process.
- **Server:** a `detect` that never returns would hold up every later call; when stdin closes, queued calls go unanswered; the held cache is dropped after a mid-sync failure; the `what_changed` notes list has no cap (about 8–10k tokens now); a `ConfigException` message names `appstein.yaml` twice.
- **`check_api`:** a deprecated member of a removed class reports `deprecated`, not `removed`; only the first named argument of a call is read as the parameter.
- **`where_is`, `route`, `toolchain`:** the word split treats non-ASCII letters as separators; path normalization trims one trailing slash only; `describe` in `route_query.dart` has two dead fields; the "Flutter's Gradle plugin" wording is also used for `minSdk`; a malformed threshold or a `found` value of null in corrupt knowledge would throw (the server's catch-all turns it into a refusal).
- **Tests to add:** `delta.json` with `apis` absent when the fetch fails; an older `state.json` without `delta.json`; a held cache with a part-way-failed sync, with an edit between server calls, and `loadedEntries > 0`; the "exists but could not be read" branch; `KnowledgeWriteException` and the catch-all in the server; several pattern matches and the 20-item cut in `route`; the tie order in `where_is`; version comparisons such as `8.9.1` and `8.10`; `measure_sync`'s `close()` has no timeout and a non-JSON line throws a `FormatException`.
- **Process:** two implementers wrote code before the test (Task 5, and the help fix in the final wave); the reviewers judged the tests sound.
