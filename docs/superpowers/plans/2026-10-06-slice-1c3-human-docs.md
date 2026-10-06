# Slice 1c.3: Human Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `appstein docs` renders a Flutter project's knowledge into readable Markdown in `docs/app/`, and `appstein docs --check` says whether those pages are behind, so a developer can understand the app without asking an agent.

**Architecture:** Rendering is a pure function: knowledge in, a map of page path to final text out. Packs contribute pages as Dart objects (`DocPage`) that return Markdown sections for a named file; the engine joins sections, adds the marker and renders its own three pages. A separate small IO layer compares the result with the docs folder, writes what differs and deletes marked pages that are no longer rendered. One engine function (`runDocs`) ties it together: freshness first, then read, render and write under the existing `.appstein/.lock`.

**Tech Stack:** Dart 3.13 (Flutter 3.47.5 through FVM), `package:crypto`, `package:path`, `package:args`, `package:test`. No new dependency.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md` §5.3 (command table), §6.9, §7 (`docs:`), §10 (`docPages`), §15 (`appstein docs` < 2 s). The spec text for this slice was approved by the owner and committed as `004c2dc`; two sentences found while planning (permissions without their plugin, a file in the way) were approved and are in the plan's commit.

## Owner decisions (2026-10-06)

1. `appstein docs` and `appstein docs --check` both bring the knowledge up to date first (the freshness step the MCP tools use).
2. A page with the marker that is no longer rendered is deleted; `--check` reports it as stale.
3. When the knowledge can't be made current or the project map is missing, nothing in `docs/app/` is written, removed or judged, and the command exits 1.
4. `decisions.md` shows proposed decisions in their own section, after the accepted ones.
5. A page's marker holds its templates' version (the contributing packs' versions, or the engine's docs version), not the Appstein version.
6. One slice, not split. `dependencies.md` has no package-gate verdict until slice 1d.
7. The pack concept text is the draft shown in chat on 2026-10-06 (Task 5 and Task 6 carry it).
8. The plan gives exact interfaces, behaviors and test cases, not every line of code.
9. `native.md` lists each permission with its manifest and line; the plugin that needs it joins the page once the map records it (1d).
10. A file without the marker at a path a page would be written to: nothing is written or removed, the file is named, exit 1.
11. Execution: native, with one review of the whole branch.

## Global Constraints

- Every Dart command runs through `fvm dart` / `fvm flutter`. Run each package's suite from inside the package folder, and the repo-root suite too.
- Tests first: write the test, watch it fail, then write the code.
- Never guess: a value that can't be read is shown as unknown with its reason. A class without a `///` comment is shown as "No description yet".
- Output is deterministic: every list is sorted, nothing depends on the file system's order, the clock or the machine. Pages have no timestamp.
- Pages are written as UTF-8 without a BOM, with `\n` line endings and one final newline.
- Every public API has a `///` comment. No file gets a byte order mark (the BOM gate runs before every commit).
- The engine core imports no pack (§5.1). Stack text and layout live in `official_mvvm`; Android and iOS text and layout live in their packs.
- The engine has no command-line code; printing and exit codes live in `appstein_cli`.
- No Play Store or App Store policy appears in any concept text.
- Windows is first-class: paths with spaces, drive letters, `\r\n` checkouts, files held open.
- Not in this slice: the `docs.stale` check and `document_public_classes` (1d); rendering at `create` and from the Stop hook (1e); an HTML site.
- Edit files with the Edit and Write tools only.

## Review Focus

1. **A docs folder checked out with `\r\n` on Windows:** `--check` exits 0 and `docs` writes nothing.
2. **Text from the app that Markdown or Mermaid would misread** (a decision title with `|`, a class summary with a backtick or `<br>`, a feature or file name with a space, `#` or parentheses): the table keeps its columns, the diagram still parses, links still point at the file.
3. **A file a person wrote where a page should go** (`docs/app/routes.md` without the marker), or a page path that differs only in letter case on Windows and macOS: never overwritten; the command says so.
4. **A docs folder that is odd** (`docs.path` is a file, a symlink inside it, a file held open, an unreadable file, a non-UTF-8 `.md`): nothing is damaged, and the message names the file.
5. **A render that would shrink the set** (the map was skipped, a knowledge file is damaged, a pack page throws): no page is written and no page is deleted.

---

### Task 1: Markdown helpers and the page marker

**Files:**
- Create: `packages/appstein_engine/lib/src/docs/markdown_text.dart`, `packages/appstein_engine/lib/src/docs/doc_marker.dart`
- Test: `packages/appstein_engine/test/docs/markdown_text_test.dart`, `packages/appstein_engine/test/docs/doc_marker_test.dart`

**Produces:**

```dart
// markdown_text.dart
/// [text] on one line, safe inside a table cell or a sentence: line breaks
/// and tabs become one space; `\`, `|`, `` ` ``, `*`, `_`, `[`, `]`, `<`, `>`
/// and a leading `#` are escaped with a backslash.
String mdText(String text);

/// [text] as inline code. The fence is one backtick longer than the longest
/// run of backticks in [text]; `|` becomes `\|` so a table cell survives.
String mdCode(String text);

/// A table with [headers] and [rows], each cell already escaped by the
/// caller. Ends with a newline. With no rows it returns the empty string.
String mdTable(List<String> headers, List<List<String>> rows);

/// [text], line by line, as a block quote (`> `); a blank line is `>`.
String mdQuote(String text);

/// A link from the page at [page] (a path inside the docs folder, with `/`)
/// to [target] (a path from the project root, with `/`), with `#L<line>`
/// when [line] is given. [docsPath] is the docs folder from the project
/// root, such as `docs/app`. Each path segment is percent-encoded.
String projectLink({required String docsPath, required String page,
    required String target, int? line, String? text});

/// A link from the page at [page] to the page at [other], both inside the
/// docs folder.
String pageLink({required String page, required String other,
    required String text});

/// A Mermaid node id made of ASCII letters, digits and `_` from [prefix]
/// and [index], such as `vm_0`.
String mermaidId(String prefix, int index);

/// [text] as a quoted Mermaid label: `"` becomes `#quot;`, line breaks
/// become a space, `<` and `>` become `#lt;` and `#gt;`.
String mermaidLabel(String text);

// doc_marker.dart
/// The version of the engine's own page templates. Bump it when README.md,
/// dependencies.md or decisions.md, or the page frame, changes shape.
const docsEngineVersion = '1';

/// The second line of every generated page.
const docNotice = '> Generated by Appstein; edits are overwritten. Write '
    '`///` doc comments or a team note instead.';

final class DocMarker {
  const DocMarker({required this.templates, required this.inputs, required this.body});
  final Map<String, String> templates; // contributor id -> version, in order
  final String inputs;                 // sha256 hex
  final String body;                   // sha256 hex
  /// `<!-- appstein:generated templates=engine@1 inputs=<hex> body=<hex> -->`
  String get line;
  /// The marker in the first line of [text]; null when there is none. A BOM
  /// before it and `\r` after it are allowed.
  static DocMarker? of(String text);
}

/// The page text for [body] (everything after the marker line):
/// marker line, `\n`, body.
String markedPage(DocMarker marker, String body);

/// The body of a page [text] that has a marker: everything after its first
/// line, with `\r\n` and lone `\r` turned into `\n`.
String bodyOf(String text);

/// sha256 hex of [body]'s UTF-8 bytes, after the same line-ending change.
String bodyHash(String body);
```

**Behaviors and tests:**
- [ ] `mdText`: each escaped character; `a|b` in a table row keeps two columns; a multi-line text is one line; a leading `# x` is not a heading; non-ASCII is unchanged.
- [ ] `mdCode`: plain; text containing one backtick; text that is only backticks; text with `|`.
- [ ] `mdTable`: header, separator, rows; empty rows give `''`.
- [ ] `mdQuote`: one line, three lines with a blank one, text that starts with `# `.
- [ ] `projectLink` from `README.md` (`../../lib/main.dart`), from `features/auth/login.md` (`../../../../lib/...`), with `docsPath: 'docs'` and `docsPath: 'a/b/c'`, with a line, with a space and a `#` in a segment (`%20`, `%23`).
- [ ] `pageLink` from `README.md` to `features/auth/login.md` and back, and between two feature pages in different folders.
- [ ] `mermaidLabel`: quotes, angle brackets, a line break.
- [ ] `DocMarker.line` and `DocMarker.of` round-trip; one and two templates; `of` returns null for a page whose first line is a heading, for an empty text, for a marker with a missing field, for a marker on line 2; it accepts a BOM and `\r\n`.
- [ ] `bodyHash('a\r\nb\n') == bodyHash('a\nb\n')`.

- [ ] Commit: `feat: Markdown helpers and the generated-page marker`

---

### Task 2: What a page may read, and how a pack contributes pages

**Files:**
- Create: `packages/appstein_engine/lib/src/docs/docs_knowledge.dart`, `packages/appstein_engine/lib/src/docs/doc_page.dart`
- Modify: `packages/appstein_engine/lib/src/packs/pack.dart` (add `docPages`), the three packs (return `const []` for now), `packages/appstein_engine/lib/src/mcp/knowledge_snapshot.dart` (add `sdk` and `deps` reads), `packages/appstein_engine/lib/appstein_engine.dart` (exports)
- Test: `packages/appstein_engine/test/docs/docs_knowledge_test.dart`, extend `test/mcp/knowledge_snapshot_test.dart`

**Produces:**

```dart
// docs_knowledge.dart
/// A Markdown file in the docs folder that Appstein didn't generate.
final class TeamNote { const TeamNote({required this.path, required this.title});
  final String path;   // inside the docs folder, with `/`
  final String title;  // its first `# ` heading, or its path
}

/// Everything the human docs are rendered from (spec §6.9).
final class DocsKnowledge {
  const DocsKnowledge({required this.docsPath, required this.projectName,
      required this.platforms, required this.stack, required this.sdk,
      required this.features, required this.symbols, required this.routes,
      required this.layers, required this.deps, required this.native,
      required this.decisions, this.teamNotes = const []});
  final String docsPath;          // such as docs/app
  final String? projectName;      // pubspec name; null when unreadable
  final List<String> platforms;   // platform folders that exist
  final String stack;             // the stack pack's id
  final SdkInfo sdk;
  final FeaturesMap features; final SymbolsMap symbols; final RoutesMap routes;
  final LayersMap layers; final DepsMap deps; final NativeConfig native;
  final DecisionSet decisions;
  final List<TeamNote> teamNotes;

  /// A view that records which parts were read.
  DocsView view();
  /// The digest of the part named [name] (one of [DocsView.read]'s names).
  String digestOf(String name);
}

/// One page source's view of the knowledge. Each getter records its name in
/// [read]; [docsPath] is not recorded (it is part of every page's hash).
final class DocsView {
  String get docsPath;
  String? get projectName; List<String> get platforms; String get stack;
  SdkInfo get sdk; FeaturesMap get features; SymbolsMap get symbols;
  RoutesMap get routes; LayersMap get layers; DepsMap get deps;
  NativeConfig get native; DecisionSet get decisions;
  List<TeamNote> get teamNotes;
  Set<String> get read;   // names, such as `features`, `native`
}

// doc_page.dart
/// One piece of a page: Markdown that goes into the file at [path].
final class DocSection { const DocSection({required this.path,
    required this.title, required this.markdown});
  final String path;      // inside the docs folder, with `/`, ending `.md`
  final String title;     // the page's `# ` heading; the first section's wins
  final String markdown;  // starts at `## ` level or with plain text
}

/// A source of pages in a pack (spec §6.9, §10).
abstract interface class DocPage {
  /// A short name for error messages, such as `features`.
  String get id;
  /// The sections it contributes: none, one, or one per feature.
  List<DocSection> sections(DocsView knowledge);
}

// pack.dart
  /// The human doc pages it renders (spec §6.9).
  List<DocPage> get docPages;
```

**Behaviors and tests:**
- [ ] Digests: a part's digest is the sha256 of its canonical JSON (`toJson()` without `meta`), so `generatedAt` never changes it. `decisions` is digested from each file's bytes by name plus the set's problems. `teamNotes` from paths and titles. Two `DocsKnowledge` with equal content have equal digests; changing one symbol's summary changes only `symbols`.
- [ ] A view records exactly the getters called; a fresh view has an empty `read`.
- [ ] `KnowledgeSnapshot.sdk` reads `platform/sdk.json` and `.deps` reads `map/deps.json`: loaded, missing and damaged cases, as the existing reads are tested.
- [ ] The three packs compile with `docPages => const []`; `packs_test` in the CLI still passes.

- [ ] Commit: `feat: DocsKnowledge, DocPage and Pack.docPages`

---

### Task 3: The renderer

**Files:**
- Create: `packages/appstein_engine/lib/src/docs/docs_renderer.dart`
- Test: `packages/appstein_engine/test/docs/docs_renderer_test.dart`, `test/docs/support/docs_support.dart` (a `sampleKnowledge({...})` builder and fake `DocPage`s)

**Produces:**

```dart
final class RenderedPage { const RenderedPage({required this.path,
    required this.title, required this.text, required this.marker});
  final String path; final String title;
  final String text;        // the whole file
  final DocMarker marker;
}

/// A page source that misbehaved: an Appstein or pack bug.
final class DocPageError extends Error { /* pack id, page id, message */ }

/// Renders every page, sorted by path (spec §6.9). [sources] pairs each
/// contributor id and version with its pages, in order: the engine's own
/// first, then each pack's. `README.md` is rendered last by [readme], which
/// is given the other pages.
List<RenderedPage> renderPages({
  required DocsKnowledge knowledge,
  required List<({String id, String version, List<DocPage> pages})> sources,
  required DocSection Function(DocsView knowledge, List<RenderedPage> pages) readme,
});
```

**Page frame** (exact):

```
<marker line>
<docNotice>

# <title>

<section 1 markdown, trimmed>

<section 2 markdown, trimmed>
```

with one `\n` at the end.

**Behaviors and tests:**
- [ ] One source, one section: the frame above, byte for byte.
- [ ] Two sources contributing to the same path: sections in source order, the first section's title, `templates` lists both contributors in order; a source contributing two sections to one path is listed once.
- [ ] `marker.inputs` covers: `docsPath`, the page's `templates`, and the digest of every part its contributors read. Changing a part a page didn't read leaves that page's text unchanged; changing one it read changes `inputs`.
- [ ] `marker.body` is `bodyHash` of everything after the marker line.
- [ ] Rendering the same knowledge twice gives identical text for every page.
- [ ] README: rendered last, receives the other pages sorted by path, its template is `engine@docsEngineVersion`.
- [ ] `DocPageError` (and no pages) when a section's path is `README.md`, is absolute, has `..`, `\`, an empty segment, doesn't end in `.md`, or two paths differ only in letter case; when a title or the markdown is empty; when a page's `sections` throws (the error names the pack and the page and keeps the cause).
- [ ] A source with no sections contributes nothing and is in no marker.

- [ ] Commit: `feat: renderPages joins sections into marked pages`

---

### Task 4: The engine's pages (`README.md`, `dependencies.md`, `decisions.md`)

**Files:**
- Create: `packages/appstein_engine/lib/src/docs/pages/readme_page.dart`, `dependencies_page.dart`, `decisions_page.dart`, and `packages/appstein_engine/lib/src/docs/engine_pages.dart` (`const engineDocPages = [DependenciesPage(), DecisionsPage()]`, `readmeSection`)
- Test: `packages/appstein_engine/test/docs/pages/readme_page_test.dart`, `dependencies_page_test.dart`, `decisions_page_test.dart`

**`dependencies.md`** (title `Dependencies`):
- Intro sentence: the versions are the resolved ones from `pubspec.lock`.
- `## Direct` (dependency `direct main`), `## Dev` (`direct dev`), `## Overridden` (`direct overridden`): a table `Package | Version | Constraint | Source | Used in`. A group with no package is left out.
- `Used in`: `not imported` for none; otherwise the number of files and the first five as links, then `and N more`.
- `## Transitive`: one sentence with the count, then a table `Package | Version | Source`.
- No packages at all: one sentence saying `pubspec.lock` lists none.

**`decisions.md`** (title `Decisions`):
- Intro: what a decision is and that agents propose and people accept (two sentences).
- `## Accepted`: for each accepted entry in file-name order, `### <number> <title>`, a line with the date when there is one and a link to the record (`.appstein/decisions/<file>`), the paths as inline code when there are any, then the Why as a block quote (`mdQuote`). An empty Why reads `No reason recorded.`
- `## Proposed, not yet agreed`: the same shape, after a sentence saying how to accept (`record_decision` with `accept`, or edit `status:`).
- `## Superseded`: a list, one line each: number, title, and `replaced by <number>` when another decision names it (§6.7).
- `## Problems`: only when there are any: unreadable files with the reason, numbers used twice with the files, and the set's other problems.
- A section with no entry is left out. With no decision files at all: one sentence, `No decisions are recorded yet.`

**`README.md`** (title: the project name, or `This app` when it is unknown):
- A table `| | |` of facts: Stack, Platforms, Flutter (version and channel), Dart, Language version (left out when null), then the lines of `appIdLines(native)` (reused from `index_sources.dart`, so INDEX.md and the README never disagree).
- `## Run it`: a `sh` code block with `flutter pub get` and `flutter run`, each prefixed with `fvm ` when `sdk.fvmVersion` is set. When Android has flavors, one sentence naming them and `--flavor <name>`.
- `## Pages`: a list of links to every non-feature page with its title. `## Features`: a list of links to the feature pages (left out when there are none). `## Team notes`: a list of links to each team note by title (left out when there are none).

**Tests** (unit, on `sampleKnowledge`):
- [ ] dependencies: each group; a group left out; `not imported`; exactly five usages; six usages (`and 1 more`); a path dependency with a null constraint (an empty cell); a package name needing no escape and a constraint with `^` and `>=`.
- [ ] decisions: accepted, proposed and superseded together; a decision superseded only because another names it (listed under Superseded with `replaced by`); an unreadable file and a duplicate number under Problems; no files; a title with `|` and `#`; a Why with a `# heading` line and a fake marker line (both stay inside the quote).
- [ ] readme: with and without FVM; with flavors; one platform; unknown project name; no features; team notes listed by title; a team-note path with a space.

- [ ] Commit: `feat: the engine's doc pages`

---

### Task 5: `official_mvvm` pages (`architecture.md`, `features/<feature>.md`, `routes.md`)

**Files:**
- Create: `packages/appstein_engine/lib/src/packs/official_mvvm/docs/concepts.dart`, `architecture_page.dart`, `feature_pages.dart`, `routes_page.dart`
- Modify: `official_mvvm_pack.dart` (`docPages`)
- Test: `packages/appstein_engine/test/packs/official_mvvm/docs/architecture_page_test.dart`, `feature_pages_test.dart`, `routes_page_test.dart`

**Concept text** (`concepts.dart`, constants; owner-approved draft):
- Screen: "A widget that shows state and passes on what the user does. It holds no business logic."
- View model: "Holds the state of one screen and the actions the screen can run. It extends `ChangeNotifier`, and the screen rebuilds when it notifies."
- Repository: "The one place a kind of data lives, such as bookings or the signed-in user. It turns what services return into the app's own models and handles caching and errors."
- Service: "Wraps one outside source: an HTTP API, a plugin, local storage. It holds no state."
- Domain model and use case: "The app's own data types, and logic that several view models share."

**`architecture.md`** (title `Architecture`):
- One sentence: the app follows Flutter's recommended architecture (MVVM), and the pack's name.
- `## The parts`: the five concepts as a list.
- `## Which layer may use which`: a Mermaid `flowchart TD` built from `officialMvvmLayerRules`: a solid arrow `from --> to` for each `allow` pair, a dotted arrow `from -.->|interfaces only| to` for each `interfaces` pair. Layers with no `allow` entry are named in one sentence as unrestricted. The `test` layer is left out of the diagram and named in that sentence.
- `## Where each layer lives`: a table `Layer | Folders | Files in this app`, from the rules' globs and a count from `layers.json`.
- `## Rule breaks right now`: only when `layers.violations` is not empty: a table `File | Imports | From layer | To layer`, with a link to the line.

**`features/<name>.md`** (title `Feature: <name>`, one page per feature, sorted):
- The folder as inline code.
- A Mermaid `flowchart LR` with one subgraph per kind that has members, in the order Screens, View models, Repositories, Services, each node labelled with the class name, and one arrow from each subgraph to the next one present. A sentence under it says the arrows show the kinds, not which class calls which.
- `## Classes`: a table `Class | Kind | Declared at | What it is for`, in the order screens, view models, repositories, services, models. The summary comes from `symbols` (same name and file); without one, `No description yet`.
- `## Routes`: the routes whose screen is one of the feature's screens: `Path | Name | Screen | Declared at`. Without any: `No route builds a screen of this feature.`
- `## Tests`: links to the feature's tests. Without any: ``No tests under `test/ui/<name>/` yet.``

**`routes.md`** (title `Routes`):
- `## Routers`: each `GoRouter` with its file and line, and whether it has a top-level redirect.
- `## Route tree`: a nested list by `parent`, sorted by path, each line: the path as code, the name when there is one, then `shows <Screen>` with a link to the route's line; `redirects to <path>` when `redirectTo` is set; `redirects (decided in code)` when `redirect` is true without it.
- `## Unresolved`: routes with `unresolved`, each with its reason and file and line, after a sentence saying Appstein never guesses them. Left out when there are none.
- No routes and no routers: one sentence.

**Tests:**
- [ ] architecture: the diagram's edges equal the rules' pairs exactly (test by parsing the lines, so a rule change can't leave the diagram behind); the folder table; the violations section present and absent.
- [ ] features: a feature with all kinds; one with only a screen (one subgraph, no arrow); a nested name gives `features/auth/login.md` and links climb the right number of folders; a class without a summary; a class name appearing in two files picks the summary by file; no routes; no tests; a summary with `|` and a backtick.
- [ ] routes: a nested tree; a route with a parent that isn't in the list (shown at the top); a constant redirect; a code redirect; an unresolved route with a null path; none at all.

- [ ] Commit: `feat: official_mvvm renders architecture, feature and route pages`

---

### Task 6: `native.md` from the platform packs

**Files:**
- Create: `packages/appstein_engine/lib/src/docs/native_section.dart` (shared, no platform knowledge), `packages/appstein_engine/lib/src/packs/android/android_docs.dart`, `packages/appstein_engine/lib/src/packs/ios/ios_docs.dart`
- Modify: `android_pack.dart`, `ios_pack.dart` (`docPages`)
- Test: `packages/appstein_engine/test/docs/native_section_test.dart`, `test/packs/android/android_docs_test.dart`, `test/packs/ios/ios_docs_test.dart`

**Produces** (`native_section.dart`):

```dart
/// The page both platform packs write into.
const nativePagePath = 'native.md';
const nativePageTitle = 'Native setup';

/// One value as table cells: what it is, and where.
/// found: the value as code; with an expression, `<expression>` then the
/// value and `(from <resolvedFrom>)`; a list joined with `, `; plus the note.
/// unknown: `unknown: <reason>`. absent: `not set` and the reason.
({String value, String where}) nativeCells(NativeValue value,
    {required String docsPath, required String page});

/// Tables for every part of [group]: its own values as one table
/// `Setting | Value | Where`, then each child group under a heading and each
/// list as a table with one row per entry. [headings] renames keys;
/// [order] puts the named keys first; every other key follows, sorted, so
/// nothing in the section is dropped.
String nativeTables(NativeGroup group, {required String docsPath,
    required String page, Map<String, String> headings = const {},
    List<String> order = const [], int level = 3});
```

**Android section** (`## Android`): the concept text, then `nativeTables` over the `android` section with these headings and order: `app` "App module", `settings` "Build tools", `gradle` "Gradle", `manifests` "Manifests and permissions", `gradleProperties` "Gradle properties".

Concept text:
- "**Application ID.** The app's identity on a device. A different ID is a different app."
- "**SDK levels.** `minSdk` is the oldest Android the app installs on, `targetSdk` the version it was tested against, and `compileSdk` the version it is built with. A value written as `flutter.minSdkVersion` comes from the Flutter SDK, so it moves when Flutter is upgraded. A number written by hand overrides that."
- "**Permissions.** Each one a manifest declares, with the manifest and line."

**iOS section** (`## iOS`): the concept text, then `nativeTables` over the `ios` section: `xcode` "Xcode project", `infoPlist` "Info.plist", `swiftPackageManager` "Swift Package Manager", `generatedPackage` "Generated plugin package".

Concept text:
- "**Bundle identifier.** The app's identity on a device."
- "**Deployment target.** The oldest iOS the app runs on."
- "**Usage descriptions.** The `Info.plist` texts iOS shows when the app asks for the camera, location and so on."

A section that is a single value (no folder, unknown, or an internal error) is the heading and one sentence with the reason; an `error` section says Appstein failed to read it and to report it. A pack whose section is missing from `native.json` contributes nothing.

**Tests:**
- [ ] `nativeCells`: found plain; found with expression and `resolvedFrom`; a list value; a boolean; a note; unknown; absent with and without `at`; `at` with and without a line.
- [ ] `nativeTables`: order and headings; an unlisted key still appears; a list of entries with children; an empty list (`none`); nested groups two deep.
- [ ] Android and iOS on the section from `goldens/native.json.golden`: text goldens `docs/native-android.golden` and `docs/native-ios.golden`; a `no android/ folder` section; an `error` section.
- [ ] Both packs through `renderPages`: one `native.md` with Android then iOS, `templates=android@…,ios@…`; with only the iOS pack, only iOS.

- [ ] Commit: `feat: the android and ios packs render native.md`

---

### Task 7: The docs folder: scan, compare, write

**Files:**
- Create: `packages/appstein_engine/lib/src/docs/docs_folder.dart`
- Test: `packages/appstein_engine/test/docs/docs_folder_test.dart`

**Produces:**

```dart
/// What is in a docs folder now.
final class DocsFolderScan {
  final Map<String, String> generated;   // path -> text, files with the marker
  final List<TeamNote> teamNotes;        // `.md` files without it, sorted
  final List<String> problems;           // sentences; non-empty stops the run
}

/// Reads the docs folder at [folder] (absolute). A missing folder is an
/// empty scan. Only `.md` files (any letter case) are read; links are not
/// followed.
DocsFolderScan scanDocsFolder(String folder);

enum DocChangeKind { unchanged, write, remove }

/// Why a page is not current.
enum DocStaleReason { missing, behind, handEdited, notRendered }

final class DocChange { final String path; final DocChangeKind kind;
  final DocStaleReason? reason;      // null when unchanged
  final bool hadHandEdits;           // a written or removed page was hand-edited
}

/// The changes that make the folder match [pages], sorted by path, and the
/// files that stand in the way.
({List<DocChange> changes, List<String> blocked}) planDocs(
    DocsFolderScan scan, List<RenderedPage> pages);

/// Writes and removes what [changes] says, each file in one step
/// (`replaceFile`), `README.md` last, then removals, then folders the
/// removals left empty (never the docs folder itself).
/// Throws `KnowledgeWriteException` when a file can't be written or removed.
Future<void> applyDocs(String folder, List<RenderedPage> pages,
    List<DocChange> changes);
```

**Rules:**
- A file counts as generated when `DocMarker.of` reads its first line. Its text is compared with the rendered text after turning `\r\n` and `\r` into `\n` and dropping a BOM: equal means `unchanged`.
- Not equal: `handEdited` when the file's own `bodyHash(bodyOf(text))` differs from its marker's `body`; otherwise `behind`.
- A generated file whose path no page has: `remove`, reason `notRendered`.
- A rendered path with no file: `write`, reason `missing`.
- **Blocked** (nothing may be written): a rendered path where a file without the marker exists, where a folder or a link exists, or whose parent path is a file; the docs folder path being a file. Each is one sentence naming the path and what to do (move or rename it).
- **Problems** from the scan: a folder or file that can't be listed or read (with `fileErrorReason`), and `.md` bytes that aren't UTF-8 at a path a page needs. A non-UTF-8 team note is listed by its path as title.
- Paths compare exactly; on a file system that ignores case, the existence check finds the differently-cased file and it is blocked or matched as the system reports it.

**Tests** (real temp folders, with a space in the path):
- [ ] Missing folder: every page is `write/missing`; `applyDocs` creates folders and files; a second `planDocs` is all `unchanged`.
- [ ] A `\r\n` copy of every page, and a copy with a BOM: all `unchanged`, and `applyDocs` leaves the files' bytes and modified times alone.
- [ ] A page with one line changed in its body: `handEdited`, `hadHandEdits`; after `applyDocs` it equals the render.
- [ ] A page whose marker and body are an older valid render: `behind`.
- [ ] A marked `features/old.md` that isn't rendered: `remove`; after `applyDocs` the file is gone, `features/` stays when another page is in it and goes when it was the last, and the docs folder itself stays.
- [ ] A hand-edited marked page that isn't rendered: removed, `hadHandEdits`.
- [ ] Team notes: `onboarding.md` and `runbooks/deploy.md` without the marker are in `teamNotes` with their headings as titles, are never in `changes`, and are byte-identical after `applyDocs`. A `.txt` file and an image are ignored.
- [ ] Blocked: an unmarked `routes.md`; a folder named `routes.md`; `features` being a file; the docs folder being a file. `applyDocs` is not called by the caller; the test asserts `blocked` and that nothing changed.
- [ ] A write that fails (a folder at `<file>.tmp`): `KnowledgeWriteException`; the old page is intact.
- [ ] A link inside the folder (skipped on Windows when links can't be made): not followed, not removed.

- [ ] Commit: `feat: scan, compare and write the docs folder`

---

### Task 8: `runDocs`: freshness, read, render, write

**Files:**
- Create: `packages/appstein_engine/lib/src/docs/docs_run.dart`
- Test: `packages/appstein_engine/test/docs/docs_run_test.dart`

**Produces:**

```dart
/// What `appstein docs` did, or why it did nothing.
sealed class DocsOutcome {}
/// `docs.enabled` is false.
final class DocsDisabled extends DocsOutcome {}
/// Nothing was written, removed or judged (spec §6.9).
final class DocsRefused extends DocsOutcome {
  final String problem; final String? fixHint; final List<String> details; }
/// The pages were compared, and written unless [check].
final class DocsDone extends DocsOutcome {
  final String docsPath; final bool check;
  final List<DocChange> changes; final List<TeamNote> teamNotes;
  bool get stale; // any change that isn't `unchanged`
}

/// Renders the human docs of the project at [projectRoot] (spec §6.9).
/// [sync] is the `KnowledgeSync` to bring the knowledge up to date with;
/// [packs] are the project's packs, in order.
Future<DocsOutcome> runDocs({required String projectRoot,
    required AppsteinConfig config, required List<Pack> packs,
    required KnowledgeSync sync, required bool check, String? dartSdkPath});
```

**Steps, in order:**
1. `config.docs.enabled` false: `DocsDisabled`, before anything else runs.
2. `sync.detect(projectRoot)`. `SyncException`, `KnowledgeLockTimeout` and `KnowledgeWriteException` become `DocsRefused` with the same problem and fix hint the MCP server gives. Any other error is not caught (a crash, exit 3).
3. A report whose `map?.skipped` is set: `DocsRefused('the project map is missing: <reason>')`, fix hint as `appstein sync` prints it.
4. Under the knowledge lock (`KnowledgeStore.locked`, the sync's timeout): read `sdk`, `features`, `symbols`, `routes`, `layers`, `deps`, `native` through `KnowledgeSnapshot` and the decisions through `readDecisions`. Any read problem: `DocsRefused` naming the file.
5. Scan the docs folder; scan problems: `DocsRefused` with them as details.
6. Build `DocsKnowledge` (project name with `projectNameOf`, platforms with `platformFolders`, stack from `config.packs.stack`), render with the engine's pages first, then each pack's.
7. `planDocs`; anything blocked: `DocsRefused('a file is in the way')` with the sentences as details.
8. `check`: return `DocsDone` with the plan. Otherwise `applyDocs`, then return it.

A timeout on the lock in step 4 is a `DocsRefused` too.

**Tests** (the fixture app through `copyFixtureApp` and the `knowledgeSync` harness, plus two decision files written with `handDecision`):
- [ ] First run: every page `write/missing`; the folder then holds `README.md`, `architecture.md`, `routes.md`, `dependencies.md`, `decisions.md`, `native.md` and one page per fixture feature. A second run: all `unchanged`, and no file's bytes or modified time changed.
- [ ] `check` on a project with no docs folder: `stale`, and the folder still doesn't exist.
- [ ] Edit a view model's `///` comment, run with `check`: only that feature's page is `behind`. Run without: it is written; `check` again is clean.
- [ ] Delete a feature's folder from the app: its page is `remove/notRendered` and the README changes.
- [ ] Add a decision file: only `decisions.md` changes.
- [ ] The map can't be built (packages not fetched, `flutter pub get` fails through the fake runner): `DocsRefused`; an existing docs folder is byte-identical afterwards, and a stale marked page in it is still there.
- [ ] No Flutter SDK: `DocsRefused` with the sync's problem.
- [ ] A damaged `map/routes.json` that the sync considers current can't happen (freshness finds the hand change and rebuilds): assert the rebuild, then a clean render.
- [ ] Another process holds the lock past the timeout (`hold_lock.dart`): `DocsRefused`, nothing written.
- [ ] `docs.enabled: false`: `DocsDisabled`, and the sync was never called (a runner that fails the test if used).
- [ ] `docs.path: documentation/the app`: pages land there, and links to source files climb three folders.
- [ ] An unmarked `routes.md` in the folder: `DocsRefused`, every other file untouched.
- [ ] **Goldens:** each rendered page of the fixture app against `goldens/docs/<path>.golden` with `expectTextGolden`. Review each golden by eye before committing it: this is the output a person reads.

- [ ] Commit: `feat: runDocs renders the human docs from fresh knowledge`

---

### Task 9: `appstein docs [--check]`

**Files:**
- Create: `packages/appstein_cli/lib/src/docs_command.dart`
- Modify: `packages/appstein_cli/lib/src/runner.dart` (register), `packages/appstein_cli/lib/appstein_cli.dart` (export if the others are)
- Test: `packages/appstein_cli/test/docs_command_test.dart`, extend `runner_test.dart` (help lists `docs`)

**Behavior:**
- No project: the same two-line message as `sync`, exit 3. An invalid `appstein.yaml`: the message and `Fix appstein.yaml, then run \`appstein docs\` again.`, exit 3.
- The `KnowledgeSync` is built as `sync` builds it, with `packageSkills: false`: package skills start a process and write agent folders, which belongs to `appstein sync`.
- Exit codes: `DocsDisabled` 0; `DocsRefused` 1; `DocsDone` 0, or 1 when `check` and `stale`.

**Output** (`String formatDocs(DocsOutcome outcome)`, public, to stdout; refusals to stderr):

```
Rendered docs/app/: 2 written, 1 removed, 9 unchanged.
  features/booking.md  written (overwrote hand edits)
  native.md            written
  features/old.md      removed
```

```
docs/app/ is up to date (12 pages).
```

```
docs/app/ is behind the app: 3 of 12 pages.
  features/booking.md  hand-edited
  features/old.md      no longer rendered
  native.md            missing
Run `appstein docs` to update them.
```

```
Human docs are turned off (docs.enabled is false in appstein.yaml).
```

Refusal: `Nothing in docs/app/ was changed: <problem>.`, each detail indented two spaces, then the fix hint.

Unchanged pages are counted, never listed. `behind` prints as `behind the app`.

**Tests:**
- [ ] `formatDocs` for each shape above, singular and plural counts, a first run (all written), a refusal with and without details.
- [ ] Through `runAppstein` on the fake-SDK project (its map can't be built): `docs` and `docs --check` exit 1, stderr names the map, no `docs/` folder appears.
- [ ] `docs.enabled: false`: exit 0 with the message, for both forms.
- [ ] No `pubspec.yaml`: exit 3. `--project` pointing at the project from another folder works.
- [ ] `appstein help` lists `docs`; `appstein docs --help` describes `--check`.

- [ ] Commit: `feat: appstein docs [--check]`

---

### Task 10: The real binary, and the 2-second budget

**Files:**
- Modify: `tool/measure_sync.dart`, `.github/workflows/ci.yml` only if the measuring step needs a new line, `packages/appstein_engine/test/mcp/mcp_stdio_test.dart`'s neighbour: create `packages/appstein_cli/test/docs_process_test.dart`

**Behavior and tests:**
- [ ] `docs_process_test.dart` (runs on the three CI systems): copy the fixture app with its stub packages into a temp folder with a space in its name, run the CLI as a real process (`dart run` of `bin/appstein.dart`, the way `mcp_stdio_test` starts it) with `docs`, then `docs --check`: exit 0 and 0, stdout as `formatDocs` prints; then append a line to one page and run `--check`: exit 1 naming it as hand-edited.
- [ ] `measure_sync.dart`: after the sync measurements on the 200-file app, measure `appstein docs` three times from fresh knowledge (first render, then two unchanged runs) and report the median; fail when the median is 2 s or more (spec §15). Add the row to the summary table it prints.
- [ ] Run `measure_sync` locally and record the numbers in the notes from execution.
- [ ] By hand: build the CLI, run `docs` on a copy of the fixture app that has Android and iOS folders from a real `flutter create` (as the 1c.2 proof run did), open the pages on disk and read every one. Fix what reads badly; record what was changed.

- [ ] Commit: `test: appstein docs as a real process, and its time budget`

---

### Task 11: Docs, graph, progress

- [ ] `///` on every public API (the doc-comments test passes).
- [ ] Guide: a new `docs/guide/human-docs.md` (what is rendered, the marker, how a pack adds a page, how staleness is decided, the line-ending rule, how to update goldens) covering every new file; update `docs/guide/README.md`, `architecture.md`, the packs page and the CLI page for `Pack.docPages` and the new command; a how-to `docs/guide/how-to/add-a-doc-page.md`.
- [ ] `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`.
- [ ] Full suites: each package from its folder, and the repo root. Analyzer and formatter clean.
- [ ] One review of the whole branch by a fresh reviewer on the most capable model, with this plan's Review Focus; fix Critical and Important findings test-first; list the Minor ones here.
- [ ] `/graphify . --update` until `tool/check_graph.py` reports nothing.
- [ ] Notes from execution in this plan; `progress.yaml`: 1c.3 done with its PR and date, and the next slice marked `next` (same commit, once the PR is open).

## Carried to later slices

- **1d:** `docs.stale` reuses `scanDocsFolder` and `planDocs` (and the marker's two hashes to say why a page is behind); `document_public_classes`; the package-gate verdict column in `dependencies.md`; the plugin that needs each permission in `native.md`, once the map records it.
- **1e:** `create` renders the first docs; the Stop hook runs `appstein docs`; the managed block tells agents never to edit generated pages.
- **Later:** an HTML site on the same Markdown.
