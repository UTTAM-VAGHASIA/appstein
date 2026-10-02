# Slice 1b.6: INDEX.md Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `appstein sync` also writes `.appstein/INDEX.md`, the one page an agent always reads. It's at most 1,500 tokens, counted as 4,500 bytes. It is built from what `sync` already knows: the SDK, the project map, `native.json`, the curated notes and `delta.md`, plus the project's decision files and `memory/current.md`.

**Architecture:**
- **Sources:** `lib/src/index/index_sources.dart` reads what INDEX.md needs from the project itself:
  - the name from `pubspec.yaml`;
  - the platform folders;
  - the decision files' front matter;
  - the first lines of `memory/current.md`.

  It also turns the in-memory `native.json` and `features.json` into ID lines and table rows.
- **Renderer:** `lib/src/index/index_document.dart` is a pure `renderIndex(inputs, byteBudget:)`, like `renderDelta`. It renders the eight §6.3 sections. If the text is over budget, it cuts sections in §6.3's fixed order, one item at a time, until it fits.
- **Wiring:** `KnowledgeSync` builds `INDEX.md` after the other files, from their in-memory builds. It hashes their input hashes plus the project files it reads. It writes `INDEX.md` last, before `state.json`, with the existing rewrite-only-on-change rule.

**Tech Stack:** Dart 3.12+ (Flutter 3.47.5 via FVM), `package:yaml`, `package:path`, `package:test`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md`. This plan implements:
- §6.3 as edited in commit `5353e1c` (owner-approved): the eight sections and where each part comes from, the budget rule (UTF-8 bytes ÷ 3, so 4,500 bytes), the cut order, and the generated time kept in the front matter;
- §6.2: `INDEX.md` is generated and git-ignored, and carries its metadata in front matter;
- §4 principle 5: only `INDEX.md` is always loaded;
- §15: determinism and Windows paths.

What isn't here, and where it goes:
- The MCP tools INDEX.md names are slice 1c. INDEX.md names them now in their final form (owner delegation, D1).
- `AGENTS.md`/`CLAUDE.md` pointing to INDEX.md is slice 1e.
- Incremental sync is 1b.7, and package skills are 1b.8.

## Global Constraints

- **Commands:** run every Dart command through FVM: `fvm dart …`. The repo pins Flutter 3.47.5 (Dart 3.13.4); packages declare `sdk: ^3.12.0`. CI also runs the unit tests on Flutter 3.44 (Dart 3.12), so no test may depend on the real Flutter or Dart SDK's contents. The real-SDK test (Task 3) is tagged `integration`.
- **Boundaries (spec §5.1):**
  - `appstein_protocol` depends on nothing internal; `appstein_engine` only on `appstein_protocol`; `appstein_cli` on the engine and protocol.
  - The engine core never imports a pack.
  - `lib/src/index/` is engine core.
  - `layer_imports` enforces all this.
- **Docs and analysis:** every public API has a `///` doc comment (`public_member_api_docs`). These must pass from the repo root:
  - `fvm dart analyze --fatal-infos`;
  - `fvm dart format --output=none --set-exit-if-changed .`;
  - `fvm dart run dependency_validator`.
- **Byte order marks:** no raw U+FEFF byte in any `.dart` file. Nothing in this slice needs the BOM escape; never type it.
- **Windows is first-class:**
  - every file-system test uses `tempDir()` (`packages/appstein_engine/test/support/temp.dart`), whose path holds a space and a non-ASCII character;
  - generated text uses `\n` on every OS;
  - INDEX.md never contains a machine path. Paths are relative to the project or to `.appstein/`, with `/`.
- **Determinism (§15):** the same inputs give byte-identical `INDEX.md` on every OS. Lists are ordered as each task says. The body holds no timestamp; `generatedAt` is only in the front matter. The file is written by `KnowledgeStore.writeGeneratedMarkdown`, which rewrites it only when its bytes would change.
- **The budget (§6.3):** the whole file, front matter included, is at most `indexByteBudget` = 4,500 UTF-8 bytes. The cut order is current work, then decisions, then features down to 5 rows, then version notes down to 5. Project, rules, where things live and freshness are never cut.
- **Never guess (§6.5):** an ID that `native.json` doesn't hold as a plain value is written as `unknown; see map/native.json`.
- **No network in unit tests.**
- **Tests stay in temp folders.** Tests never write into the repo, `graphify-out/` or `.git/hooks`.
- **Commits:** subagents never commit. The controller commits each task after its review, with the session's trailer lines, behind the BOM byte scan: `LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test` must print nothing.
- **Subagents:** at most 3 running at once (owner rule). Never use `python -` stdin heredocs.

## Review Focus

These are the five inputs most likely to bite a user, though no single feature test covers them. Each one has a test in the task named.

1. **A project missing parts.** No name in `pubspec.yaml`, no platform folders, no stack pack, or a skipped map (a failed `pub get`). INDEX.md is still written, and each such part says plainly what is missing and why. *Tests: Task 1, Task 2, Task 3.*
2. **A very large project:**
   - hundreds of features;
   - 100 or more decisions;
   - a 300-line `current.md`;
   - nine Xcode configurations with different bundle ids.

   The file stays within 4,500 bytes, front matter included. Cuts follow §6.3's order and keep its floors whenever they fit. *Tests: Task 2 (renderer), Task 3 (whole file through sync).*
3. **Hand-written decision files that are odd:**
   - no front matter;
   - an unclosed one;
   - bad YAML;
   - a list instead of a map;
   - no title;
   - an unknown status;
   - CRLF line ends;
   - a multi-line or very long title;
   - a file name with a space;
   - unreadable files.

   Each is listed as unreadable with its reason, or read correctly. Nothing throws. *Test: Task 1.*
4. **Text that would break Markdown:**
   - `|` in a feature folder;
   - multi-line titles;
   - headings and blank lines inside `current.md`;
   - over-long lines.

   Each becomes one table row, one list line or one quoted line. *Tests: Task 1, Task 2.*
5. **Re-running sync.** A second sync changes no byte. Editing a decision or `current.md` rewrites only INDEX.md. A hand-edited INDEX.md is put back. *Test: Task 3.*

## Decisions made while planning (for the owner's review)

Every fact below was checked against the repo on 2026-10-02.

- **D1, the final form now (controller, under the owner's delegation).** The owner said: "No one is going to use this until I make the desktop application. So you decide." So INDEX.md names the MCP tools as §6.3 does (`where_is()`, `feature()`, `toolchain()`, `what_changed()`, …), although they arrive in slice 1c. It also reads decisions and current work from their files, whose formats §6.7–6.8 already fix. Cost if wrong: an agent that reads INDEX.md before 1c finds no such tools. Nobody uses it before then.
- **D2, the budget counts the front matter.** §6.3 measures "the file's UTF-8 bytes". `indexBodyBudget(meta)` is 4,500 minus the front matter's bytes. `KnowledgeSync` computes the front matter with the real versions and input hash, and with a stand-in `generatedAt` (every `generatedAt` has the same length).
- **D3, version notes show the summary only.** A curated `use:` line reaches 328 bytes and a summary 264, so ten notes with both could take 6 KB. INDEX.md shows `- **id** (priority N): summary`; `delta.md` and `what_changed()` have the rest. Notes that need a newer language version are left out, as `delta.md` lists them apart. `needsNewerLanguage` becomes public in `delta_document.dart` for this.
- **D4, main files.** A feature's screens' files, then its view models' files, relative to the feature's folder. When it has neither, its files. At most two are shown, then `…`.
- **D5, IDs.**
  - **Android:** the `applicationId` from `android.app` (`defaultConfig`). When flavors exist, the line says how many may change it.
  - **iOS:** each Xcode configuration's `bundleIdentifier` from `project.pbxproj`, because `Info.plist` holds only `$(PRODUCT_BUNDLE_IDENTIFIER)`. When they are all the same, there is one id; otherwise `Debug \`a\`, Release \`b\``, sorted by configuration name.
  - **Unknown:** a value that isn't `found`, or that contains `$(` (an Xcode build variable), makes the line `unknown; see \`map/native.json\``.
  - **Missing platform:** a platform whose folder is missing (an `absent` section) has no line.
- **D6, decisions.**
  - **Which files:** `.appstein/decisions/*.md`, in file-name order.
  - **The number:** taken from the file name (`0002-…`). YAML reads `id: 0002` as the number 2, so the front matter's `id` isn't used.
  - **What is listed:** accepted and proposed decisions. Superseded ones are left out. A file whose front matter can't be read is listed as unreadable, with the reason.
  - **Links:** each line links with `[file](<decisions/file>)`. The angle brackets keep a file name with spaces a valid Markdown link.
  - **When cut:** the newest (last) decisions are kept.
- **D7, current work** is shown as a quote (`> line`), so a heading in `current.md` can't become an INDEX.md section. Blank lines at the start and end are dropped, and each line is cut to 160 characters.
- **D8, a last resort past §6.3's floors.** Only if the text still doesn't fit with 5 features and 5 notes are features, then notes, cut below 5, with their pointers left. That takes a project no real app resembles; the large-project test in Task 2 stays above the floors. If even that doesn't fit, INDEX.md is written anyway: a sync never fails over INDEX.md's size.
- **D9, the input hash** covers:
  - the input hash of every other file the sync writes (`sdk.json`, `toolchain.json`, `delta.md`, the map files, `native.json`);
  - the bytes of `pubspec.yaml`, each decision file and `memory/current.md`;
  - the platform folder list;
  - the packs' ids and versions.

  `delta.md`'s hash already covers the notes, the baseline, the language version and the map's skip reason.
- **D10, no sync-level golden.** The renderer's exact text is pinned by a unit test with fixed inputs. The sync test checks the real lines. A golden built from the bundled notes would change with every owner-reviewed note edit.
- **D11, platforms are the folders Flutter checks:** `android/`, `ios/`, `linux/`, `macos/`, `web/` and `windows/`, in that order, when they exist as folders.
- **D12, rules wording.** The four rules follow §6.3 and §14:
  - ask the MCP tools before searching;
  - run `verify()` before saying done;
  - never upgrade native toolchain versions yourself, ask `toolchain()`;
  - dependencies in one line.

---

## File map

| File | Responsibility |
|---|---|
| `packages/appstein_engine/lib/src/index/index_sources.dart` | `platformFolderNames`, `IndexFeature`, `IndexDecision`, `DeltaCounts`, `IndexSources`, `readIndexSources`, `projectNameOf`, `platformFolders`, `appIdLines`, `indexFeatures`, `decisionNumber`, `parseDecision`, `currentWorkLines` |
| `packages/appstein_engine/lib/src/index/index_document.dart` | `indexPath`, `indexByteBudget`, `IndexInputs`, `indexBodyBudget`, `renderIndex` |
| `packages/appstein_engine/lib/src/delta/delta_document.dart` | `_needsNewerLanguage` becomes the public `needsNewerLanguage` |
| `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart` | builds and writes `INDEX.md` |
| `packages/appstein_engine/lib/appstein_engine.dart` | exports the two new files |
| `packages/appstein_engine/test/index/index_sources_test.dart` | Task 1's tests |
| `packages/appstein_engine/test/index/index_document_test.dart` | Task 2's tests |
| `packages/appstein_engine/test/delta/delta_document_test.dart` | + a `needsNewerLanguage` test |
| `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart` | file lists gain `INDEX.md`; + an `INDEX.md` group |
| `packages/appstein_engine/test/integration/map_real_sdk_test.dart` | + INDEX.md checks on the real SDK |
| `packages/appstein_cli/test/sync_command_test.dart` | + the `INDEX.md` row |
| `docs/guide/index-md.md` | New guide page |
| `docs/guide/knowledge-store.md`, `docs/guide/version-delta.md`, `docs/guide/README.md` | Updated for INDEX.md |

---

### Task 1: What INDEX.md reads from the project

**Files:**
- Create: `packages/appstein_engine/lib/src/index/index_sources.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (export it)
- Test: `packages/appstein_engine/test/index/index_sources_test.dart`

**Interfaces:**
- Consumes:
  - `NativeConfig`, `NativeNode`, `NativeValue`, `NativeGroup`, `NativeList`, `NativeEntry`, `NativeStatus`, `FeaturesMap`, `Feature` and `CodeRef` (protocol);
  - `DeltaFacts`, `MigrationStatus` (`lib/src/delta/delta_facts.dart`);
  - `fileErrorReason` (`lib/src/host/file_errors.dart`).
- Produces (Task 2 and Task 3 rely on these exact names):
  - `const List<String> platformFolderNames`
  - `final class IndexFeature({required String name, required String folder, required int screens, required List<String> mainFiles})`
  - `final class IndexDecision({required String file, String? id, required String title, required String status})` and `IndexDecision.unreadable({required String file, String? id, required String problem})`. Fields: `file`, `id`, `title`, `status`, `problem`.
  - `final class DeltaCounts({required int deprecated, required int removed, required int changed, required int moved})` and `factory DeltaCounts.of(DeltaFacts facts)`
  - `final class IndexSources`, with fields `projectName` (`String?`), `platforms` (`List<String>`), `decisions` (`List<IndexDecision>`), `decisionsError` (`String?`), `currentWork` (`List<String>`), `currentWorkError` (`String?`) and `inputs` (`Map<String, List<int>?>`)
  - `IndexSources readIndexSources(String projectRoot)`
  - `String? projectNameOf(List<int>? pubspec)`
  - `List<String> platformFolders(String projectRoot)`
  - `List<String> appIdLines(NativeConfig? native)`
  - `List<IndexFeature> indexFeatures(FeaturesMap map)`
  - `String? decisionNumber(String file)`
  - `IndexDecision parseDecision(String file, String text)`
  - `List<String> currentWorkLines(String text)`

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/index/index_sources_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/temp.dart';

void main() {
  group('projectNameOf', () {
    test('reads the name from pubspec.yaml', () {
      expect(
        projectNameOf(utf8.encode('name: my_app\nversion: 1.0.0\n')),
        'my_app',
      );
    });

    test('is null for a missing, invalid or nameless pubspec', () {
      expect(projectNameOf(null), isNull);
      expect(projectNameOf(utf8.encode('name: [unclosed\n')), isNull);
      expect(projectNameOf(utf8.encode('- a list\n')), isNull);
      expect(projectNameOf(utf8.encode('name: 42\n')), isNull);
      expect(projectNameOf(utf8.encode('version: 1.0.0\n')), isNull);
      expect(projectNameOf(const [0xff, 0xfe]), isNull);
    });
  });

  test('platformFolders lists the platform folders that exist, in a fixed '
      'order', () {
    final root = tempDir().path;
    for (final name in ['windows', 'android', 'web', 'lib']) {
      Directory(p.join(root, name)).createSync();
    }
    // A file named like a platform is not a platform folder.
    File(p.join(root, 'ios')).writeAsStringSync('not a folder');
    expect(platformFolders(root), ['android', 'web', 'windows']);
  });

  group('appIdLines', () {
    NativeValue found(Object value) => NativeValue.found(value, at: 'x:1');

    NativeConfig config({NativeNode? android, NativeNode? ios}) =>
        NativeConfig({
          if (android != null) 'android': android,
          if (ios != null) 'ios': ios,
        });

    NativeGroup android(NativeNode applicationId, {List<String> flavors = const []}) =>
        NativeGroup({
          'app': NativeGroup({
            'applicationId': applicationId,
            'flavors': NativeList([
              for (final name in flavors) NativeEntry(name, const {}),
            ]),
          }),
        });

    NativeGroup ios(Map<String, NativeNode> bundleIds) => NativeGroup({
      'xcode': NativeGroup({
        'configurations': NativeList([
          for (final MapEntry(:key, :value) in bundleIds.entries)
            NativeEntry(key, {'bundleIdentifier': value}),
        ]),
      }),
    });

    test('a found applicationId, and one bundle id when every '
        'configuration has the same', () {
      expect(
        appIdLines(
          config(
            android: android(found('dev.sample.probe_app')),
            ios: ios({
              'Debug': found('dev.sample.probeApp'),
              'Profile': found('dev.sample.probeApp'),
              'Release': found('dev.sample.probeApp'),
            }),
          ),
        ),
        [
          'Android applicationId: `dev.sample.probe_app`',
          'iOS bundle id: `dev.sample.probeApp`',
        ],
      );
    });

    test('bundle ids that differ are listed per configuration, by name', () {
      expect(
        appIdLines(
          config(
            ios: ios({
              'Release': found('com.example.app'),
              'Debug': found('com.example.app.dev'),
            }),
          ),
        ),
        ['iOS bundle id: Debug `com.example.app.dev`, Release `com.example.app`'],
      );
    });

    test('flavors are counted, since they may change the id', () {
      expect(
        appIdLines(
          config(android: android(found('com.a'), flavors: ['dev', 'prod'])),
        ),
        [
          'Android applicationId: `com.a` (2 flavors may change it; see '
              '`map/native.json`)',
        ],
      );
      expect(
        appIdLines(
          config(android: android(found('com.a'), flavors: ['dev'])),
        ).single,
        contains('(1 flavor may change it;'),
      );
    });

    test('an id that is unknown, absent or uses Xcode variables is '
        'unknown, never guessed', () {
      expect(
        appIdLines(
          config(
            android: android(const NativeValue.unknown('set more than once')),
            ios: ios({
              'Debug': found(r'$(PRODUCT_BUNDLE_IDENTIFIER)'),
              'Release': found('com.example.app'),
            }),
          ),
        ),
        [
          'Android applicationId: unknown; see `map/native.json`',
          'iOS bundle id: unknown; see `map/native.json`',
        ],
      );
      expect(
        appIdLines(
          config(android: android(const NativeValue.absent('not set'))),
        ).single,
        'Android applicationId: unknown; see `map/native.json`',
      );
      expect(
        appIdLines(
          config(
            ios: NativeGroup({
              'xcode': NativeGroup({
                'configurations': const NativeValue.unknown('unreadable'),
              }),
            }),
          ),
        ).single,
        'iOS bundle id: unknown; see `map/native.json`',
      );
    });

    test('a platform without its folder has no line; a failed pack says '
        'unknown', () {
      expect(
        appIdLines(
          config(
            android: const NativeValue.absent('no android/ folder'),
            ios: const NativeValue.error('StateError'),
          ),
        ),
        ['iOS bundle id: unknown; see `map/native.json`'],
      );
      expect(appIdLines(null), isEmpty);
    });
  });

  group('indexFeatures', () {
    test('most screens first, then by name; main files are the screens\' '
        'then the view models\', relative to the folder', () {
      final rows = indexFeatures(
        FeaturesMap.fromJson(
          jsonDecode(goldenText('features.json')) as Map<String, Object?>,
        ),
      );
      expect([for (final row in rows) row.name], [
        'auth/login',
        'booking',
        'home',
        'profile',
        'settings',
      ]);
      final home = rows.firstWhere((row) => row.name == 'home');
      expect(home.folder, 'lib/ui/home');
      expect(home.screens, 1);
      expect(home.mainFiles, [
        'widgets/home_screen.dart',
        'view_models/home_viewmodel.dart',
      ]);
    });

    test('a feature with more screens comes first; one with no screens or '
        'view models lists its files', () {
      Feature feature(
        String folder, {
        List<CodeRef> screens = const [],
        List<String> files = const [],
      }) => Feature(
        folder: folder,
        viewModels: const [],
        screens: screens,
        repositories: const [],
        services: const [],
        models: const [],
        tests: const [],
        files: files,
      );
      final rows = indexFeatures(
        FeaturesMap(
          features: {
            'a': feature('lib/ui/a', files: ['lib/ui/a/widgets/a_panel.dart']),
            'z': feature(
              'lib/ui/z',
              screens: const [
                CodeRef(name: 'Z1', file: 'lib/ui/z/widgets/z1.dart'),
                CodeRef(name: 'Z2', file: 'lib/ui/z/widgets/z2.dart'),
              ],
            ),
          },
        ),
      );
      expect([for (final row in rows) row.name], ['z', 'a']);
      expect(rows.first.screens, 2);
      expect(rows.first.mainFiles, ['widgets/z1.dart', 'widgets/z2.dart']);
      expect(rows.last.mainFiles, ['widgets/a_panel.dart']);
    });
  });

  group('parseDecision', () {
    test('reads the title and status, and the number from the file name', () {
      final decision = parseDecision(
        '0002-state.md',
        '---\nid: 0002\ntitle: State management with provider + '
            'ChangeNotifier\nstatus: accepted\ndate: 2026-10-02\n---\n'
            'Why: Flutter recommends it.\n',
      );
      expect(decision.id, '0002');
      expect(
        decision.title,
        'State management with provider + ChangeNotifier',
      );
      expect(decision.status, 'accepted');
      expect(decision.problem, isNull);
      expect(decisionNumber('notes.md'), isNull);
    });

    test('CRLF line ends and a multi-line title are read; the title becomes '
        'one line', () {
      final decision = parseDecision(
        '0003-x.md',
        '---\r\ntitle: |\r\n  Two\r\n  lines\r\nstatus: proposed\r\n---\r\n',
      );
      expect(decision.title, 'Two lines');
      expect(decision.status, 'proposed');
    });

    test('a very long title is shortened to 120 characters', () {
      final decision = parseDecision(
        '0004-x.md',
        '---\ntitle: ${'word ' * 60}\nstatus: accepted\n---\n',
      );
      expect(decision.title!.runes.length, 120);
      expect(decision.title, endsWith('…'));
    });

    for (final (text, problem) in [
      ('Just text.\n', 'it has no front matter'),
      (
        '---\ntitle: x\nstatus: accepted\n',
        'its front matter has no closing ---',
      ),
      ('---\ntitle: [unclosed\n---\n', 'its front matter is not valid YAML'),
      ('---\n- a\n---\n', 'its front matter is not a map'),
      ('---\nstatus: accepted\n---\n', 'it has no title'),
      (
        '---\ntitle: x\nstatus: done\n---\n',
        'its status is not accepted, proposed or superseded',
      ),
    ]) {
      test('unreadable: $problem', () {
        final decision = parseDecision('0005-x.md', text);
        expect(decision.problem, problem);
        expect(decision.id, '0005');
        expect(decision.title, isNull);
        expect(decision.status, isNull);
      });
    }
  });

  test('currentWorkLines drops blank lines at the ends and trailing spaces, '
      'and cuts long lines to 160 characters', () {
    expect(
      currentWorkLines('\n\n# Goal\r\n\r\nShip it.   \n${'x' * 200}\n\n'),
      ['# Goal', '', 'Ship it.', '${'x' * 159}…'],
    );
    expect(currentWorkLines('  \n\n'), isEmpty);
  });

  group('readIndexSources', () {
    late String root;

    setUp(() {
      root = tempDir().path;
      File(p.join(root, 'pubspec.yaml')).writeAsStringSync('name: my_app\n');
    });

    void write(String path, String text) =>
        File(p.joinAll([root, ...path.split('/')]))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text);

    test('a new project: its name, no decisions, no current work', () {
      final sources = readIndexSources(root);
      expect(sources.projectName, 'my_app');
      expect(sources.platforms, isEmpty);
      expect(sources.decisions, isEmpty);
      expect(sources.decisionsError, isNull);
      expect(sources.currentWork, isEmpty);
      expect(sources.currentWorkError, isNull);
      expect(
        sources.inputs.keys,
        unorderedEquals(['pubspec.yaml', 'platforms']),
      );
    });

    test('decisions are read in file-name order; superseded ones and other '
        'files are left out, but every .md file is hashed', () {
      write('.appstein/decisions/0002-b.md', '---\ntitle: B\nstatus: proposed\n---\n');
      write('.appstein/decisions/0001-a.md', '---\ntitle: A\nstatus: accepted\n---\n');
      write(
        '.appstein/decisions/0003-old.md',
        '---\ntitle: Old\nstatus: superseded\n---\n',
      );
      write('.appstein/decisions/0004 with space.md', 'no front matter\n');
      write('.appstein/decisions/notes.txt', 'ignored');
      final sources = readIndexSources(root);
      expect([for (final decision in sources.decisions) decision.file], [
        '0001-a.md',
        '0002-b.md',
        '0004 with space.md',
      ]);
      expect(sources.decisions.last.problem, 'it has no front matter');
      expect(
        sources.inputs.keys,
        containsAll([
          'decisions/0001-a.md',
          'decisions/0002-b.md',
          'decisions/0003-old.md',
          'decisions/0004 with space.md',
        ]),
      );
      expect(sources.inputs.keys, isNot(contains('decisions/notes.txt')));
    });

    test('current work is read and hashed', () {
      write('.appstein/memory/current.md', '\n# Goal\n\nShip it.\n');
      final sources = readIndexSources(root);
      expect(sources.currentWork, ['# Goal', '', 'Ship it.']);
      expect(sources.inputs.keys, contains('memory/current.md'));
    });

    test('an unreadable decisions folder or current.md is reported, not '
        'thrown', () {
      write('.appstein/decisions/0001-a.md', '---\ntitle: A\nstatus: accepted\n---\n');
      write('.appstein/memory/current.md', 'Goal\n');
      final decisions = p.join(root, '.appstein', 'decisions');
      final current = p.join(root, '.appstein', 'memory', 'current.md');
      Process.runSync('chmod', ['000', decisions, current]);
      addTearDown(() => Process.runSync('chmod', ['755', decisions, current]));
      final sources = readIndexSources(root);
      expect(sources.decisions, isEmpty);
      expect(sources.decisionsError, isNotEmpty);
      expect(sources.currentWork, isEmpty);
      expect(sources.currentWorkError, isNotEmpty);
    },
        skip: Platform.isWindows
            ? 'chmod does not exist on Windows'
            : Platform.environment['USER'] == 'root'
            ? 'root reads files whatever their mode'
            : false);
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `fvm dart test packages/appstein_engine/test/index/index_sources_test.dart`
Expected: compilation errors, because `projectNameOf`, `platformFolders`, `appIdLines` and the others don't exist yet.

- [ ] **Step 3: Write `index_sources.dart`**

Create `packages/appstein_engine/lib/src/index/index_sources.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../delta/delta_facts.dart';
import '../host/file_errors.dart';

/// The platform folders a Flutter project can have, in the order `INDEX.md`
/// lists them. Flutter decides which platforms a project has by which of
/// these folders exist.
const platformFolderNames = [
  'android',
  'ios',
  'linux',
  'macos',
  'web',
  'windows',
];

/// One row of `INDEX.md`'s features table (spec §6.3).
final class IndexFeature {
  /// Creates the row.
  const IndexFeature({
    required this.name,
    required this.folder,
    required this.screens,
    required this.mainFiles,
  });

  /// The feature's name, such as `auth/login`.
  final String name;

  /// Its folder, such as `lib/ui/auth/login`.
  final String folder;

  /// How many screens it has.
  final int screens;

  /// Its main files, relative to [folder]: the screens' files, then the view
  /// models' files; its files when it has neither.
  final List<String> mainFiles;
}

/// One decision file `INDEX.md` reads (spec §6.3, §6.7).
final class IndexDecision {
  /// A decision whose front matter was read.
  const IndexDecision({
    required this.file,
    this.id,
    required String this.title,
    required String this.status,
  }) : problem = null;

  /// A decision file whose front matter can't be read, and why.
  const IndexDecision.unreadable({
    required this.file,
    this.id,
    required String this.problem,
  }) : title = null,
       status = null;

  /// Its file name inside `.appstein/decisions/`, such as `0002-state.md`.
  final String file;

  /// The number its file name starts with, such as `0002`; null when it
  /// doesn't start with one.
  final String? id;

  /// Its title, on one line; null when it can't be read.
  final String? title;

  /// `accepted`, `proposed` or `superseded`; null when it can't be read.
  final String? status;

  /// Why it can't be read; null when it was read.
  final String? problem;
}

/// How many APIs `delta.md` lists besides its notes.
final class DeltaCounts {
  /// Creates the counts.
  const DeltaCounts({
    required this.deprecated,
    required this.removed,
    required this.changed,
    required this.moved,
  });

  /// Counts what [facts] holds.
  factory DeltaCounts.of(DeltaFacts facts) => DeltaCounts(
    deprecated: facts.deprecated.length,
    removed: facts.migrated
        .where((api) => api.status == MigrationStatus.removed)
        .length,
    changed: facts.migrated
        .where((api) => api.status == MigrationStatus.changed)
        .length,
    moved: facts.moved.length,
  );

  /// Deprecated APIs.
  final int deprecated;

  /// Removed APIs.
  final int removed;

  /// Changed APIs.
  final int changed;

  /// Moved libraries.
  final int moved;
}

/// What `INDEX.md` reads from the project itself.
final class IndexSources {
  /// Creates the sources.
  const IndexSources({
    required this.projectName,
    required this.platforms,
    required this.decisions,
    required this.decisionsError,
    required this.currentWork,
    required this.currentWorkError,
    required this.inputs,
  });

  /// The name in `pubspec.yaml`; null when it can't be read.
  final String? projectName;

  /// The platform folders that exist ([platformFolders]).
  final List<String> platforms;

  /// The accepted and proposed decisions, and the unreadable decision
  /// files, in file-name order. Superseded decisions are left out.
  final List<IndexDecision> decisions;

  /// Why `.appstein/decisions/` couldn't be listed; null otherwise.
  final String? decisionsError;

  /// The lines of `memory/current.md` ([currentWorkLines]); empty when it
  /// doesn't exist.
  final List<String> currentWork;

  /// Why `memory/current.md` couldn't be read; null otherwise.
  final String? currentWorkError;

  /// What `INDEX.md`'s input hash covers from the project: `pubspec.yaml`,
  /// the platform list, each decision file and `memory/current.md`, by
  /// name.
  final Map<String, List<int>?> inputs;
}

/// Reads what `INDEX.md` needs from the project at [projectRoot]: its name,
/// its platform folders, the decision files in `.appstein/decisions/` and
/// `.appstein/memory/current.md` (spec §6.3).
///
/// It never throws for the project's own files: a file or folder that
/// can't be read is reported in [IndexSources.decisionsError],
/// [IndexSources.currentWorkError] or [IndexDecision.problem].
IndexSources readIndexSources(String projectRoot) {
  final pubspec = _bytes(p.join(projectRoot, 'pubspec.yaml'));
  final platforms = platformFolders(projectRoot);
  final inputs = <String, List<int>?>{
    'pubspec.yaml': pubspec,
    'platforms': utf8.encode(platforms.join(',')),
  };

  final decisions = <IndexDecision>[];
  String? decisionsError;
  final folder = Directory(p.join(projectRoot, '.appstein', 'decisions'));
  if (folder.existsSync()) {
    try {
      final files = [
        for (final entity in folder.listSync(followLinks: false))
          if (entity is File && entity.path.endsWith('.md')) entity,
      ]..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final file in files) {
        final name = p.basename(file.path);
        try {
          final bytes = file.readAsBytesSync();
          inputs['decisions/$name'] = bytes;
          final decision = parseDecision(
            name,
            utf8.decode(bytes, allowMalformed: true),
          );
          if (decision.status != 'superseded') decisions.add(decision);
        } on FileSystemException catch (error) {
          final reason = fileErrorReason(error);
          inputs['decisions/$name'] = utf8.encode('unreadable: $reason');
          decisions.add(
            IndexDecision.unreadable(
              file: name,
              id: decisionNumber(name),
              problem: reason,
            ),
          );
        }
      }
    } on FileSystemException catch (error) {
      decisionsError = fileErrorReason(error);
      inputs['decisions'] = utf8.encode('unreadable: $decisionsError');
      decisions.clear();
    }
  }

  var currentWork = const <String>[];
  String? currentWorkError;
  final current = File(
    p.join(projectRoot, '.appstein', 'memory', 'current.md'),
  );
  if (current.existsSync()) {
    try {
      final bytes = current.readAsBytesSync();
      inputs['memory/current.md'] = bytes;
      currentWork = currentWorkLines(utf8.decode(bytes, allowMalformed: true));
    } on FileSystemException catch (error) {
      currentWorkError = fileErrorReason(error);
      inputs['memory/current.md'] = utf8.encode(
        'unreadable: $currentWorkError',
      );
    }
  }

  return IndexSources(
    projectName: projectNameOf(pubspec),
    platforms: platforms,
    decisions: decisions,
    decisionsError: decisionsError,
    currentWork: currentWork,
    currentWorkError: currentWorkError,
    inputs: inputs,
  );
}

/// The `name:` in the bytes of a `pubspec.yaml`, or null when there are no
/// bytes, they aren't valid UTF-8 or YAML, or the name isn't a string.
String? projectNameOf(List<int>? pubspec) {
  if (pubspec == null) return null;
  try {
    final yaml = loadYaml(utf8.decode(pubspec));
    if (yaml is! Map) return null;
    final name = yaml['name'];
    return name is String && name.trim().isNotEmpty ? name.trim() : null;
  } on FormatException {
    // YamlException is a FormatException too.
    return null;
  }
}

/// The platform folders of the project at [projectRoot], from
/// [platformFolderNames], in that order.
List<String> platformFolders(String projectRoot) => [
  for (final name in platformFolderNames)
    if (Directory(p.join(projectRoot, name)).existsSync()) name,
];

const _seeNative = 'see `map/native.json`';

/// The app and bundle id lines of `INDEX.md` (spec §6.3) from [native]:
/// the Android `applicationId` and the iOS bundle id, each only when its
/// platform folder exists. An id that isn't a plain found value is
/// `unknown`, never guessed.
List<String> appIdLines(NativeConfig? native) {
  if (native == null) return const [];
  return [?_androidId(native), ?_iosId(native)];
}

String? _androidId(NativeConfig native) {
  const label = 'Android applicationId';
  final section = native.sections['android'];
  if (section == null) return null;
  if (section is NativeValue) {
    return section.status == NativeStatus.absent
        ? null
        : '$label: unknown; $_seeNative';
  }
  final id = _plainId(native.lookup(['android', 'app', 'applicationId']));
  if (id == null) return '$label: unknown; $_seeNative';
  final flavors = native.lookup(['android', 'app', 'flavors']);
  final count = flavors is NativeList ? flavors.entries.length : 0;
  if (count == 0) return '$label: `$id`';
  final noun = count == 1 ? '1 flavor' : '$count flavors';
  return '$label: `$id` ($noun may change it; $_seeNative)';
}

String? _iosId(NativeConfig native) {
  const label = 'iOS bundle id';
  final section = native.sections['ios'];
  if (section == null) return null;
  if (section is NativeValue) {
    return section.status == NativeStatus.absent
        ? null
        : '$label: unknown; $_seeNative';
  }
  final configurations = native.lookup(['ios', 'xcode', 'configurations']);
  if (configurations is! NativeList || configurations.entries.isEmpty) {
    return '$label: unknown; $_seeNative';
  }
  // NativeList keeps its entries sorted by name.
  final ids = <String, String>{};
  for (final entry in configurations.entries) {
    final id = _plainId(entry.children['bundleIdentifier']);
    if (id == null) return '$label: unknown; $_seeNative';
    ids[entry.name] = id;
  }
  final distinct = ids.values.toSet();
  if (distinct.length == 1) return '$label: `${distinct.single}`';
  return '$label: '
      '${[for (final MapEntry(:key, :value) in ids.entries) '$key `$value`'].join(', ')}';
}

/// [node]'s value when it is a found, non-empty string with no Xcode build
/// variable (`$(…)`) in it; null otherwise.
String? _plainId(NativeNode? node) => switch (node) {
  NativeValue(status: NativeStatus.found, value: final String value)
      when value.isNotEmpty && !value.contains(r'$(') =>
    value,
  _ => null,
};

/// The rows of `INDEX.md`'s features table: most screens first, then by
/// name.
List<IndexFeature> indexFeatures(FeaturesMap map) {
  final rows = [
    for (final MapEntry(key: name, value: feature) in map.features.entries)
      IndexFeature(
        name: name,
        folder: feature.folder,
        screens: feature.screens.length,
        mainFiles: _mainFiles(feature),
      ),
  ];
  rows.sort((a, b) {
    final byScreens = b.screens.compareTo(a.screens);
    return byScreens != 0 ? byScreens : a.name.compareTo(b.name);
  });
  return rows;
}

List<String> _mainFiles(Feature feature) {
  final main = <String>{
    for (final ref in feature.screens) ref.file,
    for (final ref in feature.viewModels) ref.file,
  };
  final chosen = main.isEmpty ? feature.files : main.toList();
  return [
    for (final file in chosen)
      p.posix.isWithin(feature.folder, file)
          ? p.posix.relative(file, from: feature.folder)
          : file,
  ];
}

/// The number a decision file's name starts with, such as `0002` in
/// `0002-state.md`; null when it doesn't start with digits and `-`.
String? decisionNumber(String file) =>
    RegExp(r'^(\d+)-').firstMatch(file)?.group(1);

/// Reads the front matter of the decision file [file] whose text is [text]
/// (spec §6.7): its title and status. Anything that keeps them from being
/// read gives an [IndexDecision.unreadable] that says why.
IndexDecision parseDecision(String file, String text) {
  final id = decisionNumber(file);
  IndexDecision unreadable(String problem) =>
      IndexDecision.unreadable(file: file, id: id, problem: problem);

  final lines = const LineSplitter().convert(text);
  if (lines.isEmpty || lines.first.trimRight() != '---') {
    return unreadable('it has no front matter');
  }
  final end = lines.indexWhere((line) => line.trimRight() == '---', 1);
  if (end < 0) return unreadable('its front matter has no closing ---');
  final Object? yaml;
  try {
    yaml = loadYaml(lines.sublist(1, end).join('\n'));
  } on FormatException {
    return unreadable('its front matter is not valid YAML');
  }
  if (yaml is! Map) return unreadable('its front matter is not a map');
  final title = yaml['title'];
  if (title == null || '$title'.trim().isEmpty) {
    return unreadable('it has no title');
  }
  final status = yaml['status'];
  if (status is! String ||
      !const ['accepted', 'proposed', 'superseded'].contains(status)) {
    return unreadable('its status is not accepted, proposed or superseded');
  }
  return IndexDecision(
    file: file,
    id: id,
    title: _cap(_oneLine('$title'), 120),
    status: status,
  );
}

/// The lines of a `memory/current.md` [text]: any line break, trailing
/// white space dropped, blank lines at the start and the end dropped, and
/// each line at most 160 characters.
List<String> currentWorkLines(String text) {
  final lines = [
    for (final line in const LineSplitter().convert(text))
      _cap(line.trimRight(), 160),
  ];
  while (lines.isNotEmpty && lines.first.isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

/// [text] with each run of white space as one space.
String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// [text], or its first [max] - 1 characters and `…` when it is longer. It
/// counts runes, so a character outside the Basic Multilingual Plane is
/// never split.
String _cap(String text, int max) {
  final runes = text.runes.toList();
  if (runes.length <= max) return text;
  return '${String.fromCharCodes(runes.take(max - 1)).trimRight()}…';
}

List<int>? _bytes(String path) {
  try {
    return File(path).readAsBytesSync();
  } on FileSystemException {
    return null;
  }
}
```

In `packages/appstein_engine/lib/appstein_engine.dart`, add after `export 'src/host/process_runner.dart';`:

```dart
export 'src/index/index_sources.dart';
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `fvm dart test packages/appstein_engine/test/index/index_sources_test.dart`
Expected: all pass. On Windows, the chmod test reports as skipped.

Then run `fvm dart analyze --fatal-infos` and `fvm dart format --output=none --set-exit-if-changed .` from the repo root. Both must be clean. Run `fvm dart format` on the two new files if the second complains.

- [ ] **Step 5: Report for commit**

The controller commits with the message `feat: what INDEX.md reads from the project (names, platforms, ids, decisions, current work)`. The post-commit hook warns that `lib/src/index/` has no guide page yet; Task 4 adds it.

---

### Task 2: The INDEX.md renderer and its budget

**Files:**
- Create: `packages/appstein_engine/lib/src/index/index_document.dart`
- Modify: `packages/appstein_engine/lib/src/delta/delta_document.dart` (`_needsNewerLanguage` → `needsNewerLanguage`)
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (export it)
- Test: `packages/appstein_engine/test/index/index_document_test.dart`
- Test: `packages/appstein_engine/test/delta/delta_document_test.dart`

**Interfaces:**
- Consumes:
  - Task 1's `IndexFeature`, `IndexDecision`, `DeltaCounts` and `platformFolderNames`;
  - `SdkInfo`, `NotesCoverage`, `CuratedNote` and `KnowledgeMeta` (protocol);
  - `markdownWithFrontMatter` (`lib/src/knowledge/markdown_front_matter.dart`);
  - `flutterMinorOf` (`lib/src/notes/flutter_minor.dart`).
- Produces (Task 3 relies on these):
  - `const indexPath = 'INDEX.md'`
  - `const indexByteBudget = 4500`
  - `final class IndexInputs({required String? projectName, required SdkInfo sdk, required String appsteinVersion, required String newestNotes, required String? stackPack, required List<String> platforms, required List<String> appIds, required List<IndexFeature>? features, String? featuresMissing, required Map<String, List<String>>? layers, required List<CuratedNote> notes, required DeltaCounts? apiCounts, List<IndexDecision> decisions = const [], String? decisionsError, List<String> currentWork = const [], String? currentWorkError})`
  - `int indexBodyBudget(KnowledgeMeta meta)`
  - `String renderIndex(IndexInputs inputs, {required int byteBudget})`
  - `bool needsNewerLanguage(CuratedNote note, String? languageVersion)` (in `delta_document.dart`)

- [ ] **Step 1: Write the failing tests**

Add to `packages/appstein_engine/test/delta/delta_document_test.dart`, inside `main()` after the `const` notes:

```dart
  test('needsNewerLanguage: a note for a newer language version than the '
      "project's", () {
    expect(needsNewerLanguage(primaryConstructors, '3.12'), isTrue);
    expect(needsNewerLanguage(primaryConstructors, '3.13'), isFalse);
    expect(needsNewerLanguage(popScope, '3.12'), isFalse);
    expect(needsNewerLanguage(primaryConstructors, null), isFalse);
  });
```

Create `packages/appstein_engine/test/index/index_document_test.dart`:

```dart
import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  const sdk = SdkInfo(
    flutterVersion: '3.47.5',
    dartVersion: '3.13.4',
    channel: 'stable',
    languageVersion: '3.12',
    notesCoverage: NotesCoverage.complete,
  );
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
  const headings = [
    '## Project',
    '## Rules',
    '## Features',
    '## Where things live',
    '## Version notes',
    '## Decisions',
    '## Current work',
    '## Freshness',
  ];

  IndexInputs small({
    List<IndexFeature> features = const [
      IndexFeature(
        name: 'booking',
        folder: 'lib/ui/booking',
        screens: 1,
        mainFiles: [
          'widgets/booking_screen.dart',
          'view_models/booking_viewmodel.dart',
        ],
      ),
      IndexFeature(
        name: 'profile',
        folder: 'lib/ui/profile',
        screens: 1,
        mainFiles: ['widgets/profile_screen.dart'],
      ),
    ],
    List<IndexDecision> decisions = const [
      IndexDecision(
        file: '0002-state.md',
        id: '0002',
        title: 'State management with provider + ChangeNotifier',
        status: 'accepted',
      ),
    ],
    List<String> currentWork = const [
      '# Add booking export',
      '',
      'Status: tests written.',
    ],
  }) => IndexInputs(
    projectName: 'fixture_app',
    sdk: sdk,
    appsteinVersion: '0.1.0-dev',
    newestNotes: '3.47',
    stackPack: 'official_mvvm',
    platforms: const ['android', 'ios'],
    appIds: const [
      'Android applicationId: `dev.sample.probe_app`',
      'iOS bundle id: `dev.sample.probeApp`',
    ],
    features: features,
    layers: const {
      'ui': ['lib/ui/**'],
      'domain': ['lib/domain/**'],
    },
    notes: const [popScope],
    apiCounts: const DeltaCounts(
      deprecated: 4,
      removed: 3,
      changed: 0,
      moved: 1,
    ),
    decisions: decisions,
    currentWork: currentWork,
  );

  final bundledNotes = CuratedNotes.bundled().notesFor('3.47.5');

  IndexInputs large() => IndexInputs(
    projectName: 'a_very_large_app',
    sdk: sdk,
    appsteinVersion: '0.1.0-dev',
    newestNotes: '3.47',
    stackPack: 'official_mvvm',
    platforms: platformFolderNames,
    appIds: [
      'Android applicationId: `com.example.a_very_large_app` (12 flavors may '
          'change it; see `map/native.json`)',
      'iOS bundle id: '
          '${[for (var i = 0; i < 9; i++) 'Config$i `com.example.app.flavor$i`'].join(', ')}',
    ],
    features: [
      for (var i = 0; i < 300; i++)
        IndexFeature(
          name: 'feature_$i',
          folder: 'lib/ui/feature_$i',
          screens: 300 - i,
          mainFiles: [
            'widgets/screen_$i.dart',
            'view_models/view_model_$i.dart',
            'widgets/panel_$i.dart',
          ],
        ),
    ],
    layers: const OfficialMvvmPack().layerRules!.layers,
    notes: bundledNotes,
    apiCounts: const DeltaCounts(
      deprecated: 512,
      removed: 300,
      changed: 40,
      moved: 2,
    ),
    decisions: [
      for (var i = 1; i <= 100; i++)
        IndexDecision(
          file: '${'$i'.padLeft(4, '0')}-decision.md',
          id: '$i'.padLeft(4, '0'),
          title: 'Decision $i about one part of the app, with a long title',
          status: 'accepted',
        ),
    ],
    currentWork: [
      for (var i = 1; i <= 200; i++)
        'Line $i of the current task, long enough to matter.',
    ],
  );

  int bytes(String text) => utf8.encode(text).length;

  test('a small project renders every section in full, the same way each '
      'time', () {
    final text = renderIndex(small(), byteBudget: indexByteBudget);
    expect(
      text,
      [
        '# fixture_app',
        '',
        "Appstein's summary of this project, always in view. `appstein "
            "sync` writes it; don't edit it. Everything else is in "
            "`.appstein/` and Appstein's MCP tools.",
        '',
        '## Project',
        '',
        '- Flutter 3.47.5 (stable channel), Dart 3.13.4, language version '
            '3.12',
        '- Stack pack: `official_mvvm`',
        '- Platforms: android, ios',
        '- Android applicationId: `dev.sample.probe_app`',
        '- iOS bundle id: `dev.sample.probeApp`',
        '',
        '## Rules',
        '',
        "- Ask Appstein's MCP tools (`where_is()`, `feature()`, `route()`) "
            'before searching the code.',
        '- Run `verify()` before you say a task is done.',
        '- Never upgrade native toolchain versions (Gradle, the Android '
            'Gradle Plugin, Kotlin, the NDK, SDK levels, the iOS deployment '
            'target) yourself; ask `toolchain()`.',
        '- Dependencies: pure Dart for small helpers; a package that passes '
            '`package_check()` for platform features; Pigeon with platform '
            'channels for small native code.',
        '',
        '## Features',
        '',
        '| Feature | Screens | Main files |',
        '|---|---|---|',
        '| `booking` | 1 | `lib/ui/booking/`: widgets/booking_screen.dart, '
            'view_models/booking_viewmodel.dart |',
        '| `profile` | 1 | `lib/ui/profile/`: widgets/profile_screen.dart |',
        '',
        '## Where things live',
        '',
        '- `ui`: `lib/ui/**`',
        '- `domain`: `lib/domain/**`',
        '',
        '## Version notes',
        '',
        '- **popscope-not-willpopscope** (priority 1): PopScope replaces '
            'WillPopScope.',
        '',
        '`platform/delta.md` also lists 4 deprecated APIs, 3 removed APIs, '
            '0 changed APIs and 1 moved library; ask `what_changed()`.',
        '',
        '## Decisions',
        '',
        '- 0002 State management with provider + ChangeNotifier (accepted): '
            '[0002-state.md](<decisions/0002-state.md>)',
        '',
        '## Current work',
        '',
        '> # Add booking export',
        '>',
        '> Status: tests written.',
        '',
        '## Freshness',
        '',
        'Synced by Appstein 0.1.0-dev for Flutter 3.47.5. Curated notes cover '
            'Flutter 3.47 and earlier.',
        '',
      ].join('\n'),
    );
    expect(renderIndex(small(), byteBudget: indexByteBudget), text);
  });

  test('what is unknown or missing is said plainly', () {
    final text = renderIndex(
      const IndexInputs(
        projectName: null,
        sdk: SdkInfo(
          flutterVersion: '3.48.0',
          dartVersion: '3.14.0',
          channel: 'beta',
          notesCoverage: NotesCoverage.partial,
        ),
        appsteinVersion: '0.1.0-dev',
        newestNotes: '3.47',
        stackPack: null,
        platforms: [],
        appIds: [],
        features: null,
        featuresMissing:
            'the project map was skipped: the packages could not be fetched',
        layers: null,
        notes: [],
        apiCounts: null,
        decisionsError: 'Access is denied.',
        currentWorkError: 'Access is denied.',
      ),
      byteBudget: indexByteBudget,
    );
    for (final line in [
      '# This project',
      '- Flutter 3.48.0 (beta channel), Dart 3.14.0, language version '
          'unknown',
      '- Stack pack: none',
      '- Platforms: none found',
      'Not available: the project map was skipped: the packages could not '
          'be fetched.',
      'No stack pack, so no layers.',
      'No curated notes for this SDK.',
      '`platform/delta.md` has no API lists this time; it says why. Ask '
          '`what_changed()`.',
      "Couldn't read `.appstein/decisions/`: Access is denied.",
      "Couldn't read `memory/current.md`: Access is denied.",
      'Synced by Appstein 0.1.0-dev for Flutter 3.48.0. Curated notes may be '
          'incomplete for Flutter 3.48: the newest notes are for 3.47.',
    ]) {
      expect(text, contains(line));
    }
  });

  test('table cells escape |, a feature shows at most two main files, an '
      'unreadable decision says why, and no features says so', () {
    final text = renderIndex(
      small(
        features: const [
          IndexFeature(
            name: 'odd|name',
            folder: 'lib/ui/odd|name',
            screens: 3,
            mainFiles: ['a.dart', 'b.dart', 'c.dart'],
          ),
        ],
        decisions: const [
          IndexDecision.unreadable(
            file: '0007 bad.md',
            id: '0007',
            problem: 'it has no front matter',
          ),
        ],
      ),
      byteBudget: indexByteBudget,
    );
    expect(
      text,
      contains(r'| `odd\|name` | 3 | `lib/ui/odd\|name/`: a.dart, b.dart, … |'),
    );
    expect(
      text,
      contains(
        '- [0007 bad.md](<decisions/0007 bad.md>): unreadable (it has no '
        'front matter).',
      ),
    );
    expect(
      renderIndex(small(features: const []), byteBudget: indexByteBudget),
      contains('## Features\n\nNone found.\n'),
    );
  });

  test('over budget, current work is cut first', () {
    final inputs = small(
      currentWork: [for (var i = 1; i <= 10; i++) 'Step $i of the task.'],
    );
    final full = renderIndex(inputs, byteBudget: indexByteBudget);
    final cut = renderIndex(inputs, byteBudget: bytes(full) - 1);
    expect(bytes(cut), lessThan(bytes(full)));
    expect(cut, contains('; ask `memory_read()`.'));
    expect(cut, contains('- 0002 State management'));
    expect(cut, contains('| `profile` |'));
  });

  test('a very large project fits; current work and decisions go first, and '
      'features and notes keep at least 5', () {
    const budget = indexByteBudget - 300;
    final text = renderIndex(large(), byteBudget: budget);
    expect(bytes(text), lessThanOrEqualTo(budget));
    expect(text, contains('…and 200 more lines; ask `memory_read()`.'));
    expect(text, contains('…and 100 older decisions; ask `decisions()`.'));
    final lines = text.split('\n');
    final rows = [
      for (final line in lines)
        if (line.startsWith('| `feature_')) line,
    ];
    expect(rows.length, inInclusiveRange(5, 15));
    expect(
      rows.first,
      '| `feature_0` | 300 | `lib/ui/feature_0/`: widgets/screen_0.dart, '
      'view_models/view_model_0.dart, … |',
    );
    expect(text, contains('; ask `feature()`.'));
    final notes = lines.where((line) => line.startsWith('- **')).length;
    expect(notes, inInclusiveRange(5, 10));
    expect(text, contains('…and ${bundledNotes.length - notes} more notes.'));
    for (final heading in headings) {
      expect(text, contains(heading));
    }
  });

  test('when even the floors do not fit, features and notes go too, and '
      'every section still renders', () {
    final text = renderIndex(large(), byteBudget: 1000);
    expect(text, isNot(contains('| `feature_')));
    expect(text, isNot(contains('- **')));
    expect(text, contains('…and 300 more; ask `feature()`.'));
    expect(text, contains('…and ${bundledNotes.length} more notes.'));
    for (final heading in headings) {
      expect(text, contains(heading));
    }
  });

  test('indexBodyBudget leaves room for the front matter: a body of exactly '
      'that many bytes makes a 4,500-byte file', () {
    final meta = KnowledgeMeta(
      generatedAt: '2026-10-01T09:00:00Z',
      appsteinVersion: '0.1.0-dev',
      formatVersion: knowledgeFormatVersion,
      sdkVersion: '3.47.5',
      inputHash: 'a' * 64,
    );
    final budget = indexBodyBudget(meta);
    final body = '${'x' * (budget - 1)}\n';
    expect(
      utf8.encode(markdownWithFrontMatter(body, meta)).length,
      indexByteBudget,
    );
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `fvm dart test packages/appstein_engine/test/index/index_document_test.dart packages/appstein_engine/test/delta/delta_document_test.dart`
Expected: compilation errors, because `IndexInputs`, `renderIndex`, `indexBodyBudget`, `indexByteBudget` and `needsNewerLanguage` don't exist yet.

- [ ] **Step 3: Make `needsNewerLanguage` public**

In `packages/appstein_engine/lib/src/delta/delta_document.dart`, replace

```dart
bool _needsNewerLanguage(CuratedNote note, String? languageVersion) {
```

with

```dart
/// Whether [note] needs a newer Dart language version than the project's
/// [languageVersion]: such notes are listed apart in `delta.md` and left
/// out of `INDEX.md`. False when either version is unknown.
bool needsNewerLanguage(CuratedNote note, String? languageVersion) {
```

and its one call in `renderDelta`, `(_needsNewerLanguage(note, inputs.languageVersion) ? later : usable)`, with `(needsNewerLanguage(note, inputs.languageVersion) ? later : usable)`.

- [ ] **Step 4: Write `index_document.dart`**

Create `packages/appstein_engine/lib/src/index/index_document.dart`:

```dart
import 'dart:convert';
import 'dart:math';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../knowledge/markdown_front_matter.dart';
import '../notes/flutter_minor.dart';
import 'index_sources.dart';

/// Where `INDEX.md` lives inside `.appstein/` (spec §6.2).
const indexPath = 'INDEX.md';

/// The most bytes `INDEX.md` may have, front matter included: 1,500
/// tokens, counted as UTF-8 bytes ÷ 3 (spec §6.3).
const indexByteBudget = 4500;

/// What `INDEX.md` is built from (spec §6.3).
final class IndexInputs {
  /// Creates the inputs.
  const IndexInputs({
    required this.projectName,
    required this.sdk,
    required this.appsteinVersion,
    required this.newestNotes,
    required this.stackPack,
    required this.platforms,
    required this.appIds,
    required this.features,
    this.featuresMissing,
    required this.layers,
    required this.notes,
    required this.apiCounts,
    this.decisions = const [],
    this.decisionsError,
    this.currentWork = const [],
    this.currentWorkError,
  });

  /// The name in `pubspec.yaml`; null when it can't be read.
  final String? projectName;

  /// The SDK facts, with the notes coverage.
  final SdkInfo sdk;

  /// The version of the running Appstein.
  final String appsteinVersion;

  /// The newest Flutter minor version the curated notes cover.
  final String newestNotes;

  /// The stack pack's id, or null without one.
  final String? stackPack;

  /// The platform folders that exist.
  final List<String> platforms;

  /// The app and bundle id lines (`appIdLines`).
  final List<String> appIds;

  /// The features table's rows, ordered (`indexFeatures`); null when there
  /// is no `features.json`, with the reason in [featuresMissing].
  final List<IndexFeature>? features;

  /// Why [features] is null, in words that follow "Not available: ".
  final String? featuresMissing;

  /// The stack pack's layer tags and their globs, in match order; null
  /// without a stack pack.
  final Map<String, List<String>>? layers;

  /// The curated notes to list, most important first (`delta.md`'s order,
  /// without the notes that need a newer language version).
  final List<CuratedNote> notes;

  /// How many APIs `delta.md` lists; null when it has no API lists.
  final DeltaCounts? apiCounts;

  /// The decisions to list, in file-name order.
  final List<IndexDecision> decisions;

  /// Why `.appstein/decisions/` couldn't be read; null otherwise.
  final String? decisionsError;

  /// The lines of `memory/current.md`.
  final List<String> currentWork;

  /// Why `memory/current.md` couldn't be read; null otherwise.
  final String? currentWorkError;
}

/// How many bytes `INDEX.md`'s text may have when it is written with
/// [meta]: [indexByteBudget] minus the front matter. Every `generatedAt`
/// has the same length, so any time will do in [meta].
int indexBodyBudget(KnowledgeMeta meta) =>
    indexByteBudget -
    (utf8.encode(markdownWithFrontMatter('', meta)).length - 1);

/// The text of `INDEX.md` without its front matter (spec §6.3), at most
/// [byteBudget] UTF-8 bytes when that can be done.
///
/// When the full text is longer, it cuts one item at a time in §6.3's
/// order: current work, then decisions (keeping the newest), then features
/// down to 5 rows, then notes down to 5. Each cut leaves a pointer to the
/// MCP tool that holds the rest. Only if the text still doesn't fit do
/// features, then notes, go below 5. Project, rules, where things live and
/// freshness are never cut.
String renderIndex(IndexInputs inputs, {required int byteBudget}) {
  var limits = _Limits.start(inputs);
  var text = _render(inputs, limits);
  while (utf8.encode(text).length > byteBudget) {
    final next = limits.cut();
    if (next == null) break;
    limits = next;
    text = _render(inputs, limits);
  }
  return text;
}

/// How many items of each section that can be cut are shown.
final class _Limits {
  const _Limits({
    required this.currentWork,
    required this.decisions,
    required this.features,
    required this.notes,
  });

  _Limits.start(IndexInputs inputs)
    : currentWork = min(10, inputs.currentWork.length),
      decisions = inputs.decisions.length,
      features = min(15, inputs.features?.length ?? 0),
      notes = min(10, inputs.notes.length);

  final int currentWork;
  final int decisions;
  final int features;
  final int notes;

  /// One item fewer, in §6.3's order; null when nothing is left to cut.
  _Limits? cut() {
    if (currentWork > 0) return _with(currentWork: currentWork - 1);
    if (decisions > 0) return _with(decisions: decisions - 1);
    if (features > 5) return _with(features: features - 1);
    if (notes > 5) return _with(notes: notes - 1);
    // Past §6.3's floors only when even they don't fit (D8).
    if (features > 0) return _with(features: features - 1);
    if (notes > 0) return _with(notes: notes - 1);
    return null;
  }

  _Limits _with({
    int? currentWork,
    int? decisions,
    int? features,
    int? notes,
  }) => _Limits(
    currentWork: currentWork ?? this.currentWork,
    decisions: decisions ?? this.decisions,
    features: features ?? this.features,
    notes: notes ?? this.notes,
  );
}

const _rules = [
  "- Ask Appstein's MCP tools (`where_is()`, `feature()`, `route()`) before "
      'searching the code.',
  '- Run `verify()` before you say a task is done.',
  '- Never upgrade native toolchain versions (Gradle, the Android Gradle '
      'Plugin, Kotlin, the NDK, SDK levels, the iOS deployment target) '
      'yourself; ask `toolchain()`.',
  '- Dependencies: pure Dart for small helpers; a package that passes '
      '`package_check()` for platform features; Pigeon with platform '
      'channels for small native code.',
];

String _render(IndexInputs inputs, _Limits limits) {
  final out = StringBuffer();
  void heading(String title) => out
    ..writeln()
    ..writeln('## $title')
    ..writeln();

  out
    ..writeln('# ${inputs.projectName ?? 'This project'}')
    ..writeln()
    ..writeln(
      "Appstein's summary of this project, always in view. `appstein sync` "
      "writes it; don't edit it. Everything else is in `.appstein/` and "
      "Appstein's MCP tools.",
    );
  heading('Project');
  _project(out, inputs);
  heading('Rules');
  for (final rule in _rules) {
    out.writeln(rule);
  }
  heading('Features');
  _features(out, inputs, limits.features);
  heading('Where things live');
  _layers(out, inputs.layers);
  heading('Version notes');
  _notes(out, inputs, limits.notes);
  heading('Decisions');
  _decisions(out, inputs, limits.decisions);
  heading('Current work');
  _currentWork(out, inputs, limits.currentWork);
  heading('Freshness');
  out.writeln(_freshness(inputs));
  return out.toString();
}

void _project(StringBuffer out, IndexInputs inputs) {
  final sdk = inputs.sdk;
  final stack = inputs.stackPack;
  out
    ..writeln(
      '- Flutter ${sdk.flutterVersion} (${sdk.channel} channel), Dart '
      '${sdk.dartVersion}, language version '
      '${sdk.languageVersion ?? 'unknown'}',
    )
    ..writeln('- Stack pack: ${stack == null ? 'none' : '`$stack`'}')
    ..writeln(
      '- Platforms: '
      '${inputs.platforms.isEmpty ? 'none found' : inputs.platforms.join(', ')}',
    );
  for (final line in inputs.appIds) {
    out.writeln('- $line');
  }
}

void _features(StringBuffer out, IndexInputs inputs, int shown) {
  final features = inputs.features;
  if (features == null) {
    out.writeln(
      _sentence(
        'Not available: ${inputs.featuresMissing ?? 'no reason was given'}',
      ),
    );
    return;
  }
  if (features.isEmpty) {
    out.writeln('None found.');
    return;
  }
  if (shown > 0) {
    out
      ..writeln('| Feature | Screens | Main files |')
      ..writeln('|---|---|---|');
    for (final feature in features.take(shown)) {
      final folder = '`${_cell(feature.folder)}/`';
      final files = [
        for (final file in feature.mainFiles.take(2)) _cell(file),
        if (feature.mainFiles.length > 2) '…',
      ];
      out.writeln(
        '| `${_cell(feature.name)}` | ${feature.screens} | '
        '${files.isEmpty ? folder : '$folder: ${files.join(', ')}'} |',
      );
    }
  }
  final hidden = features.length - shown;
  if (hidden > 0) {
    if (shown > 0) out.writeln();
    out.writeln('…and $hidden more; ask `feature()`.');
  }
}

void _layers(StringBuffer out, Map<String, List<String>>? layers) {
  if (layers == null || layers.isEmpty) {
    out.writeln('No stack pack, so no layers.');
    return;
  }
  for (final MapEntry(key: tag, value: globs) in layers.entries) {
    out.writeln(
      '- `$tag`: ${[for (final glob in globs) '`$glob`'].join(', ')}',
    );
  }
}

void _notes(StringBuffer out, IndexInputs inputs, int shown) {
  final notes = inputs.notes;
  if (notes.isEmpty) {
    out.writeln('No curated notes for this SDK.');
  } else {
    for (final note in notes.take(shown)) {
      out.writeln(
        '- **${note.id}** (priority ${note.priority}): '
        '${_oneLine(note.summary)}',
      );
    }
    final hidden = notes.length - shown;
    if (hidden > 0) {
      if (shown > 0) out.writeln();
      out.writeln('…and ${_count(hidden, 'more note')}.');
    }
  }
  final counts = inputs.apiCounts;
  out
    ..writeln()
    ..writeln(
      counts == null
          ? '`platform/delta.md` has no API lists this time; it says why. '
                'Ask `what_changed()`.'
          : '`platform/delta.md` also lists '
                '${_count(counts.deprecated, 'deprecated API')}, '
                '${_count(counts.removed, 'removed API')}, '
                '${_count(counts.changed, 'changed API')} and '
                '${_count(counts.moved, 'moved library', 'moved libraries')}; '
                'ask `what_changed()`.',
    );
}

void _decisions(StringBuffer out, IndexInputs inputs, int shown) {
  if (inputs.decisionsError case final error?) {
    out.writeln(_sentence("Couldn't read `.appstein/decisions/`: $error"));
    return;
  }
  final decisions = inputs.decisions;
  if (decisions.isEmpty) {
    out.writeln('None recorded yet.');
    return;
  }
  // The newest decisions are the last; they are the ones kept.
  final hidden = decisions.length - shown;
  for (final decision in decisions.skip(hidden)) {
    out.writeln(_decisionLine(decision));
  }
  if (hidden > 0) {
    if (shown > 0) out.writeln();
    out.writeln('…and ${_count(hidden, 'older decision')}; ask `decisions()`.');
  }
}

String _decisionLine(IndexDecision decision) {
  // Angle brackets keep a file name with spaces a valid link.
  final link = '[${decision.file}](<decisions/${decision.file}>)';
  if (decision.problem case final problem?) {
    return '- $link: unreadable (${_withoutFullStop(problem)}).';
  }
  final id = decision.id == null ? '' : '${decision.id} ';
  return '- $id${decision.title} (${decision.status}): $link';
}

void _currentWork(StringBuffer out, IndexInputs inputs, int shown) {
  if (inputs.currentWorkError case final error?) {
    out.writeln(_sentence("Couldn't read `memory/current.md`: $error"));
    return;
  }
  final lines = inputs.currentWork;
  if (lines.isEmpty) {
    out.writeln('None recorded yet.');
    return;
  }
  // A quote, so a heading in current.md can't become a section here.
  for (final line in lines.take(shown)) {
    out.writeln(line.isEmpty ? '>' : '> $line');
  }
  final hidden = lines.length - shown;
  if (hidden > 0) {
    if (shown > 0) out.writeln();
    out.writeln('…and ${_count(hidden, 'more line')}; ask `memory_read()`.');
  }
}

String _freshness(IndexInputs inputs) {
  final sdk = inputs.sdk;
  final notes = sdk.notesCoverage == NotesCoverage.complete
      ? 'Curated notes cover Flutter ${inputs.newestNotes} and earlier.'
      : 'Curated notes may be incomplete for Flutter '
            '${_minorText(sdk.flutterVersion)}: the newest notes are for '
            '${inputs.newestNotes}.';
  return 'Synced by Appstein ${inputs.appsteinVersion} for Flutter '
      '${sdk.flutterVersion}. $notes';
}

String _minorText(String version) {
  final minor = flutterMinorOf(version);
  return minor == null ? version : '${minor.major}.${minor.minor}';
}

/// [n] and the noun, singular for 1.
String _count(int n, String singular, [String? plural]) =>
    '$n ${n == 1 ? singular : plural ?? '${singular}s'}';

/// [text] safe inside a Markdown table cell.
String _cell(String text) => text.replaceAll('|', r'\|');

/// [text] with each run of white space as one space.
String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// [text] on one line, ending in a full stop.
String _sentence(String text) {
  final line = _oneLine(text);
  return line.endsWith('.') || line.endsWith('!') || line.endsWith('?')
      ? line
      : '$line.';
}

/// [text] on one line, without a final full stop.
String _withoutFullStop(String text) {
  final line = _oneLine(text);
  return line.endsWith('.') ? line.substring(0, line.length - 1) : line;
}
```

In `packages/appstein_engine/lib/appstein_engine.dart`, add before `export 'src/index/index_sources.dart';`:

```dart
export 'src/index/index_document.dart';
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `fvm dart test packages/appstein_engine/test/index packages/appstein_engine/test/delta`
Expected: all pass.

If the large-project test's row or note counts fall outside 5–15 or 5–10, **don't loosen the test**. Print the rendered text, and check the cut loop against §6.3's order. With the inputs as written, the floors fit (they need about 3.6 KB of the 4.2 KB).

Then run `fvm dart analyze --fatal-infos` and `fvm dart format --output=none --set-exit-if-changed .` from the repo root.

- [ ] **Step 6: Report for commit**

Commit message: `feat: render INDEX.md within its 4,500-byte budget (spec §6.3)`.

---

### Task 3: sync writes INDEX.md

**Files:**
- Modify: `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart`
- Test: `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart`
- Test: `packages/appstein_cli/test/sync_command_test.dart`
- Test: `packages/appstein_engine/test/integration/map_real_sdk_test.dart`

**Interfaces:**
- Consumes:
  - Task 1's `readIndexSources`, `appIdLines`, `indexFeatures` and `DeltaCounts.of`;
  - Task 2's `IndexInputs`, `renderIndex`, `indexBodyBudget`, `indexPath`, `indexByteBudget` and `needsNewerLanguage`;
  - the existing `PlatformBuild`, `MapBuild`, `NativeBuild`, `deltaNotes` and `inputHash`.
- Produces: `SyncReport.files` and `state.json` gain `INDEX.md`, written after every other file.

- [ ] **Step 1: Update the existing file lists, and write the failing tests**

In `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart`:

1. In `the first sync writes the platform layer and the five map files, which match the goldens`:
   - add `'INDEX.md': true,` as the last entry of the `report.files` map;
   - add `'INDEX.md',` to the `unorderedEquals([...])` list of `state.json`'s keys.
2. In `when pub get fails, the platform layer is written and the map is skipped`:
   - the `report.files.keys` list becomes `['platform/sdk.json', 'platform/toolchain.json', 'platform/delta.md', 'INDEX.md']`;
   - the `state.json` list becomes `['INDEX.md', 'platform/delta.md', 'platform/sdk.json', 'platform/toolchain.json']`. `state.json`'s keys are sorted, and `I` sorts before `p`.
3. In `a corrupted pubspec.lock skips the map and keeps the old deps.json, saying why`, the `report.files.keys` list gains `'INDEX.md'` at the end.
4. In `a failed fetch after a good sync leaves the old map files and lists only the platform files in state.json`, the `state.json` list gains `'INDEX.md'` first.
5. In `without packs, only the generic map files are written, with no layers`, the `report.files.keys` list gains `'INDEX.md'` at the end.

Then add this group at the end of `main()`:

```dart
  group('INDEX.md', () {
    const platformPacks = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];

    String index(String project) =>
        File(p.join(project, '.appstein', 'INDEX.md')).readAsStringSync();

    void write(String project, String path, String text) =>
        File(p.joinAll([project, ...path.split('/')]))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text);

    String appWithNative() {
      final app = copyFixtureApp();
      for (final folder in ['android', 'ios']) {
        copyFixtureTree(p.join(nativeTemplateDir, folder), p.join(app, folder));
      }
      return app;
    }

    test('the first sync writes INDEX.md last, within 4,500 bytes, from the '
        'map, native.json and the notes', () async {
      final app = appWithNative();
      final report = await sync(
        packs: platformPacks,
      ).run(app, dartSdkPath: testDartSdk);
      expect(report.files.keys.last, 'INDEX.md');
      expect(report.files['INDEX.md'], isTrue);
      expect((state(app)['files']! as Map).keys, contains('INDEX.md'));
      final text = index(app);
      expect(utf8.encode(text).length, lessThanOrEqualTo(indexByteBudget));
      final meta = readFrontMatter(text)!;
      expect(meta.generatedAt, '2026-10-01T09:00:00Z');
      expect(meta.sdkVersion, '3.47.5');
      final sdk = report.sdk;
      final firstNote =
          deltaNotes(
            CuratedNotes.bundled(),
            flutterVersion: '3.47.5',
            baseline: '3.16',
          ).firstWhere(
            (note) => !needsNewerLanguage(note, sdk.languageVersion),
          );
      for (final line in [
        '# fixture_app',
        '- Flutter 3.47.5 (${sdk.channel} channel), Dart ${sdk.dartVersion}, '
            'language version 3.12',
        '- Stack pack: `official_mvvm`',
        '- Platforms: android, ios',
        '- Android applicationId: `dev.sample.probe_app`',
        '- iOS bundle id: `dev.sample.probeApp`',
        '| `auth/login` | 1 | `lib/ui/auth/login/`: '
            'widgets/login_screen.dart, view_models/login_viewmodel.dart |',
        '| `home` | 1 | `lib/ui/home/`: widgets/home_screen.dart, '
            'view_models/home_viewmodel.dart |',
        '- `ui`: `lib/ui/**`',
        '- **${firstNote.id}** (priority ${firstNote.priority}): ',
        '`platform/delta.md` also lists ',
        '## Decisions\n\nNone recorded yet.\n',
        '## Current work\n\nNone recorded yet.\n',
        'Synced by Appstein 0.1.0-dev for Flutter 3.47.5.',
      ]) {
        expect(text, contains(line));
      }
    });

    test('a second sync leaves INDEX.md; a decision or current.md rewrites '
        'only INDEX.md', () async {
      final app = appWithNative();
      await sync(packs: platformPacks).run(app, dartSdkPath: testDartSdk);
      final second = await sync(
        packs: platformPacks,
      ).run(app, dartSdkPath: testDartSdk);
      expect(second.files.values, everyElement(isFalse));
      write(
        app,
        '.appstein/decisions/0001-state.md',
        '---\ntitle: State management with provider + ChangeNotifier\n'
            'status: accepted\n---\nWhy: Flutter recommends it.\n',
      );
      write(
        app,
        '.appstein/decisions/0002-old.md',
        '---\ntitle: Old idea\nstatus: superseded\n---\n',
      );
      write(
        app,
        '.appstein/memory/current.md',
        '# Booking export\n\nStatus: tests written.\n',
      );
      final third = await sync(
        packs: platformPacks,
      ).run(app, dartSdkPath: testDartSdk);
      expect({
        for (final MapEntry(:key, :value) in third.files.entries)
          if (value) key,
      }, {'INDEX.md'});
      final text = index(app);
      expect(
        text,
        contains(
          '- 0001 State management with provider + ChangeNotifier '
          '(accepted): [0001-state.md](<decisions/0001-state.md>)',
        ),
      );
      expect(text, isNot(contains('Old idea')));
      expect(
        text,
        contains('> # Booking export\n>\n> Status: tests written.\n'),
      );
    });

    test('a hand-edited INDEX.md is put back, and only it', () async {
      final app = appWithNative();
      await sync(packs: platformPacks).run(app, dartSdkPath: testDartSdk);
      File(
        p.join(app, '.appstein', 'INDEX.md'),
      ).writeAsStringSync('# edited\n');
      final second = await sync(
        packs: platformPacks,
      ).run(app, dartSdkPath: testDartSdk);
      expect({
        for (final MapEntry(:key, :value) in second.files.entries)
          if (value) key,
      }, {'INDEX.md'});
      expect(index(app), contains('# fixture_app'));
    });

    test('when the map is skipped, INDEX.md is still written and says '
        'why', () async {
      final app = appWithNative();
      File(p.join(app, '.dart_tool', 'package_config.json')).deleteSync();
      runner.when(flutter(), [
        'pub',
        'get',
      ], const RunResult(exitCode: 69, stderr: 'Could not reach pub.dev.'));
      final report = await sync(
        packs: platformPacks,
      ).run(app, dartSdkPath: testDartSdk);
      expect(report.files['INDEX.md'], isTrue);
      final text = index(app);
      expect(
        text,
        contains(
          'Not available: the project map was skipped: the packages could '
          'not be fetched.',
        ),
      );
      expect(
        text,
        contains(
          '`platform/delta.md` has no API lists this time; it says why. Ask '
          '`what_changed()`.',
        ),
      );
      expect(text, contains('- Android applicationId: `dev.sample.probe_app`'));
    });

    test('many decisions and a long current.md still fit in 4,500 bytes, '
        'front matter included', () async {
      final app = appWithNative();
      for (var i = 1; i <= 150; i++) {
        write(
          app,
          '.appstein/decisions/${'$i'.padLeft(4, '0')}-decision.md',
          '---\ntitle: Decision number $i about a part of the app, with a '
              'long title\nstatus: accepted\n---\n',
        );
      }
      write(app, '.appstein/memory/current.md', [
        for (var i = 1; i <= 300; i++)
          'Line $i of the current task, with enough words to be long.',
      ].join('\n'));
      await sync(packs: platformPacks).run(app, dartSdkPath: testDartSdk);
      final text = index(app);
      expect(utf8.encode(text).length, lessThanOrEqualTo(indexByteBudget));
      expect(text, contains('; ask `memory_read()`.'));
      expect(text, contains('; ask `decisions()`.'));
      // The fixture has 5 features, the floor, so all of them stay.
      expect(text, contains('| `settings` |'));
    });
  });
```

In `packages/appstein_cli/test/sync_command_test.dart`, in `writes the platform layer and says what it did`:
- after `expect(text, contains(row('map/native.json', 'written')));`, add `expect(text, contains(row('INDEX.md', 'written')));`;
- add `'INDEX.md',` to the list of paths whose files must exist.

In `packages/appstein_engine/test/integration/map_real_sdk_test.dart`, add before the comment `// The fetch left fresh packages, …`:

```dart
    // INDEX.md, from the real map and delta.
    final index = File(
      p.join(app, '.appstein', 'INDEX.md'),
    ).readAsStringSync();
    expect(utf8.encode(index).length, lessThanOrEqualTo(indexByteBudget));
    expect(index, contains('| `booking` | 1 |'));
    expect(index, contains('`platform/delta.md` also lists '));
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `fvm dart test packages/appstein_engine/test/knowledge/knowledge_sync_test.dart packages/appstein_cli/test/sync_command_test.dart`
Expected: the updated lists and the new `INDEX.md` tests fail, because no `INDEX.md` is written.

- [ ] **Step 3: Build and write INDEX.md in `KnowledgeSync`**

In `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart`:

1. Add the imports:

```dart
import '../index/index_document.dart';
import '../index/index_sources.dart';
```

2. Change the class comment's first sentence to: `/// Everything \`appstein sync\` writes (spec §5.4, §6.2, §6.3): the platform layer, the version delta, the project map, the native config and \`INDEX.md\`.`
3. In `run`, replace

```dart
    final delta = _delta(platform, map);
    final store = KnowledgeStore(projectRoot, clock: _clock);
```

with

```dart
    final delta = _delta(platform, map);
    // Last: it summarizes the other files.
    final index = _index(projectRoot, platform, map, native, delta);
    final store = KnowledgeStore(projectRoot, clock: _clock);
```

and `[...platform.files, delta, ...map.files, ?native.file],` with `[...platform.files, delta, ...map.files, ?native.file, index],`.
4. Add this method after `_delta`:

```dart
  /// `INDEX.md` (spec §6.3): a summary of the other files, the project's
  /// decisions and its current work, within [indexByteBudget] bytes. Its
  /// input hash covers the other files' input hashes, the project files it
  /// reads, and the packs.
  GeneratedFile _index(
    String projectRoot,
    PlatformBuild platform,
    MapBuild map,
    NativeBuild native,
    GeneratedFile delta,
  ) {
    final sdk = platform.sdk;
    final sources = readIndexSources(projectRoot);
    final hash = inputHash(
      {
        for (final file in [
          ...platform.files,
          delta,
          ...map.files,
          ?native.file,
        ])
          'file:${file.path}': utf8.encode(file.inputHash),
        ...sources.inputs,
        'packs': utf8.encode(
          [for (final pack in packs) '${pack.id}@${pack.version}'].join(','),
        ),
      },
      appsteinVersion: appsteinVersion,
      formatVersion: knowledgeFormatVersion,
    );
    final stack = packs
        .where((pack) => pack.kind == PackKind.stack)
        .firstOrNull;
    final featuresBody = map.files
        .where((file) => file.path == MapFiles.features)
        .firstOrNull
        ?.body;
    final nativeBody = native.file?.body;
    final skipped = map.report.skipped;
    final inputs = IndexInputs(
      projectName: sources.projectName,
      sdk: sdk,
      appsteinVersion: appsteinVersion,
      newestNotes: platform.newestNotes,
      stackPack: stack?.id,
      platforms: sources.platforms,
      appIds: appIdLines(
        nativeBody == null ? null : NativeConfig.fromJson(nativeBody),
      ),
      features: featuresBody == null
          ? null
          : indexFeatures(FeaturesMap.fromJson(featuresBody)),
      featuresMissing: skipped == null
          ? 'no stack pack, so no features'
          : 'the project map was skipped: $skipped',
      layers: stack?.layerRules?.layers,
      notes: [
        for (final note in deltaNotes(
          notes,
          flutterVersion: sdk.flutterVersion,
          baseline: baseline,
        ))
          if (!needsNewerLanguage(note, sdk.languageVersion)) note,
      ],
      apiCounts: switch (map.delta) {
        final facts? => DeltaCounts.of(facts),
        null => null,
      },
      decisions: sources.decisions,
      decisionsError: sources.decisionsError,
      currentWork: sources.currentWork,
      currentWorkError: sources.currentWorkError,
    );
    final budget = indexBodyBudget(
      KnowledgeMeta(
        // Any time: every one has the same length.
        generatedAt: formatKnowledgeTime(DateTime.utc(2000)),
        appsteinVersion: appsteinVersion,
        formatVersion: knowledgeFormatVersion,
        sdkVersion: sdk.flutterVersion,
        inputHash: hash,
      ),
    );
    return GeneratedFile.markdown(
      path: indexPath,
      markdown: renderIndex(inputs, byteBudget: budget),
      inputHash: hash,
    );
  }
```

5. In `run`'s doc comment, after the paragraph about `map/native.json`, add:

```dart
  /// `INDEX.md` is written last, after every other file, since it summarizes
  /// them; when the map was skipped, it says so.
  ///
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `fvm dart test packages/appstein_engine packages/appstein_cli`
Expected: all pass, with the integration tests skipped (tagged).

Then the real-SDK test, which needs the network for go_router:
`fvm dart test packages/appstein_engine/test/integration/map_real_sdk_test.dart --run-skipped -t integration`
Expected: pass. Record INDEX.md's real size in the report: add a `printOnFailure` or a one-off print, and remove it after.

Then run `fvm dart analyze --fatal-infos` and `fvm dart format --output=none --set-exit-if-changed .` from the repo root.

- [ ] **Step 5: Run a real sync by hand**

Build the CLI and sync a scratch app outside the repo, in a folder whose path has a space:
- `fvm dart compile exe packages/appstein_cli/bin/appstein.dart -o <scratch>/appstein.exe`
- `fvm flutter create --platforms=android,ios "<scratch>/index app"`
- `<scratch>/appstein.exe sync --project "<scratch>/index app"`

Read `<scratch>/index app/.appstein/INDEX.md` in full and check:
- the IDs, platforms and features match the app;
- it is under 4,500 bytes;
- a second `sync` reports `INDEX.md  unchanged`.

Paste the file and its byte count into the report. Delete nothing in the repo.

- [ ] **Step 6: Report for commit**

Commit message: `feat: appstein sync writes INDEX.md`.

---

### Task 4: Docs

**Files:**
- Create: `docs/guide/index-md.md`
- Modify: `docs/guide/knowledge-store.md`
- Modify: `docs/guide/version-delta.md`
- Modify: `docs/guide/README.md`

**Interfaces:** none. This task changes no code.

- [ ] **Step 1: Write the guide page**

Create `docs/guide/index-md.md`. It explains the code as built, in plain words, in the style of `version-delta.md` and `native-config.md`:

```markdown
<!-- covers:
packages/appstein_engine/lib/src/index/**
-->

# INDEX.md

`appstein sync` writes `.appstein/INDEX.md`: the one page an agent always has in view (spec §4 principle 5, §6.3). Everything else in `.appstein/` is read on demand. INDEX.md says what the project is and where to look next. It is at most 1,500 tokens, and the rest of this page explains how that is kept.
```

Then these sections, each with the facts given:

1. **What it holds:** a table of the eight sections, saying where each part comes from (from `index_sources.dart` and `index_document.dart`):
   - **Project:**
     - the name from `pubspec.yaml`;
     - the Flutter, Dart and language versions from `sdk.json`;
     - the stack pack;
     - the platform folders Flutter checks;
     - the IDs from `native.json`, with D5's rules: `unknown; see map/native.json`, never a guess. Android's id comes from `defaultConfig`, with a count of the flavors that may change it. iOS's comes per Xcode configuration, because `Info.plist` holds only `$(PRODUCT_BUNDLE_IDENTIFIER)`.
   - **Rules:** fixed text that names the MCP tools of slice 1c (D1).
   - **Features:** at most 15 rows, most screens first, with the main files (D4).
   - **Where things live:** the stack pack's layer globs.
   - **Version notes:** the top curated notes in `delta.md`'s order, summary only (D3), and the counts of the API lists.
   - **Decisions:** from `.appstein/decisions/*.md` (D6).
   - **Current work:** a quote of `memory/current.md` (D7).
   - **Freshness:** the versions and the notes coverage. The time is in the front matter.
2. **The budget:**
   - Tokens are counted as UTF-8 bytes ÷ 3, so the cap is 4,500 bytes. Each model tokenizes differently, and none of their tokenizers runs offline, so the rule over-counts on purpose.
   - The front matter counts too; `indexBodyBudget` subtracts it.
   - The cut loop removes one item at a time, in §6.3's order. Each cut leaves a pointer.
   - The last resort is D8.
   - Show a short example of a cut section: `…and 100 older decisions; ask \`decisions()\`.`
3. **How sync builds it:**
   - `KnowledgeSync._index` runs after the other builds and reads them from memory.
   - `readIndexSources` reads the project files.
   - `renderIndex` is pure.
   - The file is written last, before `state.json`.
   - A skipped map still gives an INDEX.md that says why.
4. **Freshness and the input hash:** D9's list, and why INDEX.md is rewritten exactly when a summarized file, a decision or `current.md` changes. A hand-edited INDEX.md is put back, like every generated file.
5. **Tests:** where each rule is pinned:
   - `index_sources_test.dart`;
   - `index_document_test.dart` (the exact text, the cut order, the large project);
   - the `INDEX.md` group in `knowledge_sync_test.dart`;
   - the real-SDK check in `map_real_sdk_test.dart`.

Use the real numbers from Task 3 Step 5 (the scratch app's INDEX.md size) where the page gives an example size.

- [ ] **Step 2: Update the other pages**

- **`docs/guide/knowledge-store.md`:**
  - **Intro:** replace "`INDEX.md` and incremental sync (1b.6) come in a later slice." with "Slice 1b.6 added **`INDEX.md`**, the page an agent always reads, which has [its own page](index-md.md). Incremental sync (1b.7) comes in a later slice."
  - **"What `sync` writes now" table:** add a row before `state.json`'s: `| \`.appstein/INDEX.md\` | The always-in-view summary: project, rules, features, layers, top notes, decisions, current work (see [index-md](index-md.md)) | any file it summarizes, a decision file, \`memory/current.md\`, \`pubspec.yaml\` or the platform folders changes, or the file was hand-edited or damaged |`.
  - **`state.json` row:** it now reads "When the map was skipped, it lists only the platform files, `delta.md`, `map/native.json` and `INDEX.md`".
  - **"How one sync runs":** add `run --> index["INDEX.md:<br/>renderIndex"]` to the Mermaid chart. Add a step between the `renderDelta` step and the `writeAll` step: "`KnowledgeSync._index` builds `INDEX.md` from the files above, still in memory, and from the project's decision files and `memory/current.md`. See [index-md](index-md.md)." In the `writeAll` step, the order becomes "platform files, `delta.md`, map files, `native.json`, `INDEX.md`, then `state.json` last".
- **`docs/guide/version-delta.md`:** where the "Needs a newer language version" section is explained, add one sentence: "`needsNewerLanguage` decides it; `INDEX.md` uses the same test to leave those notes out of its version notes."
- **`docs/guide/README.md`:** in the pages table, add after the `version-delta` row: `| [index-md](index-md.md) | How \`appstein sync\` builds \`INDEX.md\`, the always-in-view page, and keeps it within 1,500 tokens |`.

- [ ] **Step 3: Generate and check**

Run from the repo root:
- `fvm dart run tool/gen_docs.dart`
- `fvm dart run tool/check_guide.dart --since main`

Both must pass. `check_guide` fails if a changed source file's covering page wasn't updated. If it names `delta_document.dart`, that is covered by the `version-delta.md` sentence above.

- [ ] **Step 4: Report for commit**

Commit message: `docs(guide): INDEX.md page; knowledge-store, version-delta and the guide index`.

---

### Task 5: Verify, record and finish

**Files:**
- Modify: this plan's "Notes from execution"
- Modify: `docs/superpowers/progress.yaml`
- Modify: `docs/superpowers/specs/2026-09-29-appstein-design.html` (via `gen_docs`)

- [ ] **Step 1: The full check**

From the repo root:
- `fvm dart analyze --fatal-infos`
- `fvm dart format --output=none --set-exit-if-changed .`
- `fvm dart run dependency_validator`
- `fvm dart test packages/appstein_protocol packages/appstein_engine packages/appstein_cli packages/appstein_lints`
- `fvm dart test test` (repo tools)
- `fvm dart test packages/appstein_engine/test/integration --run-skipped -t integration`
- `fvm dart run tool/check_guide.dart --since main`
- `fvm dart run tool/measure_sync.dart` (the full sync must stay under 30 s)
- the BOM scan.

Record each result's numbers.

- [ ] **Step 2: Notes from execution, and progress**

Add a `## Notes from execution` section at the end of this plan. The guide check reads that heading as "the slice is done", so add it only now. Write down how it ran, the rulings, what reviews changed, the numbers (test counts, INDEX.md's size for the fixture and the scratch app, `measure_sync`), and what is carried.

Once the PR is open, in `docs/superpowers/progress.yaml`:
- set 1b.6 to `status: done`, with `pr: <n>` and `finished: <date>`;
- set 1b.7 to `status: next`.

Do it in the same commit as the notes. Run `fvm dart run tool/gen_docs.dart`, then **read back the rendered `.html`**. It must show 1b.6 Done with its PR link, and 1b.7 Next.

- [ ] **Step 3: Graph and merge**

Run `/graphify . --update` until `tool/check_graph.py` reports nothing:
- use at most 3 extraction subagents;
- see the graph runbook in memory: old-label checklists for big docs, `set -o pipefail`, no `| tail`, `old_labels.py`'s first argument is the output folder;
- afterwards check that `graph.html` has `PRECOMPUTED = true`.

Then merge by the owner's PR flow and delete the branch.

## Carried to later slices

- **1b.7 (incremental sync):**
  - `sync --changed` / `--detect`;
  - per-file hashes in `state.json` and finer map hashes;
  - path dependencies' sources and their `fix_data` in the input hashes;
  - the missing `checkPackages` tests;
  - the linear scans in `FeaturesMap.featureOf` and `readFeatures`;
  - `native.json` and INDEX.md rebuilt only when their own inputs change.
  - The analyzer cache needs an owner decision: the byte store exists only in analyzer's `src/` API. The facts are in memory, in `project_slice_1b6_research`.
- **1b.8 (package skills):** `dart run skills@ get` when `pubspec.yaml` or `pubspec.lock` changes. Unattended runs need `--all`, and the exit code is always 0 (verified facts in memory).
- **1c (MCP):**
  - the tools INDEX.md names (`where_is`, `feature`, `route`, `toolchain`, `what_changed`, `decisions`, `memory_read`, `verify`, `package_check`);
  - `overview` returns INDEX.md;
  - `record_decision` and `memory_write` write the files INDEX.md reads.
- **1e (integrate):** `AGENTS.md`/`CLAUDE.md` point to INDEX.md, and `.gitignore` lists it (spec §6.2).
- **Known limits, recorded here:**
  - a project whose minimum content alone passes 4,500 bytes gets an INDEX.md over budget (D8);
  - a decision file name with `[` or `]` gives an odd link text.

## Notes from execution

Run on 2026-10-02 on the branch `slice-1b6`. It was subagent-driven, with one implementer and one reviewer per task, and never more than 3 agents at once. Subagents never committed; the controller committed each task after its review, behind the BOM byte gate. PR #11.

**How it ran**

| Commit | What | Review |
|---|---|---|
| `33dac2b` | Task 1: `index_sources.dart` | clean; 3 minor findings deferred |
| `de2e4bb` | Task 2: `index_document.dart`, `needsNewerLanguage` public | 1 fix round: the cut-order and keep-newest-decisions rules were only loosely pinned, so a step-by-step cut-order test and a partial-decisions test were added |
| `6bd7a05` | Task 3: `KnowledgeSync._index` | clean |
| `4585951` | Task 4: guide pages (`index-md.md` new; knowledge-store, version-delta, architecture, README) | clean; 4 wording minors deferred |
| `00e1069` | Final-review fixes | re-review: all addressed |
| `f942d06` | The owner's cut-order change (spec §6.3) | clean |

**The final whole-branch review** (most capable model) found the core sound:
- the budget math is exact;
- the input hash is complete;
- the output is deterministic;
- nothing in the project's files can make sync throw.

It asked for these fixes before merge, all done in `00e1069`:
- a decision file or `current.md` saved with a UTF-8 BOM, which Windows PowerShell 5.1 writes, was listed as "unreadable (it has no front matter)". A leading BOM is now stripped, as the rest of the codebase already does;
- an id with `${VAR}` or `$VAR` was shown as a real id. Any `$` now makes it `unknown` (§6.5);
- the notes cut now ends `; ask \`what_changed()\`.`, like the other cuts (§6.3);
- guide accuracy: the placeholder text, the ÷3 reason (now echoing the spec), the code spans, the rewrite rule, and knowledge-store step 1.

**Owner decision during execution (spec §6.3 edited).** The final review showed that an ordinary app leaves about 550 bytes for Decisions and Current work. The fixture is 3,951 bytes on the real SDK before either. Under the old order those were cut while 10 generic notes stayed, so the owner chose a new order: version notes from 10 down to 5 first, then current work, then decisions, then features down to 5. D8's last resort is unchanged. This replaces the order stated in this plan's header and Task 2 code. A large project at a 4,200-byte budget now shows 12 feature rows and 5 notes, at 4,200 bytes; before it was 5 rows and 8 notes.

**Controller rulings**
- **Full test suites run from inside each package folder**, as CI does, and not with `fvm dart test packages/…` from the root as Task 5 Step 1 wrote. From the root, the package's `dart_test.yaml` skip of `integration` isn't applied, and `process_runner_test` resolves a helper relative to the working directory.
- **`_plainId` rejects any `$`**, not only `$(` as D5 said. §6.5 outranks the plan's narrower wording.
- **Left as they are:**
  - a YAML list or map title is shown as written (`[a, b]`);
  - a cut can briefly lengthen the text, but the loop still converges;
  - the index-md "Real sizes" scratch-app figure was measured before the fixes.

**Numbers**
- **Full check at `4585951`:**
  - analyze and format are clean (271 files) and `dependency_validator` is clean;
  - tests: repo tools 212, CLI 34, engine 655 with 5 skipped, lints 19, protocol 56, integration 7;
  - `check_guide` passed and the BOM scan is clean.
- **After the fixes:** engine 659.
- **`measure_sync` (Windows, 200 files):** the first sync takes 14.2 s; a full sync takes 8.5 s, against the 30 s target.
- **INDEX.md sizes:**
  - the fixture on the real SDK: 3,951 bytes;
  - a fresh `flutter create --platforms=android,ios` app (created by the PATH Flutter 3.38.6, synced on 3.47.5): 3,551 bytes, with 10 notes and "None found." for features.

**Carried** (on top of "Carried to later slices" above)
- A machine path can reach INDEX.md and `delta.md` through the map's skip reason (`project_analysis.dart:87,121`, an incomplete SDK). This has existed since 1b.5. Give the reason without the path.
- `ios_native.dart`'s `_variablesNote` checks only `$(`, a 1b.4 gap. Make it match `_plainId`.
- **Markdown edge cases in names:**
  - a decision file name with `<`, `>` or `]` breaks its link;
  - a backtick in a feature name breaks its code span;
  - `*` or `_` can become emphasis.
- The iOS id line drops `native.json`'s note that a `.xcconfig` file can override it.
- **Decision files that are skipped or misreported:**
  - `.MD` files and symlinked decision files are skipped without a word;
  - a UTF-16 file (PowerShell 5.1 `>`) is reported as "it has no front matter".
