# Slice 1b.7: Incremental Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `appstein sync --detect` (the after-every-edit hook) checks content hashes against `state.json`.
- When nothing the knowledge reads changed, it stops in about 20–110 ms.
- Otherwise it runs the normal full sync, which takes about 1 s on a 200-file app instead of about 9 s, because the Dart analyzer keeps its work in a cache in `.dart_tool/appstein/`.
- `state.json` records per-file hashes and the files that changed, so verify (1d) and package skills (1b.8) can read them.

**Architecture:**
- **Approach A (owner decision):** the incremental path is the *same* full pipeline, with a warm analyzer cache. It is never a second, patching code path, so its output is byte-identical to a full sync by construction.
- **The analyzer cache:** `lib/src/map/analyzer_cache.dart` holds every use of the analyzer's private `src/` cache API (owner decision): one file, `.dart_tool/appstein/analyzer_cache.bin`, keeping only the entries the last run used.
- **Map inputs:** `lib/src/map/map_inputs.dart` reads the map's inputs, with a SHA-256 per file and local packages included, *before* any analysis.
- **Freshness:** `KnowledgeSync` gains `freshness()` and `detect()`. Both compute every output's input hash the way a sync does, minus the analysis, and compare with `state.json`.

**Tech Stack:** Dart 3.12+ (Flutter 3.47.5 via FVM), `package:analyzer` 14.4.0 (now pinned exactly), `package:crypto`, `package:path`, `package:test`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md`. This plan implements, as edited in commit `e1fab90` (owner-approved):
- §5.3: `appstein sync [--detect]`; `--changed` was dropped;
- §5.4: `--detect` stops when nothing changed, otherwise rebuilds with the analyzer cache, and records the changed files for `verify --fast`;
- §6.2:
  - `state.json` holds an input hash per source file, a hash of each written file, the last changes and the last sync;
  - the analyzer cache lives in `.dart_tool/appstein/` and isn't knowledge;
- §15: incremental sync (`sync --detect` after one edit) of a 200-file app takes under 2 s; full sync of a 200-file app under 30 s; determinism; Windows paths.

The owner decisions, probe numbers and design are in memory (`project_slice_1b7_incremental.md`).

What isn't here, and where it goes:
- the hooks that call `sync --detect`: 1e;
- `verify --fast` reading `state.json`'s `changed`: 1d;
- `dart run skills@ get` when `pubspec.yaml` or `pubspec.lock` changed: 1b.8;
- MCP's re-sync and `overview` freshness, using `KnowledgeSync.freshness`: 1c.

## Global Constraints

- **Commands:**
  - run every Dart command through FVM (`fvm dart …`). The repo pins Flutter 3.47.5 (Dart 3.13.4); packages declare `sdk: ^3.12.0`.
  - CI also runs the unit tests on Flutter 3.44 (Dart 3.12), so no unit test may depend on the real Flutter or Dart SDK's contents. Tests analyze with `testDartSdk` (the Dart running the tests) and the stub packages.
  - Run full suites **from inside each package folder**, as CI does: `cd packages/<pkg> && fvm dart test`. Never `fvm dart test packages/x` from the repo root: there the package's `dart_test.yaml` (which skips `integration`) isn't applied, and `process_runner_test` resolves a helper relative to the working folder.
- **Boundaries (spec §5.1):**
  - `appstein_protocol` depends on nothing internal; `appstein_engine` only on `appstein_protocol`; `appstein_cli` on both.
  - The engine core never imports a pack. `layer_imports` enforces this.
- **Docs and analysis:** every public API has a `///` doc comment (`public_member_api_docs`). These must pass from the repo root:
  - `fvm dart analyze --fatal-infos`;
  - `fvm dart format --output=none --set-exit-if-changed .`;
  - `fvm dart run dependency_validator`.
- **The analyzer's `src/` API (owner decision):**
  - only `packages/appstein_engine/lib/src/map/analyzer_cache.dart` may import `package:analyzer/src/…`, under one `// ignore_for_file: implementation_imports` with the reason;
  - `packages/appstein_engine/pubspec.yaml` pins `analyzer: 14.4.0` exactly;
  - no other file gets an `implementation_imports` ignore.
- **Byte order marks:** no raw U+FEFF byte in any `.dart` file. Nothing in this slice needs the BOM escape; never type it.
- **Windows is first-class:**
  - every file-system test uses `tempDir()` (`packages/appstein_engine/test/support/temp.dart`), whose path holds a space and a non-ASCII character;
  - input names and `state.json` keys use `/`;
  - a machine path never goes into a generated file. Error messages in the sync *report* may hold one.
- **Determinism (§15):** the same inputs give byte-identical `.appstein/` files, with the analyzer cache or without it. The cache file itself is written with sorted keys.
- **The cache never fails a sync:**
  - a missing, damaged or unsaveable cache, or an analyzer error while using it, costs at most one slow sync and a line in the report;
  - it never changes the knowledge, and it never ends the process.
- **No network in unit tests.**
- **Tests stay in temp folders.** Tests never write into the repo, `graphify-out/` or `.git/hooks`. The one exception is `APPSTEIN_UPDATE_GOLDENS=1`, which this slice must not need: the goldens may not change.
- **Commits:** subagents never commit. The controller commits each task after its review, with the session's trailer lines, behind the BOM byte scan: `LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test` must print nothing.
- **Subagents:** at most 3 running at once (owner rule). Never use `python -` stdin heredocs.

## Review Focus

These are the five inputs most likely to bite a user, though no feature test asks for them. Each one has a test in the task named.

1. **A cache whose entries are garbage.** A bug, or a bit flip, can leave a cache whose header is fine but whose entries aren't. The probe on 2026-10-03 showed the analyzer then throws inside its own scheduler, an *unhandled* exception that ends the process (exit 255). Every later sync would crash until someone deleted the file by hand. The sync must instead run the analysis again with an empty cache, write correct knowledge, and replace the bad cache. *Test: Task 4.*
2. **Files outside the project that change the map.** A path dependency or a workspace sibling package can change without `pubspec.lock` changing. `--detect` must still see it. *Tests: Task 3, Task 5.*
3. **Knowledge and `state.json` that disagree:**
   - a hand-edited or deleted `.appstein/` file;
   - a damaged `state.json`, or one from before this slice;
   - a sync that was killed before it wrote `state.json`.

   `--detect` must rebuild in each case and never answer "current". *Test: Task 5.*
4. **Hook after hook with nothing changed.** The first `--detect` after a rebuild empties the change list. Every later one writes no byte and leaves the cache file and every modified time alone. *Test: Task 5.*
5. **A cache that can't be written:** a read-only folder, or `.dart_tool/appstein` existing as a file. The sync succeeds and says so in one warning line. *Tests: Task 2, Task 4.*

## Decisions made while planning (for the owner's review)

Every fact below was checked against the repo and the analyzer 14.4.0 source on 2026-10-03. The probe numbers are from the throwaway probe in the session scratchpad (`probe17/`).

- **D1, the cache file.**
  - **Place and contents:** `.dart_tool/appstein/analyzer_cache.bin`, one file.
  - **Header:** `APPSTEIN ANALYZER CACHE\n`, then the cache format (`1`) and the analyzer version (`14.4.0`).
  - **Entries:** sorted by key. Big-endian lengths.
  - **Mismatches:** a wrong header, format or analyzer version, or a file cut short, opens as an empty cache whose `damage` says why.
  - **What is kept:** a save keeps only the entries the run used (read or added). It saves only when something changed.
  - **Why one file:** the analyzer's own `FileByteStore` (2,394 small files) took 13.5 s to read the first time on Windows, and its `flush()` doesn't work there (dart-lang/sdk#64190).
- **D2, the guard (from the probe).** `catchAnalyzerErrors` runs the analysis inside `runZonedGuarded`, so an error in the analyzer's scheduler becomes a normal error.
  - With a cache, `MapSync` runs the analysis once more with an empty cache, which then replaces the bad one.
  - Without a cache, or when the retry fails too, the error is thrown. The CLI turns that into exit 3 with a crash report, instead of the process dying with exit 255.
  - The abandoned first analysis isn't disposed: its futures never complete. The process still exits normally; the probe confirmed it.
- **D3, `state.json` keeps format version 1.**
  - Its new keys `sources`, `written` and `changed` are required when it is read. A `state.json` from before this slice therefore fails to read, and `--detect` rebuilds and rewrites it.
  - Raising `knowledgeFormatVersion` would rewrite every generated file once and touch 6 tests for no gain: no user has 1b.6 state files.
  - Cost if wrong: none that a rebuild doesn't fix.
- **D4, input names and the change list.**
  - **`sources`:** keyed by the names the map's input hash already uses:
    - `project:<path>` for `.dart` files under `lib/`, `test/` and `testing/`;
    - `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`;
    - new: `local-package:<name>/<path>`.

    A file that can't be read is `missing`.
  - **`changed`:** the names whose hash differs from the previous `state.json`, sorted. That includes added and removed files. With no earlier `state.json`, every name.
  - **The report:** `SyncReport.changed` is empty when there was nothing to compare with, so a first sync doesn't print 200 "changed" files.
  - **Emptying the list:** the first `--detect` that finds nothing changed empties `changed`, under the lock, and only if `state.json` is still the one it checked.
- **D5, local packages.**
  - **Which packages:** every package in the workspace's `.dart_tool/package_config.json` that is in neither the Flutter SDK nor a pub cache folder, other than the project itself.
  - **The pub cache:** `PUB_CACHE`, else `%LOCALAPPDATA%\Pub\Cache` and `%APPDATA%\Pub\Cache` on Windows, else `~/.pub-cache`.
  - **Which files:** each one's `pubspec.yaml`, and the `.dart` and `.yaml` files under its `lib/`, which covers `fix_data` for the delta.
  - **Why safe:** a cache folder missed by this rule only costs time, since its packages get hashed as local ones.
  - This closes the item carried from 1b.5 ("path dependencies' sources, and their `fix_data`, aren't in any input hash yet").
- **D6, what `--detect` compares.** It runs every cheap step of a sync for real:
  - the platform layer (8 ms);
  - `checkPackages`;
  - the map inputs (20–110 ms);
  - native config (5 ms);
  - `readIndexSources`.

  It computes each output's input hash with the *same* functions a sync uses (`_deltaHash` and `_indexHash` are extracted for this), and compares with `state.json`. So "current" can never use a different definition of the inputs than a sync.

  It also rebuilds when:
  - the packages need `flutter pub get`;
  - the last sync skipped the map;
  - a written file's bytes differ from `written`;
  - another Appstein wrote `state.json`.
- **D7, native config and INDEX.md are rebuilt on every rebuild.** This resolves the 1b.6 carried item "rebuilt only when their own inputs change". They cost under 15 ms, and rewrite-only-on-change already keeps their bytes. A separate skip would add a code path for no measurable gain.
- **D8, `KnowledgeSync(analyzerCache: true)` by default.** Every existing sync test therefore exercises the cache too. Only the "same knowledge with and without the cache" test turns it off.
- **D9, `measure_sync`:**
  - It compiles the real `appstein` exe and times each sync as a fresh process, with `FLUTTER_ROOT` set to the Flutter SDK whose Dart runs the tool. That is how a hook runs it; CI's JIT `dart run` would distort the numbers.
  - The full-sync row is measured cold: no `.appstein/`, no cache. It is the 30 s worst case.
  - The 1,000-file rows are information only (owner decision 3).
- **D10, carried fixes:**
  - `readFeatures` becomes linear: 25 s → 73 ms at 1,000 files in the probe, with byte-identical output;
  - `MapSync`'s `featureOf` uses an index built once, giving the same answer as `FeaturesMap.featureOf`;
  - the three `checkPackages` tests carried from 1b.3 are added.
- **D11, only the engine pins analyzer exactly.** `appstein_lints` keeps `^14.4.0`: in a user's project, the lint plugin is resolved apart from Appstein's binary. In this workspace both resolve to 14.4.0.

---

## File map

| File | Responsibility |
|---|---|
| `packages/appstein_engine/lib/src/packs/official_mvvm/features.dart` | `readFeatures`, now linear (Task 1) |
| `packages/appstein_engine/lib/src/map/analyzer_cache.dart` | New. `analyzerVersion`, `analyzerCacheFormat`, `analyzerCachePath`, `encodeAnalyzerCache`, `decodeAnalyzerCache`, `AnalyzerCacheLoad`, `AnalyzerCache`, `AnalyzerCacheReport`, `analysisCollection`, `catchAnalyzerErrors` (Tasks 2, 4) |
| `packages/appstein_engine/lib/src/map/map_inputs.dart` | New. `MapInputs`, `readMapInputs`, `localPackageRoots`, `pubCacheFolders` (Task 3) |
| `packages/appstein_engine/lib/src/knowledge/freshness.dart` | New. `Freshness`, `changedSources`, `stateSources` (Task 5) |
| `packages/appstein_engine/lib/src/map/project_analysis.dart` | `analyze` takes an optional cache (Task 2) |
| `packages/appstein_engine/lib/src/map/map_sync.dart` | `featureOf` index (Task 1); map inputs (Task 3); the guard, retry and `MapBuild.cache` (Task 4) |
| `packages/appstein_engine/lib/src/knowledge/input_hash.dart` | `inputHashOfDigests` (Task 3) |
| `packages/appstein_engine/lib/src/knowledge/knowledge_store.dart` | `replaceFileBytes` (Task 2); `writeAll` records `sources`, `written` and `changed`; `readState`, `fileHash` (Task 5) |
| `packages/appstein_engine/lib/src/knowledge/platform_sync.dart` | `SyncReport.analyzerCache` (Task 4); `current`, `changed`, `rebuiltBecause` (Task 5) |
| `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart` | Cache open and save (Task 4); `_prepare`, `_rebuild`, `detect`, `freshness` (Task 5) |
| `packages/appstein_engine/lib/appstein_engine.dart` | Exports the three new files |
| `packages/appstein_engine/pubspec.yaml` | `analyzer: 14.4.0` |
| `packages/appstein_protocol/lib/src/knowledge/knowledge_state.dart` | `sources`, `written`, `changed` (Task 5) |
| `packages/appstein_cli/lib/src/sync_command.dart` | `--detect`; the report's new lines (Task 6) |
| `tool/measure_sync.dart` | Compiled exe, fresh processes, the incremental rows (Task 7) |
| Tests | `test/map/analyzer_cache_test.dart`, `test/map/map_inputs_test.dart`, `test/knowledge/support/sync_harness.dart`, `test/knowledge/knowledge_sync_cache_test.dart`, `test/knowledge/knowledge_sync_detect_test.dart` (new); `test/map/project_packages_test.dart`, `test/knowledge/knowledge_store_test.dart`, `test/knowledge/input_hash_test.dart`, protocol `test/knowledge_state_test.dart`, CLI `test/sync_command_test.dart` (changed) |
| `docs/guide/incremental-sync.md` | New guide page (Task 8) |
| `docs/guide/knowledge-store.md`, `docs/guide/project-map.md`, `docs/guide/cli.md`, `docs/guide/ci.md`, `docs/guide/README.md` | Updated (Task 8) |

---

### Task 1: Carried fixes: a linear `readFeatures`, a `featureOf` index, the `checkPackages` tests

**Files:**
- Modify: `packages/appstein_engine/lib/src/packs/official_mvvm/features.dart` (the body of `readFeatures`)
- Modify: `packages/appstein_engine/lib/src/map/map_sync.dart` (the `featureOf` closure in `build`)
- Test: `packages/appstein_engine/test/map/project_packages_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces: no new API. `readFeatures` and `MapSync.build` keep their signatures and their output, byte for byte.

**Why:** the probe found `readFeatures` cubic. For each feature it loops over every file, `owner()` loops over every feature again, and it calls `List.contains` inside loops. It took 284 ms at 200 files and **25 s at 1,000**, which put a full sync of a 1,000-file app over §15's 30 s.

- [ ] **Step 1: Add the three carried `checkPackages` tests**

They pin behaviour that already exists, so they pass at once. In `project_packages_test.dart`, add these two tests after the test `'a damaged workspace reference falls back to the project'`:

```dart
  test('a pubspec.yaml that cannot be read means pub get, with the '
      'reason', () {
    writeFetched(project);
    File(p.join(project, 'pubspec.yaml')).deleteSync();
    final status = check();
    expect(status.fresh, isFalse);
    expect(status.reason, startsWith('they could not be checked ('));
  });

  test('a workspace reference without workspaceRoot falls back to the '
      'project', () {
    Directory(p.join(project, '.dart_tool', 'pub')).createSync();
    File(
      p.join(project, '.dart_tool', 'pub', 'workspace_ref.json'),
    ).writeAsStringSync(jsonEncode({'other': 1}));
    writeFetched(project);
    final status = check();
    expect(status.fresh, isTrue);
    expect(status.workspaceRoot, project);
  });
```

Inside `group('fetchPackages', …)`, after its last test, add:

```dart
    test("in a pub workspace member, the workspace root's package config "
        'counts', () async {
      final root = p.join(tempDir().path, 'work space');
      final member = p.join(root, 'packages', 'app');
      Directory(
        p.join(member, '.dart_tool', 'pub'),
      ).createSync(recursive: true);
      File(
        p.join(member, '.dart_tool', 'pub', 'workspace_ref.json'),
      ).writeAsStringSync(
        jsonEncode({'workspaceRoot': p.join('..', '..', '..', '..')}),
      );
      final runner = FakeProcessRunner()
        ..when(flutter, ['pub', 'get'], const RunResult(exitCode: 0));
      Future<String?> fetchMember() => fetchPackages(
        member,
        flutterRoot: 'sdk',
        os: HostOs.current,
        runner: runner,
      );
      expect(
        await fetchMember(),
        '`flutter pub get` finished but did not create '
        '.dart_tool/package_config.json',
      );
      File(p.join(root, '.dart_tool', 'package_config.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{}');
      expect(await fetchMember(), isNull);
      expect(runner.workingDirectories, [member, member]);
    });
```

- [ ] **Step 2: Run them**

Run: `cd packages/appstein_engine && fvm dart test test/map/project_packages_test.dart`
Expected: PASS (all, including the 3 new ones).

- [ ] **Step 3: Make `readFeatures` linear**

In `features.dart`, add the import `import 'package:analyzer/dart/analysis/results.dart';` as the first import. Then replace the whole body of `readFeatures`, keeping its signature and doc comment:

```dart
FeaturesMap readFeatures(
  ProjectAnalysis analysis, {
  required RoutesMap routes,
  required LayerMatcher matcher,
}) {
  final libFiles = <String>[];
  final testFiles = <String>[];
  // Each file's units, so a feature reads only its own files.
  final unitsByFile = <String, List<ResolvedUnitResult>>{};
  for (final library in analysis.libraries) {
    for (final unit in library.result.units) {
      final file = analysis.relativePath(unit.path);
      if (file == null) continue;
      (unitsByFile[file] ??= []).add(unit);
      if (file.startsWith('lib/ui/')) libFiles.add(file);
      if (file.startsWith('test/ui/')) testFiles.add(file);
    }
  }
  final names = {for (final file in libFiles) ?_featureName(file)};

  String? owner(String file, String root) {
    String? best;
    for (final name in names) {
      if (file.startsWith('$root/$name/') &&
          (best == null || name.length > best.length)) {
        best = name;
      }
    }
    return best;
  }

  // Each file's feature, found once: asking per feature made this cubic.
  final filesOf = <String, List<String>>{};
  for (final file in libFiles) {
    if (owner(file, 'lib/ui') case final name?) {
      (filesOf[name] ??= []).add(file);
    }
  }
  final testsOf = <String, List<String>>{};
  for (final file in testFiles) {
    if (owner(file, 'test/ui') case final name?) {
      (testsOf[name] ??= []).add(file);
    }
  }
  // Every class of the project with its file, in library order.
  final classes = <(ClassElement, String)>[];
  for (final library in analysis.libraries) {
    for (final element in library.result.element.classes) {
      if (analysis.locationOf(element.firstFragment) case final location?) {
        classes.add((element, location.file));
      }
    }
  }

  CodeRef? refOf(Element element) {
    final name = element.name;
    final location = analysis.locationOf(element.firstFragment);
    if (name == null || location == null) return null;
    return CodeRef(name: name, file: location.file);
  }

  final features = <String, Feature>{};
  for (final name in names.toList()..sort()) {
    final files = [...?filesOf[name]]..sort();
    final fileSet = files.toSet();
    final tests = [...?testsOf[name]]..sort();

    final viewModels = [
      for (final (element, file) in classes)
        if (fileSet.contains(file) &&
            file.startsWith('lib/ui/$name/view_models/') &&
            _isViewModel(element))
          element,
    ];

    final repositories = <CodeRef>[];
    final services = <CodeRef>[];
    for (final viewModel in viewModels) {
      for (final constructor in viewModel.constructors) {
        for (final parameter in constructor.formalParameters) {
          final type = parameter.type;
          if (type is! InterfaceType) continue;
          final ref = refOf(type.element);
          if (ref == null) continue;
          switch (matcher.tagFor(ref.file)) {
            case 'data.repository':
              repositories.add(ref);
            case 'data.service':
              services.add(ref);
          }
        }
      }
    }

    final models = <CodeRef>[];
    for (final file in files) {
      for (final unit in unitsByFile[file] ?? const <ResolvedUnitResult>[]) {
        for (final import in analysis.importsOf(unit)) {
          // Use cases are domain code, but not data the feature uses (P4).
          if (matcher.tagFor(import.file) != 'domain' ||
              import.file.startsWith('lib/domain/use_cases/')) {
            continue;
          }
          for (final element in import.library.classes) {
            if (!element.isPublic) continue;
            if (refOf(element) case final ref?) models.add(ref);
          }
        }
      }
    }

    final screens = [
      for (final route in routes.routes)
        if (route.screen case final screen?
            when fileSet.contains(screen.file) &&
                screen.file.startsWith('lib/ui/$name/widgets/'))
          screen,
    ];

    features[name] = Feature(
      folder: 'lib/ui/$name',
      viewModels: _sorted([for (final element in viewModels) ?refOf(element)]),
      screens: _sorted(screens),
      repositories: _sorted(repositories),
      services: _sorted(services),
      models: _sorted(models),
      tests: tests,
      files: files,
    );
  }
  return FeaturesMap(features: features);
}
```

The output is unchanged:
- `viewModels` keeps library-then-class order, as before;
- `models`, `repositories`, `services` and `screens` go through `_sorted`, which sorts and removes duplicates;
- `files` and `tests` are sorted as before.

- [ ] **Step 4: Index `featureOf` in `MapSync`**

In `map_sync.dart`, inside `build`, replace:

```dart
      String? featureOf(String file) => features?.featureOf(file);
```

with:

```dart
      // Built once: FeaturesMap.featureOf scans every feature's file list,
      // and it is asked once per file. The first feature that lists a file
      // wins, as in featureOf.
      final featureByFile = <String, String>{};
      for (final MapEntry(key: name, value: feature)
          in features?.features.entries ?? <MapEntry<String, Feature>>[]) {
        for (final file in [...feature.files, ...feature.tests]) {
          featureByFile.putIfAbsent(file, () => name);
        }
      }
      String? featureOf(String file) => featureByFile[file];
```

- [ ] **Step 5: Prove the output didn't change**

Run: `cd packages/appstein_engine && fvm dart test`
Expected: PASS, with **no golden changed**: `git status` shows no file under `test/fixtures/apps/goldens/`. The goldens of every map file (`features.json` included) are the proof that the output is identical.

Also run from the repo root: `fvm dart analyze --fatal-infos` and `fvm dart format --output=none --set-exit-if-changed .`. Both must be clean.

- [ ] **Step 6: Report for commit**

Commit message: `perf: readFeatures and featureOf are linear; the checkPackages tests carried from 1b.3`. Add the trailer `Docs-Checked: project-map - the map's output and rules are unchanged`.

---

### Task 2: The analyzer cache file

**Files:**
- Create: `packages/appstein_engine/lib/src/map/analyzer_cache.dart`
- Modify: `packages/appstein_engine/lib/src/knowledge/knowledge_store.dart` (`replaceFile` gains a bytes twin)
- Modify: `packages/appstein_engine/lib/src/map/project_analysis.dart` (`analyze` takes a cache)
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (export)
- Modify: `packages/appstein_engine/pubspec.yaml` (`analyzer: 14.4.0`)
- Test: `packages/appstein_engine/test/map/analyzer_cache_test.dart` (new)
- Test: `packages/appstein_engine/test/knowledge/knowledge_store_test.dart`

**Interfaces:**
- Consumes: `replaceFile`'s retry behaviour, from `knowledge_store.dart`.
- Produces:
  - `const String analyzerVersion` (`'14.4.0'`) and `const int analyzerCacheFormat` (`1`);
  - `String analyzerCachePath(String projectRoot)`;
  - `Uint8List encodeAnalyzerCache(Map<String, Uint8List> entries, {String analyzer = analyzerVersion, int format = analyzerCacheFormat})`;
  - `Map<String, Uint8List> decodeAnalyzerCache(Uint8List bytes)`, which throws `FormatException`;
  - `enum AnalyzerCacheLoad { missing, loaded, damaged }`;
  - `final class AnalyzerCache`:
    - constructors `AnalyzerCache.empty(String path)` and `factory AnalyzerCache.open(String path)`;
    - fields `path`, `load`, `damage`;
    - getters `loadedEntries`, `addedEntries`, `changed`;
    - methods `Uint8List? get(String key)`, `Uint8List putGet(String key, Uint8List bytes)` and `Future<void> save()`, which throws `KnowledgeWriteException`;
  - `AnalysisContextCollection analysisCollection({required List<String> includedPaths, required String sdkPath, AnalyzerCache? cache})`;
  - `Future<T> catchAnalyzerErrors<T>(Future<T> Function() body)`;
  - `Future<void> replaceFileBytes(String path, List<int> bytes, {Duration retryFor, Duration retryEvery})`;
  - `ProjectAnalysis.analyze(String projectRoot, {required String dartSdkPath, AnalyzerCache? cache})`.

- [ ] **Step 1: Pin the analyzer exactly**

In `packages/appstein_engine/pubspec.yaml`, change `analyzer: ^14.4.0` to `analyzer: 14.4.0`. Run `fvm dart pub get` at the repo root. `git diff pubspec.lock` must show no change, since 14.4.0 is already what the lock holds. If it changed, stop and report.

- [ ] **Step 2: Write the failing tests**

Create `packages/appstein_engine/test/map/analyzer_cache_test.dart`:

```dart
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../support/fixture_app.dart';
import '../support/temp.dart';

Uint8List bytes(String text) => Uint8List.fromList(text.codeUnits);

void main() {
  late String path;

  setUp(() {
    path = p.join(
      tempDir().path,
      '.dart_tool',
      'appstein',
      'analyzer_cache.bin',
    );
  });

  group('the cache file', () {
    test('a missing file opens as an empty cache', () {
      final cache = AnalyzerCache.open(path);
      expect(cache.load, AnalyzerCacheLoad.missing);
      expect(cache.damage, isNull);
      expect(cache.loadedEntries, 0);
      expect(cache.changed, isFalse);
    });

    test('what is saved opens again', () async {
      final cache = AnalyzerCache.open(path)
        ..putGet('a.key', bytes('one'))
        ..putGet('b.key', bytes('two'));
      expect(cache.addedEntries, 2);
      expect(cache.changed, isTrue);
      await cache.save();
      final again = AnalyzerCache.open(path);
      expect(again.load, AnalyzerCacheLoad.loaded);
      expect(again.loadedEntries, 2);
      expect(String.fromCharCodes(again.get('a.key')!), 'one');
      expect(again.get('missing.key'), isNull);
    });

    test('only the entries a run used are kept', () async {
      await (AnalyzerCache.open(path)
            ..putGet('a.key', bytes('one'))
            ..putGet('b.key', bytes('two')))
          .save();
      final cache = AnalyzerCache.open(path)..get('a.key');
      expect(cache.changed, isTrue);
      await cache.save();
      final again = AnalyzerCache.open(path);
      expect(again.loadedEntries, 1);
      expect(again.get('b.key'), isNull);
    });

    test('a run that used every entry and added none changes nothing', () async {
      await (AnalyzerCache.open(path)..putGet('a.key', bytes('one'))).save();
      final cache = AnalyzerCache.open(path)..get('a.key');
      expect(cache.changed, isFalse);
    });

    test('putGet keeps the bytes already stored', () async {
      await (AnalyzerCache.open(path)..putGet('a.key', bytes('one'))).save();
      final cache = AnalyzerCache.open(path);
      expect(String.fromCharCodes(cache.putGet('a.key', bytes('other'))), 'one');
      expect(cache.addedEntries, 0);
    });

    test('the same entries give the same bytes, whatever the order', () {
      final one = encodeAnalyzerCache({
        'b.key': bytes('2'),
        'a.key': bytes('1'),
      });
      final two = encodeAnalyzerCache({
        'a.key': bytes('1'),
        'b.key': bytes('2'),
      });
      expect(one, two);
      expect(decodeAnalyzerCache(one).keys, ['a.key', 'b.key']);
    });

    group('a damaged file opens as an empty cache that says why', () {
      void expectDamaged(List<int> content, String why) {
        File(path)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(content);
        final cache = AnalyzerCache.open(path);
        expect(cache.load, AnalyzerCacheLoad.damaged);
        expect(cache.damage, why);
        expect(cache.loadedEntries, 0);
      }

      test('not a cache', () {
        expectDamaged(bytes('hello'), 'it is not an Appstein analyzer cache');
      });

      test('another cache format', () {
        expectDamaged(
          encodeAnalyzerCache({}, format: 2),
          'it was written in cache format 2, not 1',
        );
      });

      test('another analyzer', () {
        expectDamaged(
          encodeAnalyzerCache({}, analyzer: '14.3.0'),
          'it was written by analyzer 14.3.0, not $analyzerVersion',
        );
      });

      test('cut short', () {
        final whole = encodeAnalyzerCache({'a.key': bytes('one')});
        expectDamaged(whole.sublist(0, whole.length - 2), 'it is cut short');
      });
    });

    test('a cache that cannot be written throws KnowledgeWriteException', () async {
      // The folder the cache goes in is a file.
      final blocked = p.join(tempDir().path, 'blocked');
      File(blocked).writeAsStringSync('');
      final cache = AnalyzerCache.open(p.join(blocked, 'analyzer_cache.bin'))
        ..putGet('a.key', bytes('one'));
      await expectLater(cache.save(), throwsA(isA<KnowledgeWriteException>()));
    });

    test('it lives in .dart_tool/appstein', () {
      expect(
        analyzerCachePath('my app'),
        p.join('my app', '.dart_tool', 'appstein', 'analyzer_cache.bin'),
      );
    });
  });

  group('with the analyzer', () {
    test('the analyzer stores its work in the cache and reads it back '
        '(the canary for the analyzer src/ API)', () async {
      final app = copyFixtureApp();
      final cachePath = analyzerCachePath(app);
      final first = AnalyzerCache.open(cachePath);
      await (await ProjectAnalysis.analyze(
        app,
        dartSdkPath: testDartSdk,
        cache: first,
      )).dispose();
      expect(
        first.addedEntries,
        greaterThan(0),
        reason:
            'The analyzer no longer writes to the cache: check its ByteStore '
            'API after an analyzer upgrade.',
      );
      await first.save();
      final second = AnalyzerCache.open(cachePath);
      final analysis = await ProjectAnalysis.analyze(
        app,
        dartSdkPath: testDartSdk,
        cache: second,
      );
      await analysis.dispose();
      expect(analysis.libraries, isNotEmpty);
      expect(
        second.addedEntries,
        0,
        reason: 'The analyzer no longer reads from the cache.',
      );
      expect(second.changed, isFalse);
    });

    test('analyzerVersion is the exact version pubspec.yaml pins', () {
      final library = Isolate.resolvePackageUriSync(
        Uri.parse('package:appstein_engine/appstein_engine.dart'),
      )!;
      final pubspec =
          loadYaml(
                File(
                  p.join(
                    p.dirname(p.dirname(library.toFilePath())),
                    'pubspec.yaml',
                  ),
                ).readAsStringSync(),
              )
              as YamlMap;
      expect(
        (pubspec['dependencies'] as YamlMap)['analyzer'],
        analyzerVersion,
      );
    });
  });

  test('catchAnalyzerErrors turns an error nobody awaits into its '
      'result', () async {
    final result = catchAnalyzerErrors<int>(() async {
      // Like the analyzer's scheduler: an error on a future nobody awaits,
      // while the work itself waits forever.
      unawaited(Future<void>.error(StateError('from the scheduler')));
      await Completer<void>().future;
      return 1;
    });
    await expectLater(result, throwsA(isA<StateError>()));
  });

  test('catchAnalyzerErrors returns the result', () async {
    expect(await catchAnalyzerErrors(() async => 7), 7);
  });
}
```

In `knowledge_store_test.dart`, add after the test `'writes state.json as canonical JSON'`:

```dart
  test('replaceFileBytes writes bytes in one step, creating folders', () async {
    final path = p.join(tempDir().path, 'a', 'b.bin');
    await replaceFileBytes(path, [0, 255, 1]);
    expect(File(path).readAsBytesSync(), [0, 255, 1]);
    expect(File('$path.tmp').existsSync(), isFalse);
  });
```

(Check that `knowledge_store_test.dart` imports `../support/temp.dart`. If it doesn't, add the import.)

- [ ] **Step 3: Run them to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/map/analyzer_cache_test.dart test/knowledge/knowledge_store_test.dart`
Expected: FAIL to compile. `AnalyzerCache`, `replaceFileBytes` and the rest don't exist yet.

- [ ] **Step 4: Write `analyzer_cache.dart`**

Create `packages/appstein_engine/lib/src/map/analyzer_cache.dart`:

```dart
// The analyzer keeps its on-disk cache (`ByteStore`) and the collection that
// takes one (`AnalysisContextCollectionImpl`) in its `src/` folder, with no
// public way to use them. The owner chose to use them (slice 1b.7): every
// such use is in this file, and pubspec.yaml pins analyzer exactly, so an
// analyzer upgrade is a deliberate step that starts here. The canary test in
// analyzer_cache_test.dart fails if the analyzer stops using the cache.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../knowledge/knowledge_store.dart';

/// The analyzer version the cache's entries belong to: the exact version
/// `pubspec.yaml` pins. A test checks that they agree.
const analyzerVersion = '14.4.0';

/// The layout of the cache file; raise it when [encodeAnalyzerCache]
/// changes.
const analyzerCacheFormat = 1;

const _magic = 'APPSTEIN ANALYZER CACHE\n';

/// Where the analyzer cache of the project at [projectRoot] lives (spec
/// §6.2): in `.dart_tool/`, beside other Dart tools' caches, which Flutter's
/// template git-ignores and `flutter clean` deletes.
String analyzerCachePath(String projectRoot) =>
    p.join(projectRoot, '.dart_tool', 'appstein', 'analyzer_cache.bin');

/// The bytes of a cache file holding [entries]:
/// - the line `APPSTEIN ANALYZER CACHE`;
/// - [format] (4 bytes), then [analyzer] (2 bytes of length, then ASCII);
/// - each entry, sorted by key: the key (2 bytes of length, then ASCII),
///   then its bytes (4 bytes of length, then the bytes).
///
/// Numbers are big-endian. [analyzer] and [format] differ from the defaults
/// only in tests.
Uint8List encodeAnalyzerCache(
  Map<String, Uint8List> entries, {
  String analyzer = analyzerVersion,
  int format = analyzerCacheFormat,
}) {
  final out = BytesBuilder(copy: false)..add(ascii.encode(_magic));
  void number(int value, int length) {
    final data = ByteData(length);
    if (length == 2) {
      data.setUint16(0, value);
    } else {
      data.setUint32(0, value);
    }
    out.add(data.buffer.asUint8List());
  }

  number(format, 4);
  final version = ascii.encode(analyzer);
  number(version.length, 2);
  out.add(version);
  for (final key in entries.keys.toList()..sort()) {
    final name = ascii.encode(key);
    number(name.length, 2);
    out.add(name);
    final value = entries[key]!;
    number(value.length, 4);
    out.add(value);
  }
  return out.takeBytes();
}

/// The entries of a cache file's [bytes], as views into [bytes].
///
/// Throws a [FormatException] whose message says why, in words that follow
/// "the cache was not used because", when [bytes] isn't a cache file of
/// this format and analyzer version, or is cut short.
Map<String, Uint8List> decodeAnalyzerCache(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var at = 0;
  void need(int count) {
    if (at + count > bytes.length) {
      throw const FormatException('it is cut short');
    }
  }

  String text(int length) {
    need(length);
    final value = latin1.decode(Uint8List.sublistView(bytes, at, at + length));
    at += length;
    return value;
  }

  final magic = ascii.encode(_magic);
  if (bytes.length < magic.length ||
      latin1.decode(Uint8List.sublistView(bytes, 0, magic.length)) != _magic) {
    throw const FormatException('it is not an Appstein analyzer cache');
  }
  at = magic.length;
  need(4);
  final format = data.getUint32(at);
  at += 4;
  if (format != analyzerCacheFormat) {
    throw FormatException(
      'it was written in cache format $format, not $analyzerCacheFormat',
    );
  }
  need(2);
  final versionLength = data.getUint16(at);
  at += 2;
  final version = text(versionLength);
  if (version != analyzerVersion) {
    throw FormatException(
      'it was written by analyzer $version, not $analyzerVersion',
    );
  }
  final entries = <String, Uint8List>{};
  while (at < bytes.length) {
    need(2);
    final keyLength = data.getUint16(at);
    at += 2;
    final key = text(keyLength);
    need(4);
    final length = data.getUint32(at);
    at += 4;
    need(length);
    entries[key] = Uint8List.sublistView(bytes, at, at + length);
    at += length;
  }
  return entries;
}

/// How an [AnalyzerCache] opened.
enum AnalyzerCacheLoad {
  /// There was no cache file: the first sync, or after `flutter clean`.
  missing,

  /// The cache file was read.
  loaded,

  /// The cache file couldn't be used ([AnalyzerCache.damage] says why), so
  /// the cache starts empty.
  damaged,
}

/// The Dart analyzer's on-disk cache for one project (spec §6.2): what it
/// worked out about each library, so the next sync doesn't redo it.
///
/// It only makes syncs faster. The knowledge is the same with it, without
/// it, or with a damaged one.
final class AnalyzerCache {
  AnalyzerCache._(this.path, this.load, this.damage, this._loaded);

  /// An empty cache that saves to [path].
  AnalyzerCache.empty(this.path)
    : load = AnalyzerCacheLoad.missing,
      damage = null,
      _loaded = const {};

  /// Opens the cache file at [path]. A missing file gives an empty cache.
  /// So does a damaged or unreadable one, or one of another format or
  /// analyzer version, with [damage] saying why. It never throws.
  factory AnalyzerCache.open(String path) {
    final file = File(path);
    final Uint8List bytes;
    try {
      bytes = file.readAsBytesSync();
    } on FileSystemException catch (error) {
      if (!file.existsSync()) return AnalyzerCache.empty(path);
      return AnalyzerCache._(
        path,
        AnalyzerCacheLoad.damaged,
        'it could not be read (${fileErrorReason(error)})',
        const {},
      );
    }
    try {
      return AnalyzerCache._(
        path,
        AnalyzerCacheLoad.loaded,
        null,
        decodeAnalyzerCache(bytes),
      );
    } on FormatException catch (error) {
      return AnalyzerCache._(
        path,
        AnalyzerCacheLoad.damaged,
        error.message,
        const {},
      );
    }
  }

  /// The cache file.
  final String path;

  /// How it opened.
  final AnalyzerCacheLoad load;

  /// Why the file couldn't be used, when [load] is
  /// [AnalyzerCacheLoad.damaged].
  final String? damage;

  final Map<String, Uint8List> _loaded;
  final _used = <String, Uint8List>{};
  var _added = 0;
  late final ByteStore _store = _Store(this);

  /// How many entries were read from the file.
  int get loadedEntries => _loaded.length;

  /// How many entries the analyzer added since the cache was opened.
  int get addedEntries => _added;

  /// Whether [save] would write something different: an entry was added,
  /// or one that was read went unused.
  bool get changed => _added > 0 || _used.length != _loaded.length;

  /// The bytes stored for [key], or null. The entry counts as used.
  Uint8List? get(String key) {
    final bytes = _used[key] ?? _loaded[key];
    if (bytes != null) _used[key] = bytes;
    return bytes;
  }

  /// Stores [bytes] for [key], unless bytes are already stored for it, and
  /// returns the stored bytes. The entry counts as used.
  Uint8List putGet(String key, Uint8List bytes) {
    if (_used[key] ?? _loaded[key] case final existing?) {
      return _used[key] = existing;
    }
    _added++;
    return _used[key] = bytes;
  }

  /// Writes the entries used since the cache was opened to [path], in one
  /// step, so the file never holds entries no run needs.
  ///
  /// Throws a `KnowledgeWriteException` when it can't be written.
  Future<void> save() => replaceFileBytes(path, encodeAnalyzerCache(_used));
}

/// The analyzer's view of an [AnalyzerCache].
final class _Store implements ByteStore {
  _Store(this._cache);

  final AnalyzerCache _cache;

  @override
  Uint8List? get(String key) => _cache.get(key);

  @override
  Uint8List putGet(String key, Uint8List bytes) => _cache.putGet(key, bytes);

  @override
  void release(Iterable<String> keys) {}
}

/// The analyzer's view of the folders [includedPaths], reading `dart:`
/// libraries from the Dart SDK at [sdkPath]. With a [cache], the analyzer
/// keeps its work there.
AnalysisContextCollection analysisCollection({
  required List<String> includedPaths,
  required String sdkPath,
  AnalyzerCache? cache,
}) => cache == null
    ? AnalysisContextCollection(includedPaths: includedPaths, sdkPath: sdkPath)
    : AnalysisContextCollectionImpl(
        includedPaths: includedPaths,
        sdkPath: sdkPath,
        byteStore: cache._store,
      );

/// Runs [body] and returns its result.
///
/// The analyzer does its work in a scheduler of its own. An error there,
/// such as one from a cache entry holding garbage, isn't an error of
/// [body]'s futures: it ends the process (seen in the 1b.7 probe). Here it
/// becomes the returned future's error. An error after [body] finished is
/// ignored.
Future<T> catchAnalyzerErrors<T>(Future<T> Function() body) {
  final done = Completer<T>();
  runZonedGuarded(
    () async {
      final value = await body();
      if (!done.isCompleted) done.complete(value);
    },
    (error, stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    },
  );
  return done.future;
}
```

`file_errors.dart` lives in `lib/src/host/`: check the relative import path with `ls packages/appstein_engine/lib/src/host/file_errors.dart`.

- [ ] **Step 5: Add `replaceFileBytes`**

In `knowledge_store.dart`, replace the whole top-level `replaceFile` function with these three functions, keeping `replaceFile`'s doc comment on it:

```dart
Future<void> replaceFile(
  String path,
  String contents, {
  Duration retryFor = const Duration(seconds: 2),
  Duration retryEvery = const Duration(milliseconds: 20),
}) => _replace(
  path,
  (temp) => temp.writeAsStringSync(contents, flush: true),
  retryFor: retryFor,
  retryEvery: retryEvery,
);

/// Replaces the file at [path] with [bytes] in one step, as [replaceFile]
/// does with text.
Future<void> replaceFileBytes(
  String path,
  List<int> bytes, {
  Duration retryFor = const Duration(seconds: 2),
  Duration retryEvery = const Duration(milliseconds: 20),
}) => _replace(
  path,
  (temp) => temp.writeAsBytesSync(bytes, flush: true),
  retryFor: retryFor,
  retryEvery: retryEvery,
);

Future<void> _replace(
  String path,
  void Function(File temp) write, {
  required Duration retryFor,
  required Duration retryEvery,
}) async {
  // The old body of replaceFile, unchanged, except that
  // `temp.writeAsStringSync(contents, flush: true);` becomes `write(temp);`.
}
```

The comment inside `_replace` stands for moving the old body. Move it in full, from `final temp = File('$path.tmp');` to the end, with only that one line changed.

- [ ] **Step 6: Let `ProjectAnalysis.analyze` take the cache**

In `project_analysis.dart`:
- add `import 'analyzer_cache.dart';`;
- remove `import 'package:analyzer/dart/analysis/analysis_context_collection.dart';` only if the analyzer then reports it unused. The field `_collection` keeps the type `AnalysisContextCollection?`, so it most likely stays.

Change the signature and the doc comment's first paragraph:

```dart
  /// Analyzes the project at [projectRoot], reading `dart:` libraries from
  /// the Dart SDK at [dartSdkPath] (inside a Flutter SDK, that is
  /// `bin/cache/dart-sdk`). With a [cache], the analyzer keeps its work there
  /// for the next analysis (spec §6.2).
  static Future<ProjectAnalysis> analyze(
    String projectRoot, {
    required String dartSdkPath,
    AnalyzerCache? cache,
  }) async {
```

and replace:

```dart
    final collection = AnalysisContextCollection(
      includedPaths: included,
      sdkPath: sdk,
    );
```

with:

```dart
    final collection = analysisCollection(
      includedPaths: included,
      sdkPath: sdk,
      cache: cache,
    );
```

- [ ] **Step 7: Export it**

In `packages/appstein_engine/lib/appstein_engine.dart`, add `export 'src/map/analyzer_cache.dart';` before `export 'src/map/ast_values.dart';`.

- [ ] **Step 8: Run the tests**

Run: `cd packages/appstein_engine && fvm dart test test/map/analyzer_cache_test.dart test/knowledge/knowledge_store_test.dart test/map/project_analysis_test.dart`
Expected: PASS.

If the canary fails on `addedEntries`, the analyzer isn't calling our store. Check `AnalysisContextCollectionImpl`'s `byteStore` parameter in `~/.pub-cache/hosted/pub.dev/analyzer-14.4.0/lib/src/dart/analysis/analysis_context_collection.dart` (on Windows, `%LOCALAPPDATA%\Pub\Cache\…`). Then report; don't change the test.

Then, from the repo root: `fvm dart analyze --fatal-infos`. It must be clean. The only `implementation_imports` ignore is the one in `analyzer_cache.dart`.

- [ ] **Step 9: Report for commit**

Commit message: `feat: the analyzer cache file, pinned to analyzer 14.4.0`. Add the trailer `Docs-Checked: project-map - the new cache is documented with the sync in Task 8`.

---

### Task 3: Map inputs, with local packages, read before any analysis

**Files:**
- Create: `packages/appstein_engine/lib/src/map/map_inputs.dart`
- Modify: `packages/appstein_engine/lib/src/knowledge/input_hash.dart` (`inputHashOfDigests`)
- Modify: `packages/appstein_engine/lib/src/map/map_sync.dart` (uses `readMapInputs`; `MapBuild.inputs`)
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (export)
- Test: `packages/appstein_engine/test/map/map_inputs_test.dart` (new)
- Test: `packages/appstein_engine/test/knowledge/input_hash_test.dart`

**Interfaces:**
- Consumes: `ProjectAnalysis.folders`; `Pack`; `HostEnvironment.variable`, `.os` and `.homeDir`; `sha256Hex`; `knowledgeFormatVersion` (protocol).
- Produces:
  - `String inputHashOfDigests(Map<String, String?> digests, {required String appsteinVersion, required int formatVersion})`;
  - `final class MapInputs { Map<String, String?> sources; String inputHash; }`;
  - `MapInputs readMapInputs(String projectRoot, {required String workspaceRoot, required String flutterVersion, required String flutterRoot, required List<Pack> packs, required String appsteinVersion, required HostEnvironment environment})`;
  - `Map<String, String> localPackageRoots(String projectRoot, {required String workspaceRoot, required String flutterRoot, required HostEnvironment environment})`;
  - `List<String> pubCacheFolders(HostEnvironment environment)`;
  - `MapBuild.inputs` (`MapInputs?`). `MapBuild.inputHash` stays, as a getter.

- [ ] **Step 1: Write the failing tests**

In `input_hash_test.dart`, add:

```dart
  test('inputHashOfDigests gives inputHash from the inputs\' digests', () {
    final inputs = <String, List<int>?>{
      'a': [1, 2],
      'b': null,
    };
    expect(
      inputHashOfDigests(
        {'a': sha256Hex([1, 2]), 'b': null},
        appsteinVersion: '0.1.0-dev',
        formatVersion: 1,
      ),
      inputHash(inputs, appsteinVersion: '0.1.0-dev', formatVersion: 1),
    );
  });
```

Create `packages/appstein_engine/test/map/map_inputs_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/temp.dart';

void main() {
  MapInputs read(String app, {List<Pack> packs = const [OfficialMvvmPack()]}) =>
      readMapInputs(
        app,
        workspaceRoot: app,
        flutterVersion: '3.47.5',
        flutterRoot: p.join(tempDir().path, 'no flutter here'),
        packs: packs,
        appsteinVersion: '0.1.0-dev',
        environment: fakeEnvironment({}),
      );

  test('the project files, pubspec.yaml, the lock and analysis_options.yaml '
      'are inputs', () {
    final app = copyFixtureApp();
    final sources = read(app).sources;
    expect(sources['project:lib/main.dart'], isNotNull);
    expect(sources['pubspec.yaml'], isNotNull);
    expect(sources['pubspec.lock'], isNotNull);
    expect(sources.containsKey('analysis_options.yaml'), isTrue);
    expect(sources['analysis_options.yaml'], isNull);
    expect(
      sources.keys.where((name) => name.startsWith('project:')),
      everyElement(matches(RegExp(r'^project:(lib|test|testing)/.+\.dart$'))),
    );
  });

  test("a local package's lib files and pubspec are inputs; the project "
      'itself is not a local package', () {
    final app = copyFixtureApp();
    expect(
      localPackageRoots(
        app,
        workspaceRoot: app,
        flutterRoot: p.join(tempDir().path, 'no flutter here'),
        environment: fakeEnvironment({}),
      ).keys,
      unorderedEquals(['flutter', 'flutter_test', 'go_router']),
    );
    final sources = read(app).sources;
    expect(sources['local-package:go_router/lib/go_router.dart'], isNotNull);
    expect(sources['local-package:go_router/lib/fix_data.yaml'], isNotNull);
    expect(sources.containsKey('local-package:go_router/pubspec.yaml'), isTrue);
  });

  test('packages in the pub cache or the Flutter SDK are not local', () {
    final work = tempDir().path;
    final project = p.join(work, 'app');
    final cache = p.join(work, 'pub cache');
    final flutter = p.join(work, 'flutter');
    File(p.join(project, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'hosted',
              'rootUri': Uri.directory(
                p.join(cache, 'hosted', 'pub.dev', 'hosted-1.0.0'),
              ).toString(),
              'packageUri': 'lib/',
            },
            {
              'name': 'flutter',
              'rootUri': Uri.directory(
                p.join(flutter, 'packages', 'flutter'),
              ).toString(),
              'packageUri': 'lib/',
            },
            {'name': 'core', 'rootUri': '../../core', 'packageUri': 'lib/'},
          ],
        }),
      );
    expect(
      localPackageRoots(
        project,
        workspaceRoot: project,
        flutterRoot: flutter,
        environment: fakeEnvironment({'PUB_CACHE': cache}),
      ),
      {'core': p.join(work, 'core')},
    );
  });

  test('a missing or damaged package config means no local packages', () {
    final project = p.join(tempDir().path, 'app');
    Map<String, String> roots() => localPackageRoots(
      project,
      workspaceRoot: project,
      flutterRoot: 'flutter',
      environment: fakeEnvironment({}),
    );
    expect(roots(), isEmpty);
    File(p.join(project, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{not json');
    expect(roots(), isEmpty);
  });

  test('pubCacheFolders follows PUB_CACHE, then the OS default', () {
    expect(
      pubCacheFolders(fakeEnvironment({'PUB_CACHE': p.join('x', 'cache')})),
      [p.normalize(p.absolute(p.join('x', 'cache')))],
    );
    expect(
      pubCacheFolders(
        fakeEnvironment({
          'LOCALAPPDATA': r'C:\Users\a\AppData\Local',
          'APPDATA': r'C:\Users\a\AppData\Roaming',
        }, os: HostOs.windows),
      ),
      [
        p.join(r'C:\Users\a\AppData\Local', 'Pub', 'Cache'),
        p.join(r'C:\Users\a\AppData\Roaming', 'Pub', 'Cache'),
      ],
    );
    expect(
      pubCacheFolders(fakeEnvironment({'HOME': '/home/a'}, os: HostOs.linux)),
      [p.join('/home/a', '.pub-cache')],
    );
  });

  test("editing a local package's file changes the hash", () {
    final app = copyFixtureApp();
    final before = read(app).inputHash;
    File(
      p.join(p.dirname(app), 'stubs', 'go_router', 'lib', 'go_router.dart'),
    ).writeAsStringSync('\n// edited\n', mode: FileMode.append);
    expect(read(app).inputHash, isNot(before));
  });

  test('the same files give the same hash, wherever the project is', () {
    expect(read(copyFixtureApp()).inputHash, read(copyFixtureApp()).inputHash);
  });

  test('the packs are part of the hash', () {
    final app = copyFixtureApp();
    expect(read(app).inputHash, isNot(read(app, packs: const []).inputHash));
  });
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/map/map_inputs_test.dart test/knowledge/input_hash_test.dart`
Expected: FAIL to compile. `readMapInputs` and the rest don't exist yet.

- [ ] **Step 3: Write `inputHashOfDigests`**

In `input_hash.dart`, replace `inputHash` with these two functions, keeping `inputHash`'s doc comment:

```dart
String inputHash(
  Map<String, List<int>?> inputs, {
  required String appsteinVersion,
  required int formatVersion,
}) => inputHashOfDigests(
  {
    for (final MapEntry(:key, :value) in inputs.entries)
      key: value == null ? null : sha256Hex(value),
  },
  appsteinVersion: appsteinVersion,
  formatVersion: formatVersion,
);

/// [inputHash] from each input's SHA-256 ([sha256Hex] of its bytes), or null
/// when it is missing, instead of its bytes. For the same inputs it gives
/// the same hash as [inputHash]. The map uses it: it keeps each file's
/// digest for `state.json` (spec §6.2).
String inputHashOfDigests(
  Map<String, String?> digests, {
  required String appsteinVersion,
  required int formatVersion,
}) {
  final names = digests.keys.toList()..sort();
  final lines = [
    'appstein $appsteinVersion',
    'format $formatVersion',
    for (final name in names) '$name ${digests[name] ?? 'missing'}',
  ];
  return sha256Hex(utf8.encode(lines.join('\n')));
}
```

- [ ] **Step 4: Write `map_inputs.dart`**

Create `packages/appstein_engine/lib/src/map/map_inputs.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../host/host_environment.dart';
import '../knowledge/input_hash.dart';
import '../packs/pack.dart';
import 'project_analysis.dart';

/// What the project map is built from (spec §6.2, §6.5), read before any
/// analysis, so `sync --detect` can tell whether the map is current.
final class MapInputs {
  /// Creates the inputs.
  const MapInputs({required this.sources, required this.inputHash});

  /// The SHA-256 of each input file, by input name, or null when the file
  /// can't be read:
  /// - `project:<path>` for each `.dart` file under
  ///   [ProjectAnalysis.folders];
  /// - `pubspec.yaml`, `pubspec.lock` (the workspace root's) and
  ///   `analysis_options.yaml`;
  /// - `local-package:<name>/<path>` for a local package's `pubspec.yaml`
  ///   and each `.dart` or `.yaml` file under its `lib/`
  ///   ([localPackageRoots]).
  ///
  /// A folder that can't be listed is an input named after it
  /// (`project:lib/`, `local-package:<name>/lib/`) with null.
  final Map<String, String?> sources;

  /// The input hash every map file shares: [sources], the Flutter version,
  /// and the packs' ids and versions.
  final String inputHash;
}

/// Reads the inputs of the map of the project at [projectRoot], whose
/// `pubspec.lock` and package config are in [workspaceRoot] (the project
/// itself, or its pub workspace's root), for Flutter [flutterVersion] at
/// [flutterRoot].
MapInputs readMapInputs(
  String projectRoot, {
  required String workspaceRoot,
  required String flutterVersion,
  required String flutterRoot,
  required List<Pack> packs,
  required String appsteinVersion,
  required HostEnvironment environment,
}) {
  final sources = <String, String?>{
    'pubspec.yaml': _digest(p.join(projectRoot, 'pubspec.yaml')),
    'pubspec.lock': _digest(p.join(workspaceRoot, 'pubspec.lock')),
    // Its `exclude:` changes which files the map covers.
    'analysis_options.yaml': _digest(
      p.join(projectRoot, 'analysis_options.yaml'),
    ),
  };
  for (final folder in ProjectAnalysis.folders) {
    final files = _filesUnder(p.join(projectRoot, folder), const ['.dart']);
    if (files == null) {
      sources['project:$folder/'] = null;
      continue;
    }
    for (final file in files) {
      sources['project:${_relative(file, projectRoot)}'] = _digest(file);
    }
  }
  final locals = localPackageRoots(
    projectRoot,
    workspaceRoot: workspaceRoot,
    flutterRoot: flutterRoot,
    environment: environment,
  );
  for (final MapEntry(key: name, value: root) in locals.entries) {
    sources['local-package:$name/pubspec.yaml'] = _digest(
      p.join(root, 'pubspec.yaml'),
    );
    final files = _filesUnder(p.join(root, 'lib'), const ['.dart', '.yaml']);
    if (files == null) {
      sources['local-package:$name/lib/'] = null;
      continue;
    }
    for (final file in files) {
      sources['local-package:$name/${_relative(file, root)}'] = _digest(file);
    }
  }
  return MapInputs(
    sources: sources,
    inputHash: inputHashOfDigests(
      {
        ...sources,
        'flutter': sha256Hex(utf8.encode(flutterVersion)),
        'packs': sha256Hex(
          utf8.encode(
            [for (final pack in packs) '${pack.id}@${pack.version}'].join(','),
          ),
        ),
      },
      appsteinVersion: appsteinVersion,
      formatVersion: knowledgeFormatVersion,
    ),
  );
}

/// The project's local packages, by name, with their folders.
///
/// A local package is a package in the workspace's
/// `.dart_tool/package_config.json` that is in neither the Flutter SDK at
/// [flutterRoot] nor a pub cache folder ([pubCacheFolders]), other than the
/// project itself. A path dependency or a workspace sibling can change
/// without `pubspec.lock` changing, so the map hashes its files. Packages
/// from pub.dev or git are pinned by `pubspec.lock`, and the SDK's by the
/// Flutter version.
///
/// A missing or damaged package config gives none.
Map<String, String> localPackageRoots(
  String projectRoot, {
  required String workspaceRoot,
  required String flutterRoot,
  required HostEnvironment environment,
}) {
  final config = File(
    p.join(workspaceRoot, '.dart_tool', 'package_config.json'),
  );
  final Object? json;
  try {
    json = jsonDecode(config.readAsStringSync());
  } on FileSystemException {
    return const {};
  } on FormatException {
    return const {};
  }
  if (json case {'packages': final List<Object?> packages}) {
    final skipped = [
      p.normalize(p.absolute(flutterRoot)),
      ...pubCacheFolders(environment),
    ];
    final project = p.normalize(p.absolute(projectRoot));
    // Root URIs are relative to the package config file itself.
    final base = Uri.file(config.absolute.path);
    final roots = <String, String>{};
    for (final package in packages) {
      if (package case {
        'name': final String name,
        'rootUri': final String rootUri,
      }) {
        final String root;
        try {
          root = p.normalize(base.resolve(rootUri).toFilePath());
        } on FormatException {
          continue;
        } on UnsupportedError {
          // Not a file URI.
          continue;
        }
        if (p.equals(root, project) ||
            skipped.any(
              (folder) => p.equals(folder, root) || p.isWithin(folder, root),
            )) {
          continue;
        }
        roots[name] = root;
      }
    }
    return roots;
  }
  return const {};
}

/// Where pub keeps downloaded packages: `PUB_CACHE` when it is set, else
/// pub's default for the OS. On Windows that is `%LOCALAPPDATA%\Pub\Cache`,
/// and the older `%APPDATA%\Pub\Cache` too. A cache missing from this list
/// costs only time: its packages are hashed as local ones.
List<String> pubCacheFolders(HostEnvironment environment) {
  if (environment.variable('PUB_CACHE') case final cache?) {
    return [p.normalize(p.absolute(cache))];
  }
  if (environment.os == HostOs.windows) {
    return [
      for (final name in const ['LOCALAPPDATA', 'APPDATA'])
        if (environment.variable(name) case final base?)
          p.join(base, 'Pub', 'Cache'),
    ];
  }
  return [
    if (environment.homeDir case final home?) p.join(home, '.pub-cache'),
  ];
}

/// The files under [folder] whose names end with one of [extensions], or
/// null when it can't be listed. A missing folder has none.
List<String>? _filesUnder(String folder, List<String> extensions) {
  final directory = Directory(folder);
  if (!directory.existsSync()) return const [];
  try {
    return [
      for (final entity in directory.listSync(
        recursive: true,
        followLinks: false,
      ))
        if (entity is File && extensions.any(entity.path.endsWith))
          entity.path,
    ];
  } on FileSystemException {
    return null;
  }
}

String _relative(String file, String root) =>
    p.split(p.relative(file, from: root)).join('/');

String? _digest(String path) {
  try {
    return sha256Hex(File(path).readAsBytesSync());
  } on FileSystemException {
    return null;
  }
}
```

Export it: in `appstein_engine.dart`, add `export 'src/map/map_inputs.dart';` after `export 'src/map/layers.dart';`.

- [ ] **Step 5: `MapSync` reads its inputs with `readMapInputs`**

In `map_sync.dart`:

1. Add `import 'map_inputs.dart';`.
2. In `MapBuild`:
   - replace the constructor parameter `this.inputHash,` with `this.inputs,`;
   - replace the field `final String? inputHash;` and its doc with:

```dart
  /// What the map was built from; null when the map was skipped.
  final MapInputs? inputs;

  /// The input hash every map file shares; null when the map was skipped.
  String? get inputHash => inputs?.inputHash;
```

3. In `build`, replace:

```dart
      final hash = _inputHash(
        projectRoot,
        lockFile: lockFile,
        flutterVersion: flutterVersion,
      );
```

with:

```dart
      final inputs = readMapInputs(
        projectRoot,
        workspaceRoot: status.workspaceRoot,
        flutterVersion: flutterVersion,
        flutterRoot: flutterRoot,
        packs: packs,
        appsteinVersion: appsteinVersion,
        environment: environment,
      );
```

   Then, in the returned `MapBuild`:
   - the files use `inputHash: inputs.inputHash`;
   - `inputHash: hash,` becomes `inputs: inputs,`.
4. Delete the methods `_inputHash` and `_bytes`. Delete the imports the analyzer then reports unused (most likely `dart:convert` and `../knowledge/input_hash.dart`).

- [ ] **Step 6: Run the tests**

Run: `cd packages/appstein_engine && fvm dart test`
Expected: PASS, with no golden changed. The map's input hash for a project with local packages now also covers them, which no existing test pins.

From the repo root, run `fvm dart analyze --fatal-infos`. It must be clean.

- [ ] **Step 7: Report for commit**

Commit message: `feat: the map's inputs, local packages included, are read before the analysis`.

---

### Task 4: Sync uses the cache, and survives a bad one

**Files:**
- Modify: `packages/appstein_engine/lib/src/map/analyzer_cache.dart` (`AnalyzerCacheReport`)
- Modify: `packages/appstein_engine/lib/src/map/map_sync.dart` (guard, retry, `MapBuild.cache`, `MapBuild.cacheRetry`)
- Modify: `packages/appstein_engine/lib/src/knowledge/platform_sync.dart` (`SyncReport.analyzerCache`)
- Modify: `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart` (open, pass, save)
- Create: `packages/appstein_engine/test/knowledge/support/sync_harness.dart`
- Test: `packages/appstein_engine/test/knowledge/knowledge_sync_cache_test.dart` (new)

**Interfaces:**
- Consumes (Task 2): `AnalyzerCache`, `AnalyzerCacheLoad`, `analyzerCachePath`, `catchAnalyzerErrors`, `encodeAnalyzerCache`, `decodeAnalyzerCache`, and `ProjectAnalysis.analyze(…, cache:)`.
- Produces:
  - `final class AnalyzerCacheReport { AnalyzerCacheLoad load; String? damage; String? retried; String? saveError; }`;
  - `MapSync.build(…, AnalyzerCache? cache)`;
  - `MapBuild.cache` (`AnalyzerCache?`) and `MapBuild.cacheRetry` (`String?`);
  - `SyncReport.analyzerCache` (`AnalyzerCacheReport?`);
  - `KnowledgeSync(…, bool analyzerCache = true)`.
  - Test support: `String fakeFlutter({String version})`, `KnowledgeSync knowledgeSync({…})`, `String flutterCommand(String sdk)`, `Map<String, (String, DateTime)> snapshot(String project)`, `Map<String, String> knowledgeFiles(String project)`.

- [ ] **Step 1: Write the test harness**

Create `packages/appstein_engine/test/knowledge/support/sync_harness.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_process_runner.dart';
import '../../support/fake_sdk.dart';
import '../../support/flutter_fixtures.dart';
import '../../support/temp.dart';

/// A fake Flutter SDK of [version] with its toolchain files, in a temp
/// folder. The toolchain fixtures exist for 3.47.5 and 3.44.9.
String fakeFlutter({String version = '3.47.5'}) {
  final sdk = createFakeSdk(
    p.join(tempDir().path, 'flutter'),
    flutter: version,
  );
  addToolchainFiles(sdk, version);
  return sdk;
}

/// The `flutter` launcher of the SDK at [sdk], as `flutter pub get` runs it.
String flutterCommand(String sdk) =>
    p.join(sdk, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter');

/// `KnowledgeSync` as `appstein sync` builds it, on the Flutter SDK at
/// [flutterRoot], with [runner] for `flutter pub get` and a fixed clock.
KnowledgeSync knowledgeSync({
  required String flutterRoot,
  required FakeProcessRunner runner,
  List<Pack> packs = const [OfficialMvvmPack()],
  String baseline = '3.16',
  String appsteinVersion = '0.1.0-dev',
  bool analyzerCache = true,
}) => KnowledgeSync(
  environment: fakeEnvironment({'FLUTTER_ROOT': flutterRoot}),
  appsteinVersion: appsteinVersion,
  packs: packs,
  runner: runner,
  clock: () => DateTime.utc(2026, 10, 1, 9),
  baseline: baseline,
  analyzerCache: analyzerCache,
);

/// The text of every file under [project]'s `.appstein/`, by its path
/// there with `/`, except the lock file.
Map<String, String> knowledgeFiles(String project) {
  final folder = p.join(project, '.appstein');
  return {
    for (final entity in Directory(folder).listSync(recursive: true))
      if (entity is File && p.basename(entity.path) != '.lock')
        p.split(p.relative(entity.path, from: folder)).join('/'): entity
            .readAsStringSync(),
  };
}

/// Every file under [project]'s `.appstein/` and `.dart_tool/appstein/`,
/// with its text (Latin-1, so any bytes compare) and modified time, to check
/// that nothing was written.
Map<String, (String, DateTime)> snapshot(String project) => {
  for (final folder in [
    p.join(project, '.appstein'),
    p.join(project, '.dart_tool', 'appstein'),
  ])
    if (Directory(folder).existsSync())
      for (final entity in Directory(folder).listSync(recursive: true))
        if (entity is File)
          entity.path: (
            latin1.decode(entity.readAsBytesSync()),
            entity.lastModifiedSync(),
          ),
};
```

- [ ] **Step 2: Write the failing tests**

Create `packages/appstein_engine/test/knowledge/knowledge_sync_cache_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import 'support/sync_harness.dart';

void main() {
  late String sdk;
  late FakeProcessRunner runner;

  setUp(() {
    sdk = fakeFlutter();
    runner = FakeProcessRunner();
  });

  KnowledgeSync sync({bool analyzerCache = true}) => knowledgeSync(
    flutterRoot: sdk,
    runner: runner,
    analyzerCache: analyzerCache,
  );

  test('the first sync creates the analyzer cache, and the next one reads it '
      'without adding anything', () async {
    final app = copyFixtureApp();
    final first = await sync().run(app, dartSdkPath: testDartSdk);
    expect(first.analyzerCache!.load, AnalyzerCacheLoad.missing);
    final file = File(analyzerCachePath(app));
    expect(file.existsSync(), isTrue);
    final saved = file.readAsBytesSync();
    final second = await sync().run(app, dartSdkPath: testDartSdk);
    expect(second.analyzerCache!.load, AnalyzerCacheLoad.loaded);
    expect(second.analyzerCache!.retried, isNull);
    // Nothing new, so the file wasn't rewritten.
    expect(file.readAsBytesSync(), saved);
  });

  test('the knowledge is the same with a warm cache as with none', () async {
    final none = copyFixtureApp();
    final warm = copyFixtureApp();
    await sync(analyzerCache: false).run(none, dartSdkPath: testDartSdk);
    expect(File(analyzerCachePath(none)).existsSync(), isFalse);
    await sync().run(warm, dartSdkPath: testDartSdk);
    Directory(p.join(warm, '.appstein')).deleteSync(recursive: true);
    final report = await sync().run(warm, dartSdkPath: testDartSdk);
    expect(report.analyzerCache!.load, AnalyzerCacheLoad.loaded);
    expect(knowledgeFiles(warm), knowledgeFiles(none));
  });

  test('a damaged cache is not used, and is replaced', () async {
    final app = copyFixtureApp();
    File(analyzerCachePath(app))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('not a cache');
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.analyzerCache!.load, AnalyzerCacheLoad.damaged);
    expect(
      report.analyzerCache!.damage,
      'it is not an Appstein analyzer cache',
    );
    expect(report.map!.skipped, isNull);
    expect(
      AnalyzerCache.open(analyzerCachePath(app)).load,
      AnalyzerCacheLoad.loaded,
    );
  });

  test('a cache whose entries are garbage makes the analysis run again '
      'without it, instead of ending the process', () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    final file = File(analyzerCachePath(app));
    final entries = decodeAnalyzerCache(file.readAsBytesSync());
    file.writeAsBytesSync(
      encodeAnalyzerCache({
        for (final MapEntry(:key, :value) in entries.entries)
          key: Uint8List(value.length)..fillRange(0, value.length, 0xFF),
      }),
    );
    Directory(p.join(app, '.appstein')).deleteSync(recursive: true);
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.analyzerCache!.retried, isNotNull);
    expect(report.map!.skipped, isNull);
    for (final path in MapFiles.all) {
      final name = p.posix.basename(path);
      expectGolden(name, readMapBody(app, name));
    }
    // The garbage was replaced: the next sync reads the cache and adds
    // nothing.
    final next = await sync().run(app, dartSdkPath: testDartSdk);
    expect(next.analyzerCache!.retried, isNull);
    expect(next.analyzerCache!.load, AnalyzerCacheLoad.loaded);
  });

  test('a cache that cannot be saved is a warning; the sync still '
      'succeeds', () async {
    final app = copyFixtureApp();
    // Where the cache's folder goes, there is a file.
    File(p.join(app, '.dart_tool', 'appstein')).writeAsStringSync('');
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.analyzerCache!.saveError, isNotNull);
    expect(report.map!.skipped, isNull);
    expect(
      File(p.join(app, '.appstein', 'map', 'symbols.json')).existsSync(),
      isTrue,
    );
  });

  test('a skipped map leaves the cache alone', () async {
    final app = copyFixtureApp();
    File(p.join(app, '.dart_tool', 'package_config.json')).deleteSync();
    runner.when(flutterCommand(sdk), [
      'pub',
      'get',
    ], const RunResult(exitCode: 69, stderr: 'offline'));
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.map!.skipped, isNotNull);
    expect(File(analyzerCachePath(app)).existsSync(), isFalse);
  });
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/knowledge/knowledge_sync_cache_test.dart`
Expected: FAIL to compile. There is no `analyzerCache` parameter or report yet.

- [ ] **Step 4: `AnalyzerCacheReport`**

Append to `analyzer_cache.dart`:

```dart
/// What a sync did with the analyzer cache.
final class AnalyzerCacheReport {
  /// Creates the report.
  const AnalyzerCacheReport({
    required this.load,
    this.damage,
    this.retried,
    this.saveError,
  });

  /// How the cache opened.
  final AnalyzerCacheLoad load;

  /// Why the cache file couldn't be used, when it was damaged.
  final String? damage;

  /// The analyzer's error, in one line, that made the sync analyze again
  /// with an empty cache; null when it didn't.
  final String? retried;

  /// Why the cache couldn't be saved. The sync still succeeded; the next one
  /// is slower.
  final String? saveError;
}
```

- [ ] **Step 5: `MapSync` guards the analysis and retries without the cache**

In `map_sync.dart`, add `import 'analyzer_cache.dart';`. In `MapBuild`:
- add the constructor parameters `this.cache, this.cacheRetry,`;
- add the fields:

```dart
  /// The analyzer cache the analysis used, to be saved; null when the map
  /// was skipped or there was no cache.
  final AnalyzerCache? cache;

  /// The analyzer's error, in one line, that made the analysis run again
  /// with an empty cache; null when it didn't.
  final String? cacheRetry;
```

Split `build`:
- `build` keeps the packages part. Everything from `final ProjectAnalysis analysis;` to the end moves into a new private method `_analyze`.
- `build` gets a `cache` parameter and wraps `_analyze` in the guard.

The new `build`, from after the packages part:

```dart
  Future<MapBuild> build(
    String projectRoot, {
    required String flutterVersion,
    required String flutterRoot,
    String? dartSdkPath,
    AnalyzerCache? cache,
  }) async {
    // … the packages part, unchanged, from `var status = checkPackages(…)`
    // to `status = checkPackages(…)` after a fetch …

    final sdk = dartSdkPath ?? p.join(flutterRoot, 'bin', 'cache', 'dart-sdk');
    Future<MapBuild> analyzeWith(AnalyzerCache? cache, {String? retried}) =>
        catchAnalyzerErrors(
          () => _analyze(
            projectRoot,
            status: status,
            action: action,
            reason: reason,
            flutterVersion: flutterVersion,
            flutterRoot: flutterRoot,
            sdk: sdk,
            cache: cache,
            retried: retried,
          ),
        );
    try {
      return await analyzeWith(cache);
    } on Object catch (error) {
      // Only an error inside the analyzer, or an Appstein bug, gets here:
      // the project's own problems are returned as a skipped map. A cache
      // entry holding garbage is one such error, so analyze once more with
      // an empty cache, which then replaces the old one. Any other error
      // happens again and is thrown.
      if (cache == null) rethrow;
      return analyzeWith(
        AnalyzerCache.empty(cache.path),
        retried: '${error.runtimeType}: ${'$error'.split('\n').first}',
      );
    }
  }

  Future<MapBuild> _analyze(
    String projectRoot, {
    required PackagesStatus status,
    required PackagesAction action,
    required String reason,
    required String flutterVersion,
    required String flutterRoot,
    required String sdk,
    required AnalyzerCache? cache,
    required String? retried,
  }) async {
    final ProjectAnalysis analysis;
    try {
      analysis = await ProjectAnalysis.analyze(
        projectRoot,
        dartSdkPath: sdk,
        cache: cache,
      );
    } on ProjectAnalysisException catch (error) {
      // … unchanged …
    }
    // … the rest of the old build, unchanged, except the successful
    // MapBuild gains `cache: cache, cacheRetry: retried,` …
  }
```

The `// …` comments stand for the existing code, moved without change. Keep `build`'s doc comment and add a sentence: "With a [cache], the analyzer keeps its work there. An error inside the analyzer while using the cache makes it analyze once more with an empty cache ([MapBuild.cacheRetry])." The skipped `MapBuild`s leave `cache` null, so a skipped map saves nothing.

The existing test `'two extractors writing the same map file is a StateError'` still expects `throwsStateError`: it has no cache, so the error is rethrown.

- [ ] **Step 6: `SyncReport.analyzerCache`**

In `platform_sync.dart`, add `import '../map/analyzer_cache.dart';`. To `SyncReport`, add the constructor parameter `this.analyzerCache,` and the field:

```dart
  /// What happened to the analyzer cache; null when the sync ran without
  /// one (the platform layer alone, or `KnowledgeSync(analyzerCache:
  /// false)`).
  final AnalyzerCacheReport? analyzerCache;
```

- [ ] **Step 7: `KnowledgeSync` opens, passes and saves the cache**

In `knowledge_sync.dart`:
- add `import '../map/analyzer_cache.dart';` and `import 'knowledge_write_exception.dart';`;
- add the constructor parameter `this.analyzerCache = true,` and the field:

```dart
  /// Whether the analyzer keeps its work in `.dart_tool/appstein/` between
  /// syncs (spec §6.2). Only tests turn it off, to compare the knowledge
  /// with and without it.
  final bool analyzerCache;
```

In `run`, before `final map =`:

```dart
    final cache = analyzerCache
        ? AnalyzerCache.open(analyzerCachePath(projectRoot))
        : null;
```

pass `cache: cache,` to `MapSync(…).build(…)`, and replace the `store.locked(…)` call with:

```dart
    return store.locked(() async {
      final files = await store.writeAll(
        [...platform.files, delta, ...map.files, ?native.file, index],
        appsteinVersion: appsteinVersion,
        sdkVersion: platform.sdk.flutterVersion,
      );
      // After the knowledge, inside the lock, so two syncs never write the
      // same temporary file. The cache only makes the next sync faster, so
      // failing to save it is a warning.
      String? saveError;
      if (map.cache case final used? when used.changed) {
        try {
          await used.save();
        } on KnowledgeWriteException catch (error) {
          saveError = error.reason;
        }
      }
      return SyncReport(
        sdk: platform.sdk,
        files: files,
        newestNotes: platform.newestNotes,
        fallbacks: platform.fallbacks,
        map: map.report,
        native: native.report,
        analyzerCache: cache == null
            ? null
            : AnalyzerCacheReport(
                load: cache.load,
                damage: cache.damage,
                retried: map.cacheRetry,
                saveError: saveError,
              ),
      );
    }, timeout: lockTimeout);
```

Add to `run`'s doc comment: "The analyzer cache in `.dart_tool/appstein/` (spec §6.2) is read first and saved last; what happened to it is in [SyncReport.analyzerCache]."

- [ ] **Step 8: Run the tests**

Run: `cd packages/appstein_engine && fvm dart test`
Expected: PASS. The garbage-cache test is the Review Focus #1 proof. If it hangs or the test process dies, the guard isn't wrapping the analysis: report, with the output.

From the repo root, run `fvm dart analyze --fatal-infos`. It must be clean.

- [ ] **Step 9: Report for commit**

Commit message: `feat: sync keeps the analyzer cache in .dart_tool/appstein and survives a damaged one`.

---

### Task 5: Freshness, `state.json`, and `KnowledgeSync.detect`

**Files:**
- Modify: `packages/appstein_protocol/lib/src/knowledge/knowledge_state.dart`
- Create: `packages/appstein_engine/lib/src/knowledge/freshness.dart`
- Modify: `packages/appstein_engine/lib/src/knowledge/knowledge_store.dart` (`writeAll`, `readState`, `fileHash`)
- Modify: `packages/appstein_engine/lib/src/knowledge/platform_sync.dart` (`SyncReport.current`, `.changed`, `.rebuiltBecause`)
- Modify: `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart` (the whole file, below)
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (export)
- Test: `packages/appstein_protocol/test/knowledge_state_test.dart`
- Test: `packages/appstein_engine/test/knowledge/knowledge_store_test.dart`
- Test: `packages/appstein_engine/test/knowledge/knowledge_sync_detect_test.dart` (new)

**Interfaces:**
- Consumes (Task 3): `MapInputs`, `readMapInputs`, `MapBuild.inputs`. Also `checkPackages` and `readIndexSources`.
- Produces:
  - `KnowledgeState.sources` (`Map<String, String>`), `.written` (`Map<String, String>`) and `.changed` (`List<String>`), all required;
  - `final class Freshness { List<String> reasons; List<String> changed; KnowledgeState? state; bool get current; }`;
  - `List<String> changedSources(Map<String, String>? before, Map<String, String?> now)`;
  - `Map<String, String> stateSources(Map<String, String?> sources)`;
  - `KnowledgeStore.writeAll(…, {Map<String, String?> sources = const {}, List<String> changed = const []})`;
  - `KnowledgeStore.readState()`, which returns `({KnowledgeState? state, String? problem})`;
  - `KnowledgeStore.fileHash(String path)`, which returns `String?`;
  - `SyncReport.current` (`bool`, default `false`), `.changed` (`List<String>`, default `const []`) and `.rebuiltBecause` (`List<String>`, default `const []`);
  - `KnowledgeSync.detect(String projectRoot, {SdkDetection? sdk, String? dartSdkPath})`, which returns `Future<SyncReport>`;
  - `KnowledgeSync.freshness(String projectRoot, {SdkDetection? sdk})`, which returns `Freshness`.

- [ ] **Step 1: `KnowledgeState` gains three fields**

Replace `packages/appstein_protocol/test/knowledge_state_test.dart` with:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> json({Object? files}) => {
    'formatVersion': 1,
    'appsteinVersion': '0.1.0-dev',
    'lastSync': '2026-10-01T09:30:05Z',
    'files': files ?? {'platform/sdk.json': 'h1'},
    'sources': {'project:lib/main.dart': 's1', 'pubspec.lock': 'missing'},
    'written': {'platform/sdk.json': 'w1'},
    'changed': ['project:lib/main.dart'],
  };

  test('round-trips through JSON', () {
    const state = KnowledgeState(
      formatVersion: 1,
      appsteinVersion: '0.1.0-dev',
      lastSync: '2026-10-01T09:30:05Z',
      files: {'platform/sdk.json': 'h1'},
      sources: {'project:lib/main.dart': 's1', 'pubspec.lock': 'missing'},
      written: {'platform/sdk.json': 'w1'},
      changed: ['project:lib/main.dart'],
    );
    expect(state.toJson(), json());
    expect(KnowledgeState.fromJson(json()).toJson(), json());
  });

  test('file hashes must be strings', () {
    expect(
      () => KnowledgeState.fromJson(json(files: {'a': 1})),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'state.json: "files" must be an object of strings.',
        ),
      ),
    );
  });

  test('a state.json from before 1b.7, without sources, is an error', () {
    expect(
      () => KnowledgeState.fromJson(json()..remove('sources')),
      throwsFormatException,
    );
  });
}
```

Then, in `knowledge_state.dart`:
- add the constructor parameters `required this.sources, required this.written, required this.changed,`;
- read them in `fromJson` with `sources: fields.stringMap('sources'), written: fields.stringMap('written'), changed: fields.strings('changed'),`;
- write them in `toJson` as `'sources': sources, 'written': written, 'changed': changed,`;
- add the fields:

```dart
  /// The SHA-256 of each file the project map is built from, by input name
  /// (such as `project:lib/main.dart`), or `missing` (spec §6.2).
  final Map<String, String> sources;

  /// The SHA-256 of each generated file as it was written, by its path
  /// inside `.appstein/`. A file whose bytes differ was changed by hand.
  final Map<String, String> written;

  /// The input names whose hash changed in the sync that wrote this state,
  /// sorted. The next `sync --detect` that finds nothing changed empties it
  /// (spec §5.4), so `verify --fast` checks each change once.
  final List<String> changed;
```

Update the class doc to: "The contents of `.appstein/state.json` (spec §6.2): when the knowledge was last synced, the input hash of each generated file and the hash of its bytes, the hash of each file the map is built from, and what changed in the last sync."

In `knowledge_store_test.dart`, the test `'writes state.json as canonical JSON'` constructs a `KnowledgeState`. Add `sources: {'pubspec.yaml': 's1'}, written: {'platform/sdk.json': 'w1'}, changed: ['pubspec.yaml'],`, and expect this text:

```dart
      '{\n'
      '  "appsteinVersion": "0.1.0-dev",\n'
      '  "changed": [\n'
      '    "pubspec.yaml"\n'
      '  ],\n'
      '  "files": {\n'
      '    "platform/sdk.json": "h1"\n'
      '  },\n'
      '  "formatVersion": 1,\n'
      '  "lastSync": "2026-10-01T00:00:00Z",\n'
      '  "sources": {\n'
      '    "pubspec.yaml": "s1"\n'
      '  },\n'
      '  "written": {\n'
      '    "platform/sdk.json": "w1"\n'
      '  }\n'
      '}\n',
```

Before relying on that exact text, check how `canonicalJson` prints a list: read `packages/appstein_engine/lib/src/knowledge/canonical_json.dart`, and write the expected text the way it formats.

Run: `cd packages/appstein_protocol && fvm dart test`. Expected: PASS.

- [ ] **Step 2: `freshness.dart`**

Create `packages/appstein_engine/lib/src/knowledge/freshness.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

/// Whether `.appstein/` holds what a sync would write now (spec §5.4,
/// §6.2), and which input files changed since the last sync.
///
/// `KnowledgeSync.freshness` computes it; `sync --detect`, `verify`'s
/// `knowledge.stale` check (1d) and the MCP server (1c) share it.
final class Freshness {
  /// Creates the result.
  const Freshness({required this.reasons, required this.changed, this.state});

  /// Whether nothing the knowledge reads changed since the last sync.
  bool get current => reasons.isEmpty;

  /// Why the knowledge must be rebuilt, in words that follow "because",
  /// such as `map/symbols.json is out of date`; empty when [current].
  final List<String> reasons;

  /// The input files that changed since the last sync, by input name,
  /// sorted ([changedSources]).
  final List<String> changed;

  /// The `state.json` it compared with; null when there was none, or it
  /// couldn't be read.
  final KnowledgeState? state;
}

/// The input names whose hash in [now] differs from [before] (a
/// `state.json`'s `sources`), files added and removed included, sorted.
/// With no [before], every name in [now].
List<String> changedSources(
  Map<String, String>? before,
  Map<String, String?> now,
) {
  final current = stateSources(now);
  if (before == null) return current.keys.toList()..sort();
  return {
    for (final MapEntry(:key, :value) in current.entries)
      if (before[key] != value) key,
    for (final key in before.keys)
      if (!current.containsKey(key)) key,
  }.toList()..sort();
}

/// [sources] as `state.json` keeps them: a file that can't be read is
/// `missing`.
Map<String, String> stateSources(Map<String, String?> sources) => {
  for (final MapEntry(:key, :value) in sources.entries)
    key: value ?? 'missing',
};
```

Export it: in `appstein_engine.dart`, add `export 'src/knowledge/freshness.dart';` after `export 'src/knowledge/canonical_json.dart';`.

- [ ] **Step 3: `KnowledgeStore` records and reads the new state**

In `knowledge_store.dart`:
- add `import 'freshness.dart';` and `import 'input_hash.dart';`;
- split each of `writeGenerated` and `writeGeneratedMarkdown`:
  - the work moves into a private method that returns `(bool, String)`: whether it wrote, and the file's final text;
  - the public method keeps its signature, its doc, and its `ArgumentError` for a body with a `meta` key, and returns `.$1`;
  - the final text is `stored.text` when the write was skipped, else the new text.

```dart
  Future<bool> writeGenerated(
    String path,
    Map<String, Object?> body, {
    required String inputHash,
    required String appsteinVersion,
    required String sdkVersion,
  }) async => (await _writeJson(
    path,
    body,
    inputHash: inputHash,
    appsteinVersion: appsteinVersion,
    sdkVersion: sdkVersion,
  )).$1;

  Future<(bool, String)> _writeJson(
    String path,
    Map<String, Object?> body, {
    required String inputHash,
    required String appsteinVersion,
    required String sdkVersion,
  }) async {
    if (body.containsKey('meta')) {
      throw ArgumentError.value(body, 'body', 'must not have a "meta" key');
    }
    final target = _pathOf(path);
    String textWith(String generatedAt) => canonicalJson({
      ...body,
      'meta': KnowledgeMeta(
        generatedAt: generatedAt,
        appsteinVersion: appsteinVersion,
        formatVersion: knowledgeFormatVersion,
        sdkVersion: sdkVersion,
        inputHash: inputHash,
      ).toJson(),
    });
    final stored = _storedGeneratedAt(target);
    if (stored != null && stored.text == textWith(stored.generatedAt)) {
      return (false, stored.text);
    }
    final text = textWith(now());
    await replaceFile(target, text);
    return (true, text);
  }
```

The same for Markdown:

```dart
  Future<bool> writeGeneratedMarkdown(
    String path,
    String markdown, {
    required String inputHash,
    required String appsteinVersion,
    required String sdkVersion,
  }) async => (await _writeMarkdown(
    path,
    markdown,
    inputHash: inputHash,
    appsteinVersion: appsteinVersion,
    sdkVersion: sdkVersion,
  )).$1;

  Future<(bool, String)> _writeMarkdown(
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
      return (false, stored.text);
    }
    final text = textWith(now());
    await replaceFile(target, text);
    return (true, text);
  }
```

Then replace `writeAll`, keeping its doc comment plus the added sentence below:

```dart
  Future<Map<String, bool>> writeAll(
    List<GeneratedFile> files, {
    required String appsteinVersion,
    required String sdkVersion,
    Map<String, String?> sources = const {},
    List<String> changed = const [],
  }) async {
    final written = <String, bool>{};
    final hashes = <String, String>{};
    for (final file in files) {
      final (bool, String) result;
      if (file.body case final body?) {
        result = await _writeJson(
          file.path,
          body,
          inputHash: file.inputHash,
          appsteinVersion: appsteinVersion,
          sdkVersion: sdkVersion,
        );
      } else {
        result = await _writeMarkdown(
          file.path,
          file.markdown!,
          inputHash: file.inputHash,
          appsteinVersion: appsteinVersion,
          sdkVersion: sdkVersion,
        );
      }
      written[file.path] = result.$1;
      hashes[file.path] = sha256Hex(utf8.encode(result.$2));
    }
    await writeState(
      KnowledgeState(
        formatVersion: knowledgeFormatVersion,
        appsteinVersion: appsteinVersion,
        lastSync: now(),
        files: {for (final file in files) file.path: file.inputHash},
        sources: stateSources(sources),
        written: hashes,
        changed: changed,
      ),
    );
    return written;
  }
```

The added doc sentence: "`state.json` also records the hash of each file's bytes, the map's [sources] and the [changed] input names (spec §6.2)."

Add:

```dart
  /// `state.json`, or null with the reason (words that follow "because")
  /// when there is none, or it is damaged, or it comes from an Appstein
  /// before 1b.7, without the fields this one needs.
  ({KnowledgeState? state, String? problem}) readState() {
    final file = File(_pathOf('state.json'));
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map<String, Object?>) {
        return (state: KnowledgeState.fromJson(json), problem: null);
      }
    } on FileSystemException catch (error) {
      return (
        state: null,
        problem: file.existsSync()
            ? 'state.json could not be read (${fileErrorReason(error)})'
            : 'no sync has run here yet',
      );
    } on FormatException {
      // Below.
    }
    return (
      state: null,
      problem: 'state.json is damaged or from an older Appstein',
    );
  }

  /// The SHA-256 of the file at [path] inside `.appstein/`, or null when it
  /// is missing or can't be read.
  String? fileHash(String path) {
    try {
      return sha256Hex(File(_pathOf(path)).readAsBytesSync());
    } on FileSystemException {
      return null;
    }
  }
```

Add a store test after `'writeAll writes JSON and Markdown files …'`:

```dart
    test('writeAll records the bytes, the sources and the change list, and '
        'readState reads them back', () async {
      final store = storeAt(DateTime.utc(2026, 10, 1));
      await store.writeAll(
        const [
          GeneratedFile(
            path: 'platform/sdk.json',
            body: {'flutter': '3.47.5'},
            inputHash: 'h1',
          ),
        ],
        appsteinVersion: '0.1.0-dev',
        sdkVersion: '3.47.5',
        sources: const {'pubspec.yaml': 'p1', 'pubspec.lock': null},
        changed: const ['pubspec.yaml'],
      );
      final state = store.readState().state!;
      expect(state.sources, {'pubspec.yaml': 'p1', 'pubspec.lock': 'missing'});
      expect(state.changed, ['pubspec.yaml']);
      expect(state.written['platform/sdk.json'], store.fileHash('platform/sdk.json'));
    });

    test('readState says why there is no state', () {
      final store = storeAt(DateTime.utc(2026));
      expect(store.readState().problem, 'no sync has run here yet');
      File(p.join(project, '.appstein', 'state.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"formatVersion": 1}');
      expect(
        store.readState().problem,
        'state.json is damaged or from an older Appstein',
      );
    });
```

(`fileErrorReason` is already imported by `knowledge_store.dart`.)

- [ ] **Step 4: `SyncReport` says what `detect` did**

In `platform_sync.dart`, add to `SyncReport` the constructor parameters `this.current = false, this.changed = const [], this.rebuiltBecause = const [],` and these fields:

```dart
  /// True when `sync --detect` found nothing changed, so nothing was rebuilt
  /// or written; [files] is then empty.
  final bool current;

  /// The input files that changed since the last sync, by input name
  /// (`Freshness.changed`); empty when there was no earlier sync to compare
  /// with.
  final List<String> changed;

  /// Why `sync --detect` rebuilt (`Freshness.reasons`); empty for a plain
  /// sync.
  final List<String> rebuiltBecause;
```

- [ ] **Step 5: Write the failing `detect` tests**

Create `packages/appstein_engine/test/knowledge/knowledge_sync_detect_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
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

  KnowledgeSync sync({
    List<Pack> packs = const [OfficialMvvmPack()],
    String baseline = '3.16',
    String? flutterRoot,
    String appsteinVersion = '0.1.0-dev',
  }) => knowledgeSync(
    flutterRoot: flutterRoot ?? sdk,
    runner: runner,
    packs: packs,
    baseline: baseline,
    appsteinVersion: appsteinVersion,
  );

  Future<SyncReport> full({List<Pack> packs = const [OfficialMvvmPack()]}) =>
      sync(packs: packs).run(app, dartSdkPath: testDartSdk);

  Future<SyncReport> detect({
    List<Pack> packs = const [OfficialMvvmPack()],
    String baseline = '3.16',
    String? flutterRoot,
    String appsteinVersion = '0.1.0-dev',
  }) => sync(
    packs: packs,
    baseline: baseline,
    flutterRoot: flutterRoot,
    appsteinVersion: appsteinVersion,
  ).detect(app, dartSdkPath: testDartSdk);

  File fileOf(String relative) => File(p.joinAll([app, ...relative.split('/')]));

  void write(String relative, String text) => fileOf(relative)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  KnowledgeState state() => KnowledgeState.fromJson(
    jsonDecode(fileOf('.appstein/state.json').readAsStringSync())
        as Map<String, Object?>,
  );

  /// A full sync right after writes nothing, so what detect wrote is what a
  /// full sync writes.
  Future<void> expectLikeFullSync() async {
    final again = await sync().run(app, dartSdkPath: testDartSdk);
    expect(again.files.values, everyElement(isFalse));
  }

  group('nothing changed', () {
    test('detect writes no byte, and leaves every modified time alone', () async {
      await full();
      await detect(); // Empties the change list the full sync recorded.
      final before = snapshot(app);
      final report = await detect();
      expect(report.current, isTrue);
      expect(report.files, isEmpty);
      expect(snapshot(app), before);
    });

    test('the first detect after a sync empties the change list, and changes '
        'nothing else', () async {
      await full();
      expect(state().changed, isNotEmpty);
      final knowledge = knowledgeFiles(app)..remove('state.json');
      final report = await detect();
      expect(report.current, isTrue);
      expect(state().changed, isEmpty);
      expect(knowledgeFiles(app)..remove('state.json'), knowledge);
    });

    test('freshness() says current and writes nothing', () async {
      await full();
      final before = snapshot(app);
      final freshness = sync().freshness(app);
      expect(freshness.current, isTrue, reason: '${freshness.reasons}');
      expect(snapshot(app), before);
    });
  });

  group('a change rebuilds, as a full sync would', () {
    setUp(() async {
      await full();
      await detect();
    });

    test('a Dart file edited', () async {
      fileOf('lib/main.dart').writeAsStringSync(
        "\n/// Says hi.\nString hi() => 'hi';\n",
        mode: FileMode.append,
      );
      final report = await detect();
      expect(report.current, isFalse);
      expect(report.changed, ['project:lib/main.dart']);
      expect(report.files[MapFiles.symbols], isTrue);
      expect(jsonEncode(readMapBody(app, 'symbols.json')), contains('"hi"'));
      expect(state().changed, ['project:lib/main.dart']);
      expect(
        state().sources['project:lib/main.dart'],
        sha256Hex(fileOf('lib/main.dart').readAsBytesSync()),
      );
      await expectLikeFullSync();
    });

    test('a Dart file added, then deleted', () async {
      write('lib/extra.dart', '/// Extra.\nclass Extra {}\n');
      expect((await detect()).changed, ['project:lib/extra.dart']);
      fileOf('lib/extra.dart').deleteSync();
      final report = await detect();
      expect(report.changed, ['project:lib/extra.dart']);
      expect(jsonEncode(readMapBody(app, 'symbols.json')), isNot(contains('Extra')));
      await expectLikeFullSync();
    });

    test('pubspec.lock edited', () async {
      fileOf('pubspec.lock').writeAsStringSync('\n# edited\n', mode: FileMode.append);
      expect((await detect()).changed, ['pubspec.lock']);
    });

    test('pubspec.yaml edited: the packages are fetched first', () async {
      runner.when(flutterCommand(sdk), ['pub', 'get'], const RunResult(exitCode: 0));
      fileOf('pubspec.yaml').writeAsStringSync('\n# edited\n', mode: FileMode.append);
      final report = await detect();
      expect(report.changed, contains('pubspec.yaml'));
      expect(runner.calls, ['${flutterCommand(sdk)} pub get']);
    });

    test('analysis_options.yaml added', () async {
      write('analysis_options.yaml', 'analyzer:\n  exclude: [testing/**]\n');
      expect((await detect()).changed, ['analysis_options.yaml']);
    });

    test('a local package edited', () async {
      File(
        p.join(p.dirname(app), 'stubs', 'go_router', 'lib', 'go_router.dart'),
      ).writeAsStringSync('\n// edited\n', mode: FileMode.append);
      expect(
        (await detect()).changed,
        ['local-package:go_router/lib/go_router.dart'],
      );
    });

    test('a decision file or current.md: INDEX.md is rebuilt', () async {
      write('.appstein/decisions/0001-state.md', '---\nid: 0001\ntitle: State\nstatus: accepted\n---\nWhy: test.\n');
      var report = await detect();
      expect(report.changed, isEmpty);
      expect(report.rebuiltBecause, contains('INDEX.md is out of date'));
      write('.appstein/memory/current.md', 'Goal: test.\n');
      report = await detect();
      expect(report.rebuiltBecause, contains('INDEX.md is out of date'));
    });

    test('the delta baseline changed', () async {
      final report = await detect(baseline: '3.22');
      expect(report.rebuiltBecause, contains('platform/delta.md is out of date'));
    });

    test('another Flutter version', () async {
      final other = fakeFlutter(version: '3.44.9');
      runner.when(flutterCommand(other), ['pub', 'get'], const RunResult(exitCode: 0));
      final report = await detect(flutterRoot: other);
      expect(report.rebuiltBecause, contains('platform/sdk.json is out of date'));
      expect(
        report.rebuiltBecause,
        contains(startsWith('the packages need `flutter pub get`')),
      );
    });

    test('another Appstein', () async {
      final report = await detect(appsteinVersion: '0.2.0');
      expect(
        report.rebuiltBecause,
        contains('the last sync was made by Appstein 0.1.0-dev'),
      );
    });
  });

  group('knowledge and state.json that disagree', () {
    setUp(() async {
      await full();
      await detect();
    });

    test('a knowledge file changed by hand is put back', () async {
      final original = fileOf('.appstein/map/symbols.json').readAsStringSync();
      fileOf('.appstein/map/symbols.json').writeAsStringSync('{}');
      final report = await detect();
      expect(report.rebuiltBecause, contains('map/symbols.json was changed by hand'));
      expect(fileOf('.appstein/map/symbols.json').readAsStringSync(), original);
    });

    test('a deleted knowledge file is written again', () async {
      fileOf('.appstein/INDEX.md').deleteSync();
      final report = await detect();
      expect(report.rebuiltBecause, contains('INDEX.md is missing'));
      expect(fileOf('.appstein/INDEX.md').existsSync(), isTrue);
    });

    test('a damaged state.json', () async {
      fileOf('.appstein/state.json').writeAsStringSync('{not json');
      final report = await detect();
      expect(report.rebuiltBecause, ['state.json is damaged or from an older Appstein']);
      expect(state().changed, isNotEmpty);
    });

    test('a state.json from before 1b.7', () async {
      final json = jsonDecode(fileOf('.appstein/state.json').readAsStringSync())
          as Map<String, Object?>
        ..remove('sources');
      fileOf('.appstein/state.json').writeAsStringSync(jsonEncode(json));
      final report = await detect();
      expect(report.rebuiltBecause, ['state.json is damaged or from an older Appstein']);
    });
  });

  test('the first detect, with no state.json, rebuilds; the report lists no '
      'changes, but state.json lists every input', () async {
    final report = await detect();
    expect(report.rebuiltBecause, ['no sync has run here yet']);
    expect(report.changed, isEmpty);
    expect(state().changed, contains('project:lib/main.dart'));
  });

  test('when the last sync skipped the map, detect tries again', () async {
    fileOf('.dart_tool/package_config.json').deleteSync();
    runner.when(flutterCommand(sdk), [
      'pub',
      'get',
    ], const RunResult(exitCode: 69, stderr: 'offline'));
    await full();
    final report = await detect();
    expect(report.current, isFalse);
    expect(
      report.rebuiltBecause,
      contains('the last sync could not build the project map'),
    );
    expect(runner.calls, hasLength(2));
  });

  test('an Android file changed: native.json is rebuilt', () async {
    const packs = [OfficialMvvmPack(), AndroidPack()];
    await full(packs: packs);
    await detect(packs: packs);
    write('android/app/src/main/AndroidManifest.xml', '<manifest/>\n');
    final report = await detect(packs: packs);
    expect(report.changed, isEmpty);
    expect(report.rebuiltBecause, contains('map/native.json is out of date'));
  });

  test('other packs: rebuilt', () async {
    await full();
    final report = await detect(packs: const [OfficialMvvmPack(), AndroidPack()]);
    expect(report.current, isFalse);
  });
}
```

Run: `cd packages/appstein_engine && fvm dart test test/knowledge/knowledge_sync_detect_test.dart`
Expected: FAIL to compile. There is no `detect` or `freshness` yet.

- [ ] **Step 6: Rewrite `KnowledgeSync`**

Replace `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart` with the file below. Compared with the current file:
- `run` becomes "prepare, then rebuild";
- the cheap steps move into `_prepare`;
- the input hashes of `delta.md` and `INDEX.md` move into `_deltaHash` and `_indexHash`, so that `_freshness` computes them exactly as a sync does;
- `detect` and `freshness` are new.

`_delta` and `_index` keep their rendering code, so their output is unchanged.

```dart
import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../delta/delta_document.dart';
import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../index/index_document.dart';
import '../index/index_sources.dart';
import '../map/analyzer_cache.dart';
import '../map/map_inputs.dart';
import '../map/map_sync.dart';
import '../map/project_packages.dart';
import '../native/native_extractor.dart';
import '../native/native_sync.dart';
import '../notes/curated_notes.dart';
import '../packs/pack.dart';
import '../sdk/sdk_detector.dart';
import 'canonical_json.dart';
import 'freshness.dart';
import 'generated_file.dart';
import 'input_hash.dart';
import 'knowledge_store.dart';
import 'knowledge_write_exception.dart';
import 'platform_sync.dart';

/// Everything `appstein sync` writes (spec §5.4, §6.2, §6.3): the platform
/// layer, the version delta, the project map, the native config and
/// `INDEX.md`. All are built first, then written under one lock, with a
/// `state.json` that lists them.
///
/// [run] rebuilds everything; [detect] rebuilds only when something the
/// knowledge reads changed ([freshness]).
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
    this.deltaCollector,
    this.analyzerCache = true,
  }) : notes = notes ?? CuratedNotes.bundled(),
       runner = runner ?? const SystemProcessRunner();

  // … the fields environment, appsteinVersion, packs, notes, runner,
  // lockTimeout, baseline, deltaCollector, analyzerCache and _clock,
  // unchanged from Task 4 …

  /// Syncs the project at [projectRoot], rebuilding everything. [sdk] is the
  /// SDK detection to use (by default it is detected for the project);
  /// [dartSdkPath] overrides where `dart:` libraries are read from, for
  /// tests.
  ///
  /// … keep the rest of the old `run` doc comment unchanged, including the
  /// analyzer cache sentence Task 4 added …
  ///
  /// [SyncReport.changed] lists the input files that changed since the last
  /// sync, and `state.json` records them for `verify --fast` (spec §5.4).
  Future<SyncReport> run(
    String projectRoot, {
    SdkDetection? sdk,
    String? dartSdkPath,
  }) async => _rebuild(
    projectRoot,
    _prepare(projectRoot, sdk: sdk),
    dartSdkPath: dartSdkPath,
  );

  /// `appstein sync --detect` (spec §5.3, §5.4): rebuilds, as [run] does,
  /// only when [freshness] finds something changed, saying why in
  /// [SyncReport.rebuiltBecause].
  ///
  /// When nothing changed, it builds and writes nothing, and the report has
  /// [SyncReport.current]. The first such call after a rebuild empties
  /// `state.json`'s change list, so `verify --fast` checks each change once.
  /// It does that under the lock, and only if `state.json` is still the one
  /// it checked.
  ///
  /// Throws as [run] does.
  Future<SyncReport> detect(
    String projectRoot, {
    SdkDetection? sdk,
    String? dartSdkPath,
  }) async {
    final prepared = _prepare(projectRoot, sdk: sdk);
    final freshness = _freshness(projectRoot, prepared);
    if (!freshness.current) {
      return _rebuild(
        projectRoot,
        prepared,
        dartSdkPath: dartSdkPath,
        reasons: freshness.reasons,
      );
    }
    final checked = freshness.state!;
    if (checked.changed.isNotEmpty) {
      final store = KnowledgeStore(projectRoot, clock: _clock);
      await store.locked(() async {
        final now = store.readState().state;
        if (now != null &&
            canonicalJson(now.toJson()) == canonicalJson(checked.toJson())) {
          await store.writeState(
            KnowledgeState(
              formatVersion: now.formatVersion,
              appsteinVersion: now.appsteinVersion,
              lastSync: now.lastSync,
              files: now.files,
              sources: now.sources,
              written: now.written,
              changed: const [],
            ),
          );
        }
      }, timeout: lockTimeout);
    }
    final platform = prepared.platform;
    return SyncReport(
      sdk: platform.sdk,
      files: const {},
      newestNotes: platform.newestNotes,
      fallbacks: platform.fallbacks,
      current: true,
    );
  }

  /// Whether the `.appstein/` of the project at [projectRoot] holds what a
  /// sync would write now, without analyzing or writing anything.
  ///
  /// It runs a sync's cheap steps (the platform layer, the packages check,
  /// the map's inputs, native config and INDEX.md's sources). It computes
  /// each file's input hash the way a sync does, and compares them with
  /// `state.json`. It also finds the knowledge out of date when:
  /// - the packages need `flutter pub get`;
  /// - the last sync skipped the map;
  /// - another Appstein wrote `state.json`;
  /// - a file's bytes differ from what was written.
  ///
  /// Throws `SyncException` when no usable SDK is found.
  Freshness freshness(String projectRoot, {SdkDetection? sdk}) =>
      _freshness(projectRoot, _prepare(projectRoot, sdk: sdk));

  _Prepared _prepare(String projectRoot, {SdkDetection? sdk}) {
    final platform = PlatformSync(
      environment: environment,
      appsteinVersion: appsteinVersion,
      notes: notes,
      clock: _clock,
    ).build(projectRoot, sdk: sdk);
    final packages = checkPackages(
      projectRoot,
      flutterVersion: platform.sdk.flutterVersion,
    );
    return _Prepared(
      platform: platform,
      packages: packages,
      mapInputs: readMapInputs(
        projectRoot,
        workspaceRoot: packages.workspaceRoot,
        flutterVersion: platform.sdk.flutterVersion,
        flutterRoot: platform.location.root,
        packs: packs,
        appsteinVersion: appsteinVersion,
        environment: environment,
      ),
      native: _native(projectRoot, platform),
      sources: readIndexSources(projectRoot),
    );
  }

  Future<SyncReport> _rebuild(
    String projectRoot,
    _Prepared prepared, {
    String? dartSdkPath,
    List<String> reasons = const [],
  }) async {
    final platform = prepared.platform;
    final store = KnowledgeStore(projectRoot, clock: _clock);
    final previous = store.readState().state;
    final cache = analyzerCache
        ? AnalyzerCache.open(analyzerCachePath(projectRoot))
        : null;
    final map =
        await MapSync(
          environment: environment,
          appsteinVersion: appsteinVersion,
          packs: packs,
          runner: runner,
          deltaCollector: deltaCollector,
        ).build(
          projectRoot,
          flutterVersion: platform.sdk.flutterVersion,
          flutterRoot: platform.location.root,
          dartSdkPath: dartSdkPath,
          cache: cache,
        );
    // After MapSync: a `flutter pub get` it ran rewrites the generated
    // Package.swift that native config reads.
    final native = _native(projectRoot, platform);
    final delta = _delta(platform, map);
    // Last: it summarizes the other files.
    final index = _index(platform, map, native, delta, prepared.sources);
    // The map read its inputs after any fetch, which may change
    // pubspec.lock.
    final sources = map.inputs?.sources ?? prepared.mapInputs.sources;
    final changed = changedSources(previous?.sources, sources);
    return store.locked(() async {
      final files = await store.writeAll(
        [...platform.files, delta, ...map.files, ?native.file, index],
        appsteinVersion: appsteinVersion,
        sdkVersion: platform.sdk.flutterVersion,
        sources: sources,
        changed: changed,
      );
      // After the knowledge, inside the lock, so two syncs never write the
      // same temporary file. The cache only makes the next sync faster, so
      // failing to save it is a warning.
      String? saveError;
      if (map.cache case final used? when used.changed) {
        try {
          await used.save();
        } on KnowledgeWriteException catch (error) {
          saveError = error.reason;
        }
      }
      return SyncReport(
        sdk: platform.sdk,
        files: files,
        newestNotes: platform.newestNotes,
        fallbacks: platform.fallbacks,
        map: map.report,
        native: native.report,
        // With no earlier state there is nothing to compare with.
        changed: previous == null ? const [] : changed,
        rebuiltBecause: reasons,
        analyzerCache: cache == null
            ? null
            : AnalyzerCacheReport(
                load: cache.load,
                damage: cache.damage,
                retried: map.cacheRetry,
                saveError: saveError,
              ),
      );
    }, timeout: lockTimeout);
  }

  Freshness _freshness(String projectRoot, _Prepared prepared) {
    final store = KnowledgeStore(projectRoot);
    final read = store.readState();
    final sources = prepared.mapInputs.sources;
    final state = read.state;
    if (state == null) {
      return Freshness(
        reasons: [read.problem!],
        changed: changedSources(null, sources),
      );
    }
    final platform = prepared.platform;
    final reasons = [
      if (state.appsteinVersion != appsteinVersion)
        'the last sync was made by Appstein ${state.appsteinVersion}',
      if (state.formatVersion != knowledgeFormatVersion)
        'state.json is in format ${state.formatVersion}',
      if (!prepared.packages.fresh)
        'the packages need `flutter pub get`: ${prepared.packages.reason}',
      if (!state.files.containsKey(MapFiles.symbols))
        'the last sync could not build the project map',
    ];
    // Each file's input hash, computed as a sync computes it. The map's
    // files all share the map's hash; which files those are depends only on
    // the packs, which are part of that hash.
    final mapHash = prepared.mapInputs.inputHash;
    final expected = <String, String>{
      for (final file in platform.files) file.path: file.inputHash,
      if (prepared.native.file case final file?) file.path: file.inputHash,
      for (final path in state.files.keys)
        if (path.startsWith('map/') && path != MapFiles.native) path: mapHash,
      deltaPath: _deltaHash(platform.sdk, mapHash),
    };
    expected[indexPath] = _indexHash(expected, prepared.sources);
    for (final path in {...expected.keys, ...state.files.keys}.toList()
      ..sort()) {
      if (expected[path] != state.files[path]) {
        reasons.add('$path is out of date');
      }
    }
    for (final MapEntry(key: path, value: hash) in state.written.entries) {
      final actual = store.fileHash(path);
      if (actual == null) {
        reasons.add('$path is missing');
      } else if (actual != hash) {
        reasons.add('$path was changed by hand');
      }
    }
    return Freshness(
      reasons: reasons,
      changed: changedSources(state.sources, sources),
      state: state,
    );
  }

  NativeBuild _native(String projectRoot, PlatformBuild platform) =>
      NativeSync(appsteinVersion: appsteinVersion, packs: packs).build(
        NativeContext(
          projectRoot: projectRoot,
          flutterVersion: platform.sdk.flutterVersion,
          channel: platform.sdk.channel,
          environment: environment,
          android: platform.toolchain.android,
        ),
      );

  /// `delta.md`: the notes, and the delta facts when they were collected.
  /// … the old doc comment, unchanged …
  GeneratedFile _delta(PlatformBuild platform, MapBuild map) {
    // … the old body, unchanged, except that the GeneratedFile's
    // `inputHash:` argument becomes:
    //   inputHash: _deltaHash(
    //     sdk,
    //     facts == null ? 'skipped: $skipped' : map.inputHash!,
    //   ),
  }

  /// The input hash of `delta.md`: [mapPart] (the map's input hash, or why
  /// there are no facts), the notes, the baseline, the language version and
  /// the Flutter version.
  String _deltaHash(SdkInfo sdk, String mapPart) => inputHash(
    {
      'map': utf8.encode(mapPart),
      ...notes.inputs,
      'baseline': utf8.encode(baseline),
      'languageVersion': utf8.encode(sdk.languageVersion ?? ''),
      'flutter': utf8.encode(sdk.flutterVersion),
    },
    appsteinVersion: appsteinVersion,
    formatVersion: knowledgeFormatVersion,
  );

  /// `INDEX.md` (spec §6.3). … the old doc comment, unchanged …
  GeneratedFile _index(
    PlatformBuild platform,
    MapBuild map,
    NativeBuild native,
    GeneratedFile delta,
    IndexSources sources,
  ) {
    final sdk = platform.sdk;
    final hash = _indexHash({
      for (final file in [
        ...platform.files,
        delta,
        ...map.files,
        ?native.file,
      ])
        file.path: file.inputHash,
    }, sources);
    // … the old body from `final stack = packs…` to the end, unchanged …
  }

  /// The input hash of `INDEX.md`: [fileHashes] (each other file's input
  /// hash, by path), the project files [sources] read, and the packs.
  String _indexHash(Map<String, String> fileHashes, IndexSources sources) =>
      inputHash(
        {
          for (final MapEntry(key: path, value: hash) in fileHashes.entries)
            'file:$path': utf8.encode(hash),
          ...sources.inputs,
          'packs': utf8.encode(
            [for (final pack in packs) '${pack.id}@${pack.version}'].join(','),
          ),
        },
        appsteinVersion: appsteinVersion,
        formatVersion: knowledgeFormatVersion,
      );
}

/// What a sync builds before the analysis: everything [KnowledgeSync]
/// needs to decide whether the knowledge is current.
final class _Prepared {
  const _Prepared({
    required this.platform,
    required this.packages,
    required this.mapInputs,
    required this.native,
    required this.sources,
  });

  final PlatformBuild platform;
  final PackagesStatus packages;
  final MapInputs mapInputs;
  final NativeBuild native;
  final IndexSources sources;
}
```

The `// …` comments stand for existing code and doc comments, moved without change. Write them out in full. `_index` no longer reads the project itself: `readIndexSources` runs once, in `_prepare`.

A rule for the implementer: `_index`'s hash must equal the old one for the same inputs. It does, because the keys (`file:<path>`, the sources' names, `packs`) and their bytes are the same. The existing INDEX.md tests in `knowledge_sync_test.dart` check its rewrite behaviour.

- [ ] **Step 7: Run all the tests**

Run: `cd packages/appstein_engine && fvm dart test`, then `cd packages/appstein_protocol && fvm dart test`.
Expected: PASS, with no golden changed.

From the repo root, run `fvm dart analyze --fatal-infos`. It must be clean.

- [ ] **Step 8: Report for commit**

Commit message: `feat: sync --detect's freshness check; state.json records sources, written bytes and the change list`.

---

### Task 6: `appstein sync --detect`

**Files:**
- Modify: `packages/appstein_cli/lib/src/sync_command.dart`
- Test: `packages/appstein_cli/test/sync_command_test.dart`

**Interfaces:**
- Consumes (Tasks 4–5): `KnowledgeSync.detect`, `SyncReport.current`, `.changed`, `.rebuiltBecause` and `.analyzerCache`, plus `AnalyzerCacheReport`.
- Produces: the `--detect` flag, and the report's new lines (exact text below).

- [ ] **Step 1: Write the failing tests**

Add to `sync_command_test.dart`, after the test `'a second run changes nothing'`:

```dart
  test('--detect with no earlier sync rebuilds and says why', () async {
    expect(await run(['sync', '--detect']), ExitCodes.ok, reason: '$err');
    final text = out.toString();
    expect(text, startsWith('Synced .appstein/ for Flutter 3.47.5'));
    expect(text, contains('Rebuilt because no sync has run here yet.\n'));
  });

  test('--changed is no longer an option (spec §5.3)', () async {
    expect(
      await run(['sync', '--changed', 'lib/main.dart']),
      ExitCodes.appsteinFailed,
    );
    expect(err.toString(), contains('changed'));
  });
```

And after the test `'a partial coverage line names the minor version'`:

```dart
  const sdkInfo = SdkInfo(
    flutterVersion: '3.47.5',
    dartVersion: '3.13.4',
    channel: 'stable',
    notesCoverage: NotesCoverage.complete,
  );

  test('a current report is one line', () {
    expect(
      formatSyncReport(
        const SyncReport(
          sdk: sdkInfo,
          files: {},
          newestNotes: '3.47',
          fallbacks: [],
          current: true,
        ),
      ),
      'Knowledge is current for Flutter 3.47.5 (Dart 3.13.4, stable '
      'channel): nothing it reads changed since the last sync.\n',
    );
  });

  test('the report names what changed, at most five, without project:', () {
    final text = formatSyncReport(
      const SyncReport(
        sdk: sdkInfo,
        files: {'map/symbols.json': true},
        newestNotes: '3.47',
        fallbacks: [],
        changed: [
          'local-package:core/lib/a.dart',
          'project:lib/a.dart',
          'project:lib/b.dart',
          'project:lib/c.dart',
          'project:lib/d.dart',
          'project:lib/e.dart',
          'pubspec.lock',
        ],
        rebuiltBecause: ['map/symbols.json is out of date'],
      ),
    );
    expect(
      text,
      contains(
        'Changed since the last sync: local-package:core/lib/a.dart, '
        'lib/a.dart, lib/b.dart, lib/c.dart, lib/d.dart and 2 more.\n',
      ),
    );
    expect(text, isNot(contains('Rebuilt because')));
  });

  test('with nothing changed in the sources, the report gives the first '
      'reason', () {
    final text = formatSyncReport(
      const SyncReport(
        sdk: sdkInfo,
        files: {'INDEX.md': true},
        newestNotes: '3.47',
        fallbacks: [],
        rebuiltBecause: ['INDEX.md is out of date', 'x'],
      ),
    );
    expect(
      text,
      contains('Rebuilt because INDEX.md is out of date (and 1 more).\n'),
    );
  });

  test('the report says what went wrong with the analyzer cache', () {
    final text = formatSyncReport(
      const SyncReport(
        sdk: sdkInfo,
        files: {'map/symbols.json': true},
        newestNotes: '3.47',
        fallbacks: [],
        analyzerCache: AnalyzerCacheReport(
          load: AnalyzerCacheLoad.damaged,
          damage: 'it is cut short',
          retried: 'RangeError: bad',
          saveError: 'Access is denied.',
        ),
      ),
    );
    expect(
      text,
      contains(
        'The analyzer cache could not be used (it is cut short), so this sync '
        'analyzed without it.\n'
        'The analyzer failed while reading its cache (RangeError: bad), so the '
        'analysis ran again without it and the cache was replaced.\n'
        'warning: the analyzer cache could not be saved (Access is denied.); '
        'the next sync will be slower.\n',
      ),
    );
  });

  test('a healthy cache adds no line', () {
    final text = formatSyncReport(
      const SyncReport(
        sdk: sdkInfo,
        files: {'map/symbols.json': true},
        newestNotes: '3.47',
        fallbacks: [],
        analyzerCache: AnalyzerCacheReport(load: AnalyzerCacheLoad.loaded),
      ),
    );
    expect(text, isNot(contains('analyzer cache')));
  });
```

Run: `cd packages/appstein_cli && fvm dart test test/sync_command_test.dart`
Expected: FAIL. There is no `--detect` or new report lines yet.

- [ ] **Step 2: Add the flag**

In `SyncCommand`, add a constructor body:

```dart
  SyncCommand({
    required this.out,
    required this.err,
    required this.environment,
  }) {
    argParser.addFlag(
      'detect',
      negatable: false,
      help:
          'Rebuild only when something the knowledge reads changed, found by '
          'content hash (the after-edit hook).',
    );
  }
```

In `run`, replace the `KnowledgeSync(…).run(projectRoot)` call with:

```dart
      final sync = KnowledgeSync(
        environment: environment,
        appsteinVersion: appsteinVersion,
        packs: packsFor(config),
        baseline: config.delta.baseline,
      );
      final report = argResults!['detect'] as bool
          ? await sync.detect(projectRoot)
          : await sync.run(projectRoot);
```

Update the class doc's first sentence to: "`appstein sync [--detect]`: regenerates the knowledge Appstein keeps in `.appstein/` (spec §5.3, §5.4). With `--detect`, only when something it reads changed."

- [ ] **Step 3: The report's new lines**

In `formatSyncReport`, add `import 'package:appstein_engine/appstein_engine.dart';` if it isn't imported yet; it is, for `SyncReport`. Then:

1. At the top, after `final sdk = report.sdk;`:

```dart
  if (report.current) {
    return 'Knowledge is current for Flutter ${sdk.flutterVersion} '
        '(Dart ${sdk.dartVersion}, ${sdk.channel} channel): nothing it reads '
        'changed since the last sync.\n';
  }
```

2. Right after the `Synced .appstein/ …` line, before the file rows:

```dart
  if (report.changed.isNotEmpty) {
    buffer.writeln('Changed since the last sync: ${_names(report.changed)}.');
  } else if (report.rebuiltBecause case [final first, ...final rest]) {
    buffer.writeln(
      'Rebuilt because $first'
      '${rest.isEmpty ? '' : ' (and ${rest.length} more)'}.',
    );
  }
```

3. Before the notes-coverage lines:

```dart
  if (report.analyzerCache case final cache?) {
    if (cache.damage case final why?) {
      buffer.writeln(
        'The analyzer cache could not be used ($why), so this sync analyzed '
        'without it.',
      );
    }
    if (cache.retried case final error?) {
      buffer.writeln(
        'The analyzer failed while reading its cache ($error), so the '
        'analysis ran again without it and the cache was replaced.',
      );
    }
    if (cache.saveError case final why?) {
      buffer.writeln(
        'warning: the analyzer cache could not be saved ($why); the next '
        'sync will be slower.',
      );
    }
  }
```

4. A private helper at the end of the file:

```dart
/// [names] (input names) for one line: the first five, without the
/// `project:` prefix, then how many more.
String _names(List<String> names) {
  const prefix = 'project:';
  final shown = [
    for (final name in names.take(5))
      name.startsWith(prefix) ? name.substring(prefix.length) : name,
  ];
  final rest = names.length - shown.length;
  return '${shown.join(', ')}${rest > 0 ? ' and $rest more' : ''}';
}
```

Update `formatSyncReport`'s doc comment to add: "a `--detect` that found nothing changed is one line; otherwise it says what changed or why it rebuilt, and any analyzer-cache problem".

- [ ] **Step 4: Run the tests**

Run: `cd packages/appstein_cli && fvm dart test`
Expected: PASS.

From the repo root, run `fvm dart analyze --fatal-infos`. It must be clean.

- [ ] **Step 5: Report for commit**

Commit message: `feat: appstein sync --detect`.

---

### Task 7: Measure the incremental sync

**Files:**
- Modify: `tool/measure_sync.dart` (rewritten)

**Interfaces:**
- Consumes: the `appstein` CLI (`packages/appstein_cli/bin/appstein.dart`) and its output lines:
  - `Knowledge is current`;
  - `Changed since the last sync: …`;
  - `Native config: android read; ios read.`;
  - `Project map skipped`.
- Produces: the CI `measure` job's table. It exits 1 when a held row misses its target or a check fails.

- [ ] **Step 1: Rewrite the tool**

Replace `tool/measure_sync.dart` with this file. `_generateApp` stays as it is today; copy it unchanged from the current file.

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

/// Measures `appstein sync` against spec §15, on generated official_mvvm apps
/// with a new app's `android/` and `ios/` files:
/// - a full sync of a 200-file app, with fresh packages and no analyzer
///   cache: under 30 s;
/// - `sync --detect` on that app when nothing changed, and after one edit of
///   a view model: each under 2 s.
///
/// The same rows for a 1,000-file app are printed for information only and
/// never fail (owner decision, slice 1b.7).
///
/// It compiles the `appstein` command first and runs every sync as a new
/// process, the way an agent's hook runs it, with FLUTTER_ROOT set to the
/// Flutter SDK whose Dart runs this tool.
///
/// Usage, from the repo root:
///   fvm dart run tool/measure_sync.dart
///
/// The first sync of each app fetches its packages (go_router needs the
/// network). Prints a Markdown table, and exits 1 when a held row misses its
/// target or a check fails.
Future<void> main() async {
  final flutterRoot = _flutterRoot();
  if (flutterRoot == null) {
    stderr.writeln(
      'Run this with the Dart of a Flutter SDK (fvm dart run '
      'tool/measure_sync.dart): ${Platform.resolvedExecutable} is not inside '
      'one.',
    );
    exitCode = 1;
    return;
  }
  final work = Directory.systemTemp.createTempSync('appstein measure sync ');
  try {
    final exe = await _compile(work.path);
    if (exe == null) {
      exitCode = 1;
      return;
    }
    final columns = <int, Map<String, Duration>>{};
    var missed = <String>[];
    for (final (files, held) in const [(200, true), (1000, false)]) {
      final app = p.join(work.path, 'app $files');
      _generateApp(app, features: (files - 2) ~/ 2);
      Future<_Run> sync([List<String> flags = const []]) =>
          _run(exe, app, flutterRoot, flags);
      final times = columns[files] = {};

      final first = await sync();
      if (first.problem() case final problem?) {
        stderr.writeln('The first sync of the $files-file app: $problem');
        exitCode = 1;
        return;
      }
      times['first'] = first.elapsed;

      // Cold: no knowledge and no analyzer cache, the 30 s worst case.
      Directory(p.join(app, '.appstein')).deleteSync(recursive: true);
      final cache = Directory(p.join(app, '.dart_tool', 'appstein'));
      if (cache.existsSync()) cache.deleteSync(recursive: true);
      final full = await sync();
      if (full.problem() case final problem?) {
        stderr.writeln('The full sync of the $files-file app: $problem');
        exitCode = 1;
        return;
      }
      times['full'] = full.elapsed;

      // The first detect empties the change list the full sync recorded;
      // the second is what a hook sees after a command that changed nothing.
      await sync(const ['--detect']);
      final unchanged = await sync(const ['--detect']);
      if (!unchanged.stdout.startsWith('Knowledge is current')) {
        stderr.writeln(
          'A detect with nothing changed rebuilt:\n${unchanged.stdout}',
        );
        exitCode = 1;
        return;
      }
      times['unchanged'] = unchanged.elapsed;

      const viewModel = 'lib/ui/feature_5/view_models/feature_5_view_model.dart';
      _edit(
        p.join(app, viewModel),
        'int taps = 0;',
        'int taps = 0;\n\n  /// Whether it was opened.\n  bool opened = false;',
      );
      final edited = await sync(const ['--detect']);
      if (edited.problem() != null ||
          !edited.stdout.contains('Changed since the last sync: $viewModel.')) {
        stderr.writeln(
          'A detect after the view model edit did not rebuild it:\n'
          '${edited.stdout}${edited.stderr}',
        );
        exitCode = 1;
        return;
      }
      times['viewModel'] = edited.elapsed;

      _edit(
        p.join(app, 'lib', 'routing', 'router.dart'),
        "'/feature-0'",
        "'/feature-zero'",
      );
      final router = await sync(const ['--detect']);
      if (router.problem() case final problem?) {
        stderr.writeln('A detect after the router edit: $problem');
        exitCode = 1;
        return;
      }
      times['router'] = router.elapsed;

      if (held) {
        missed = [
          if (full.elapsed >= const Duration(seconds: 30))
            'a full sync took ${full.elapsed.inMilliseconds} ms (under 30 s)',
          if (unchanged.elapsed >= const Duration(seconds: 2))
            'a detect with nothing changed took '
                '${unchanged.elapsed.inMilliseconds} ms (under 2 s)',
          if (edited.elapsed >= const Duration(seconds: 2))
            'a detect after one edit took ${edited.elapsed.inMilliseconds} ms '
                '(under 2 s)',
        ];
      }
    }
    String cell(int files, String row) =>
        '${columns[files]![row]!.inMilliseconds} ms';
    String line(String label, String row) =>
        '| $label | ${cell(200, row)} | ${cell(1000, row)} |';
    stdout.writeln('''
| Measurement (${Platform.operatingSystem}, a new process each) | 200 files | 1,000 files (info) |
|---|---|---|
${line('First sync, with `flutter pub get`', 'first')}
${line('**Full sync, no analyzer cache** (target under 30 s)', 'full')}
${line('**`sync --detect`, nothing changed** (target under 2 s)', 'unchanged')}
${line('**`sync --detect` after editing a view model** (target under 2 s)', 'viewModel')}
${line('`sync --detect` after editing the router', 'router')}
''');
    if (missed.isNotEmpty) {
      stderr.writeln('Spec §15 targets missed on the 200-file app:');
      for (final miss in missed) {
        stderr.writeln('  $miss');
      }
      exitCode = 1;
    }
  } finally {
    try {
      work.deleteSync(recursive: true);
    } on FileSystemException {
      stderr.writeln(
        'warning: could not delete ${work.path}; remove it by hand',
      );
    }
  }
}

/// One `appstein sync` process: its exit code, output and time.
final class _Run {
  _Run(this.exitCode, this.stdout, this.stderr, this.elapsed);

  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration elapsed;

  /// Why this run doesn't count as a real sync, or null. A failed run, a
  /// skipped map or unread native config would be cheaper than a real sync.
  String? problem() {
    if (exitCode != 0) return 'exit code $exitCode:\n$stdout$stderr';
    if (stdout.contains('Project map skipped')) {
      return 'the project map was skipped:\n$stdout';
    }
    if (!stdout.contains('Native config: android read; ios read.')) {
      return 'native config was not read:\n$stdout';
    }
    return null;
  }
}

Future<_Run> _run(
  String exe,
  String app,
  String flutterRoot,
  List<String> flags,
) async {
  final watch = Stopwatch()..start();
  final result = await Process.run(exe, [
    '--project',
    app,
    'sync',
    ...flags,
  ], environment: {'FLUTTER_ROOT': flutterRoot});
  watch.stop();
  return _Run(
    result.exitCode,
    '${result.stdout}',
    '${result.stderr}',
    watch.elapsed,
  );
}

/// The Flutter SDK whose Dart runs this tool
/// (`<flutter>/bin/cache/dart-sdk/bin/dart`), or null when this Dart isn't
/// inside one.
String? _flutterRoot() {
  var folder = p.dirname(Platform.resolvedExecutable);
  for (var i = 0; i < 4; i++) {
    folder = p.dirname(folder);
  }
  return File(
        p.join(folder, 'bin', 'cache', 'flutter.version.json'),
      ).existsSync()
      ? folder
      : null;
}

/// Compiles the `appstein` command into [work]; null, with the compiler's
/// output printed, when it fails.
Future<String?> _compile(String work) async {
  final exe = p.join(work, Platform.isWindows ? 'appstein.exe' : 'appstein');
  final result = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    p.join('packages', 'appstein_cli', 'bin', 'appstein.dart'),
    '-o',
    exe,
  ]);
  if (result.exitCode != 0) {
    stderr.writeln(
      'Could not compile appstein:\n${result.stdout}${result.stderr}',
    );
    return null;
  }
  return exe;
}

void _edit(String path, String from, String to) {
  final file = File(path);
  final text = file.readAsStringSync();
  if (!text.contains(from)) throw StateError('"$from" is not in $path');
  file.writeAsStringSync(text.replaceFirst(from, to));
}

// … _generateApp, unchanged from the current file …
```

`missed` is assigned only for the held size. Write it as `var missed = <String>[];` as above, and keep the lint clean (`prefer_final_locals` doesn't apply to a reassigned variable).

- [ ] **Step 2: Run it**

Run from the repo root: `fvm dart run tool/measure_sync.dart`
Expected:
- the table prints and the exit code is 0;
- on the development machine, about: full 7–9 s at 200 files, unchanged 20–200 ms, view model about 1.0–1.3 s;
- the 1,000-file view-model row is about 2 s, information only.

Paste the table into the report. If a held row misses its target, report the numbers and don't change the targets.

From the repo root, run `fvm dart analyze --fatal-infos`. It must be clean.

- [ ] **Step 3: Report for commit**

Commit message: `ci: measure_sync times sync --detect in fresh processes (spec §15)`. Add the trailer `Docs-Checked: ci - the measure job's command is unchanged; Task 8 updates the page's numbers`.

---

### Task 8: Docs

**Files:**
- Create: `docs/guide/incremental-sync.md`
- Modify: `docs/guide/knowledge-store.md`, `docs/guide/project-map.md`, `docs/guide/cli.md`, `docs/guide/ci.md`, `docs/guide/README.md`

**Interfaces:** none. This task changes no code.

- [ ] **Step 1: Write the guide page**

Create `docs/guide/incremental-sync.md`, in the style of `index-md.md` and `version-delta.md`. It explains the code as built, in plain words:

```markdown
<!-- covers:
packages/appstein_engine/lib/src/map/analyzer_cache.dart
packages/appstein_engine/lib/src/map/map_inputs.dart
packages/appstein_engine/lib/src/knowledge/freshness.dart
-->

# Incremental sync

An agent's hook runs `appstein sync --detect` after every edit (spec §5.4). It must cost almost nothing when the edit changed nothing the knowledge reads, and stay under 2 s when it did (§15). This page explains how.
```

Then these sections, each with the facts given:

1. **The idea (approach A):**
   - `--detect` never patches the knowledge. It either stops, or runs the same full sync as `appstein sync`, so its output can't differ from a full sync's.
   - The speed comes from the analyzer cache.
   - Give the measured numbers from Task 7's table (200 and 1,000 files), and the probe's "before": about 9 s for every sync.
2. **How `--detect` decides (`KnowledgeSync.freshness`):**
   - the cheap steps it runs (platform 8 ms, `checkPackages`, map inputs 20–110 ms, native 5 ms, `readIndexSources`);
   - every output's input hash, computed by the same functions a sync uses (`_deltaHash`, `_indexHash`);
   - the other reasons to rebuild, with their exact words: `the packages need \`flutter pub get\``, `the last sync could not build the project map`, `… was changed by hand`, `… is missing`, `the last sync was made by Appstein …`, `state.json is damaged or from an older Appstein`, `no sync has run here yet`.
3. **The map's inputs (`map_inputs.dart`):**
   - the input names (`project:`, `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `local-package:`);
   - what a local package is (D5) and why it is hashed: a path dependency can change without the lock changing;
   - an unlistable folder;
   - that the names, not paths, make a moved project keep its hashes.
4. **`state.json`:**
   - `files` (input hashes), `sources`, `written` (bytes, to catch hand edits) and `changed`;
   - who reads `changed` (verify `--fast`, 1d; package skills, 1b.8);
   - how the first `--detect` that finds nothing empties it, under the lock, and only if `state.json` is unchanged;
   - that `state.json` from before 1b.7 reads as "damaged or from an older Appstein" and causes one rebuild (D3).
5. **The analyzer cache (`analyzer_cache.dart`):**
   - **Where it lives:** `.dart_tool/appstein/analyzer_cache.bin`.
   - **The owner's decision:** the analyzer's cache API is in its `src/` folder. All of it is in this one file, and `analyzer` is pinned to exactly `14.4.0`.
   - **To upgrade the analyzer:**
     1. change the pin and `analyzerVersion`;
     2. run the canary test;
     3. check `AnalysisContextCollectionImpl`'s `byteStore` parameter.
   - **The file format:** the header, the sorted entries, and that only the entries used are kept.
   - **The probe's numbers:** 57 MB at 200 files, load 12–22 ms, save 60–77 ms.
   - **Why one file:** `FileByteStore`'s 13.5 s first read on Windows, and `flush()` (dart-lang/sdk#64190).
   - **The failure table:** missing, damaged, garbage entries (the guard and the retry), can't save (a warning), skipped map (left alone).
   - **The probe finding behind `catchAnalyzerErrors`:** garbage entries made the analyzer throw in its own scheduler, and the process died with exit 255.
6. **Measuring (`tool/measure_sync.dart`):** fresh processes, the compiled exe, `FLUTTER_ROOT` from the running Dart, the cold full-sync row, and the 1,000-file rows being information only.
7. **Tests:** where each rule is pinned:
   - `analyzer_cache_test.dart` (the format, and the canary);
   - `map_inputs_test.dart`;
   - `knowledge_sync_cache_test.dart` (warm equals none, garbage, can't save);
   - `knowledge_sync_detect_test.dart` (the freshness matrix);
   - the CLI's `sync_command_test.dart`.

- [ ] **Step 2: Update the other pages**

- **`knowledge-store.md`:**
  - **Intro:** replace "Incremental sync (1b.7) comes in a later slice." with "Slice 1b.7 added **`sync --detect`** and the analyzer cache, which have [their own page](incremental-sync.md)."
  - **`state.json` row:** add "It also holds `sources` (the hash of each file the map reads), `written` (the hash of each file's bytes) and `changed` (what the last rebuild found changed); see [incremental-sync](incremental-sync.md)."
  - **"How one sync runs" Mermaid chart and steps:** the cheap steps now run first, in `_prepare`. The analyzer cache is opened before the map and saved after `state.json`, inside the lock. Add one step: "`--detect` compares first and may stop here; see [incremental-sync](incremental-sync.md)."
- **`project-map.md`:**
  - **readFeatures:** one sentence: "`readFeatures` finds each file's feature once; asking per feature was cubic, 25 s at 1,000 files (fixed in 1b.7)."
  - **The map's input hash:** where the page describes it, say it now comes from `readMapInputs` and also covers local packages, with a link to [incremental-sync](incremental-sync.md).
  - **`ProjectAnalysis.analyze`:** one sentence: it takes an optional `AnalyzerCache`.
- **`cli.md`:** in the `sync` section, add `--detect` and the new report lines: the one-line current report, "Changed since the last sync: …", "Rebuilt because …", and the three analyzer-cache lines. State that `--changed` doesn't exist (spec §5.3).
- **`ci.md`:** in the `measure` job, the sync measurement now compiles the exe and times `--detect`, and the 1,000-file rows are information only. Paste the Task 7 numbers where the page gives example numbers.
- **`README.md` (guide index):** add after the `index-md` row: `| [incremental-sync](incremental-sync.md) | How \`appstein sync --detect\` decides whether to rebuild, and the analyzer cache that makes a rebuild take about 1 s |`.

- [ ] **Step 3: Generate and check**

Run from the repo root:
- `fvm dart run tool/gen_docs.dart`
- `fvm dart run tool/check_guide.dart --since main`

Both must pass. `check_guide` fails if a changed source file's covering page wasn't updated. Name every page this task touched in the report.

- [ ] **Step 4: Report for commit**

Commit message: `docs(guide): incremental sync page; knowledge-store, project-map, cli, ci and the guide index`.

---

### Task 9: Verify, record and finish

**Files:**
- Modify: this plan's "Notes from execution"
- Modify: `docs/superpowers/progress.yaml`
- Modify: `docs/superpowers/specs/2026-09-29-appstein-design.html` (via `gen_docs`)

- [ ] **Step 1: The full check**

From the repo root:
- `fvm dart analyze --fatal-infos`
- `fvm dart format --output=none --set-exit-if-changed .`
- `fvm dart run dependency_validator`
- `for pkg in packages/*/; do (cd "$pkg" && fvm dart test) || exit 1; done`
- `fvm dart test test` (repo tools)
- `cd packages/appstein_engine && fvm dart test --run-skipped --tags integration test/integration/sync_real_environment_test.dart test/integration/map_real_sdk_test.dart test/integration/native_real_sdk_test.dart`
- `fvm dart run tool/check_guide.dart --since main`
- `fvm dart run tool/measure_sync.dart`
- the BOM scan.

Record each result's numbers.

- [ ] **Step 2: Notes from execution, and progress**

Add a `## Notes from execution` section at the end of this plan. The guide check reads that heading as "the slice is done", so add it only now. Write down:
- how it ran;
- the rulings;
- what the reviews changed;
- the numbers: test counts, and the `measure_sync` table for both sizes;
- what is carried.

Once the PR is open, in `docs/superpowers/progress.yaml`:
- set 1b.7 to `status: done`, with `plan: 2026-10-03-slice-1b7-incremental-sync.md` (set when the plan is committed), `pr: <n>` and `finished: <date>`;
- set 1b.8 to `status: next`.

Do it in the same commit as the notes. Run `fvm dart run tool/gen_docs.dart`, then **read back the rendered `.html`**. It must show 1b.7 Done with its PR link, and 1b.8 Next.

- [ ] **Step 3: Graph and merge**

Run `/graphify . --update` until `tool/check_graph.py` reports nothing:
- use at most 3 extraction subagents;
- see the graph runbook in memory: old-label checklists for big docs, `set -o pipefail`, no `| tail`, and `old_labels.py`'s first argument is the output folder;
- afterwards, check that `graph.html` has `PRECOMPUTED = true`.

Then merge by the owner's PR flow and delete the branch.

## Carried to later slices

- **1b.8 (package skills):** run `dart run skills@ get` when `state.json`'s `changed` holds `pubspec.yaml` or `pubspec.lock`. Verified facts are in memory (`project_slice_1b6_research`).
- **1c (MCP):**
  - the server re-syncs with `KnowledgeSync.detect` when the knowledge is stale (spec §8, target under 2 s);
  - `overview`'s "live freshness status" is `KnowledgeSync.freshness`;
  - a long-running server could keep the analysis warm in memory, which the cache file doesn't need, but it may.
- **1d (verify):**
  - `verify --fast` reads `state.json`'s `changed`;
  - `knowledge.stale` uses `KnowledgeSync.freshness`;
  - **a gap:** the map reads only `lib/`, `test/` and `testing/`, so edits in `integration_test/` or `bin/` never show in `changed`. 1d decides whether `sources` widens or verify finds them itself.
- **Known limits, recorded here:**
  - **The 1,000-file app:** an edit takes about 2 s (analysis 1.46 s). The parked optimisation is to read facts from the analyzer's summaries instead of resolving every body (owner decision 3).
  - **Large monorepos:** `--detect` hashes every input. An mtime-and-size shortcut, as git does it, can come later without changing the command line.
  - **An abandoned analysis after a cache error isn't disposed** (D2). The process exits normally; a long-running MCP server (1c) must recheck this.
- **Still carried from 1b.6:**
  - the machine path in the map's skip reason (`project_analysis.dart`, the incomplete-SDK message);
  - `ios_native.dart`'s `_variablesNote` checks only `$(`;
  - Markdown edge cases in names;
  - the iOS id line drops the `.xcconfig` note;
  - `.MD`, symlinked and UTF-16 decision files.

## Notes from execution

Run on 2026-10-03 on the branch `slice-1b7`. It was subagent-driven, with one implementer and one reviewer per task, never more than 3 agents at once, and Opus for the riskiest reviews.
- Subagents never committed. The controller staged each task, reviewed the staged diff against the task's base, and committed after the review, behind the BOM byte gate.
- Spec edits: `e1fab90` (owner-approved). Plan: `b059596`.

**How it ran**

| Commit | What | Review |
|---|---|---|
| `0787ad0` | Task 1: linear `readFeatures`, the `featureOf` index, 3 `checkPackages` tests | clean |
| `3014111` | Task 2: the analyzer cache file, analyzer pinned to 14.4.0 | clean |
| `e7a96a6` | Task 3: map inputs with local packages | clean |
| `7f5483c` | Task 4: sync uses the cache; the guard and retry | clean |
| `e470228` | Task 5: freshness, `state.json`, `detect` | 1 fix round (Opus review): the map inputs were read **after** the analysis. A file edited during a sync was then recorded with its new hash over an old map, and later detects answered "current". They are now read before the analysis, and a test edits a file mid-sync through the `deltaCollector` seam |
| `c6a3e51` | Task 6: CLI `--detect` | clean |
| `fd5756f` | Task 7: `measure_sync` in fresh processes | clean |
| `da2c5f2` | Task 8: docs | 1 fix round: "four new keys" should have been three, and the reasons table missed `state.json is in format N` |
| `9159235` | Final-review fix wave | scoped re-review: F1–F9 all addressed |

**The final whole-branch review** (Opus) found the design sound. It also found a Critical and an Important hole in the same function. Both would have let `--detect` answer "current" over a stale map:
- **Critical:** `_filesUnder` didn't follow links, while the analyzer does. Code behind a symlink or a Windows junction was mapped but never hashed. The reviewer reproduced it with `mklink /J`.
- **Important:** one unlistable subfolder made the whole top folder a single null input. The analyzer skips only that subfolder.

The fix wave rewrote the walk the way analyzer 14.4.0 does it: one folder at a time, links followed, loops guarded along the current path, and only an unlistable folder recorded as `<name>/` = null.

It also made the remaining cache and hook paths safer:
- any error saving the cache is now a warning;
- a busy lock never fails a no-change detect;
- the report says "the cache was replaced" only when the cache was saved;
- new tests prove `detect` reaches "current" with the platform packs, and after a decision rebuild.

**Rulings** (all in the ledger; the final summary lists them for the owner):
- **The Task 1 trailer.** I first ruled that a `Docs-Checked: project-map` trailer (missing `.md`) was harmless, which was wrong: `check_guide --since main` rejects it. I reworded that one commit message with `git filter-branch --msg-filter` on the unpushed branch. The trees were checked to be identical.
- **The fix wave's loop guard deviated from my fix spec.** It tracks only the folders on the current path, as the analyzer does, instead of every folder already walked. The implementer's probe showed the analyzer maps two links to one folder twice. The spec's rule would have hidden a removed link.
- **The task trailers** use the `<page>.md` form that the docs hook needs, not the plan's bare page names.
- **`architecture.md`** also had to change, for the three new engine exports. The plan had left it out.

**Numbers**
- **The full check at `9159235`:**
  - analyze and format are clean (279 files), and `dependency_validator` is clean;
  - tests: CLI 42, engine 725 with 6 skipped, lints 19, protocol 57, repo tools 212, integration 4;
  - `check_guide --since main` passed and the BOM scan is clean.
- **`measure_sync`** (Windows, a new process each, after the fix wave):

| Measurement | 200 files | 1,000 files (info) |
|---|---|---|
| First sync, with `flutter pub get` | 8,464 ms | 10,195 ms |
| **Full sync, no analyzer cache** (target under 30 s) | 7,121 ms | 8,034 ms |
| **`sync --detect`, nothing changed** (target under 2 s) | 120 ms | 324 ms |
| **`sync --detect` after editing a view model** (target under 2 s) | 1,267 ms | 2,571 ms |
| `sync --detect` after editing the router | 1,357 ms | 2,589 ms |

  - **Before the fix wave:** 77 ms and 1,102 ms at 200 files. The walk that follows links costs about 40–160 ms.
  - **Before this slice:** every sync took about 9 s at 200 files, and a full sync of 1,000 files about 34 s (the cubic `readFeatures`).

**Also carried** (on top of "Carried to later slices" above)
- **A `FLUTTER_ROOT` given as a link path** makes the SDK's packages look local. That costs time on every detect, never correctness. Resolve links before comparing.
- **Inputs the analyzer reads that the map doesn't hash:**
  - files outside `lib/`, `test/` and `testing/` reached by a relative import;
  - a local file `include:`d from `analysis_options.yaml`;
  - nested `analysis_options.yaml` files;
  - a folder that can't be listed but whose files can still be opened by path.

  Each is rare. Today they can give a stale "current".
- **After a delta internal error,** every detect rebuilds with the misleading reason `platform/delta.md is out of date`. Name the delta error instead.
- **A read-only `.appstein/`** still fails a no-change detect when it empties the change list. The busy-lock case is handled.
- **Two comments** (`map_inputs.dart`, `incremental-sync.md`) say the analyzer skips an unresolvable folder "too". In fact the analyzer stops reading the rest of that folder's parent, so the inputs hash a superset. The direction is safe; only the wording is inexact.
- **Two tests** (the platform packs, the decision rebuild) don't assert that the middle detect is current. Only the last one is checked.
- **The chmod test** for an unreadable folder runs only on POSIX, so CI's Linux job runs it first.
