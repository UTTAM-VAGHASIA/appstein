# Slice 1b.5: Version delta Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `appstein sync` also writes `.appstein/platform/delta.md`. It's a cheat sheet that tells an agent, before it writes code, which APIs of the installed Flutter, Dart and the project's packages are deprecated, removed or moved, and what to use instead. It also lists Appstein's curated notes since the baseline.

**Architecture:**
- **`fix_data` parser:** `lib/src/delta/fix_data.dart` reads `fix_data` YAML (the migration files `dart fix` reads) into `FixDataTransform`s.
- **Collector:** `lib/src/delta/delta_collector.dart` runs while the project map's analyzer is still open.
  - It walks the export namespaces of every library the project imports and collects every `@Deprecated` element, by kind.
  - It finds the `fix_data` files of those packages and of the Dart SDK.
  - It classifies each migration in scope as attached to a deprecation, `removed`, `changed`, or a moved library.
- **Renderer:** `lib/src/delta/delta_document.dart` turns the facts and the curated notes into Markdown. It's pure, so a golden file pins it.
- **Store:** it learns to write Markdown files with their metadata in YAML front matter.
- **Wiring:** `MapSync` returns the facts and its input hash; `KnowledgeSync` renders `delta.md` and writes it with the other files; the CLI passes `delta.baseline` from `appstein.yaml`.

**Tech Stack:** Dart 3.12+ (Flutter 3.47.5 via FVM), `package:analyzer` 14.4 (element model and export namespaces), `package:yaml`, `package:path`, `package:test`.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md`. This plan implements:
- §6.4 as edited in commit `3e123a5` (owner-approved E1–E7): three sources, the baseline limiting only the notes, filtering by what the imports expose, removed APIs, and the notes-only fallback;
- §6.2: `delta.md` and Markdown metadata in front matter;
- §5.2: the `delta/` component;
- §15: determinism, Windows paths, offline, and the 30 s full-sync target.

`check_api` and `what_changed` (§8) are slice 1c; the INDEX entries (§6.3) are slice 1b.6.

## Global Constraints

- **Commands:** run every Dart command through FVM: `fvm dart …`. The repo pins Flutter 3.47.5 (Dart 3.13.4); packages declare `sdk: ^3.12.0`. CI also runs the unit tests on Flutter 3.44 (Dart 3.12), so no test may depend on exact contents of the real Dart SDK or real Flutter beyond what this plan names.
- **Boundaries (spec §5.1):**
  - `appstein_protocol` depends on nothing internal; `appstein_engine` only on `appstein_protocol`; `appstein_cli` on the engine and protocol.
  - The engine core never imports a pack.
  - `lib/src/delta/` is engine core.
  - `layer_imports` enforces all this.
- **Docs and analysis:** every public API has a `///` doc comment (`public_member_api_docs`). These must pass from the repo root:
  - `fvm dart analyze --fatal-infos`;
  - `fvm dart format --output=none --set-exit-if-changed .`;
  - `fvm dart run dependency_validator`.
- **Byte order marks:** no raw U+FEFF byte in any `.dart` file. Nothing in this slice needs the BOM escape.
- **Windows is first-class:**
  - every file-system test uses `tempDir()` (`packages/appstein_engine/test/support/temp.dart`), whose path holds a space and a non-ASCII character;
  - generated text uses `\n` on every OS;
  - names in `delta.md` never contain a machine path.
- **Analyzer paths:** `package:analyzer` accepts only absolute, normalized paths. `ProjectAnalysis` already normalizes.
- **Determinism (§15):**
  - every list in the facts is sorted as its task specifies, and the renderer adds nothing that varies;
  - the same inputs give byte-identical `delta.md` on every OS;
  - the file is written by `KnowledgeStore.writeGeneratedMarkdown` (rewritten only when its bytes would change).
- **Never invent advice (owner decision):** every line quotes the library's own message, the migration's own title, or a curated note. The only Appstein words are the section intros, the rule for each deprecation kind, and the words `removed`/`changed`.
- **No network in unit tests.** Only the real-SDK integration test (Task 6) runs a real `flutter pub get`.
- **Fixtures:**
  - fixture Dart and YAML files end in `.fixture`, so the repo's analyzer, formatter and graph ignore them; the test helper copies them without the suffix;
  - golden files end in `.golden`.
- **Tests stay in temp folders:** tests never write into the repo, `graphify-out/` or `.git/hooks`. The single exception is `APPSTEIN_UPDATE_GOLDENS=1`, which a person runs on purpose.
- **Commits:** subagents never commit. The controller commits each task after its review, with the session's trailer lines, behind the BOM byte scan: `LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test` must print nothing.
- **Subagents:** at most 3 running at once (owner rule).
- **analyzer 14.4 names:** if a member this plan uses has a different name in analyzer 14.4, use the 14.4 name with the same meaning, and say so in the report. Don't change behaviour.

## Review Focus

These are the five inputs most likely to bite a user, though no single feature test covers them. Each one has a test in the task named.

1. **The map is skipped** (offline with nothing cached, or a broken `pubspec.lock`). `sync` still exits 0 and writes a notes-only `delta.md` that says why the rest is missing and what to do. *Tests: Task 4 (render), Task 5 (sync).*
2. **A package's migration file is odd**:
   - an empty file (Flutter ships `fix_template.yaml` empty);
   - a library migration (Flutter 3.47's `material_ui` move);
   - a broken file;
   - relative and absolute URIs for the same library (go_router's).

   The odd file is reported under "Not read" or handled; the rest of the delta is intact; `sync` never fails. *Tests: Task 2, Task 3.*
3. **The same API reachable in several ways**: through two imports; inherited from a private superclass; a field and its getter. It's listed once, under a public name. *Test: Task 3.*
4. **Messages that would break one line of Markdown**: line breaks, backticks, `*`, or no message at all (`@deprecated`). Each becomes one readable line. *Tests: Task 3 (collect), Task 4 (render).*
5. **Versions at the edges**:
   - a Flutter newer than the notes (partial coverage);
   - an unknown language version (no `sdk:` lower bound);
   - a custom baseline such as `"3.24"`.

   The right notes appear, and the coverage line says so. *Tests: Task 4, Task 5 (baseline from `appstein.yaml` through the CLI).*

## Decisions made while planning (for the owner's review)

Every fact below was checked against Flutter's or Dart's own files on 2026-10-01.

- **D1, the migration scope rule is Dart's.** A migration counts when a project library **directly imports** one of the libraries it lists.
  - Read in the Dart SDK's `pkg/analysis_server/lib/src/services/correction/fix/data_driven/element_matcher.dart`, lines 132–139 and 164–189: `dart fix` doesn't follow re-exports and ignores `show`/`hide`.
  - Deprecations instead use what the imports **expose** (the export namespaces), as the analyzer's `deprecated_member_use` sees them; `show`/`hide` aren't applied.
  - Cost if wrong: an API hidden with `hide` is still listed (harmless guidance).
- **D2, library migrations get their own short section, "Moved libraries."** Flutter 3.47 ships two `fix_data` entries with `library:` instead of `element:`: `flutter/material.dart` → `material_ui`, and the Cupertino twin. They aren't removed APIs. The line quotes the title, and the section intro says to check the curated notes before switching (the notes explain the `material_ui` bridge limitation). Cost if wrong: an agent switches libraries early; the notes and the 1d check below guard against it.
- **D3, migration files are read from:**
  - the packages the project imports directly (`<package lib>/fix_data.yaml` and `<package lib>/fix_data/**.yaml`, the two places the analyzer looks, verified in analyzer 14.4's `src/util/file_paths.dart`);
  - the Dart SDK's `lib/_internal/fix_data.yaml` (212 entries in Dart 3.13.4, and present since at least 3.10.7).

  A package's file that names *another* package's libraries is not read. Cost if wrong: a rare cross-package migration is missing.
- **D4, headings name the package without its version** (`### package:go_router`). Versions are in `deps.json`. This is a change to the Part 1 sample, which showed a version.
- **D5, a deprecated member inherited from a private superclass** is listed under the public class that exposes it (`Panel.show`, not `_PanelBase.show`). A member of a public superclass is listed under that superclass.
- **D6, a migration for a deprecated element or parameter is attached to its deprecation line** ("`dart fix` migrates it: …"), not repeated under Removed. Example: Flutter's `NewBox(width:)` → `size` style renames of deprecated parameters.
- **D7, an unknown Flutter version** (`0.0.0-unknown`, a fork) gets no notes, the same answer `CuratedNotes.notesFor` already gives, plus the partial-coverage line.
- **D8, the delta's model stays in the engine** (`lib/src/delta/delta_facts.dart`), not the protocol. Nothing serializes it yet. Slice 1c moves it to the protocol if `check_api` needs JSON.
- **D9, `delta.md`'s input hash** covers:
  - the map's own input hash (or "skipped" and the reason);
  - every notes file;
  - the baseline;
  - the language version;
  - the Flutter version.

  The map's hash already covers the project's Dart files, `pubspec.yaml`, the lock file and `analysis_options.yaml`, and so every package's version.
- **D10, the front matter** is `---`, one `key: value` line per metadata field in key order, each value written as JSON (also valid YAML, and quoting keeps `generatedAt` a string), then `---`, a blank line, and the text.
- **D11, the size guard:**
  - the real-SDK test checks at most **1,500 lines** and no duplicate entry line;
  - today, everything Flutter 3.47.5 marks (about 500 deprecations) plus every migration (383 Flutter, 212 Dart, 13 go_router) is under 1,150 entries, so more lines means duplicates.

---

## File map

| File | Responsibility |
|---|---|
| `packages/appstein_engine/lib/src/knowledge/generated_file.dart` | `GeneratedFile` gains `GeneratedFile.markdown` |
| `packages/appstein_engine/lib/src/knowledge/markdown_front_matter.dart` | `markdownWithFrontMatter`, `readFrontMatter` |
| `packages/appstein_engine/lib/src/knowledge/knowledge_store.dart` | + `writeGeneratedMarkdown`; `writeAll` writes both kinds |
| `packages/appstein_engine/lib/src/delta/fix_data.dart` | `parseFixData`, `FixDataTransform`, `FixDataFormatException`, `fixDataElementKinds` |
| `packages/appstein_engine/lib/src/delta/delta_facts.dart` | `DeprecationKind`, `DeprecatedApi`, `MigrationStatus`, `MigratedApi`, `MovedLibrary`, `UnreadMigrations`, `DeltaFacts` |
| `packages/appstein_engine/lib/src/delta/delta_collector.dart` | `collectDelta` |
| `packages/appstein_engine/lib/src/delta/delta_document.dart` | `deltaPath`, `DeltaInputs`, `deltaNotes`, `renderDelta` |
| `packages/appstein_engine/lib/src/map/map_sync.dart` | `MapBuild` gains `inputHash` and `delta`; `build` collects the delta |
| `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart` | `baseline`; renders and writes `delta.md` |
| `packages/appstein_engine/lib/appstein_engine.dart` | exports the new files |
| `packages/appstein_cli/lib/src/sync_command.dart` | passes `config.delta.baseline` |
| `packages/appstein_engine/test/fixtures/apps/stubs/delta_kit/**.fixture` | A package made for the delta tests |
| `packages/appstein_engine/test/fixtures/apps/stubs/go_router/lib/fix_data.yaml.fixture` | go_router's real `location` migration |
| `packages/appstein_engine/test/fixtures/apps/goldens/delta.md.golden` | The renderer's golden |
| `packages/appstein_engine/test/support/fixture_app.dart` | + `expectTextGolden`, `analyzeDeltaApp` |
| `docs/guide/version-delta.md` | New guide page |

---

### Task 1: Markdown files in the knowledge store

**Files:**
- Modify: `packages/appstein_engine/lib/src/knowledge/generated_file.dart`
- Create: `packages/appstein_engine/lib/src/knowledge/markdown_front_matter.dart`
- Modify: `packages/appstein_engine/lib/src/knowledge/knowledge_store.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart`
- Test: `packages/appstein_engine/test/knowledge/knowledge_store_test.dart`, `packages/appstein_engine/test/knowledge/markdown_front_matter_test.dart`

**Interfaces:**
- Consumes: `KnowledgeMeta`, `knowledgeFormatVersion` (protocol); `replaceFile`, `KnowledgeStore.now()`.
- Produces:
  - `GeneratedFile.markdown({required String path, required String markdown, required String inputHash})`; `GeneratedFile.body` becomes `Map<String, Object?>?`, and `GeneratedFile.markdown` is a `String?` field;
  - `String markdownWithFrontMatter(String markdown, KnowledgeMeta meta)`;
  - `KnowledgeMeta? readFrontMatter(String text)`;
  - `Future<bool> KnowledgeStore.writeGeneratedMarkdown(String path, String markdown, {required String inputHash, required String appsteinVersion, required String sdkVersion})`;
  - `writeAll` accepts both kinds.

- [ ] **Step 1: Write the failing front-matter tests**

Create `packages/appstein_engine/test/knowledge/markdown_front_matter_test.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  const meta = KnowledgeMeta(
    generatedAt: '2026-10-01T09:30:05Z',
    appsteinVersion: '0.1.0-dev',
    formatVersion: 1,
    sdkVersion: '3.47.5',
    inputHash: 'h1',
  );

  test('puts the meta in front matter, keys sorted, values as JSON', () {
    expect(
      markdownWithFrontMatter('# Delta\n\nBody.\n', meta),
      '---\n'
      'appsteinVersion: "0.1.0-dev"\n'
      'formatVersion: 1\n'
      'generatedAt: "2026-10-01T09:30:05Z"\n'
      'inputHash: "h1"\n'
      'sdkVersion: "3.47.5"\n'
      '---\n'
      '\n'
      '# Delta\n'
      '\n'
      'Body.\n',
    );
  });

  test('turns CRLF into LF and ends the text with exactly one newline', () {
    expect(
      markdownWithFrontMatter('# Delta\r\n\r\nBody.\r\n\r\n\r\n', meta),
      endsWith('---\n\n# Delta\n\nBody.\n'),
    );
  });

  test('reads back what it wrote', () {
    final read = readFrontMatter(markdownWithFrontMatter('# Delta\n', meta))!;
    expect(read.toJson(), meta.toJson());
  });

  for (final damaged in [
    '# Delta\n',
    '---\n---\n\n# Delta\n',
    '---\ngeneratedAt: 2026\n---\n\n# Delta\n',
    '---\nappsteinVersion "x"\n---\n',
    '---\nappsteinVersion: "x"\n',
    '---\nappsteinVersion: not json\n---\n',
  ]) {
    test('gives null for damaged front matter: ${damaged.split('\n')[1]}', () {
      expect(readFrontMatter(damaged), isNull);
    });
  }
}
```

- [ ] **Step 2: Write the failing store tests**

Append inside `main()` of `packages/appstein_engine/test/knowledge/knowledge_store_test.dart`, after the test `'now() is the clock in the .appstein/ time format'`:

```dart
  group('Markdown files', () {
    File deltaFile() =>
        File(p.join(project, '.appstein', 'platform', 'delta.md'));

    Future<bool> writeMarkdown(
      KnowledgeStore store,
      String hash, {
      String text = '# Delta\n\nBody.\n',
    }) => store.writeGeneratedMarkdown(
      'platform/delta.md',
      text,
      inputHash: hash,
      appsteinVersion: '0.1.0-dev',
      sdkVersion: '3.47.5',
    );

    test('writes the text after front matter, creating folders', () async {
      final wrote = await writeMarkdown(
        storeAt(DateTime.utc(2026, 10, 1, 9, 30, 5)),
        'h1',
      );
      expect(wrote, isTrue);
      expect(
        deltaFile().readAsStringSync(),
        '---\n'
        'appsteinVersion: "0.1.0-dev"\n'
        'formatVersion: 1\n'
        'generatedAt: "2026-10-01T09:30:05Z"\n'
        'inputHash: "h1"\n'
        'sdkVersion: "3.47.5"\n'
        '---\n'
        '\n'
        '# Delta\n'
        '\n'
        'Body.\n',
      );
    });

    test('skips unchanged Markdown, so no byte changes', () async {
      await writeMarkdown(storeAt(DateTime.utc(2026, 10, 1)), 'h1');
      final before = deltaFile().readAsStringSync();
      final wrote = await writeMarkdown(storeAt(DateTime.utc(2026, 10, 2)), 'h1');
      expect(wrote, isFalse);
      expect(deltaFile().readAsStringSync(), before);
    });

    test('rewrites Markdown whose input hash changed', () async {
      await writeMarkdown(storeAt(DateTime.utc(2026, 10, 1)), 'h1');
      final wrote = await writeMarkdown(storeAt(DateTime.utc(2026, 10, 2)), 'h2');
      expect(wrote, isTrue);
      expect(deltaFile().readAsStringSync(), contains('inputHash: "h2"'));
      expect(deltaFile().readAsStringSync(), contains('2026-10-02T00:00:00Z'));
    });

    test('puts back hand-edited Markdown whose front matter is intact',
        () async {
      await writeMarkdown(storeAt(DateTime.utc(2026, 10, 1)), 'h1');
      final original = deltaFile().readAsStringSync();
      deltaFile().writeAsStringSync(original.replaceFirst('Body.', 'Edited.'));
      final wrote = await writeMarkdown(storeAt(DateTime.utc(2026, 10, 2)), 'h1');
      expect(wrote, isTrue);
      expect(
        deltaFile().readAsStringSync(),
        original.replaceFirst('2026-10-01T', '2026-10-02T'),
      );
    });

    for (final damaged in ['no front matter\n', '---\n---\n', '']) {
      test('rewrites a damaged Markdown file: ${damaged.trim()}', () async {
        deltaFile()
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(damaged);
        expect(
          await writeMarkdown(storeAt(DateTime.utc(2026, 10, 1)), 'h1'),
          isTrue,
        );
        expect(deltaFile().readAsStringSync(), contains('inputHash: "h1"'));
      });
    }

    test('writeAll writes JSON and Markdown files and lists both in '
        'state.json', () async {
      final store = storeAt(DateTime.utc(2026, 10, 1));
      final written = await store.writeAll(
        const [
          GeneratedFile(
            path: 'platform/sdk.json',
            body: {'flutter': '3.47.5'},
            inputHash: 'h1',
          ),
          GeneratedFile.markdown(
            path: 'platform/delta.md',
            markdown: '# Delta\n',
            inputHash: 'h2',
          ),
        ],
        appsteinVersion: '0.1.0-dev',
        sdkVersion: '3.47.5',
      );
      expect(written, {'platform/sdk.json': true, 'platform/delta.md': true});
      expect(readFrontMatter(deltaFile().readAsStringSync())!.inputHash, 'h2');
      expect(
        File(p.join(project, '.appstein', 'state.json')).readAsStringSync(),
        contains('"platform/delta.md": "h2"'),
      );
    });
  });
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/knowledge/markdown_front_matter_test.dart test/knowledge/knowledge_store_test.dart`
Expected: FAIL to compile: `markdownWithFrontMatter`, `readFrontMatter`, `writeGeneratedMarkdown` and `GeneratedFile.markdown` aren't defined.

- [ ] **Step 4: Write `markdown_front_matter.dart`**

Create `packages/appstein_engine/lib/src/knowledge/markdown_front_matter.dart`:

```dart
import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';

/// [markdown] with [meta] in a YAML front matter block before it (spec
/// §6.2): `---`, one `key: value` line per field in key order, `---`, a
/// blank line, then the text.
///
/// Each value is written as JSON, which is also valid YAML; the quotes keep
/// `generatedAt` a string for YAML readers that know timestamps. Line ends
/// are `\n`, and the text ends with exactly one `\n`.
String markdownWithFrontMatter(String markdown, KnowledgeMeta meta) {
  final fields = meta.toJson();
  final keys = fields.keys.toList()..sort();
  final buffer = StringBuffer('---\n');
  for (final key in keys) {
    buffer.writeln('$key: ${jsonEncode(fields[key])}');
  }
  buffer
    ..write('---\n\n')
    ..write(markdown.replaceAll('\r\n', '\n').trimRight())
    ..write('\n');
  return buffer.toString();
}

/// The metadata in the front matter of a generated Markdown [text], as
/// [markdownWithFrontMatter] writes it, or null when the text has none or
/// it is damaged.
KnowledgeMeta? readFrontMatter(String text) {
  if (!text.startsWith('---\n')) return null;
  final end = text.indexOf('\n---\n', 3);
  if (end < 4) return null;
  final fields = <String, Object?>{};
  for (final line in text.substring(4, end).split('\n')) {
    final colon = line.indexOf(': ');
    if (colon <= 0) return null;
    try {
      fields[line.substring(0, colon)] = jsonDecode(line.substring(colon + 2));
    } on FormatException {
      return null;
    }
  }
  try {
    return KnowledgeMeta.fromJson(fields, file: 'front matter');
  } on FormatException {
    return null;
  }
}
```

- [ ] **Step 5: Give `GeneratedFile` a Markdown form**

Replace the whole of `packages/appstein_engine/lib/src/knowledge/generated_file.dart` with:

```dart
/// A generated `.appstein/` file, built but not yet written: JSON with a
/// [body], or Markdown with a [markdown] text (spec §6.2).
final class GeneratedFile {
  /// A JSON file. The store adds its `meta` key.
  const GeneratedFile({
    required this.path,
    required Map<String, Object?> this.body,
    required this.inputHash,
  }) : markdown = null;

  /// A Markdown file. The store adds the front matter that holds its
  /// metadata.
  const GeneratedFile.markdown({
    required this.path,
    required String this.markdown,
    required this.inputHash,
  }) : body = null;

  /// Its path inside `.appstein/`, with `/`, such as `map/routes.json`.
  final String path;

  /// A JSON file's content, without `meta` (the store adds that); null for a
  /// Markdown file.
  final Map<String, Object?>? body;

  /// A Markdown file's text, without its front matter (the store adds that);
  /// null for a JSON file.
  final String? markdown;

  /// The hash of everything it was built from (spec §6.2).
  final String inputHash;
}
```

- [ ] **Step 6: Teach the store to write Markdown**

In `packages/appstein_engine/lib/src/knowledge/knowledge_store.dart`:

1. Add `import 'markdown_front_matter.dart';` after `import 'knowledge_write_exception.dart';`.
2. Change the class doc comment's first sentence to: `/// A project's `.appstein/` folder (spec §6.2).` followed by a new paragraph:

```dart
///
/// It writes generated files, JSON with a `meta` key or Markdown with
/// front matter, skips a file whose content wouldn't change (so its bytes,
/// `generatedAt` included, stay the same; a hand-edited file is put back),
/// and replaces files in one step.
```

   This replaces the existing second paragraph.
3. Add this method after `writeGenerated`:

```dart
  /// Writes the Markdown [markdown] to [path] (inside `.appstein/`, with `/`
  /// separators), after a front matter block with its metadata
  /// ([markdownWithFrontMatter]). It follows the same rule as
  /// [writeGenerated]: it rebuilds the text with the `generatedAt` already in
  /// the file and skips the write only when the bytes would be the same.
  /// Returns whether it wrote.
  ///
  /// Throws a [KnowledgeWriteException] when the file can't be written. Call
  /// it inside [locked].
  Future<bool> writeGeneratedMarkdown(
    String path,
    String markdown, {
    required String inputHash,
    required String appsteinVersion,
    required String sdkVersion,
  }) async {
    final target = _pathOf(path);
    String textWith(String generatedAt) => markdownWithFrontMatter(
      markdown,
      KnowledgeMeta(
        generatedAt: generatedAt,
        appsteinVersion: appsteinVersion,
        formatVersion: knowledgeFormatVersion,
        sdkVersion: sdkVersion,
        inputHash: inputHash,
      ),
    );
    final stored = _storedMarkdownGeneratedAt(target);
    if (stored != null && stored.text == textWith(stored.generatedAt)) {
      return false;
    }
    await replaceFile(target, textWith(now()));
    return true;
  }
```

4. In `writeAll`, replace the loop body with:

```dart
    for (final file in files) {
      written[file.path] = file.body case final body?
          ? await writeGenerated(
              file.path,
              body,
              inputHash: file.inputHash,
              appsteinVersion: appsteinVersion,
              sdkVersion: sdkVersion,
            )
          : await writeGeneratedMarkdown(
              file.path,
              file.markdown!,
              inputHash: file.inputHash,
              appsteinVersion: appsteinVersion,
              sdkVersion: sdkVersion,
            );
    }
```

   If the formatter or the analyzer rejects `case` in a conditional expression, use `if (file.body case final body?) { … } else { … }` with the same two calls.
5. Change `writeAll`'s doc comment first line to: `/// Writes each of [files] (JSON with [writeGenerated], Markdown with [writeGeneratedMarkdown]), then `state.json` listing`.
6. Add this helper after `_storedGeneratedAt`:

```dart
  /// The text of the Markdown file at [path] and the `generatedAt` in its
  /// front matter, or null when the file is missing, unreadable or damaged.
  static ({String text, String generatedAt})? _storedMarkdownGeneratedAt(
    String path,
  ) {
    try {
      final text = File(path).readAsStringSync();
      final meta = readFrontMatter(text);
      return meta == null ? null : (text: text, generatedAt: meta.generatedAt);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }
```

In `packages/appstein_engine/lib/appstein_engine.dart`, add `export 'src/knowledge/markdown_front_matter.dart';` after `export 'src/knowledge/knowledge_write_exception.dart';`.

- [ ] **Step 7: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/knowledge/`
Expected: PASS, including every earlier test in that folder (the JSON path is unchanged).

- [ ] **Step 8: Analyze and format**

Run from the repo root:
- `fvm dart analyze --fatal-infos`
- `fvm dart format --output=none --set-exit-if-changed .`

Expected: no issues.

- [ ] **Step 9: Commit (controller)**

```bash
git add packages/appstein_engine/lib/src/knowledge packages/appstein_engine/lib/appstein_engine.dart packages/appstein_engine/test/knowledge
git commit -m "feat: generated Markdown files with their metadata in front matter (spec §6.2)"
```

---

### Task 2: The `fix_data` parser

**Files:**
- Create: `packages/appstein_engine/lib/src/delta/fix_data.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart`
- Test: `packages/appstein_engine/test/delta/fix_data_test.dart`

**Interfaces:**
- Consumes: `package:yaml`.
- Produces:
  - `const Set<String> fixDataElementKinds`;
  - `final class FixDataTransform` with `title`, `uris` (`List<Uri>`), `kind`, `name`, `container`, `oldParameters` (`Set<String>`), `library` (`Uri?`), `newLibrary` (`Uri?`);
  - `final class FixDataFormatException implements Exception` with `file`, `line` (`int?`), `problem` and a `reason` getter;
  - `List<FixDataTransform> parseFixData(String text, {required String file, required Uri base})`.

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/delta/fix_data_test.dart`. The first sample is copied from Flutter 3.47.5's `fix_widgets.yaml` (the two `Stack` entries, abridged) and go_router 18.0.2's `fix_data.yaml`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  final flutter = Uri.parse('package:flutter/');

  List<FixDataTransform> parse(String text, {Uri? base}) =>
      parseFixData(text, file: 'fix.yaml', base: base ?? flutter);

  // Two of Flutter 3.47.5's real migrations, from fix_widgets.yaml.
  const stack = '''
version: 1
transforms:
  # Changes made in https://github.com/flutter/flutter/pull/66305
  - title: "Migrate to 'clipBehavior'"
    date: 2020-09-22
    element:
      uris: [ 'widgets.dart', 'material.dart', 'cupertino.dart' ]
      field: 'overflow'
      inClass: 'Stack'
    changes:
      - kind: 'rename'
        newName: 'clipBehavior'

  - title: "Migrate to 'clipBehavior'"
    date: 2020-09-22
    element:
      uris: [ 'widgets.dart', 'material.dart', 'cupertino.dart' ]
      constructor: ''
      inClass: 'Stack'
    oneOf:
      - if: "overflow == 'Overflow.clip'"
        changes:
          - kind: 'addParameter'
            index: 0
            name: 'clipBehavior'
            style: optional_named
          - kind: 'removeParameter'
            name: 'overflow'
''';

  test('reads element migrations, resolving relative URIs against the '
      'package', () {
    final transforms = parse(stack);
    expect(transforms, hasLength(2));
    final field = transforms[0];
    expect(field.title, "Migrate to 'clipBehavior'");
    expect(field.uris.map((u) => '$u'), [
      'package:flutter/widgets.dart',
      'package:flutter/material.dart',
      'package:flutter/cupertino.dart',
    ]);
    expect(field.kind, 'field');
    expect(field.name, 'overflow');
    expect(field.container, 'Stack');
    expect(field.oldParameters, isEmpty);
    expect(field.library, isNull);
  });

  test('an unnamed constructor has the name "", and old parameters come '
      'from oneOf too', () {
    final constructor = parse(stack)[1];
    expect(constructor.kind, 'constructor');
    expect(constructor.name, '');
    expect(constructor.oldParameters, {'overflow'});
  });

  test('renamed parameters count by their old name', () {
    final transforms = parse('''
transforms:
  - title: "Migrate 'child' to 'content'"
    element:
      uris: [ 'cupertino.dart' ]
      constructor: ''
      inClass: 'CupertinoPopupSurface'
    changes:
      - kind: 'renameParameter'
        oldName: 'child'
        newName: 'content'
''');
    expect(transforms.single.oldParameters, {'child'});
  });

  test('the same library named relatively and absolutely counts once, '
      "as in go_router's file", () {
    final transforms = parse('''
transforms:
  - title: "Replaces 'location' in 'GoRouterState' with `uri.toString()`"
    date: 2023-07-06
    bulkApply: true
    element:
      # TODO(ahmednfwela): Workaround for https://github.com/dart-lang/sdk/issues/52233
      uris: [ 'go_router.dart', 'package:go_router/go_router.dart' ]
      field: 'location'
      inClass: 'GoRouterState'
    changes:
      - kind: 'rename'
        newName: 'uri.toString()'
''', base: Uri.parse('package:go_router/'));
    expect(transforms.single.uris.map((u) => '$u'), [
      'package:go_router/go_router.dart',
    ]);
  });

  test('top-level kinds and the other containers', () {
    final transforms = parse('''
transforms:
  - title: 'A'
    element: {uris: ['a.dart'], function: 'f'}
  - title: 'B'
    element: {uris: ['a.dart'], constant: 'b', inEnum: 'E'}
  - title: 'C'
    element: {uris: ['a.dart'], method: 'm', inExtension: 'X'}
  - title: 'D'
    element: {uris: ['a.dart'], getter: 'g', inMixin: 'M'}
''');
    expect(
      [for (final t in transforms) '${t.kind} ${t.name} ${t.container}'],
      ['function f null', 'constant b E', 'method m X', 'getter g M'],
    );
  });

  test("reads a library migration, as Flutter 3.47's material_ui move", () {
    final transform = parse('''
transforms:
  - title: 'Migrate from flutter/material.dart to material_ui/material_ui.dart.'
    date: 2026-07-08
    library: 'package:flutter/material.dart'
    changes:
      - kind: 'replacedBy'
        newLibrary: 'package:material_ui/material_ui.dart'
''').single;
    expect(transform.library, Uri.parse('package:flutter/material.dart'));
    expect(
      transform.newLibrary,
      Uri.parse('package:material_ui/material_ui.dart'),
    );
    expect(transform.uris, isEmpty);
    expect(transform.kind, isNull);
  });

  test('a library migration without replacedBy has no new library', () {
    final transform = parse('''
transforms:
  - title: 'Stop using it.'
    library: 'package:flutter/material.dart'
''').single;
    expect(transform.newLibrary, isNull);
  });

  for (final empty in [
    '',
    '# Only a comment, like Flutter\'s fix_template.yaml.\n',
    'version: 1\n',
    'version: 1\ntransforms:\n',
  ]) {
    test('has no transforms: ${empty.split('\n').first}', () {
      expect(parse(empty), isEmpty);
    });
  }

  test('CRLF text reads the same', () {
    expect(
      parse(stack.replaceAll('\n', '\r\n')).map((t) => t.name),
      ['overflow', ''],
    );
  });

  for (final (text, line, problem) in [
    ('- a\n', 1, 'must be a map with a "transforms" list.'),
    ('transforms: 3\n', 1, '"transforms" must be a list.'),
    ('transforms:\n  - 3\n', 2, 'Each transform must be a map.'),
    ('transforms:\n  - date: 2020-01-01\n', 2, 'A transform needs a "title" string.'),
    (
      "transforms:\n  - title: 'x'\n",
      2,
      'A transform needs an "element" map or a "library".',
    ),
    (
      "transforms:\n  - title: 'x'\n    element:\n      class: 'A'\n",
      4,
      '"uris" must be a list of URI strings.',
    ),
    (
      "transforms:\n  - title: 'x'\n    element:\n      uris: ['a.dart']\n      class: 'A'\n      method: 'm'\n",
      4,
      'The element must name exactly one of: class, constant, constructor, '
          'enum, extension, field, function, getter, method, mixin, setter, '
          'typedef, variable.',
    ),
    (
      "transforms:\n  - title: 'x'\n    element:\n      uris: ['a.dart']\n      extensionType: 'A'\n",
      4,
      'The element must name exactly one of: class, constant, constructor, '
          'enum, extension, field, function, getter, method, mixin, setter, '
          'typedef, variable.',
    ),
    (
      "transforms:\n  - title: 'x'\n    element:\n      uris: ['a.dart']\n      method: 'm'\n      inClass: 'A'\n      inMixin: 'B'\n",
      4,
      'The element may have only one of inClass, inEnum, inExtension, '
          'inMixin.',
    ),
  ]) {
    test('reports line $line: $problem', () {
      expect(
        () => parse(text),
        throwsA(
          isA<FixDataFormatException>()
              .having((e) => e.file, 'file', 'fix.yaml')
              .having((e) => e.line, 'line', line)
              .having((e) => e.problem, 'problem', problem)
              .having((e) => e.reason, 'reason', 'line $line: $problem'),
        ),
      );
    });
  }

  test('invalid YAML is a FixDataFormatException with its line', () {
    expect(
      () => parse('transforms:\n  - title: [\n'),
      throwsA(
        isA<FixDataFormatException>()
            .having((e) => e.line, 'line', isNotNull)
            .having((e) => e.problem, 'problem', startsWith('is not valid YAML')),
      ),
    );
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/delta/fix_data_test.dart`
Expected: FAIL to compile: `parseFixData` isn't defined.

- [ ] **Step 3: Write the parser**

Create `packages/appstein_engine/lib/src/delta/fix_data.dart`:

```dart
import 'package:yaml/yaml.dart';

/// The element kinds a `fix_data` migration can name, the keys of its
/// `element:` map that `dart fix` reads.
const fixDataElementKinds = {
  'class',
  'constant',
  'constructor',
  'enum',
  'extension',
  'field',
  'function',
  'getter',
  'method',
  'mixin',
  'setter',
  'typedef',
  'variable',
};

const _containerKeys = ['inClass', 'inEnum', 'inExtension', 'inMixin'];

/// Thrown when a `fix_data` file can't be read as `dart fix` migrations.
final class FixDataFormatException implements Exception {
  /// Creates the exception.
  const FixDataFormatException(this.file, this.line, this.problem);

  /// The file, as the caller named it.
  final String file;

  /// The 1-based line of the problem, or null when unknown.
  final int? line;

  /// What is wrong.
  final String problem;

  /// The problem with its line, such as `line 4: "uris" must be a list…`.
  String get reason => line == null ? problem : 'line $line: $problem';

  @override
  String toString() => '$file: $reason';
}

/// One migration in a `fix_data` file (a data-driven fix that `dart fix`
/// applies): either an element that was renamed, removed or changed, or a
/// library that moved.
final class FixDataTransform {
  /// Creates the migration.
  const FixDataTransform({
    required this.title,
    this.uris = const [],
    this.kind,
    this.name,
    this.container,
    this.oldParameters = const {},
    this.library,
    this.newLibrary,
  });

  /// The migration's title, such as `Migrate to 'clipBehavior'`.
  final String title;

  /// The libraries the element is reachable through, resolved
  /// (`material.dart` in Flutter's files is `package:flutter/material.dart`),
  /// each once. Empty for a library migration.
  final List<Uri> uris;

  /// The element's kind, one of [fixDataElementKinds]; null for a library
  /// migration.
  final String? kind;

  /// The element's name: '' for an unnamed constructor, null for a library
  /// migration.
  final String? name;

  /// The class, enum, extension or mixin that declares the element, or null
  /// for a top-level element.
  final String? container;

  /// The old names of the parameters the migration removes or renames.
  final Set<String> oldParameters;

  /// For a library migration, the library it moves away from.
  final Uri? library;

  /// For a library migration, where its `replacedBy` change moves it, or
  /// null.
  final Uri? newLibrary;
}

/// Reads the `fix_data` file [text], named [file] in errors. Relative URIs
/// resolve against [base], the package's `lib/` folder as a URI such as
/// `package:flutter/`. An empty file, or one without `transforms`, has no
/// migrations.
///
/// Throws a [FixDataFormatException] when the text isn't valid YAML, isn't a
/// map, or a migration lacks a title, an element or a library, or names no
/// known element kind.
List<FixDataTransform> parseFixData(
  String text, {
  required String file,
  required Uri base,
}) {
  final YamlNode root;
  try {
    root = loadYamlNode(text);
  } on YamlException catch (error) {
    final span = error.span;
    throw FixDataFormatException(
      file,
      span == null ? null : span.start.line + 1,
      'is not valid YAML: ${error.message}',
    );
  }
  if (root is YamlScalar && root.value == null) return const [];
  if (root is! YamlMap) {
    throw FixDataFormatException(
      file,
      _lineOf(root),
      'must be a map with a "transforms" list.',
    );
  }
  final transforms = root.nodes['transforms'];
  if (transforms == null ||
      (transforms is YamlScalar && transforms.value == null)) {
    return const [];
  }
  if (transforms is! YamlList) {
    throw FixDataFormatException(
      file,
      _lineOf(transforms),
      '"transforms" must be a list.',
    );
  }
  try {
    return [for (final node in transforms.nodes) _transform(node, file, base)];
  } on FormatException catch (error) {
    // A URI that Uri.parse rejects.
    throw FixDataFormatException(file, null, 'has an invalid URI: ${error.message}');
  }
}

FixDataTransform _transform(YamlNode node, String file, Uri base) {
  FixDataFormatException error(YamlNode at, String problem) =>
      FixDataFormatException(file, _lineOf(at), problem);
  if (node is! YamlMap) throw error(node, 'Each transform must be a map.');
  final title = node.nodes['title'];
  if (title is! YamlScalar || title.value is! String) {
    throw error(node, 'A transform needs a "title" string.');
  }
  final changes = _changes(node);
  final library = node.nodes['library'];
  if (library != null) {
    if (library is! YamlScalar || library.value is! String) {
      throw error(library, '"library" must be a URI string.');
    }
    Uri? newLibrary;
    for (final change in changes) {
      if (change['kind'] == 'replacedBy' && change['newLibrary'] is String) {
        newLibrary = _resolve(change['newLibrary'] as String, base);
      }
    }
    return FixDataTransform(
      title: title.value as String,
      library: _resolve(library.value as String, base),
      newLibrary: newLibrary,
    );
  }
  final element = node.nodes['element'];
  if (element is! YamlMap) {
    throw error(node, 'A transform needs an "element" map or a "library".');
  }
  final uris = element.nodes['uris'];
  if (uris is! YamlList ||
      uris.nodes.isEmpty ||
      uris.nodes.any((uri) => uri is! YamlScalar || uri.value is! String)) {
    throw error(element, '"uris" must be a list of URI strings.');
  }
  final kinds = [
    for (final key in element.keys)
      if (key is String && fixDataElementKinds.contains(key)) key,
  ];
  if (kinds.length != 1) {
    throw error(
      element,
      'The element must name exactly one of: '
      '${(fixDataElementKinds.toList()..sort()).join(', ')}.',
    );
  }
  final kind = kinds.single;
  final name = element[kind];
  if (name is! String) throw error(element, '"$kind" must be a string.');
  final containers = [
    for (final key in _containerKeys)
      if (element[key] case final String value) value,
  ];
  if (containers.length > 1) {
    throw error(
      element,
      'The element may have only one of ${_containerKeys.join(', ')}.',
    );
  }
  return FixDataTransform(
    title: title.value as String,
    uris: {
      for (final uri in uris.nodes)
        _resolve((uri as YamlScalar).value as String, base),
    }.toList(),
    kind: kind,
    name: name,
    container: containers.firstOrNull,
    oldParameters: {
      for (final change in changes)
        if (change['kind'] == 'removeParameter' && change['name'] is String)
          change['name'] as String
        else if (change['kind'] == 'renameParameter' &&
            change['oldName'] is String)
          change['oldName'] as String,
    },
  );
}

/// The transform's changes, with those of each `oneOf` option.
List<YamlMap> _changes(YamlMap transform) => [
  ...?_maps(transform.nodes['changes']),
  if (transform.nodes['oneOf'] case final YamlList options)
    for (final option in options.nodes)
      if (option is YamlMap) ...?_maps(option.nodes['changes']),
];

List<YamlMap>? _maps(YamlNode? node) =>
    node is YamlList ? node.nodes.whereType<YamlMap>().toList() : null;

Uri _resolve(String uri, Uri base) =>
    uri.contains(':') ? Uri.parse(uri) : base.resolve(uri);

int _lineOf(YamlNode node) => node.span.start.line + 1;
```

In `packages/appstein_engine/lib/appstein_engine.dart`, add `export 'src/delta/fix_data.dart';` after `export 'src/config/config_loader.dart';` (keep the exports sorted).

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/delta/fix_data_test.dart`
Expected: PASS. If a test's expected line is off by one because of how `package:yaml` places a map's span, fix the test's number only after printing the span and confirming the line the error names is the transform or element the message is about. Record that in the report.

- [ ] **Step 5: Analyze, format, commit (controller)**

Run `fvm dart analyze --fatal-infos` and `fvm dart format --output=none --set-exit-if-changed .` from the repo root (no issues), then:

```bash
git add packages/appstein_engine/lib/src/delta/fix_data.dart packages/appstein_engine/lib/appstein_engine.dart packages/appstein_engine/test/delta/fix_data_test.dart
git commit -m "feat: read dart fix migrations (fix_data) for the version delta (spec §6.4)"
```

---

### Task 3: Collect the delta's facts from the analyzed project

**Files:**
- Create: `packages/appstein_engine/lib/src/delta/delta_facts.dart`
- Create: `packages/appstein_engine/lib/src/delta/delta_collector.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart`
- Create: the `delta_kit` stand-in package, in `packages/appstein_engine/test/fixtures/apps/stubs/delta_kit/lib/`:
  - `delta_kit.dart.fixture`, `extra.dart.fixture`;
  - `src/boxes.dart.fixture`, `src/panels.dart.fixture`;
  - `fix_data/fix_boxes.yaml.fixture`, `fix_data/fix_broken.yaml.fixture`, `fix_data/fix_empty.yaml.fixture`.
- Create: `packages/appstein_engine/test/fixtures/apps/stubs/go_router/lib/fix_data.yaml.fixture`
- Modify: `packages/appstein_engine/test/support/fixture_app.dart` (+ `analyzeDeltaApp`)
- Test: `packages/appstein_engine/test/delta/delta_collector_test.dart`

**Interfaces:**
- Consumes: `ProjectAnalysis` (its `libraries`, `relativePath`); `parseFixData`, `FixDataTransform`, `FixDataFormatException` (Task 2); `fileErrorReason`.
- Produces:
  - **`delta_facts.dart`:**
    - `enum DeprecationKind { use, implement, extend, subclass, instantiate, mixin, optional }` with `String? get rule`;
    - `final class DeprecatedApi` with `group`, `name`, `kind`, `message` (`String?`) and `migrations` (`List<String>`);
    - `enum MigrationStatus { removed, changed }`;
    - `final class MigratedApi` with `group`, `name`, `status` and `title`;
    - `final class MovedLibrary` with `from`, `to` (`String?`) and `title`;
    - `final class UnreadMigrations` with `file` and `reason`;
    - `final class DeltaFacts` with `deprecated`, `migrated`, `moved` and `unread`.

    All of them have value equality and a `toString`.
  - **`delta_collector.dart`:** `DeltaFacts collectDelta(ProjectAnalysis analysis, {required String dartSdkPath})`.
  - **Test helper:** `Future<ProjectAnalysis> analyzeDeltaApp(String mainDart)` in `fixture_app.dart`.

- [ ] **Step 1: Add the `delta_kit` stand-in package and go_router's real migration**

`delta_kit` is a package made for these tests, not a stand-in for a real one. It has one of each kind of deprecation, and migrations in Flutter's format. The map's goldens don't change: the map covers only the app's own files.

`stubs/delta_kit/lib/delta_kit.dart.fixture`:

```dart
// A package made for the version-delta tests, not a stand-in for a real
// one: one of each kind of deprecation, and migrations in lib/fix_data/.
export 'src/boxes.dart';
export 'src/panels.dart' show Panel;
```

`stubs/delta_kit/lib/src/boxes.dart.fixture`:

```dart
@Deprecated(
  'Use NewBox instead.\n'
  '    This feature was deprecated after v1.2.0-3.0.pre.',
)
class OldBox {}

class NewBox {
  NewBox({
    @Deprecated('Use size instead.') int? width,
    int? size,
    @Deprecated.optional('Pass a label; it becomes required in 2.0.')
    String? label,
  });

  @Deprecated('Use paint instead.')
  void draw() {}

  void paint() {}

  @Deprecated('Use area instead.')
  int get surface => 0;

  int get area => 0;

  @deprecated
  set colour(int value) {}
}

@Deprecated.implement('Extend Shape instead.')
abstract class Shape {}

@Deprecated.extend()
class Sealing {}

enum Mode {
  a,
  @Deprecated('Use a.')
  b,
}

@Deprecated('Use `paint()` instead of drawing *by hand*.')
void drawAll() {}
```

`stubs/delta_kit/lib/src/panels.dart.fixture`:

```dart
class _PanelBase {
  @Deprecated('Use open instead.')
  void show() {}

  void open() {}
}

class Panel extends _PanelBase {}

@Deprecated('Not exported, so not in the delta.')
class Hidden {}
```

`stubs/delta_kit/lib/extra.dart.fixture`:

```dart
@Deprecated('Not imported, so not in the delta.')
class Extra {}
```

`stubs/delta_kit/lib/fix_data/fix_boxes.yaml.fixture`:

```yaml
# Migrations for the version-delta tests, in Flutter's format.
version: 1
transforms:
  - title: "Rename to 'NewBox'"
    date: 2026-01-01
    element:
      uris: [ 'delta_kit.dart' ]
      class: 'GoneBox'
    changes:
      - kind: 'rename'
        newName: 'NewBox'

  - title: "Rename to 'paint'"
    date: 2026-01-01
    element:
      uris: [ 'delta_kit.dart' ]
      method: 'render'
      inClass: 'NewBox'
    changes:
      - kind: 'rename'
        newName: 'paint'

  - title: "Migrate to 'NewBox'"
    date: 2026-01-01
    element:
      uris: [ 'delta_kit.dart' ]
      class: 'OldBox'
    changes:
      - kind: 'rename'
        newName: 'NewBox'

  - title: "Migrate 'width' to 'size'"
    date: 2026-01-01
    element:
      uris: [ 'delta_kit.dart' ]
      constructor: ''
      inClass: 'NewBox'
    changes:
      - kind: 'renameParameter'
        oldName: 'width'
        newName: 'size'

  - title: "Migrate from 'height'"
    date: 2026-01-01
    element:
      uris: [ 'package:delta_kit/delta_kit.dart' ]
      constructor: ''
      inClass: 'NewBox'
    oneOf:
      - if: "height != ''"
        changes:
          - kind: 'removeParameter'
            name: 'height'

  - title: "Rename to 'Extra2'"
    date: 2026-01-01
    element:
      uris: [ 'extra.dart' ]
      class: 'Extra'
    changes:
      - kind: 'rename'
        newName: 'Extra2'

  - title: 'Migrate from delta_kit to delta_kit_v2.'
    date: 2026-01-01
    library: 'package:delta_kit/delta_kit.dart'
    changes:
      - kind: 'replacedBy'
        newLibrary: 'package:delta_kit_v2/delta_kit_v2.dart'
```

`stubs/delta_kit/lib/fix_data/fix_broken.yaml.fixture` (exactly these two lines):

```yaml
transforms:
  - title: 'No element'
```

`stubs/delta_kit/lib/fix_data/fix_empty.yaml.fixture` (exactly this line):

```yaml
# No migrations yet, like Flutter's fix_template.yaml.
```

`stubs/go_router/lib/fix_data.yaml.fixture` is the `location` migration copied from go_router 18.0.2's `lib/fix_data.yaml` (BSD licence, comment kept):

```yaml
# Copied from go_router 18.0.2's lib/fix_data.yaml: its migration for the
# removed GoRouterState.location (the stand-in has no `location` either).
version: 1
transforms:
  - title: "Replaces 'location' in 'GoRouterState' with `uri.toString()`"
    date: 2023-07-06
    bulkApply: true
    element:
      # TODO(ahmednfwela): Workaround for https://github.com/dart-lang/sdk/issues/52233
      uris: [ 'go_router.dart', 'package:go_router/go_router.dart' ]
      field: 'location'
      inClass: 'GoRouterState'
    changes:
      - kind: 'rename'
        newName: 'uri.toString()'
```

- [ ] **Step 2: Add the test helper**

In `packages/appstein_engine/test/support/fixture_app.dart`, add after `writeStubPackages`:

```dart
/// Analyzes a new app in a temp folder whose `lib/main.dart` is [mainDart],
/// with the `delta_kit` stand-in as its one package (see
/// `fixtures/apps/stubs/delta_kit/`). The analysis is disposed when the
/// test ends.
Future<ProjectAnalysis> analyzeDeltaApp(String mainDart) async {
  final work = tempDir().path;
  copyFixtureTree(p.join(fixtureAppsDir, 'stubs'), p.join(work, 'stubs'));
  final app = p.join(work, 'delta app');
  File(p.join(app, 'pubspec.yaml'))
    ..createSync(recursive: true)
    ..writeAsStringSync('name: delta_app\nenvironment:\n  sdk: ^3.12.0\n');
  File(p.join(app, 'lib', 'main.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync(mainDart);
  writeStubPackages(app, packages: const ['delta_kit']);
  final analysis = await ProjectAnalysis.analyze(
    app,
    dartSdkPath: testDartSdk,
  );
  addTearDown(analysis.dispose);
  return analysis;
}
```

- [ ] **Step 3: Write the failing tests**

Create `packages/appstein_engine/test/delta/delta_collector_test.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../support/fixture_app.dart';

void main() {
  const mainDart = '''
import 'package:delta_kit/delta_kit.dart';

/// The app's own deprecated API, which the delta leaves out.
@Deprecated('Use newHelper instead.')
void oldHelper() {}

Object box() => NewBox(size: 1);
''';

  Future<DeltaFacts> collect(String main) async =>
      collectDelta(await analyzeDeltaApp(main), dartSdkPath: testDartSdk);

  List<String> kit(Iterable<Object> facts) => [
    for (final fact in facts)
      if ('$fact'.startsWith('package:delta_kit ')) '$fact',
  ];

  test("lists every kind of deprecation the imports expose, with the "
      "library's own message on one line", () async {
    final facts = await collect(mainDart);
    expect(kit(facts.deprecated), [
      'package:delta_kit Mode.b [use] Use a.',
      'package:delta_kit NewBox.colour= [use] (no message)',
      'package:delta_kit NewBox.draw [use] Use paint instead.',
      'package:delta_kit NewBox.new(label) [optional] Pass a label; it '
          'becomes required in 2.0.',
      "package:delta_kit NewBox.new(width) [use] Use size instead. "
          "| Migrate 'width' to 'size'",
      'package:delta_kit NewBox.surface [use] Use area instead.',
      "package:delta_kit OldBox [use] Use NewBox instead. This feature was "
          "deprecated after v1.2.0-3.0.pre. | Migrate to 'NewBox'",
      'package:delta_kit Panel.show [use] Use open instead.',
      'package:delta_kit Sealing [extend] (no message)',
      'package:delta_kit Shape [implement] Extend Shape instead.',
      'package:delta_kit drawAll [use] Use `paint()` instead of drawing '
          '*by hand*.',
    ]);
  });

  test("leaves out the app's own code and what no import exposes", () async {
    final text = (await collect(mainDart)).toString();
    expect(text, isNot(contains('oldHelper')));
    expect(text, isNot(contains('Hidden')));
    expect(text, isNot(contains('Extra')));
    expect(text, isNot(contains('_PanelBase')));
  });

  test('classifies the migrations in scope: removed, changed, or attached '
      'to a deprecation', () async {
    final facts = await collect(mainDart);
    expect(kit(facts.migrated), [
      "package:delta_kit GoneBox removed Rename to 'NewBox'",
      "package:delta_kit NewBox.new changed Migrate from 'height'",
      "package:delta_kit NewBox.render removed Rename to 'paint'",
    ]);
  });

  test('a library migration is a moved library when the app imports '
      'it', () async {
    final facts = await collect(mainDart);
    expect(facts.moved.map((m) => '$m'), [
      'package:delta_kit/delta_kit.dart -> '
          'package:delta_kit_v2/delta_kit_v2.dart: '
          'Migrate from delta_kit to delta_kit_v2.',
    ]);
  });

  test('a broken migration file is reported, an empty one is not, and '
      'the rest still counts', () async {
    final facts = await collect(mainDart);
    expect(facts.unread.map((u) => '$u'), [
      'package:delta_kit/fix_data/fix_broken.yaml: line 2: A transform '
          'needs an "element" map or a "library".',
    ]);
    expect(kit(facts.migrated), isNotEmpty);
  });

  test('an app that imports nothing from delta_kit gets nothing from '
      'it', () async {
    final facts = await collect("String hi() => 'hi';\n");
    expect(kit(facts.deprecated), isEmpty);
    expect(kit(facts.migrated), isEmpty);
    expect(facts.moved, isEmpty);
    expect(facts.unread, isEmpty);
  });

  test("importing dart:io brings the Dart SDK's own migrations", () async {
    final facts = await collect(
      "import 'dart:io';\n\nString home() => Platform.pathSeparator;\n",
    );
    expect(facts.migrated.where((m) => m.group == 'dart:io'), isNotEmpty);
  });

  test("go_router's single fix_data.yaml counts: location was "
      'removed', () async {
    final app = copyFixtureApp();
    final analysis = await ProjectAnalysis.analyze(
      app,
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    final facts = collectDelta(analysis, dartSdkPath: testDartSdk);
    expect(
      facts.migrated.map((m) => '$m'),
      contains(
        "package:go_router GoRouterState.location removed Replaces "
        "'location' in 'GoRouterState' with `uri.toString()`",
      ),
    );
  });

  test('two collections of the same project are equal', () async {
    final analysis = await analyzeDeltaApp(mainDart);
    final first = collectDelta(analysis, dartSdkPath: testDartSdk);
    final second = collectDelta(analysis, dartSdkPath: testDartSdk);
    expect('$second', '$first');
  });
}
```

- [ ] **Step 4: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/delta/delta_collector_test.dart`
Expected: FAIL to compile: `collectDelta` and `DeltaFacts` aren't defined.

- [ ] **Step 5: Write the facts**

Create `packages/appstein_engine/lib/src/delta/delta_facts.dart`:

```dart
/// What a deprecation forbids: Dart's `Deprecated` constructors
/// (`dart:core`).
enum DeprecationKind {
  /// `@Deprecated(...)` or `@deprecated`: any use.
  use,

  /// `@Deprecated.implement(...)`: implementing the class or mixin.
  implement,

  /// `@Deprecated.extend(...)`: extending the class.
  extend,

  /// `@Deprecated.subclass(...)`: extending or implementing it.
  subclass,

  /// `@Deprecated.instantiate(...)`: creating instances of the class.
  instantiate,

  /// `@Deprecated.mixin(...)`: mixing the class in.
  mixin,

  /// `@Deprecated.optional(...)`: leaving out the argument.
  optional;

  /// What not to do, as the delta says it; null for [use], whose message
  /// says it all.
  String? get rule => switch (this) {
    DeprecationKind.use => null,
    DeprecationKind.implement => "don't implement it.",
    DeprecationKind.extend => "don't extend it.",
    DeprecationKind.subclass => "don't extend or implement it.",
    DeprecationKind.instantiate => "don't create instances of it.",
    DeprecationKind.mixin => "don't mix it in.",
    DeprecationKind.optional =>
      'always pass this argument: it will become required.',
  };
}

/// A deprecated API the project can reach.
final class DeprecatedApi {
  /// Creates the entry.
  const DeprecatedApi({
    required this.group,
    required this.name,
    required this.kind,
    this.message,
    this.migrations = const [],
  });

  /// The library or package that declares it: `dart:core`,
  /// `package:flutter`.
  final String group;

  /// Its name as code writes it: `WillPopScope`, `Color.withOpacity`,
  /// `NewBox.new(width)` for a parameter, `NewBox.colour=` for a setter.
  final String name;

  /// What the deprecation forbids.
  final DeprecationKind kind;

  /// The library's own message on one line, or null when it has none.
  final String? message;

  /// The titles of the `fix_data` migrations that migrate it, sorted.
  final List<String> migrations;

  @override
  bool operator ==(Object other) =>
      other is DeprecatedApi && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;

  @override
  String toString() =>
      '$group $name [${kind.name}] ${message ?? '(no message)'}'
      '${migrations.isEmpty ? '' : ' | ${migrations.join(' | ')}'}';
}

/// Whether an API in a migration is gone, or is still there in a new form.
enum MigrationStatus {
  /// The element is gone.
  removed,

  /// The element is there, but an old parameter or form is gone.
  changed,
}

/// An API a `fix_data` migration says is removed or changed.
final class MigratedApi {
  /// Creates the entry.
  const MigratedApi({
    required this.group,
    required this.name,
    required this.status,
    required this.title,
  });

  /// The library or package, as in [DeprecatedApi.group].
  final String group;

  /// Its name as code writes it, as in [DeprecatedApi.name].
  final String name;

  /// Removed or changed.
  final MigrationStatus status;

  /// The migration's title.
  final String title;

  @override
  bool operator ==(Object other) =>
      other is MigratedApi && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;

  @override
  String toString() => '$group $name ${status.name} $title';
}

/// A library that a `fix_data` migration moves elsewhere.
final class MovedLibrary {
  /// Creates the entry.
  const MovedLibrary({required this.from, required this.to, required this.title});

  /// The library's URI, such as `package:flutter/material.dart`.
  final String from;

  /// Where it moves, or null when the migration doesn't say.
  final String? to;

  /// The migration's title.
  final String title;

  @override
  bool operator ==(Object other) =>
      other is MovedLibrary && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;

  @override
  String toString() => '$from -> ${to ?? '?'}: $title';
}

/// A migration file that couldn't be read.
final class UnreadMigrations {
  /// Creates the entry.
  const UnreadMigrations({required this.file, required this.reason});

  /// The file, named without any machine path:
  /// `package:delta_kit/fix_data/fix_broken.yaml` or
  /// `dart-sdk/lib/_internal/fix_data.yaml`.
  final String file;

  /// Why it couldn't be read.
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is UnreadMigrations && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;

  @override
  String toString() => '$file: $reason';
}

/// What the version delta lists besides the curated notes (spec §6.4), each
/// list sorted by group, then name.
final class DeltaFacts {
  /// Creates the facts.
  const DeltaFacts({
    this.deprecated = const [],
    this.migrated = const [],
    this.moved = const [],
    this.unread = const [],
  });

  /// The deprecated APIs the project's imports expose.
  final List<DeprecatedApi> deprecated;

  /// The removed and changed APIs from the migrations in scope.
  final List<MigratedApi> migrated;

  /// The libraries the migrations in scope move.
  final List<MovedLibrary> moved;

  /// The migration files that couldn't be read.
  final List<UnreadMigrations> unread;

  @override
  String toString() => [
    ...deprecated,
    ...migrated,
    ...moved,
    ...unread,
  ].join('\n');
}
```

- [ ] **Step 6: Write the collector**

Create `packages/appstein_engine/lib/src/delta/delta_collector.dart`:

```dart
import 'dart:io';

import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../map/project_analysis.dart';
import 'delta_facts.dart';
import 'fix_data.dart';

/// Collects what the version delta lists about the project in [analysis]
/// (spec §6.4), besides the curated notes.
///
/// - **Deprecated:**
///   - every declaration, member and parameter with a `Deprecated`
///     annotation, of any kind, that the libraries the project imports
///     export, except the project's own;
///   - a member inherited from a private superclass is listed under the
///     public class that exposes it.
/// - **Removed, changed and moved:**
///   - the migrations in the `fix_data` files (`fix_data.yaml` or
///     `fix_data/**.yaml` in `lib/`) of each package the project imports,
///     and in the Dart SDK's `lib/_internal/fix_data.yaml` under
///     [dartSdkPath];
///   - a migration counts when the project imports one of its libraries
///     directly, which is the rule `dart fix` uses;
///   - a migration of an element or parameter that is still there and
///     deprecated is attached to that deprecation.
/// - **Unread:** the migration files that couldn't be read, and why.
///
/// It never throws for a package's bad `fix_data` file.
DeltaFacts collectDelta(
  ProjectAnalysis analysis, {
  required String dartSdkPath,
}) => _Collector(analysis, dartSdkPath).run();

typedef _MigrationFile = ({String name, String path, Uri base});

final class _Found {
  _Found(this.group, this.display, this.kind, this.message);

  final String group;
  String display;
  final DeprecationKind kind;
  final String? message;
  final migrations = <String>{};
}

final class _Collector {
  _Collector(this.analysis, this.dartSdkPath);

  final ProjectAnalysis analysis;
  final String dartSdkPath;

  /// Every library the project imports, except its own, by URI.
  final _imported = <Uri, LibraryElement>{};

  /// Each deprecation found, by its element and kind.
  final _found = <(Element, DeprecationKind), _Found>{};

  final _visited = <Element>{};
  final _visitedTypes = <(InstanceElement, String)>{};

  DeltaFacts run() {
    for (final library in analysis.libraries) {
      final element = library.result.element;
      // dart:core is imported by every library, even when no directive says
      // so.
      final LibraryElement? core =
          element.typeProvider.objectType.element.library;
      if (core != null) _import(core);
      for (
        LibraryFragment? fragment = element.firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      ) {
        for (final import in fragment.libraryImports) {
          if (import.importedLibrary case final imported?) _import(imported);
        }
      }
    }
    final uris = _imported.keys.toList()
      ..sort((a, b) => '$a'.compareTo('$b'));
    for (final uri in uris) {
      for (final element
          in _imported[uri]!.exportNamespace.definedNames2.values) {
        _visit(element);
      }
    }

    final migrated = <(String, String, MigrationStatus, String)>{};
    final moved = <(String, String?, String)>{};
    final unread = <UnreadMigrations>[];
    for (final file in _migrationFiles(unread)) {
      for (final transform in _read(file, unread)) {
        _classify(transform, migrated, moved);
      }
    }

    final deprecated = <String, DeprecatedApi>{};
    for (final found in _found.values) {
      final key =
          '${found.group}\n${found.display}\n${found.kind.index}\n'
          '${found.message}';
      final migrations = {
        ...?deprecated[key]?.migrations,
        ...found.migrations,
      }.toList()..sort();
      deprecated[key] = DeprecatedApi(
        group: found.group,
        name: found.display,
        kind: found.kind,
        message: found.message,
        migrations: migrations,
      );
    }
    return DeltaFacts(
      deprecated: deprecated.values.toList()
        ..sort(
          (a, b) => _compare([
            a.group.compareTo(b.group),
            a.name.compareTo(b.name),
            a.kind.index.compareTo(b.kind.index),
            (a.message ?? '').compareTo(b.message ?? ''),
          ]),
        ),
      migrated: [
        for (final (group, name, status, title) in migrated)
          MigratedApi(group: group, name: name, status: status, title: title),
      ]..sort(
          (a, b) => _compare([
            a.group.compareTo(b.group),
            a.name.compareTo(b.name),
            a.status.index.compareTo(b.status.index),
            a.title.compareTo(b.title),
          ]),
        ),
      moved: [
        for (final (from, to, title) in moved)
          MovedLibrary(from: from, to: to, title: title),
      ]..sort((a, b) => '$a'.compareTo('$b')),
      unread: unread..sort((a, b) => '$a'.compareTo('$b')),
    );
  }

  void _import(LibraryElement library) {
    if (!_isProjects(library)) _imported[library.uri] = library;
  }

  bool _isProjects(LibraryElement library) =>
      analysis.relativePath(library.firstFragment.source.fullName) != null;

  /// Notes [element], a name a library exports, with its members and
  /// parameters.
  void _visit(Element element) {
    if (!_visited.add(element)) return;
    final name = element.name;
    if (name == null || name.startsWith('_')) return;
    _note(element, name);
    if (element is ExecutableElement) _noteParameters(element, name);
    if (element is InterfaceElement) {
      _noteMembers(element, name);
      _noteConstructors(element, name);
      for (final supertype in element.allSupertypes) {
        final declaring = supertype.element;
        final declaringName = declaring.name;
        if (declaringName == null) continue;
        _noteMembers(
          declaring,
          declaringName.startsWith('_') ? name : declaringName,
        );
      }
    } else if (element is InstanceElement) {
      _noteMembers(element, name);
    }
  }

  void _noteMembers(InstanceElement type, String owner) {
    if (!_visitedTypes.add((type, owner))) return;
    for (final member in <Element>[
      ...type.fields,
      ...type.getters,
      ...type.methods,
    ]) {
      final name = member.name;
      if (name == null || name.startsWith('_')) continue;
      _note(member, '$owner.$name');
      if (member is ExecutableElement) {
        _noteParameters(member, '$owner.$name');
      }
    }
    for (final setter in type.setters) {
      final name = setter.name;
      if (name == null || name.startsWith('_')) continue;
      final plain = name.endsWith('=')
          ? name.substring(0, name.length - 1)
          : name;
      _note(setter, '$owner.$plain=');
    }
  }

  void _noteConstructors(InterfaceElement type, String owner) {
    for (final constructor in type.constructors) {
      final name = constructor.name;
      if (name != null && name.startsWith('_')) continue;
      final display = _isUnnamed(name) ? '$owner.new' : '$owner.$name';
      _note(constructor, display);
      _noteParameters(constructor, display);
    }
  }

  void _noteParameters(ExecutableElement executable, String owner) {
    for (final parameter in executable.formalParameters) {
      final name = parameter.name;
      if (name == null || name.startsWith('_')) continue;
      _note(parameter, '$owner($name)');
    }
  }

  /// Records each deprecation annotation on [element] under [display],
  /// keeping the first name in sort order when the element is reached
  /// under several names.
  void _note(Element element, String display) {
    final LibraryElement? library = element.library;
    if (library == null || _isProjects(library)) return;
    for (final annotation in element.metadata.annotations) {
      if (!annotation.isDeprecated) continue;
      final kind = _kindOf(annotation);
      final found = _found[(element, kind)];
      if (found == null) {
        _found[(element, kind)] = _Found(
          _group(library.uri),
          display,
          kind,
          _messageOf(annotation),
        );
      } else if (display.compareTo(found.display) < 0) {
        found.display = display;
      }
    }
  }

  List<_MigrationFile> _migrationFiles(List<UnreadMigrations> unread) {
    final files = <_MigrationFile>[
      (
        name: 'dart-sdk/lib/_internal/fix_data.yaml',
        path: p.join(dartSdkPath, 'lib', '_internal', 'fix_data.yaml'),
        base: Uri.parse('dart:core'),
      ),
    ];
    final libFolders = <String, String>{};
    for (final MapEntry(key: uri, value: library) in _imported.entries) {
      if (uri.scheme != 'package' || uri.pathSegments.length < 2) continue;
      var folder = library.firstFragment.source.fullName;
      for (var i = 1; i < uri.pathSegments.length; i++) {
        folder = p.dirname(folder);
      }
      libFolders.putIfAbsent(uri.pathSegments.first, () => folder);
    }
    for (final package in libFolders.keys.toList()..sort()) {
      final lib = libFolders[package]!;
      final base = Uri.parse('package:$package/');
      files.add((
        name: 'package:$package/fix_data.yaml',
        path: p.join(lib, 'fix_data.yaml'),
        base: base,
      ));
      final folder = Directory(p.join(lib, 'fix_data'));
      try {
        if (!folder.existsSync()) continue;
        final paths = [
          for (final entity in folder.listSync(recursive: true))
            if (entity is File && entity.path.endsWith('.yaml')) entity.path,
        ]..sort();
        for (final path in paths) {
          final relative = p.split(p.relative(path, from: lib)).join('/');
          files.add((name: 'package:$package/$relative', path: path, base: base));
        }
      } on FileSystemException catch (error) {
        unread.add(
          UnreadMigrations(
            file: 'package:$package/fix_data/',
            reason: fileErrorReason(error),
          ),
        );
      }
    }
    return files;
  }

  List<FixDataTransform> _read(
    _MigrationFile file,
    List<UnreadMigrations> unread,
  ) {
    final source = File(file.path);
    try {
      if (!source.existsSync()) return const [];
      return parseFixData(
        source.readAsStringSync(),
        file: file.name,
        base: file.base,
      );
    } on FileSystemException catch (error) {
      unread.add(UnreadMigrations(file: file.name, reason: fileErrorReason(error)));
    } on FixDataFormatException catch (error) {
      unread.add(UnreadMigrations(file: file.name, reason: error.reason));
    } on FormatException catch (error) {
      unread.add(UnreadMigrations(file: file.name, reason: error.message));
    }
    return const [];
  }

  void _classify(
    FixDataTransform transform,
    Set<(String, String, MigrationStatus, String)> migrated,
    Set<(String, String?, String)> moved,
  ) {
    if (transform.library case final library?) {
      if (_imported.containsKey(library)) {
        moved.add(('$library', transform.newLibrary?.toString(), transform.title));
      }
      return;
    }
    final scope = [
      for (final uri in transform.uris)
        if (_imported[uri] case final library?) (uri, library),
    ];
    if (scope.isEmpty) return;
    final name = _migrationName(transform);
    final group = _group(scope.first.$1);
    Element? target;
    for (final (_, library) in scope) {
      target = _lookUp(library, transform);
      if (target != null) break;
    }
    if (target == null) {
      migrated.add((group, name, MigrationStatus.removed, transform.title));
      return;
    }
    final candidates = <(Element, String)>[
      (target, name),
      if (target is ExecutableElement)
        for (final parameter in target.formalParameters)
          if (parameter.name case final parameterName?
              when transform.oldParameters.contains(parameterName))
            (parameter, '$name($parameterName)'),
    ];
    var attached = false;
    for (final (element, display) in candidates) {
      if (!element.metadata.annotations.any((a) => a.isDeprecated)) continue;
      _note(element, display);
      for (final MapEntry(:key, :value) in _found.entries) {
        if (key.$1 == element) {
          value.migrations.add(transform.title);
          attached = true;
        }
      }
    }
    if (!attached) {
      migrated.add((group, name, MigrationStatus.changed, transform.title));
    }
  }

  /// The element [transform] names, looked up in what [library] exports,
  /// or null when it is gone.
  Element? _lookUp(LibraryElement library, FixDataTransform transform) {
    final names = library.exportNamespace.definedNames2;
    final name = transform.name!;
    final container = transform.container;
    if (container == null) return names[name] ?? names['$name='];
    final owner = names[container];
    if (owner is! InstanceElement) return null;
    if (transform.kind == 'constructor') {
      if (owner is! InterfaceElement) return null;
      return owner.constructors
          .where(
            (c) => name.isEmpty ? _isUnnamed(c.name) : c.name == name,
          )
          .firstOrNull;
    }
    final types = <InstanceElement>[
      owner,
      if (owner is InterfaceElement)
        for (final supertype in owner.allSupertypes) supertype.element,
    ];
    for (final type in types) {
      final members = switch (transform.kind) {
        'method' => <Element>[...type.methods],
        'setter' => <Element>[...type.setters],
        _ => <Element>[...type.fields, ...type.getters],
      };
      for (final member in members) {
        final memberName = member.name;
        if (memberName == null) continue;
        final plain = memberName.endsWith('=')
            ? memberName.substring(0, memberName.length - 1)
            : memberName;
        if (plain == name) return member;
      }
    }
    return null;
  }
}

String _migrationName(FixDataTransform transform) {
  final name = transform.name!;
  final container = transform.container;
  if (container == null) {
    return transform.kind == 'setter' ? '$name=' : name;
  }
  return switch (transform.kind) {
    'constructor' => name.isEmpty ? '$container.new' : '$container.$name',
    'setter' => '$container.$name=',
    _ => '$container.$name',
  };
}

DeprecationKind _kindOf(ElementAnnotation annotation) {
  final element = annotation.element;
  if (element is! ConstructorElement) return DeprecationKind.use;
  return switch (element.name) {
    'implement' => DeprecationKind.implement,
    'extend' => DeprecationKind.extend,
    'subclass' => DeprecationKind.subclass,
    'instantiate' => DeprecationKind.instantiate,
    'mixin' => DeprecationKind.mixin,
    'optional' => DeprecationKind.optional,
    _ => DeprecationKind.use,
  };
}

/// The annotation's message on one line, or null. The `deprecated` constant
/// (`@deprecated`) says only "next release", so it counts as no message.
String? _messageOf(ElementAnnotation annotation) {
  if (annotation.element is! ConstructorElement) return null;
  final message = annotation
      .computeConstantValue()
      ?.getField('message')
      ?.toStringValue();
  if (message == null) return null;
  final oneLine = message.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.isEmpty ? null : oneLine;
}

/// `dart:core` for `dart:core`, `package:flutter` for any library of the
/// flutter package.
String _group(Uri uri) => switch (uri.scheme) {
  'package' => 'package:${uri.pathSegments.first}',
  'dart' => 'dart:${uri.path.split('/').first}',
  _ => '$uri',
};

bool _isUnnamed(String? name) => name == null || name.isEmpty || name == 'new';

int _compare(List<int> results) =>
    results.firstWhere((result) => result != 0, orElse: () => 0);
```

In `packages/appstein_engine/lib/appstein_engine.dart`, add, keeping the exports sorted:

```dart
export 'src/delta/delta_collector.dart';
export 'src/delta/delta_facts.dart';
```

- [ ] **Step 7: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/delta/`
Expected: PASS.
- If `NewBox.colour=` comes out as `NewBox.colour==` or `NewBox.colour`, analyzer 14.4 names setters differently; fix the stripping in `_noteMembers`, not the test.
- If `Mode.b` is missing, check that enum constants are in `fields`.
- If a dart: library's internals leak in (a group such as `dart:_internal`), report it with the entry and leave it; the owner decides.

- [ ] **Step 8: Check the map goldens are untouched**

Run: `cd packages/appstein_engine && fvm dart test test/knowledge/knowledge_sync_test.dart test/map/ test/packs/`
Expected: PASS with no golden change. The new stub files are outside the app.

- [ ] **Step 9: Analyze, format, commit (controller)**

Run analyze and format from the repo root (no issues), then:

```bash
git add packages/appstein_engine/lib/src/delta packages/appstein_engine/lib/appstein_engine.dart packages/appstein_engine/test/delta packages/appstein_engine/test/support/fixture_app.dart packages/appstein_engine/test/fixtures/apps/stubs
git commit -m "feat: collect deprecated, removed and moved APIs the project can reach (spec §6.4)"
```

---

### Task 4: Render `delta.md`

**Files:**
- Create: `packages/appstein_engine/lib/src/delta/delta_document.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart`
- Modify: `packages/appstein_engine/test/support/fixture_app.dart` (+ `expectTextGolden`)
- Create: `packages/appstein_engine/test/fixtures/apps/goldens/delta.md.golden`
- Test: `packages/appstein_engine/test/delta/delta_document_test.dart`

**Interfaces:**
- Consumes:
  - `DeltaFacts` and the other fact types (Task 3);
  - `CuratedNote` and `NotesCoverage` (protocol);
  - `CuratedNotes.notesFor`, `flutterMinorOf` and `compareFlutterMinors` (engine notes).
- Produces:
  - `const deltaPath = 'platform/delta.md'`;
  - `final class DeltaInputs` with `flutterVersion`, `languageVersion` (`String?`), `baseline`, `coverage`, `newestNotes`, `notes`, `facts` (`DeltaFacts?`) and `skipped` (`String?`);
  - `List<CuratedNote> deltaNotes(CuratedNotes notes, {required String flutterVersion, required String baseline})`;
  - `String renderDelta(DeltaInputs inputs)`;
  - the test helper `void expectTextGolden(String name, String actual)`.

- [ ] **Step 1: Add the text golden helper**

In `packages/appstein_engine/test/support/fixture_app.dart`, add after `expectGolden`:

```dart
/// Checks [actual] text against `test/fixtures/apps/goldens/<name>.golden`,
/// with `APPSTEIN_UPDATE_GOLDENS=1` handled as in [expectGolden].
void expectTextGolden(String name, String actual) {
  final golden = File(p.join(fixtureAppsDir, 'goldens', '$name.golden'));
  if (Platform.environment['APPSTEIN_UPDATE_GOLDENS'] == '1') {
    golden
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(actual);
    return;
  }
  expect(
    golden.existsSync(),
    isTrue,
    reason:
        'No golden at ${golden.path}. Run the test with '
        'APPSTEIN_UPDATE_GOLDENS=1 to create it, then review it.',
  );
  expect(
    actual,
    goldenText(name),
    reason:
        'The text differs from ${golden.path}. If the change is intended, '
        'rerun with APPSTEIN_UPDATE_GOLDENS=1 and review the diff.',
  );
}
```

- [ ] **Step 2: Write the golden**

Create `packages/appstein_engine/test/fixtures/apps/goldens/delta.md.golden`, LF line ends, ending with one newline, exactly:

````markdown
# Version delta: Flutter 3.47.5, Dart language 3.12

What changed in Flutter, Dart and this project's packages that matters for the code you write. `appstein sync` generates this file from the installed SDK, the project's packages and Appstein's curated notes; don't edit it.

## Notes

Appstein's curated notes since Flutter 3.16, most important first (priority 1 to 3).

- **popscope-not-willpopscope** (priority 1, since 3.16): PopScope replaces WillPopScope.
  - Use: `PopScope` with `canPop` and `onPopInvokedWithResult`.
  - Avoid: `WillPopScope`.
  - Source: https://docs.flutter.dev/release/breaking-changes/android-predictive-back
- **dot-shorthands** (priority 2, since 3.38, language 3.10): Dot shorthands omit the type name.
  - Use: `mainAxisAlignment: .center`.
  - Avoid: Shorthands below language version 3.10.
  - Source: https://dart.dev/language/dot-shorthands

## Needs a newer language version

The project's language version is 3.12, the lower bound of `environment: sdk:` in `pubspec.yaml`. These notes need a newer one: raise that bound to use them.

- **dart-primary-constructors** (priority 2, since 3.47, language 3.13): Primary constructors declare fields in the class header.
  - Use: `class Point(final int x, final int y);`.
  - Avoid: Primary constructors below language version 3.13.
  - Source: https://dart.dev/language/constructors

## Deprecated

APIs the project's imports expose that are deprecated, with each library's own message. `dart analyze` reports each use.

### dart:core

- `RegExp`: don't implement it. This class will become 'final' in a future release. 'Pattern' may be a more appropriate interface to implement.

### package:flutter

- `Text.new(textScaleFactor)`: deprecated, with no message.
- `WillPopScope`: Use PopScope instead. This feature was deprecated after v3.12.0-1.0.pre. `dart fix` migrates it: Migrate to 'PopScope'.

### package:go_router

- `GoRouter.new(label)`: always pass this argument: it will become required.

## Removed

APIs that are gone or changed, from the migration lists (`fix_data`) of the SDKs and the packages. Code that uses them doesn't compile; `dart fix` applies each migration.

### package:flutter

- `Stack.new`: changed. Migrate to 'clipBehavior'.
- `Stack.overflow`: removed. Migrate to 'clipBehavior'.

### package:go_router

- `GoRouterState.location`: removed. Replaces 'location' in 'GoRouterState' with `uri.toString()`.

## Moved libraries

Libraries a migration (`fix_data`) moves elsewhere. Check the notes above before switching.

- `package:flutter/material.dart` → `package:material_ui/material_ui.dart`: Migrate from flutter/material.dart to material_ui/material_ui.dart.

## Not read

Migration files Appstein couldn't read, so their migrations are missing above.

- `package:delta_kit/fix_data/fix_broken.yaml`: line 2: A transform needs an "element" map or a "library".
````

(The outer fence above is only for this plan; the golden starts with `# Version delta` and ends after the last list item's newline.)

- [ ] **Step 3: Write the failing tests**

Create `packages/appstein_engine/test/delta/delta_document_test.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../support/fixture_app.dart';

void main() {
  const popScope = CuratedNote(
    id: 'popscope-not-willpopscope',
    since: '3.16',
    priority: 1,
    area: NoteArea.framework,
    summary: 'PopScope replaces WillPopScope.',
    use: '`PopScope` with `canPop` and `onPopInvokedWithResult`.',
    avoid: '`WillPopScope`.',
    source:
        'https://docs.flutter.dev/release/breaking-changes/android-predictive-back',
  );
  const dotShorthands = CuratedNote(
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
  const primaryConstructors = CuratedNote(
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
  const facts = DeltaFacts(
    deprecated: [
      DeprecatedApi(
        group: 'dart:core',
        name: 'RegExp',
        kind: DeprecationKind.implement,
        message:
            "This class will become 'final' in a future release. 'Pattern' "
            'may be a more appropriate interface to implement.',
      ),
      DeprecatedApi(
        group: 'package:flutter',
        name: 'Text.new(textScaleFactor)',
        kind: DeprecationKind.use,
      ),
      DeprecatedApi(
        group: 'package:flutter',
        name: 'WillPopScope',
        kind: DeprecationKind.use,
        message:
            'Use PopScope instead. This feature was deprecated after '
            'v3.12.0-1.0.pre.',
        migrations: ["Migrate to 'PopScope'"],
      ),
      DeprecatedApi(
        group: 'package:go_router',
        name: 'GoRouter.new(label)',
        kind: DeprecationKind.optional,
      ),
    ],
    migrated: [
      MigratedApi(
        group: 'package:flutter',
        name: 'Stack.new',
        status: MigrationStatus.changed,
        title: "Migrate to 'clipBehavior'",
      ),
      MigratedApi(
        group: 'package:flutter',
        name: 'Stack.overflow',
        status: MigrationStatus.removed,
        title: "Migrate to 'clipBehavior'",
      ),
      MigratedApi(
        group: 'package:go_router',
        name: 'GoRouterState.location',
        status: MigrationStatus.removed,
        title: "Replaces 'location' in 'GoRouterState' with `uri.toString()`",
      ),
    ],
    moved: [
      MovedLibrary(
        from: 'package:flutter/material.dart',
        to: 'package:material_ui/material_ui.dart',
        title:
            'Migrate from flutter/material.dart to material_ui/material_ui.dart.',
      ),
    ],
    unread: [
      UnreadMigrations(
        file: 'package:delta_kit/fix_data/fix_broken.yaml',
        reason: 'line 2: A transform needs an "element" map or a "library".',
      ),
    ],
  );

  DeltaInputs inputs({
    String flutterVersion = '3.47.5',
    String? languageVersion = '3.12',
    NotesCoverage coverage = NotesCoverage.complete,
    List<CuratedNote> notes = const [
      popScope,
      dotShorthands,
      primaryConstructors,
    ],
    DeltaFacts? facts = facts,
    String? skipped,
  }) => DeltaInputs(
    flutterVersion: flutterVersion,
    languageVersion: languageVersion,
    baseline: '3.16',
    coverage: coverage,
    newestNotes: '3.47',
    notes: notes,
    facts: facts,
    skipped: skipped,
  );

  test('renders every section, matching the golden', () {
    expectTextGolden('delta.md', renderDelta(inputs()));
  });

  test('with no facts it says why, and lists only the notes', () {
    final text = renderDelta(
      inputs(facts: null, skipped: 'the packages could not be fetched'),
    );
    expect(
      text,
      contains(
        'Deprecated and removed APIs are missing because the project map was '
        'skipped: the packages could not be fetched. Fix that, then run '
        '`appstein sync` again.',
      ),
    );
    expect(text, contains('## Notes'));
    for (final missing in [
      '## Deprecated',
      '## Removed',
      '## Moved libraries',
      '## Not read',
    ]) {
      expect(text, isNot(contains(missing)));
    }
  });

  test('a skip reason ending in a full stop is not doubled', () {
    final text = renderDelta(
      inputs(facts: null, skipped: 'pubspec.lock is not valid YAML.'),
    );
    expect(text, contains('skipped: pubspec.lock is not valid YAML. Fix'));
  });

  test('empty facts say None, and leave out the optional sections', () {
    final text = renderDelta(inputs(facts: const DeltaFacts()));
    expect(text, contains('## Deprecated\n\nAPIs'));
    expect(text, contains('`dart analyze` reports each use.\n\nNone.\n'));
    expect(text, contains('`dart fix` applies each migration.\n\nNone.\n'));
    expect(text, isNot(contains('## Moved libraries')));
    expect(text, isNot(contains('## Not read')));
  });

  test('no notes says None', () {
    expect(
      renderDelta(inputs(notes: const [])),
      contains('most important first (priority 1 to 3).\n\nNone.\n'),
    );
  });

  test('partial coverage adds the notes-may-be-incomplete line', () {
    expect(
      renderDelta(
        inputs(flutterVersion: '3.50.1', coverage: NotesCoverage.partial),
      ),
      contains(
        'Curated notes may be incomplete for Flutter 3.50: the newest notes '
        'are for 3.47.',
      ),
    );
  });

  test('an unknown language version keeps every note in Notes, each marked '
      'with its language', () {
    final text = renderDelta(inputs(languageVersion: null));
    expect(text, startsWith('# Version delta: Flutter 3.47.5, Dart language unknown\n'));
    expect(text, isNot(contains('## Needs a newer language version')));
    expect(text, contains('(priority 2, since 3.47, language 3.13)'));
  });

  group('deltaNotes', () {
    final notes = CuratedNotes.bundled();

    test('the default baseline keeps the 3.16 notes', () {
      expect(
        deltaNotes(notes, flutterVersion: '3.47.5', baseline: '3.16')
            .map((n) => n.id),
        contains('popscope-not-willpopscope'),
      );
    });

    test('a later baseline drops the older notes', () {
      final ids = deltaNotes(
        notes,
        flutterVersion: '3.47.5',
        baseline: '3.24',
      ).map((n) => n.id);
      expect(ids, isNot(contains('popscope-not-willpopscope')));
      expect(ids, contains('material-ui-packages'));
    });

    test('notes newer than the SDK are left out', () {
      expect(
        deltaNotes(notes, flutterVersion: '3.44.9', baseline: '3.16')
            .map((n) => n.id),
        isNot(contains('material-ui-packages')),
      );
    });

    test('an unknown Flutter version gets no notes', () {
      expect(
        deltaNotes(notes, flutterVersion: '0.0.0-unknown', baseline: '3.16'),
        isEmpty,
      );
    });
  });
}
```

- [ ] **Step 4: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/delta/delta_document_test.dart`
Expected: FAIL to compile: `renderDelta`, `DeltaInputs` and `deltaNotes` aren't defined.

- [ ] **Step 5: Write the renderer**

Create `packages/appstein_engine/lib/src/delta/delta_document.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import '../notes/curated_notes.dart';
import '../notes/flutter_minor.dart';
import 'delta_facts.dart';

/// Where the version delta lives inside `.appstein/` (spec §6.2).
const deltaPath = 'platform/delta.md';

/// What the version delta is built from.
final class DeltaInputs {
  /// Creates the inputs.
  const DeltaInputs({
    required this.flutterVersion,
    required this.languageVersion,
    required this.baseline,
    required this.coverage,
    required this.newestNotes,
    required this.notes,
    this.facts,
    this.skipped,
  });

  /// The installed Flutter version, such as `3.47.5`.
  final String flutterVersion;

  /// The project's Dart language version, such as `3.12`, or null when
  /// unknown.
  final String? languageVersion;

  /// How far back the notes reach (`delta.baseline`, spec §7).
  final String baseline;

  /// How well the curated notes cover this Flutter.
  final NotesCoverage coverage;

  /// The newest Flutter minor version the notes cover.
  final String newestNotes;

  /// The notes to list ([deltaNotes]), most important first.
  final List<CuratedNote> notes;

  /// The deprecated, removed and moved APIs; null when the project map was
  /// skipped.
  final DeltaFacts? facts;

  /// Why [facts] is null: the project map's skip reason.
  final String? skipped;
}

/// The curated notes the delta lists: those for [flutterVersion] whose
/// `since` is at or after [baseline], most important first. None when
/// [flutterVersion] isn't a version number.
List<CuratedNote> deltaNotes(
  CuratedNotes notes, {
  required String flutterVersion,
  required String baseline,
}) {
  final floor = flutterMinorOf(baseline);
  return [
    for (final note in notes.notesFor(flutterVersion))
      if (floor == null ||
          compareFlutterMinors(flutterMinorOf(note.since)!, floor) >= 0)
        note,
  ];
}

/// The text of `delta.md` without its front matter (spec §6.4): the notes,
/// the notes that need a newer language version, then (when the map ran)
/// the deprecated, removed and moved APIs, and the migration files that
/// couldn't be read. Every line quotes a note, a library's message or a
/// migration's title.
String renderDelta(DeltaInputs inputs) {
  final out = StringBuffer();
  void paragraph(String text) => out
    ..writeln()
    ..writeln(text);

  out.writeln(
    '# Version delta: Flutter ${inputs.flutterVersion}, Dart language '
    '${inputs.languageVersion ?? 'unknown'}',
  );
  paragraph(
    "What changed in Flutter, Dart and this project's packages that matters "
    'for the code you write. `appstein sync` generates this file from the '
    "installed SDK, the project's packages and Appstein's curated notes; "
    "don't edit it.",
  );
  if (inputs.coverage == NotesCoverage.partial) {
    paragraph(
      'Curated notes may be incomplete for Flutter '
      '${_minorText(inputs.flutterVersion)}: the newest notes are for '
      '${inputs.newestNotes}.',
    );
  }
  final facts = inputs.facts;
  if (facts == null) {
    paragraph(
      'Deprecated and removed APIs are missing because the project map was '
      'skipped: ${_withFullStop(inputs.skipped ?? 'no reason was given')} '
      'Fix that, then run `appstein sync` again.',
    );
  }

  final usable = <CuratedNote>[];
  final later = <CuratedNote>[];
  for (final note in inputs.notes) {
    (_needsNewerLanguage(note, inputs.languageVersion) ? later : usable).add(
      note,
    );
  }
  paragraph('## Notes');
  paragraph(
    "Appstein's curated notes since Flutter ${inputs.baseline}, most "
    'important first (priority 1 to 3).',
  );
  _notes(out, usable);
  if (later.isNotEmpty) {
    paragraph('## Needs a newer language version');
    paragraph(
      "The project's language version is ${inputs.languageVersion}, the "
      'lower bound of `environment: sdk:` in `pubspec.yaml`. These notes '
      'need a newer one: raise that bound to use them.',
    );
    _notes(out, later);
  }
  if (facts == null) return out.toString();

  paragraph('## Deprecated');
  paragraph(
    "APIs the project's imports expose that are deprecated, with each "
    "library's own message. `dart analyze` reports each use.",
  );
  _grouped(out, [
    for (final api in facts.deprecated) (api.group, _deprecatedLine(api)),
  ]);
  paragraph('## Removed');
  paragraph(
    'APIs that are gone or changed, from the migration lists (`fix_data`) '
    "of the SDKs and the packages. Code that uses them doesn't compile; "
    '`dart fix` applies each migration.',
  );
  _grouped(out, [
    for (final api in facts.migrated)
      (
        api.group,
        '- `${api.name}`: ${api.status.name}. ${_withFullStop(api.title)}',
      ),
  ]);
  if (facts.moved.isNotEmpty) {
    paragraph('## Moved libraries');
    paragraph(
      'Libraries a migration (`fix_data`) moves elsewhere. Check the notes '
      'above before switching.',
    );
    out.writeln();
    for (final moved in facts.moved) {
      final to = moved.to == null ? '' : ' → `${moved.to}`';
      out.writeln('- `${moved.from}`$to: ${_withFullStop(moved.title)}');
    }
  }
  if (facts.unread.isNotEmpty) {
    paragraph('## Not read');
    paragraph(
      "Migration files Appstein couldn't read, so their migrations are "
      'missing above.',
    );
    out.writeln();
    for (final unread in facts.unread) {
      out.writeln('- `${unread.file}`: ${unread.reason}');
    }
  }
  return out.toString();
}

void _notes(StringBuffer out, List<CuratedNote> notes) {
  out.writeln();
  if (notes.isEmpty) {
    out.writeln('None.');
    return;
  }
  for (final note in notes) {
    final language = note.languageVersion == null
        ? ''
        : ', language ${note.languageVersion}';
    out
      ..writeln(
        '- **${note.id}** (priority ${note.priority}, since '
        '${note.since}$language): ${note.summary}',
      )
      ..writeln('  - Use: ${note.use}')
      ..writeln('  - Avoid: ${note.avoid}')
      ..writeln('  - Source: ${note.source}');
  }
}

/// Writes [lines] under a `###` heading per group, in the order given.
void _grouped(StringBuffer out, List<(String, String)> lines) {
  if (lines.isEmpty) {
    out
      ..writeln()
      ..writeln('None.');
    return;
  }
  String? current;
  for (final (group, line) in lines) {
    if (group != current) {
      out
        ..writeln()
        ..writeln('### $group')
        ..writeln();
      current = group;
    }
    out.writeln(line);
  }
}

String _deprecatedLine(DeprecatedApi api) {
  final parts = [
    if (api.kind.rule case final rule?) rule,
    if (api.message case final message?)
      message
    else if (api.kind == DeprecationKind.use)
      'deprecated, with no message.',
    for (final title in api.migrations)
      '`dart fix` migrates it: ${_withFullStop(title)}',
  ];
  return '- `${api.name}`: ${parts.join(' ')}';
}

bool _needsNewerLanguage(CuratedNote note, String? languageVersion) {
  final needed = note.languageVersion;
  if (needed == null || languageVersion == null) return false;
  final neededMinor = flutterMinorOf(needed);
  final projectMinor = flutterMinorOf(languageVersion);
  if (neededMinor == null || projectMinor == null) return false;
  return compareFlutterMinors(neededMinor, projectMinor) > 0;
}

String _minorText(String version) {
  final minor = flutterMinorOf(version);
  return minor == null ? version : '${minor.major}.${minor.minor}';
}

String _withFullStop(String text) =>
    text.endsWith('.') || text.endsWith('!') || text.endsWith('?')
    ? text
    : '$text.';
```

In `packages/appstein_engine/lib/appstein_engine.dart`, add `export 'src/delta/delta_document.dart';` in sorted position.

- [ ] **Step 6: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/delta/`
Expected: PASS.
- **If the golden test fails:** diff the output against the golden from Step 2. The golden is the specification; change the renderer to match it, not the golden.
- **The one exception:** an obvious typo in the plan's golden. Rule on it, record the ruling, and only then run `APPSTEIN_UPDATE_GOLDENS=1`.
- **If `deltaNotes`' `material-ui-packages` id is wrong:** check its id in `notes/3.47.yaml` and use the real id of a note with `since: "3.47"`.

- [ ] **Step 7: Analyze, format, commit (controller)**

Run analyze and format (no issues), then:

```bash
git add packages/appstein_engine/lib/src/delta/delta_document.dart packages/appstein_engine/lib/appstein_engine.dart packages/appstein_engine/test/delta/delta_document_test.dart packages/appstein_engine/test/support/fixture_app.dart packages/appstein_engine/test/fixtures/apps/goldens/delta.md.golden
git commit -m "feat: render the version delta as Markdown (spec §6.4)"
```

---

### Task 5: Write `delta.md` in every sync

**Files:**
- Modify: `packages/appstein_engine/lib/src/map/map_sync.dart`
- Modify: `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart`
- Modify: `packages/appstein_cli/lib/src/sync_command.dart`
- Test: `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart`, `packages/appstein_cli/test/sync_command_test.dart`

**Interfaces:**
- Consumes:
  - `collectDelta` (Task 3);
  - `deltaPath`, `DeltaInputs`, `deltaNotes`, `renderDelta` (Task 4);
  - `GeneratedFile.markdown`, `readFrontMatter` (Task 1);
  - `inputHash`, `knowledgeFormatVersion`.
- Produces:
  - `MapBuild` gains `final String? inputHash` and `final DeltaFacts? delta`, both null when the map was skipped;
  - `KnowledgeSync` gains `final String baseline` (default `'3.16'`, the default of `delta.baseline`, spec §7);
  - `sync` writes `platform/delta.md` after the platform files and before the map files.

- [ ] **Step 1: Write the failing sync tests**

In `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart`:

1. Change the `sync` helper to take a baseline:

```dart
  KnowledgeSync sync({
    List<Pack> packs = const [OfficialMvvmPack()],
    String baseline = '3.16',
  }) => KnowledgeSync(
    environment: fakeEnvironment({'FLUTTER_ROOT': sdk}),
    appsteinVersion: '0.1.0-dev',
    packs: packs,
    runner: runner,
    clock: () => DateTime.utc(2026, 10, 1, 9),
    baseline: baseline,
  );

  String delta(String project) => File(
    p.join(project, '.appstein', 'platform', 'delta.md'),
  ).readAsStringSync();
```

2. In the first test, add `'platform/delta.md': true,` after `'platform/toolchain.json': true,` in the expected `report.files`, and add `'platform/delta.md',` after `'platform/toolchain.json',` in the expected `state.json` keys.
3. In the tests `'when pub get fails, …'`, `'a corrupted pubspec.lock …'`, `'a failed fetch after a good sync …'` and `'without packs, …'`, insert `'platform/delta.md',` after `'platform/toolchain.json',` in every expected list of files or `state.json` keys.
4. Add these tests at the end of `main()`:

```dart
  test('the first sync writes delta.md: the notes, then what the stand-ins '
      'and the Dart SDK mark, with go_router\'s removed location', () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    final text = delta(app);
    final meta = readFrontMatter(text)!;
    expect(meta.sdkVersion, '3.47.5');
    expect(meta.generatedAt, '2026-10-01T09:00:00Z');
    expect(
      text,
      contains('# Version delta: Flutter 3.47.5, Dart language 3.12\n'),
    );
    expect(text, contains('## Notes'));
    expect(text, contains('popscope-not-willpopscope'));
    expect(text, contains('## Deprecated'));
    expect(
      text,
      contains(
        "- `GoRouterState.location`: removed. Replaces 'location' in "
        "'GoRouterState' with `uri.toString()`.",
      ),
    );
    expect((state(app)['files']! as Map)['platform/delta.md'], meta.inputHash);
  });

  test('when the map is skipped, delta.md holds only the notes and says '
      'why', () async {
    final app = copyFixtureApp();
    File(p.join(app, '.dart_tool', 'package_config.json')).deleteSync();
    runner.when(flutter(), [
      'pub',
      'get',
    ], const RunResult(exitCode: 69, stderr: 'Could not reach pub.dev.'));
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.files['platform/delta.md'], isTrue);
    final text = delta(app);
    expect(
      text,
      contains(
        'project map was skipped: the packages could not be fetched. Fix '
        'that, then run `appstein sync` again.',
      ),
    );
    expect(text, contains('popscope-not-willpopscope'));
    expect(text, isNot(contains('## Deprecated')));
  });

  test('a later baseline drops the older notes', () async {
    final app = copyFixtureApp();
    await sync(baseline: '3.47').run(app, dartSdkPath: testDartSdk);
    final text = delta(app);
    expect(text, contains('since Flutter 3.47'));
    expect(text, isNot(contains('popscope-not-willpopscope')));
  });

  test('a hand-edited delta.md is put back', () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    final file = File(p.join(app, '.appstein', 'platform', 'delta.md'));
    final original = file.readAsStringSync();
    file.writeAsStringSync(original.replaceFirst('## Notes', '## Edited'));
    final second = await sync().run(app, dartSdkPath: testDartSdk);
    expect(second.files['platform/delta.md'], isTrue);
    expect(file.readAsStringSync(), contains('## Notes'));
  });

  test("editing a source file changes delta.md's input hash", () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    final before = readFrontMatter(delta(app))!.inputHash;
    final source = File(p.join(app, 'lib', 'utils', 'result.dart'));
    source.writeAsStringSync('${source.readAsStringSync()}\n// edited\n');
    await sync().run(app, dartSdkPath: testDartSdk);
    expect(readFrontMatter(delta(app))!.inputHash, isNot(before));
  });
```

- [ ] **Step 2: Write the failing CLI tests**

In `packages/appstein_cli/test/sync_command_test.dart`:

1. In the test `'writes the platform layer and says what it did'`, add after the `toolchain.json` row check:

```dart
    expect(text, contains(row('platform/delta.md', 'written')));
```

   Add `'platform/delta.md',` to the list of paths that must exist.
2. Add this test after `'a broken appstein.yaml exits 3 and says what to fix'`:

```dart
  test("the delta's baseline comes from appstein.yaml", () async {
    File(
      p.join(project, 'appstein.yaml'),
    ).writeAsStringSync('delta:\n  baseline: "3.47"\n');
    expect(await run(['sync']), ExitCodes.ok, reason: '$err');
    final text = File(
      p.join(project, '.appstein', 'platform', 'delta.md'),
    ).readAsStringSync();
    expect(text, contains('since Flutter 3.47'));
    expect(text, isNot(contains('popscope-not-willpopscope')));
  });
```

- [ ] **Step 3: Run the tests to see them fail**

Run:
- `cd packages/appstein_engine && fvm dart test test/knowledge/knowledge_sync_test.dart`
- `cd packages/appstein_cli && fvm dart test test/sync_command_test.dart`

Expected: FAIL. `KnowledgeSync` has no `baseline`, and no `delta.md` is written.

- [ ] **Step 4: Have `MapSync` collect the delta**

In `packages/appstein_engine/lib/src/map/map_sync.dart`:

1. Add imports, keeping them sorted:

```dart
import '../delta/delta_collector.dart';
import '../delta/delta_facts.dart';
```

2. Replace `MapBuild` with:

```dart
/// The project map, built but not yet written.
final class MapBuild {
  /// Creates the build.
  const MapBuild({
    required this.files,
    required this.report,
    this.inputHash,
    this.delta,
  });

  /// The map files; empty when the map was skipped.
  final List<GeneratedFile> files;

  /// What happened.
  final MapReport report;

  /// The input hash every map file shares; null when the map was skipped.
  final String? inputHash;

  /// The deprecated, removed and moved APIs the project can reach, for the
  /// version delta (spec §6.4); null when the map was skipped.
  final DeltaFacts? delta;
}
```

3. In `build`, before `final ProjectAnalysis analysis;`, add:

```dart
    final sdk = dartSdkPath ?? p.join(flutterRoot, 'bin', 'cache', 'dart-sdk');
```

   Then pass `dartSdkPath: sdk,` to `ProjectAnalysis.analyze`.
4. After `bodies[MapFiles.deps] = …;`, add:

```dart
      // While the analysis is still open: the delta walks what the imports
      // expose.
      final delta = collectDelta(analysis, dartSdkPath: sdk);
```

5. In the successful `return MapBuild(…)`, add `inputHash: hash,` and `delta: delta,` after `report: …`.
6. Add this paragraph to the class doc comment of `MapSync`, after its first paragraph:

```dart
///
/// While the analysis is open, it also collects the version delta's facts
/// ([collectDelta]); `KnowledgeSync` renders them into `delta.md`.
```

- [ ] **Step 5: Have `KnowledgeSync` write `delta.md`**

Replace `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart` with:

```dart
import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../delta/delta_document.dart';
import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../map/map_sync.dart';
import '../notes/curated_notes.dart';
import '../packs/pack.dart';
import '../sdk/sdk_detector.dart';
import 'generated_file.dart';
import 'input_hash.dart';
import 'knowledge_store.dart';
import 'platform_sync.dart';

/// Everything `appstein sync` writes (spec §5.4, §6.2): the platform layer,
/// the version delta and the project map. All are built first, then written
/// under one lock, with a `state.json` that lists them.
final class KnowledgeSync {
  /// Creates the sync. [packs] are the project's packs (the CLI chooses
  /// them from `appstein.yaml`), [notes] default to the compiled-in curated
  /// notes, [runner] runs `flutter pub get`, [clock] gives the time, and
  /// [baseline] is `delta.baseline` from `appstein.yaml`.
  KnowledgeSync({
    required this.environment,
    required this.appsteinVersion,
    this.packs = const [],
    CuratedNotes? notes,
    ProcessRunner? runner,
    this._clock,
    this.lockTimeout = const Duration(seconds: 10),
    this.baseline = '3.16',
  }) : notes = notes ?? CuratedNotes.bundled(),
       runner = runner ?? const SystemProcessRunner();

  /// The machine.
  final HostEnvironment environment;

  /// The version of the running Appstein.
  final String appsteinVersion;

  /// The project's packs.
  final List<Pack> packs;

  /// The curated notes.
  final CuratedNotes notes;

  /// Runs `flutter pub get`.
  final ProcessRunner runner;

  /// How long to wait for another writer's lock.
  final Duration lockTimeout;

  /// How far back the delta's curated notes reach (spec §6.4, §7); `3.16`
  /// is the default of `delta.baseline`.
  final String baseline;

  final DateTime Function()? _clock;

  /// Syncs the project at [projectRoot]. [sdk] is the SDK detection to use
  /// (by default it is detected for the project); [dartSdkPath] overrides
  /// where `dart:` libraries are read from, for tests.
  ///
  /// The map is skipped, with the reason in [SyncReport.map], when the
  /// packages can't be fetched or the Dart SDK is incomplete. The platform
  /// layer and a notes-only `delta.md` are still written.
  ///
  /// Throws `SyncException` when no usable SDK is found, a
  /// `KnowledgeLockTimeout` when another writer holds the lock too long,
  /// and a `KnowledgeWriteException` when a file can't be written.
  Future<SyncReport> run(
    String projectRoot, {
    SdkDetection? sdk,
    String? dartSdkPath,
  }) async {
    final platform = PlatformSync(
      environment: environment,
      appsteinVersion: appsteinVersion,
      notes: notes,
      clock: _clock,
    ).build(projectRoot, sdk: sdk);
    final map =
        await MapSync(
          environment: environment,
          appsteinVersion: appsteinVersion,
          packs: packs,
          runner: runner,
        ).build(
          projectRoot,
          flutterVersion: platform.sdk.flutterVersion,
          flutterRoot: platform.location.root,
          dartSdkPath: dartSdkPath,
        );
    final delta = _delta(platform, map);
    final store = KnowledgeStore(projectRoot, clock: _clock);
    return store.locked(
      () async => SyncReport(
        sdk: platform.sdk,
        files: await store.writeAll(
          [...platform.files, delta, ...map.files],
          appsteinVersion: appsteinVersion,
          sdkVersion: platform.sdk.flutterVersion,
        ),
        newestNotes: platform.newestNotes,
        fallbacks: platform.fallbacks,
        map: map.report,
      ),
      timeout: lockTimeout,
    );
  }

  /// `delta.md`: the notes, and the map's delta facts when it ran. Its
  /// input hash covers the map's own hash (so the project's code, packages
  /// and Flutter version), the notes, the baseline and the language version.
  GeneratedFile _delta(PlatformBuild platform, MapBuild map) {
    final sdk = platform.sdk;
    final markdown = renderDelta(
      DeltaInputs(
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
        facts: map.delta,
        skipped: map.report.skipped,
      ),
    );
    return GeneratedFile.markdown(
      path: deltaPath,
      markdown: markdown,
      inputHash: inputHash(
        {
          'map': utf8.encode(
            map.inputHash ?? 'skipped: ${map.report.skipped}',
          ),
          ...notes.inputs,
          'baseline': utf8.encode(baseline),
          'languageVersion': utf8.encode(sdk.languageVersion ?? ''),
          'flutter': utf8.encode(sdk.flutterVersion),
        },
        appsteinVersion: appsteinVersion,
        formatVersion: knowledgeFormatVersion,
      ),
    );
  }
}
```

- [ ] **Step 6: Pass the baseline from the CLI**

In `packages/appstein_cli/lib/src/sync_command.dart`, in `run()`, add `baseline: config.delta.baseline,` after `packs: packsFor(config),`. Change the class doc comment's last sentence to: `It writes the platform layer (`sdk.json`, `toolchain.json`), the version delta (`delta.md`) and the project map (`map/*.json`), then `state.json`.`

- [ ] **Step 7: Run the tests to see them pass**

Run:
- `cd packages/appstein_engine && fvm dart test`
- `cd packages/appstein_cli && fvm dart test`

Expected: PASS, every test. The map goldens are unchanged.

- [ ] **Step 8: Analyze, format, commit (controller)**

Run analyze, format and `fvm dart run dependency_validator` from the repo root (no issues), then:

```bash
git add packages/appstein_engine/lib/src/map/map_sync.dart packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart packages/appstein_cli/lib/src/sync_command.dart packages/appstein_engine/test/knowledge/knowledge_sync_test.dart packages/appstein_cli/test/sync_command_test.dart
git commit -m "feat: appstein sync writes the version delta, platform/delta.md (spec §6.4)"
```

---

### Task 6: The real-SDK check

**Files:**
- Modify: `packages/appstein_engine/test/integration/map_real_sdk_test.dart`

**Interfaces:**
- Consumes: the sync from Task 5; the real Flutter (3.47.5 locally and in the `test` job, 3.44 in `min-sdk`) and the real go_router 18.

The facts below hold for both Flutter 3.44 and 3.47. They were checked on 2026-10-01 in Flutter's git tags `3.44.0` and `3.47.0`:
- `WillPopScope`'s message is identical in both;
- both `Stack` migrations are at the same lines of `fix_widgets.yaml`;
- go_router 18.0.2 has the `location` migration.

- [ ] **Step 1: Add the assertions**

In `packages/appstein_engine/test/integration/map_real_sdk_test.dart`, add `import 'dart:io';` and `import 'package:path/path.dart' as p;` (sorted), then insert after the `deps.json` checks and before `// The fetch left fresh packages…`:

```dart
    // The version delta, from the real Flutter, Dart and go_router.
    final delta = File(
      p.join(app, '.appstein', 'platform', 'delta.md'),
    ).readAsStringSync();
    expect(delta, contains('### package:flutter'));
    expect(
      delta,
      contains(
        '- `WillPopScope`: Use PopScope instead. The Android predictive back '
        'feature will not work with WillPopScope. This feature was deprecated '
        'after v3.12.0-1.0.pre.',
      ),
    );
    expect(
      delta,
      contains("- `Stack.overflow`: removed. Migrate to 'clipBehavior'."),
    );
    expect(delta, contains("- `Stack.new`: changed. Migrate to 'clipBehavior'."));
    expect(
      delta,
      contains(
        "- `GoRouterState.location`: removed. Replaces 'location' in "
        "'GoRouterState' with `uri.toString()`.",
      ),
    );
    // The app imports widgets, not cupertino.
    expect(delta, isNot(contains('`Cupertino')));
    // D11: everything Flutter and Dart mark fits in 1,500 lines today, so
    // more means duplicates.
    final lines = delta.split('\n');
    expect(lines.length, lessThanOrEqualTo(1500));
    final entries = [
      for (final line in lines)
        if (line.startsWith('- `')) line,
    ];
    expect(entries.toSet().length, entries.length, reason: 'duplicate lines');
    printOnFailure('delta.md: ${lines.length} lines, ${entries.length} entries');
```

- [ ] **Step 2: Run it against the real SDK**

Run: `cd packages/appstein_engine && fvm dart test --run-skipped --tags integration test/integration/map_real_sdk_test.dart`
Expected: PASS. It needs the network for go_router the first time.
- Then print the size once with `print` in place of `printOnFailure`, record the line and entry counts in the report, and switch it back.
- If an assertion fails, read the real `delta.md` and decide whether the code or the assumption is wrong. Report it; don't weaken the assertion silently.

- [ ] **Step 3: Run the whole test suite once**

Run each package's tests, then the real-machine tests:
- `cd packages/appstein_engine && fvm dart test`
- `cd ../appstein_cli && fvm dart test`
- `cd ../appstein_protocol && fvm dart test`
- `cd ../appstein_lints && fvm dart test`
- `cd ../appstein_engine && fvm dart test --run-skipped --tags integration`

Expected: all PASS.

- [ ] **Step 4: Measure the sync**

Run: `fvm dart run tool/measure_sync.dart`
Expected: the full sync stays under the 30 s budget (1b.3 measured 9.5–11.4 s here). Record the time in the report.

- [ ] **Step 5: Commit (controller)**

```bash
git add packages/appstein_engine/test/integration/map_real_sdk_test.dart
git commit -m "test: the version delta against the real Flutter, Dart and go_router"
```

---

### Task 7: The developer guide

**Files:**
- Create: `docs/guide/version-delta.md`
- Modify: `docs/guide/knowledge-store.md`, `docs/guide/project-map.md`, `docs/guide/cli.md`, `docs/guide/config.md`, `docs/guide/testing.md`, `docs/guide/architecture.md`, `docs/guide/README.md`

**Interfaces:**
- Consumes: everything built in Tasks 1–6.

- [ ] **Step 1: Write the new page**

Create `docs/guide/version-delta.md`:

````markdown
<!-- covers: packages/appstein_engine/lib/src/delta/** -->

# The version delta

`appstein sync` writes `.appstein/platform/delta.md` (spec §6.4). It's a cheat sheet an agent reads before it writes code: which APIs of the installed Flutter, Dart and the project's packages are deprecated, removed or moved, and what to use instead, plus Appstein's curated notes. This page explains where each line comes from and why it is built this way. The facts behind each decision were checked against Flutter's and Dart's own files; they're listed in the [slice 1b.5 plan](../superpowers/plans/2026-10-01-slice-1b5-version-delta.md#decisions-made-while-planning-for-the-owners-review).

## What the file holds

| Section | Holds | From |
|---|---|---|
| Notes | Appstein's curated notes since the baseline (`delta.baseline` in `appstein.yaml`, `3.16` by default), most important first | `notes/*.yaml`, compiled in (see [knowledge-store](knowledge-store.md#the-curated-notes)) |
| Needs a newer language version | Notes the project can't use yet, because its language version (the lower bound of `environment: sdk:`) is older than the note's | the same notes |
| Deprecated | Every deprecated declaration, member and parameter the project's imports expose, with the library's own message | `Deprecated` annotations, read through the analyzer |
| Removed | APIs that are gone (`removed`) or whose old form is gone (`changed`), with the migration's title | `fix_data` migrations |
| Moved libraries | Libraries a migration moves, such as `package:flutter/material.dart` to `material_ui` | `fix_data` migrations with a `library:` |
| Not read | Migration files Appstein couldn't read, and why | |

Deprecated and Removed are grouped by package (`dart:core`, `package:flutter`, `package:go_router`), never by Flutter's private `src/` files, which no one should import. Each line quotes the library: Appstein adds only the section intros, the words `removed` and `changed`, and the rule of each deprecation kind.

## Why every deprecation is listed, whatever its age

The baseline limits only the curated notes. Deprecations and migrations are listed however old they are, for two reasons:

- **Their age can't be read from the SDK.**
  - A deprecation message names a development build, not a release: `WillPopScope` says "deprecated after v3.12.0-1.0.pre", but it first shipped deprecated in stable 3.16, and `v3.16.0-17.0.pre` first shipped in 3.24.
  - A `fix_data` date is when the fix was written, so dates don't even follow release order.
  - Only Flutter's git tags know, and reading them takes minutes.
- **Hiding old ones would backfire.** `verify` fails on every deprecated use (spec §9.1), so a cheat sheet that left out the 115 deprecations older than 3.16 would let an agent write code our own check then rejects.

The list never reaches *newer* than the installed SDK: it is read from the user's own SDK and packages.

## What "the imports expose" means

- **Deprecations:**
  - [`collectDelta`](../../packages/appstein_engine/lib/src/delta/delta_collector.dart) walks the export namespace of every library the project imports (`dart:core` included, since every library imports it), the way the analyzer's `deprecated_member_use` sees them;
  - it notes each declaration, member, constructor and parameter that carries a `Deprecated` annotation;
  - a member inherited from a private superclass is listed under the public class that exposes it;
  - the project's own code is left out;
  - `show` and `hide` on imports are not applied.
- **Migrations:**
  - a migration counts when the project imports one of its libraries **directly**: the rule `dart fix` uses (`ElementMatcher` in the Dart SDK's analysis server);
  - its element is then looked up: missing means `removed`; present but not deprecated means `changed`;
  - present and deprecated, or an old parameter that is deprecated, means the migration is attached to that deprecation line ("`dart fix` migrates it: …").

Dart has seven kinds of deprecation (`dart:core`'s `Deprecated` constructors). The delta words each one:

| Annotation | The line says |
|---|---|
| `@Deprecated(…)`, `@deprecated` | the message (or "deprecated, with no message.") |
| `@Deprecated.implement` | don't implement it. |
| `@Deprecated.extend` | don't extend it. |
| `@Deprecated.subclass` | don't extend or implement it. |
| `@Deprecated.instantiate` | don't create instances of it. |
| `@Deprecated.mixin` | don't mix it in. |
| `@Deprecated.optional` | always pass this argument: it will become required. |

So `RegExp` (`@Deprecated.implement`) appears as "don't implement it", and using `RegExp` stays fine.

## Where the migrations come from

[`parseFixData`](../../packages/appstein_engine/lib/src/delta/fix_data.dart) reads the files `dart fix` reads:
- each imported package's `lib/fix_data.yaml` or `lib/fix_data/**.yaml` (Flutter uses the folder, go_router the single file);
- the Dart SDK's `lib/_internal/fix_data.yaml`.

Relative URIs (`material.dart`) resolve against the package. An empty file (Flutter ships `fix_template.yaml` empty) has no migrations. A broken file is listed under "Not read" and the rest of the delta is kept: a package's bad file never fails `sync`. Names in the file are package URIs (`package:delta_kit/fix_data/fix_broken.yaml`), never machine paths.

## How sync builds it

```text
KnowledgeSync.run
  |-- PlatformSync.build     sdk.json, toolchain.json
  |-- MapSync.build          ... the map, then, while the analysis is open:
  |     collectDelta         deprecations + migrations -> DeltaFacts
  |-- deltaNotes             the notes from the baseline up to this SDK
  |-- renderDelta            -> GeneratedFile.markdown('platform/delta.md')
  `-- KnowledgeStore.locked  writeAll: platform files, delta.md, map files, state.json
```

- [`renderDelta`](../../packages/appstein_engine/lib/src/delta/delta_document.dart) is pure: the same inputs give the same text, and a golden file pins it.
- **When the map is skipped** (the packages can't be fetched, or a broken `pubspec.lock`), there is no analysis, so `delta.md` holds only the notes and a line saying why the rest is missing. The Flutter SDK has no package config of its own, so nothing can be resolved without the project's packages.
- The file is Markdown with its metadata in front matter (see [knowledge-store](knowledge-store.md#three-rules-every-generated-file-follows)).

## Freshness

`delta.md`'s input hash covers:
- the map's own input hash: the project's Dart files, `pubspec.yaml`, the lock file (so every package version), `analysis_options.yaml`, the Flutter version and the packs (or "skipped" and its reason);
- the notes files;
- the baseline;
- the language version.

So a new package version, a new Flutter, an edited import or a new baseline rebuilds it.

## Tests

- **Parser:** `test/delta/fix_data_test.dart`, with entries copied from Flutter's and go_router's real files.
- **Collector:** `test/delta/delta_collector_test.dart`, on the `delta_kit` stand-in package in `test/fixtures/apps/stubs/delta_kit/`. That package was made for these tests: one of each kind of deprecation, a private superclass, a hidden class, and migration files that are removed, changed, attached, out of scope, a library move, broken and empty.
- **Renderer:** `test/delta/delta_document_test.dart`, against `goldens/delta.md.golden`.
- **Sync:** `test/knowledge/knowledge_sync_test.dart`.
- **Real SDK:** `test/integration/map_real_sdk_test.dart` checks lines that hold on both Flutter 3.44 and 3.47 (`WillPopScope`, `Stack`, go_router's `location`), a 1,500-line ceiling, and no duplicate lines.

See [testing](testing.md#the-fixture-app-and-goldens).
````

- [ ] **Step 2: Update the existing pages**

1. **`docs/guide/knowledge-store.md`:**
   - In the intro, replace "Native config (1b.4), the version delta (`delta.md`, 1b.5), and `INDEX.md` and incremental sync (1b.6) come in later slices." with: "Slice 1b.5 added the **version delta**, `delta.md`, which has [its own page](version-delta.md). Native config (1b.4), and `INDEX.md` and incremental sync (1b.6), come in later slices."
   - Add this row to the table after the `toolchain.json` row:

     `| .appstein/platform/delta.md | The version delta: curated notes, then the deprecated, removed and moved APIs the project can reach (see [version-delta](version-delta.md)) | any map input, the notes, the baseline or the language version changes, or the file was hand-edited or damaged |`

     The path is in backticks, like the other rows.
   - In the "How one sync runs" flowchart, add this line after the `MapSync.build` line:

     ```text
       run --> delta["renderDelta:<br/>delta.md"]
     ```

     In the numbered list under it:
     - insert a new item 4: "[`renderDelta`](../../packages/appstein_engine/lib/src/delta/delta_document.dart) turns the curated notes and the map's delta facts into `delta.md`, a `GeneratedFile.markdown`. When the map was skipped, it holds only the notes. See [version-delta](version-delta.md).";
     - renumber the `writeAll` item to 5, and change its start to: "Under the lock, `writeAll` writes each `GeneratedFile` (JSON with `writeGenerated`, Markdown with `writeGeneratedMarkdown`), in the order: platform files, `delta.md`, map files, then `state.json` last, listing exactly the files it was given."
   - Under "Three rules every generated file follows", change "**Canonical JSON.**" to start "**Canonical JSON, or Markdown with front matter.**". Add after its paragraph:

     "A Markdown file (`delta.md`) carries the same metadata in a front matter block, written by [`markdownWithFrontMatter`](../../packages/appstein_engine/lib/src/knowledge/markdown_front_matter.dart): `---`, one `key: value` line per field in key order, each value as JSON (valid YAML, and the quotes keep `generatedAt` a string), `---`, a blank line, then the text with `\n` line ends. `readFrontMatter` reads it back. `writeGeneratedMarkdown` follows the same rewrite-only-on-change rule."
2. **`docs/guide/project-map.md`:** in the "How sync builds it" diagram, add these lines after `5. one input hash …`:

   ```text
   |     6. delta facts       collectDelta, while the analysis is open (version-delta.md)
   ```

   Add this line before `` `-- KnowledgeStore.locked``:

   ```text
   |-- renderDelta           platform/delta.md                  (no writing yet)
   ```

   In "Two things to notice", add to the second bullet: "`delta.md` is still written then, with only the notes."
3. **`docs/guide/cli.md`:**
   - In "`appstein sync`", step 2 becomes: "**Reads `appstein.yaml`** … to learn which stack pack the project uses and the delta's baseline (`delta.baseline`)."
   - Step 3 becomes: "**Runs the engine's `KnowledgeSync`** with those packs and that baseline. It writes the platform layer, the version delta and the project map."
4. **`docs/guide/config.md`:** in "Where config is used today", change the `appstein sync` bullet to start "**`appstein sync`**, which reads **`packs.stack`** to choose the stack pack and **`delta.baseline`** to choose how far back the version delta's curated notes reach ([version-delta](version-delta.md)).", keeping the rest of the bullet.
5. **`docs/guide/testing.md`:** under "Stand-in packages", add:

   "`stubs/delta_kit/` is different: it's a package made for the version-delta tests, not a stand-in for a real one. It has one of each kind of deprecation and migration files in Flutter's format (see [version-delta](version-delta.md#tests)). `stubs/go_router/lib/fix_data.yaml` is go_router 18.0.2's real `location` migration. `analyzeDeltaApp` analyzes a small app that imports `delta_kit`."

   Under "Goldens", add `delta.md.golden` (the renderer's output, compared with `expectTextGolden`).
6. **`docs/guide/architecture.md`:**
   - In "What exists now", change the knowledge bullet to: "the knowledge Appstein writes into a project's `.appstein/`: the platform layer, the version delta (see [version-delta](version-delta.md)) and the project map of the app's Dart code (see [project-map](project-map.md));".
   - In the engine table, add after the `map/` row:

     `| delta/ | The version delta: `fix_data` migrations, the deprecations the imports expose, the Markdown | [version-delta](version-delta.md) |`

     The folder name is in backticks, like the other rows.
7. **`docs/guide/README.md`:** in the guide map, add after the `project-map` row:

   `| [version-delta](version-delta.md) | How `appstein sync` builds `delta.md`: the deprecations, removed and moved APIs the project can reach, and the curated notes |`

- [ ] **Step 3: Regenerate and check**

Run from the repo root:
- `fvm dart run tool/gen_docs.dart`
- `fvm dart run tool/check_guide.dart --since main`

Expected:
- `gen_docs` updates the engine's export list in `architecture.md` if it shows one;
- the guide check passes: every new source file is covered, and every changed page is newer than its code.

- [ ] **Step 4: Commit (controller)**

```bash
git add docs/guide
git commit -m "docs: the version delta in the guide (spec §19.6)"
```

---

### Task 8: Verify, open the PR, record (controller)

- [ ] **Step 1: Full local verification**

From the repo root:
- `fvm dart analyze --fatal-infos`
- `fvm dart format --output=none --set-exit-if-changed .`
- `fvm dart run dependency_validator`
- each package's tests, plus `fvm dart test --run-skipped --tags integration` in the engine
- `fvm dart test` in `tool/`'s test folder (the repo tool tests)
- `fvm dart run tool/gen_docs.dart` (no change)
- `fvm dart run tool/gen_notes.dart` (no change)
- `fvm dart run tool/check_guide.dart --since main`
- `dart doc --dry-run` in `packages/appstein_engine` and `packages/appstein_protocol` (0 warnings)
- the BOM scan

- [ ] **Step 2: `appstein sync` by hand**

On the development machine, run the compiled CLI (`fvm dart compile exe packages/appstein_cli/bin/appstein.dart -o build/appstein.exe`) against a scratch Flutter project in the scratchpad that imports `material.dart`. Show the owner `delta.md`'s size and a sample of each section. Run it twice; the second run must report `platform/delta.md  unchanged`.

- [ ] **Step 3: Push `slice-1b5` and open the PR**

PR body:
- what the slice adds;
- the decisions D1–D11;
- the owner rulings: the baseline rule, the filter, packages, removed APIs, approach A, and spec edits E1–E7;
- the verification results.

The body ends with the session's PR attribution lines. CI must be green on all jobs, including `min-sdk` (Flutter 3.44) and `measure`.

- [ ] **Step 4: One commit after the PR opens**

- Append "## Notes from execution" to this plan (outside any code fence).
- In `docs/superpowers/progress.yaml`, set 1b.5 to `status: done` with `pr: <n>` and `finished: <date>`, and mark 1b.4 `next`.
- Run `fvm dart run tool/gen_docs.dart`, then **read back the rendered `.html`**: 1b.5 Done with its PR link, 1b.4 Next (owner rule, 2026-10-01).

Push it.

- [ ] **Step 5: Graph and merge**

Run `/graphify . --update` until `tool/check_graph.py` reports nothing, with at most 3 extraction subagents. Then merge by the owner's PR flow and delete the branch.

## Carried to later slices

- **1d (verify):** at "done", the Stop hook runs `dart fix --apply`, which may apply Flutter 3.47's **library** migration (`flutter/material.dart` → `material_ui`) by itself. Spec §13.1 says to switch only when every dependency is compatible. Check what `dart fix` does with `library:` migrations, and guard it if needed.
- **1c (MCP):**
  - `check_api` and `what_changed` read the delta;
  - decide whether `DeltaFacts` moves to the protocol with a JSON form (D8);
  - `check_api` answers for any symbol, so it may need the unfiltered facts.
- **1f (benchmark):** spec §6.4 ranks notes "then by how often the benchmark sees agents hit the entry". There is no benchmark data yet, so notes are ranked by priority, then `since`, then id. Add the hit counts when the first benchmark run records them.
- **1b.6:**
  - INDEX.md's 5–10 top delta entries (spec §6.3);
  - path dependencies' sources, and their `fix_data`, aren't in any input hash yet.
- **Known limits, recorded here:**
  - `show`/`hide` on imports aren't applied to deprecations (D1);
  - a package's `fix_data` that names another package's libraries isn't read (D3);
  - an unknown Flutter version gets no notes (D7).
