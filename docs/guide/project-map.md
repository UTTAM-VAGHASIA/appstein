<!-- covers:
packages/appstein_engine/lib/src/map/**
packages/appstein_engine/lib/src/packs/**
packages/appstein_engine/lib/official_mvvm.dart
-->

# The project map

The project map is what `appstein sync` writes about a Flutter app's own code: which symbols it declares, which layer each file is in, which packages it uses, which features and routes it has. An agent reads these files instead of searching the code. This page explains how the map is built, one step at a time. The files' formats are in the protocol package ([`map/`](../../packages/appstein_protocol/lib/src/map/map_files.dart)), and the decisions behind them are in [spec §6.1 and §6.5](../superpowers/specs/2026-09-29-appstein-design.md). How the files are written to disk is on the [knowledge-store](knowledge-store.md) page.

## What the map is

The map is layer 2 of the knowledge Appstein keeps (spec §6.1). Layer 1, the platform, says what Flutter and the toolchain are. Layer 2 says what *this app* is. It lives in `.appstein/map/`, one file per question an agent asks:

| File | An agent asks | Written by |
|---|---|---|
| `symbols.json` | "Where is `BookingViewModel` declared, and what does it do?" | the engine, for any app |
| `layers.json` | "Which layer is this file in, what does it import, and which imports break the rules?" | the engine, with the stack pack's rules |
| `deps.json` | "Which packages does the app use, at which version, and where?" | the engine, for any app |
| `features.json` | "What is in the booking feature: screens, view models, repositories, tests?" | the stack pack |
| `routes.json` | "Which route shows which screen?" | the stack pack |

`native.json`, the Android and iOS configuration, comes in slice 1b.4. It will be written by the platform packs, the way the stack pack writes `features.json` and `routes.json`.

Every file is generated, never edited by hand, and follows the rules in [knowledge-store](knowledge-store.md#three-rules-every-generated-file-follows): canonical JSON, a `meta` block with an input hash, and a rewrite only when the bytes would change.

## How sync builds it

`appstein sync` runs [`KnowledgeSync.run`](../../packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart). It builds everything first and writes it all at the end:

```text
KnowledgeSync.run
  |
  |-- PlatformSync.build     sdk.json, toolchain.json            (no writing yet)
  |
  |-- MapSync.build          (no writing yet)
  |     1. packages          fresh? if not, flutter pub get
  |     2. ProjectAnalysis   the analyzer resolves lib/, test/, testing/
  |     3. pack extractors   routes.json, features.json
  |     4. generic files     symbols.json, layers.json, deps.json
  |     5. one input hash    shared by every map file
  |     6. delta facts       collectDelta, while the analysis is open (version-delta.md)
  |
  |-- renderDelta           platform/delta.md                  (no writing yet)
  |
  `-- KnowledgeStore.locked
        writeAll             every file, then state.json last
```

Two things to notice.

- **Building happens outside the lock, writing happens inside it.** The analysis takes seconds, and holding the lock that long would make any other writer wait. [`writeAll`](../../packages/appstein_engine/lib/src/knowledge/knowledge_store.dart) takes the platform files and the map files together and writes `state.json` last, so `state.json` only ever lists files that were written. The consequence: two syncs that run at the same moment are last-writer-wins. Each write is consistent inside itself, and its input hash shows if it was built from something that has since changed.
- **The map can be skipped without failing the sync.** When the packages can't be fetched, or the project files can't be read, [`MapSync`](../../packages/appstein_engine/lib/src/map/map_sync.dart) returns no files and a reason. The platform layer is still written, and so is `delta.md`, with only the notes. A failure while collecting the delta facts (step 6) is kept apart: the map is still written, and `delta.md` says its API lists are missing because of an internal error, which the user should report (see [version-delta](version-delta.md#how-sync-builds-it)). See [A failed fetch](#a-failed-fetch).

## Packages first

The analyzer can only resolve `package:go_router/go_router.dart` if it knows where `go_router` is on disk. That is what `.dart_tool/package_config.json` records, and it exists only after `flutter pub get`. So the first step of a map build is [`checkPackages`](../../packages/appstein_engine/lib/src/map/project_packages.dart): do the packages need fetching?

### Flutter's rule, copied

Appstein does not invent a rule. It copies the one `flutter run`, `flutter analyze` and `flutter test` use, in `flutter_tools`' `pub.dart` (the `get` method with `checkUpToDate`). This is the code, from Flutter 3.47.5:

```text
// If the pubspec.yaml is older than the package config file and the last
// flutter version used is the same as the current version skip pub get.
if (checkUpToDate &&
    pubLockFile.existsSync() &&
    pubspecYaml.lastModifiedSync().isBefore(pubLockFile.lastModifiedSync()) &&
    pubspecYaml.lastModifiedSync().isBefore(packageConfigFile.lastModifiedSync()) &&
    lastVersion.existsSync() &&
    lastVersion.readAsStringSync() == versionFromFile.frameworkVersion) {
  return;   // skip pub get
}
```

Flutter also skips pub when the package config was written by something other than pub (its `generator` is not `pub`). `checkPackages` does the same.

**Why copy it?** If sync re-fetched when Flutter would not, it would be slow and would change files the user didn't expect to change. If it skipped when Flutter would fetch, the map would be built from stale packages. Doing exactly what Flutter does means the map and `flutter run` agree. Each answer comes with a reason in words that follow "because", such as "pubspec.yaml changed after they were fetched".

### What the report says when it fetches

When the packages are stale, sync runs `flutter pub get` through [`fetchPackages`](../../packages/appstein_engine/lib/src/map/project_packages.dart) and prints a line such as:

```text
Fetched the packages with `flutter pub get`, because pubspec.yaml changed after they were fetched.
```

When the packages are fresh, it prints nothing about packages.

### A failed fetch

If `flutter pub get` fails (no network, a version conflict, a timeout after 5 minutes), the map is **skipped**:

- sync prints `Could not fetch the packages:` with the last ten lines Flutter printed, then `Project map skipped: the packages could not be fetched.`;
- the exit code is **0**. The platform layer was written, and a project whose packages can't be fetched is a project problem, not an Appstein failure (see [cli](cli.md#appstein-sync));
- the old map files are **not deleted**. They are stale, but they were true once, and the new `state.json` lists only the platform files and `delta.md`, so a reader can see that the map files are not current.

### Where Appstein differs from Flutter

Flutter has one gap in a **pub workspace**, where several packages share one `.dart_tool/package_config.json` and one `pubspec.lock` at the workspace root. Pub leaves `.dart_tool/pub/workspace_ref.json` in each package. It says where the root is:

```text
{"workspaceRoot": "../../.."}
```

Flutter's code joins that folder to the package's own `.dart_tool/pub` folder and uses the result as if it were the `package_config.json` *file*. A folder is not a file, so `existsSync()` is false and Flutter always runs `pub get` there. It is slow but harmless for Flutter.

Appstein reads what the reference means: the workspace root is the folder, and `package_config.json`, `pubspec.lock` and `.dart_tool/version` are looked for inside it ([`_workspaceRoot`](../../packages/appstein_engine/lib/src/map/project_packages.dart)). The freshness rule is otherwise the same. A damaged or unreadable reference is ignored, and the project's own files are used. That is a deliberate difference from Flutter: its `pub.dart` decodes the JSON without a catch, so invalid JSON crashes `flutter`. Flutter ignores only valid JSON of the wrong shape. Appstein falls back instead of crashing.

### `pub get` may touch `analysis_options.yaml`

Flutter 3.47's `pub get` may also update the app's `analysis_options.yaml`, adding `build/` and the platform folders to its `exclude:` list. That is Flutter's doing, not Appstein's. Sync starts `pub get` only when `flutter run` would, so it changes that file only when Flutter was going to anyway.

`fetchPackages` runs Flutter with the project as its working folder, instead of passing a path. The reason is on [running-tools](running-tools.md#processrunner-and-systemprocessrunner).

## Resolving the code

[`ProjectAnalysis.analyze`](../../packages/appstein_engine/lib/src/map/project_analysis.dart) asks `package:analyzer` to resolve the whole project once. Every later step reads that one result.

- **Which folders.** `lib/`, `test/` and `testing/`, whichever exist. `integration_test/`, `tool/` and the platform folders are not part of the map.
- **Which SDK.** `dart:core` and the other `dart:` libraries come from the Dart SDK inside the Flutter SDK (`bin/cache/dart-sdk`). If that folder has no `lib/core/core.dart`, the map is skipped with "The Dart SDK at … is incomplete".
- **Paths.** `package:analyzer` accepts only absolute, normalized paths, so the project path goes through `p.normalize(p.absolute(...))` first. Everything *written* to the map is relative to the project and uses `/`, on every OS, so the same app gives the same map on Windows and Linux.
- **Code with errors still maps.** The analyzer resolves as much as it can. A project in the middle of an edit gets a map of what resolves; it is not refused.
- **The user's `exclude:` applies.** The analyzer reads the project's `analysis_options.yaml`, so files the user excluded from analysis are not in the map either. `ProjectAnalysis.libraries` lists libraries; a part file is not one, but it is listed by its library's `units`, so the layer map still sees it.

### Speed

Spec §15 sets a target: a full sync of a 200-file app in under 30 s. Resolving a 200-file app took about 12 s cold and 3.9 s warm in the spike. The repo's [`tool/measure_sync.dart`](../../tool/measure_sync.dart) measures the whole sync on a generated app of that size: first sync (including a real `flutter pub get`), then a full rebuild with fresh packages, which is held to the 30 s limit. On the Windows development machine, the rebuild took 9.5 s, and 15.4 s for a first sync. CI runs the tool on Linux and Windows (see [ci](ci.md#measure)). There is no on-disk analyzer cache yet; incremental sync (slice 1b.6) will need one.

## The generic files

Three files need nothing from a pack: [`symbols.dart`](../../packages/appstein_engine/lib/src/map/symbols.dart), [`layers.dart`](../../packages/appstein_engine/lib/src/map/layers.dart) and [`dependencies.dart`](../../packages/appstein_engine/lib/src/map/dependencies.dart).

### symbols.json

Every **public top-level** class, mixin, enum, named extension, extension type, typedef and function in `lib/`, with its file, line, layer, feature and a one-sentence summary. Private names, members of classes, and anything in `test/` are left out: an agent asks "where is X", and X is a top-level name.

```text
{ "name": "HomeViewModel", "kind": "class", "file": "lib/ui/home/view_models/home_viewmodel.dart",
  "line": 8, "layer": "ui", "feature": "home",
  "summary": "Loads the user's bookings for the home screen." }
```

The list is sorted by file, then line, then name.

**The summary rule** ([`docSummary`](../../packages/appstein_engine/lib/src/map/symbols.dart)): the first sentence of the first paragraph of the doc comment. A sentence ends at `.`, `!` or `?` followed by a space or the end, so `v1.2` doesn't end one.

| Doc comment | Summary |
|---|---|
| `/// Books a trip and shows the result.` | `Books a trip and shows the result.` |
| `/// Uses v1.2 of the API. It is old.` | `Uses v1.2 of the API.` |
| a first paragraph with no full stop | the whole paragraph, joined into one line |
| no comment, or an empty one | `null` |

### layers.json

Every analyzed file, with its layer tag, its feature, and the project files it imports or exports. After them comes the list of **violations**: imports the layer rules forbid.

- **Tags** come from the stack pack's rules, through `LayerMatcher` (first matching glob wins).
- **Imports** are only imports of other files of the project. `package:` and `dart:` imports are not listed. A conditional import (`import 'a.dart' if (dart.library.io) 'b.dart'`) counts by its **main URI**, `a.dart`, as the analyzer reports it.
- **Violations equal the lint's.** The map and the `layer_imports` lint must agree, or an agent would see one answer in `layers.json` and another in the editor. They agree because both use the same `LayerMatcher` and `LayerRules.mayImport`, from the protocol package, and the same "interface file" test. That test, `isInterfaceLibrary`, exists twice: the lints package can't import the engine, so there is a copy in each ([engine](../../packages/appstein_engine/lib/src/map/interface_library.dart), [lints](../../packages/appstein_lints/lib/src/layer_imports/interface_library.dart)). Each file's comment names the other. Keep them in step. See [lints](lints.md#interface-files). Conditional imports are a known gap in both, and the same gap: each reads the import's main URI (`libraryImport?.importedLibrary`), and neither checks the `if (...)` alternatives. The analyzer picks an alternative only when declared variables match, and neither sets any. So the map and the lint still agree. Checking the alternatives is carried to slice 1d.

When a project has no stack pack, there are no rules: files have no tag, and there are no violations.

### deps.json

The packages of the project, from `pubspec.lock`:

- **The lock file is the source of truth** for which packages exist, and for each one's resolved `version`, `dependency` kind (`direct main`, `direct dev`, `transitive`, ...) and `source`.
- **The constraint** (`^18.0.0`) comes from `pubspec.yaml`, since the lock file doesn't keep it. Entries in `dependency_overrides` win over `dependencies` and `dev_dependencies`. A package with no constraint there (a transitive one, or an SDK package such as `flutter`) has `null`.
- **`usages`** lists the project files that import or export the package, sorted.
- In a pub workspace the lock file is the workspace root's, found as described in [Packages first](#packages-first).

**Health arrives later.** Package age, maintenance and advisories come with the package gate (a later slice). The file's shape leaves room for them.

**A damaged lock file or `pubspec.yaml` skips the map.** [`buildDeps`](../../packages/appstein_engine/lib/src/map/dependencies.dart) throws a `DependenciesException` when either file is missing, unreadable, invalid UTF-8, not valid YAML (the message gives the line), or not a YAML map. An empty `deps.json` would claim the app has no packages, which is worse than no file (spec §15). `MapSync` reports it like this:

```text
Project map skipped: pubspec.lock is not valid YAML (line 4); run `flutter pub get`.
Fix that, then run `appstein sync` again.
```

The old map files stay, as after a failed fetch. A lock file that is valid but has no `packages:` entries is fine: it gives an empty list. A file system error while hashing the map's inputs (below) is reported the same way, as "the project files could not be read (...)".

## The official_mvvm pack

The generic files know nothing about how an app is structured. The [`official_mvvm`](../../packages/appstein_engine/lib/src/packs/official_mvvm/official_mvvm_pack.dart) pack knows Flutter's recommended architecture (the one in its `compass_app` sample), and gives the engine three things: layer rules, features and routes.

### The layer tags and what may import what

[`layer_rules.dart`](../../packages/appstein_engine/lib/src/packs/official_mvvm/layer_rules.dart) declares the tags and their globs:

| Tag | Files |
|---|---|
| `test` | `test/**`, `testing/**` (listed first, so a test file is never tagged by a `lib/` glob) |
| `ui` | `lib/ui/**` |
| `data.repository` | `lib/data/repositories/**` |
| `data.service` | `lib/data/services/**` |
| `data.model` | `lib/data/model/**` |
| `domain` | `lib/domain/**` |
| `routing`, `config`, `utils` | `lib/routing/**`, `lib/config/**`, `lib/utils/**` |

And what each may import:

| From | May import (besides itself) | Plus, only the interfaces of |
|---|---|---|
| `ui` | `domain`, `routing`, `config`, `utils` | `data.repository`, `data.service` |
| `domain` | `utils` | `data.repository` |
| `data.*` | everything except `ui` | |
| `routing`, `config`, `utils`, `test` | anything (no rule) | |

**Why `interfaces` exists.** In `compass_app`, a use case in `domain` calls a repository, and a view model in `ui` takes a repository in its constructor. Those need the repository's *type*. But a screen must not reach the repository's implementation, which talks to the network. A plain "may import `data.repository`" rule would allow both, and "may not" would forbid both. The `interfaces` rule splits them: a file may import another layer's **interface files**, those whose classes are all abstract, such as `booking_repository.dart`, and not its implementation, `booking_repository_remote.dart`. The fixture app has one violation on purpose: a screen importing the remote implementation (see [testing](testing.md#the-fixture-app-and-goldens)).

### Features

[`features.dart`](../../packages/appstein_engine/lib/src/packs/official_mvvm/features.dart) builds `features.json`. In the fixture app, `home` looks like this:

```text
"home": {
  "folder": "lib/ui/home",
  "viewModels":   [HomeViewModel],
  "screens":      [HomeScreen],
  "repositories": [BookingRepository],
  "services":     [AnalyticsService],
  "models":       [Booking],
  "tests":        ["test/ui/home/widgets/home_screen_test.dart"],
  "files":        [...]
}
```

How each part is found:

- **A feature is a folder under `lib/ui/`** that has a `view_models/` or `widgets/` folder inside it. Its name is its path below `lib/ui/`, so `lib/ui/auth/login/` is the feature `auth/login`. **`lib/ui/core/` is not a feature**: it holds shared widgets and themes.
- **The deepest folder owns a file.** If `lib/ui/auth/` and `lib/ui/auth/login/` were both features, a file in `login/` belongs to `auth/login` only.
- **View models** are the concrete classes in the feature's `view_models/` that extend Flutter's `ChangeNotifier`, directly or through other classes. **Abstract base classes are excluded:** the fixture's `BaseViewModel` is a shared helper, not a screen's state.
- **Repositories and services** come from the view models' constructor parameters: a parameter whose type is declared in `data/repositories/` is a repository, in `data/services/` a service. It is read from the types, not from names.
- **Models** are the public classes of the `domain` files the feature imports, **except use cases**. A use case is domain *behaviour*, not data the feature shows, so `BookingCreateUseCase` is not a model of `booking`, while `Booking` is.
- **Tests** are the files under `test/ui/<feature>/`, owned by the same deepest-folder rule.
- **Screens come only from routes.** A screen is what a route's builder returns, when that class is declared in this feature's `widgets/` folder. A widget that no route shows is not a screen. This follows spec §6.5: never guess from names.

### Routes

[`routes.dart`](../../packages/appstein_engine/lib/src/packs/official_mvvm/routes.dart) reads every `GoRouter(...)` in `lib/`. What it reads:

- `GoRoute`, and the routes inside `ShellRoute` and `StatefulShellRoute` (each `StatefulShellBranch`). A shell adds no path of its own.
- Each route's `path`, `name`, whether it has a `redirect`, its parent, its screen, and the file and line.
- A router's own `redirect:` is recorded on the router (`routers` in `routes.json`).
- **A literal `null` argument counts as not passed**, so `redirect: null` is no redirect (as for the callee's default).

**Paths are joined** as go_router joins them: the non-empty segments of the parent and the child, after one `/`. In the fixture, `/` plus `booking` is `/booking`, and then `:id` gives `/booking/:id`. A top-level path is kept as written. A path is read when it is a compile-time constant string: a literal, adjacent literals, an interpolation of constants, or a `const` such as `Routes.home`, which the analyzer evaluates ([`ast_values.dart`](../../packages/appstein_engine/lib/src/map/ast_values.dart)).

**The screen** is the widget constructor the route's builder returns. A route with no builder at all (like `:id`, which only redirects) has no screen, and is not unresolved. When both `pageBuilder` and `builder` are given, go_router uses `pageBuilder`, so Appstein does too, and reads the screen from the page's `child:` argument (as in `NoTransitionPage(child: LoginScreen(...))`).

**What can't be read statically is recorded as unresolved, with a reason. Nothing is guessed.** The route (or router) is kept in the file with `unresolved: true`, so an agent knows the map is incomplete there. The reasons:

| Reason | When |
|---|---|
| `this GoRouter has no routes list` | the `GoRouter(...)` call has no `routes:` argument |
| `typed routes (go_router_builder) are not read yet` | `routes: $appRoutes` |
| `the routes are not a list literal` | `routes:` is a variable or a call |
| `a spread or a condition in a routes list is not read` | `...more` or `if (...)` inside the list |
| `the route is not a GoRoute, ShellRoute or StatefulShellRoute constructor call` | a list item is anything else |
| `the branches are not a list literal` | a `StatefulShellRoute`'s `branches:` isn't a list |
| `the branch is not a StatefulShellBranch constructor call` | a branch item is anything else |
| `the path is not a constant string` | `path: _searchPath()` |
| `the parent route's path is not a constant string` | a child of such a route (its own path can't be joined) |
| `the builder is not a function literal` | `builder: someFunction` |
| `the builder is not a single plain return` | several `return`s, or none as the last statement |
| `the builder doesn't return a widget constructor call` | for example, a variable or a method call |
| `the page builder doesn't return a page with a child: argument` | a `pageBuilder` whose page has no `child:` |
| `the builder returns X, which is not declared in this project` | a widget from a package (`Text`) |

In the fixture app, the `/settings` route returns `ProfileScreen` or `SettingsScreen` from an `if`, so it is `the builder is not a single plain return`; `search` is `the path is not a constant string`, but its screen, `SettingsScreen`, is still recorded; `/about` is `the builder returns Text, which is not declared in this project`.

## Packs and the core

A **pack** ([`pack.dart`](../../packages/appstein_engine/lib/src/packs/pack.dart)) is what is specific to one stack or platform. The `Pack` interface is deliberately small: an `id`, a `kind` (stack or platform), a `version`, a list of `extractors` and optional `layerRules`. The interface grows only when a slice first needs a member (spec §10): a bigger interface written before there are two packs would be guessed, and wrong. The `version` is part of the map's input hash, so a new version of a pack rebuilds the map.

A [`MapExtractor`](../../packages/appstein_engine/lib/src/map/map_extractor.dart) turns the resolved project into files. It has one method, `extract(ProjectAnalysis)`, which returns bodies by their path (`map/routes.json`), each written with its `meta`. `OfficialMvvmExtractor` returns `routes.json` and `features.json`. `MapSync` runs every extractor of every pack, builds `symbols.json`, `layers.json` and `deps.json` with the stack pack's rules, then sorts all the files by path.

**The core never imports a pack** (spec §5.1). Only `lib/src/packs/official_mvvm/**` and [`official_mvvm.dart`](../../packages/appstein_engine/lib/official_mvvm.dart), the pack's public entry, hold pack code. `MapSync` receives a `List<Pack>` and knows only the interface. The CLI wires one in: [`packsFor`](../../packages/appstein_cli/lib/src/packs.dart) turns `packs.stack` from `appstein.yaml` into a list of packs. `layer_imports` enforces the rule on this repo (see [lints](lints.md#our-own-boundaries)). That matters because later packs (android, ios, other stacks) should plug in without touching `MapSync`.

## Determinism and freshness

The same code must give byte-identical files on every OS (spec §15):

- every list is sorted (symbols by file, line and name; layers and features by path or name; usages and imports by path);
- files are written by `KnowledgeStore.writeGenerated`, which uses canonical JSON, so key order never varies;
- paths use `/` and are relative to the project.

**One coarse input hash.** Every map file gets the same `meta.inputHash`: a SHA-256 over every `.dart` file under `lib/`, `test/` and `testing/`, `pubspec.yaml`, the lock file, the project's `analysis_options.yaml` (its `exclude:` changes which files are mapped), the Flutter version, and the packs' ids and versions, plus Appstein's own version. So any change to any of those changes every hash. That is coarse on purpose: it is simple. It does not cover everything yet: the sources of path dependencies are not hashed, which is carried to slice 1b.6. A reader (the future `knowledge.stale` check) can compare a file's hash with a fresh one to see if the file is behind. Finer hashes, per file, come with incremental sync in slice 1b.6.

## Tests

The map is tested against a small fixture app, with golden files for the output, and once against the real Flutter and go_router. See [testing](testing.md#the-fixture-app-and-goldens).
