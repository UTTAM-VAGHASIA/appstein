# Slice 1b.3: Project map (Dart code) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `appstein sync` also writes the project map of the user's Dart code: `.appstein/map/symbols.json`, `layers.json`, `deps.json`, `features.json` and `routes.json`. It builds them from the resolved Dart AST through the `official_mvvm` stack pack, and runs `flutter pub get` first when Flutter would.

**Architecture:**
- **Protocol:**
  - the map file formats live in `appstein_protocol/lib/src/map/`;
  - `LayerRules` gains `interfaces`;
  - `LayerMatcher` moves from the lints package into the protocol, so the lint and `layers.json` tag files with the same code.
- **Engine core:**
  - `lib/src/map/` checks the packages the way Flutter does (running `flutter pub get` when needed);
  - it resolves `lib/`, `test/` and `testing/` with `package:analyzer`;
  - it builds the generic files: symbols, layers and deps.
- **Pack:** `lib/src/packs/pack.dart` is the small `Pack` interface (spec §10). The `official_mvvm` pack (`lib/src/packs/official_mvvm/`, published as `package:appstein_engine/official_mvvm.dart`) builds routes and features.
- **Wiring:**
  - `KnowledgeSync` builds the platform layer and the map, then writes everything under one lock;
  - the CLI registers the pack (the engine core never imports a pack, §5.1).

**Tech Stack:** Dart 3.12+ (Flutter 3.47.5 via FVM), `package:analyzer` 14.4 (resolved AST and element model), `package:glob`, `package:yaml`, `package:test`, and `analyzer_testing` for the lint.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md`. This plan implements:
- §6.5 as edited on 2026-10-01 (commit `cf9d208`): resolution, layer tags, features, symbols, routes, layers and dependencies; native config is slice 1b.4;
- §6.2 (the `map/` files and their metadata);
- §9.6 (the `layer_imports` `interfaces` rule and the `official_mvvm` layer rules);
- §10 (the `Pack` interface, members `id`, `kind`, `version`, `extractors`, `layerRules`);
- §15 (determinism, Windows paths, the 30 s full-sync target for a 200-file app).

## Global Constraints

- **Commands:** run every Dart command through FVM: `fvm dart …`. The repo pins Flutter 3.47.5 (Dart 3.13.4); packages declare `sdk: ^3.12.0`.
- **Boundaries (spec §5.1):**
  - `appstein_protocol` depends on nothing internal; `appstein_engine` only on `appstein_protocol`; `appstein_cli` on the engine and protocol; `appstein_lints` only on `appstein_protocol`.
  - **The engine core never imports a pack:** nothing outside `lib/src/packs/official_mvvm/**` and `lib/official_mvvm.dart` imports them. The CLI wires the pack.
  - The `layer_imports` lint enforces all of this on our own repo.
- **Docs and analysis:** every public API has a `///` doc comment (`public_member_api_docs`). These must pass from the repo root:
  - `fvm dart analyze --fatal-infos`;
  - `fvm dart format --output=none --set-exit-if-changed .`;
  - `fvm dart run dependency_validator`.
- **Byte order marks:** no raw U+FEFF byte in any `.dart` file. Nothing in this slice needs the BOM escape.
- **Windows is first-class:**
  - every file-system test uses `tempDir()` (`packages/appstein_engine/test/support/temp.dart`), whose path holds a space and a non-ASCII character;
  - the fixture app is copied into a folder named `mvvm app`.
- **Analyzer paths:** `package:analyzer` accepts only absolute, normalized paths, so pass `p.normalize(p.absolute(path))`. Paths written to the map are relative to the project root and use `/` on every OS.
- **Determinism (§15):**
  - every map file is written by `KnowledgeStore.writeGenerated` (canonical JSON, the `meta` block, rewritten only when its bytes would change);
  - every list in a map file is sorted as its task specifies, so the same code gives byte-identical files on every OS.
- **Never guess (§6.5):** a route path, a screen, or a builder that can't be resolved statically is recorded as `unresolved` with a reason. A feature's screens come only from routes, never from names.
- **Fixtures:**
  - files of the fixture app and the stand-in packages end in `.fixture`, so the repo's analyzer, formatter and graph ignore them (as in slice 1b.2); the test helper copies them without the suffix;
  - golden files end in `.golden`.
- **No network in unit tests.** Only the real-SDK integration test (Task 12) and the measure tool may run a real `flutter pub get`.
- **Tests stay in temp folders:** tests never write into the repo, `graphify-out/` or `.git/hooks`. The single exception is `APPSTEIN_UPDATE_GOLDENS=1`, which a person runs on purpose to rewrite the goldens.
- **Commits:** subagents never commit. The controller commits each task after its review, with the trailer lines the session gives, behind the BOM byte scan.

## Review Focus

These are the five inputs most likely to bite a user, though no single feature test covers them. Each one has a test in the task named.

1. **A project whose packages aren't fetched, or are stale.** Examples: a fresh clone, an edited `pubspec.yaml`, or packages fetched by another Flutter version.
   - `sync` runs `flutter pub get` in the project, exactly when Flutter would.
   - If that fails (for example, offline), it still writes the platform layer, skips the map, says why and what to run, and exits 0.
   - *Tests: Task 3 (the rule), Task 10 (stale → fetched; fetch fails → skipped).*
2. **Code with errors:** a missing import, an unknown superclass. The analyzer still resolves what it can and the map is written, never a crash. *Test: Task 4.*
3. **Paths with spaces and non-ASCII characters, and CRLF files.** Map paths are always project-relative with `/`, and line numbers are the same for `\r\n` files. *Tests: Task 4 (the folder `mvvm app` under `appstein tëst`), Task 8 (a CRLF `router.dart` gives the same lines).*
4. **A project that doesn't follow official_mvvm**, such as a plain Dart package with only `lib/`, or an app without go_router. The map is still written: no features, no routes, and correct symbols, layers and deps. *Tests: Task 10, plus the CI smoke project in Task 12.*
5. **Routes that can't be resolved:**
   - a non-constant path, a builder with two returns, or a builder returning a widget from Flutter;
   - a spread in a routes list, typed routes (`$appRoutes`), or a child of an unresolved route.

   Each is recorded as `unresolved` with a reason, never guessed. *Test: Task 8.*

## Decisions made while planning (for the owner's review)

- **P1, pub workspaces:** Flutter's `pub.dart` joins `workspace_ref.json`'s `workspaceRoot` (a folder) and then treats it as the package-config *file*. That check always fails, so Flutter always re-fetches in a workspace member.
  - Appstein reads `<workspace root>/.dart_tool/package_config.json`, `pubspec.lock` and `.dart_tool/version`, which is what the reference means.
  - Documented under "where Appstein differs from Flutter".
  - Cost if wrong: a workspace member skips a fetch that Flutter would run while everything is fresh.
- **P2:** `sync` exits **0** when the map is skipped. The platform layer was written, and the report says why the map wasn't and what to run. Hooks run `sync` at session start, where exit 3 would look like a crash. Cost if wrong: a script that checks only the exit code misses a skipped map.
- **P3:** an **abstract** class that extends `ChangeNotifier` (a `BaseViewModel`) is not listed as a view model. Cost if wrong: base classes missing from `viewModels`.
- **P4 (owner-delegated, 2026-10-01):** a feature's **models** are the public classes in the `domain` files its files import, **except use cases** (files under `lib/domain/use_cases/`, the folder Flutter's guide names). A use case isn't data the feature works with. Spec §6.5 was amended to say so.
- **P5:** the user's `analysis_options.yaml` `exclude:` applies to the map, because the analyzer skips excluded files. Cost if wrong: excluded files are missing from the map.
- **P6:** there is no on-disk analyzer cache in this slice. The spike resolved a 200-file Flutter app in 12 s cold (AOT) and 3.9 s warm, against the 30 s target. Incremental sync (1b.6) will need one.
- **P7:** `LayerMatcher` moves into `appstein_protocol`, which gains `glob` and `path` as dependencies, so the lint and `layers.json` tag files identically.
- **P8:** `isInterfaceLibrary` (every class abstract) is a five-line function, written twice: in the lints package and in the engine. The lints can't import the engine. Each copy has its own tests, and the doc comments point at each other.
- **P9:** each map file's input hash covers:
  - every `.dart` file under `lib/`, `test/` and `testing/`;
  - `pubspec.yaml` and the lock file;
  - the Flutter version;
  - the packs' ids and versions.

  It is coarse but honest: incremental sync (1b.6) refines it.
- **P10:** when the map is skipped, `state.json` lists only the files this sync wrote or confirmed. Old map files stay on disk with their old `meta.inputHash`, so `knowledge.stale` (1d) will catch them.
- **P11:** when a route has both `builder` and `pageBuilder`, `pageBuilder` wins, as in go_router.
- **P12:** a conditional import counts by its main URI, as the `layer_imports` lint already does.

---

## File map

| File | Responsibility |
|---|---|
| `packages/appstein_protocol/lib/src/layer_rules.dart` | + `interfaces`, `mayImport(…, interfaceOnly:)`, `describeAllowed` |
| `packages/appstein_protocol/lib/src/layer_matcher.dart` | `LayerMatcher` (moved from the lints package) |
| `packages/appstein_protocol/lib/src/json_fields.dart` | + `boolean`, `optionalInteger`, `strings`, `objectMap` |
| `packages/appstein_protocol/lib/src/map/map_files.dart` | `MapFiles`: the five paths inside `.appstein/` |
| `packages/appstein_protocol/lib/src/map/code_ref.dart` | `CodeRef` (a named declaration and its file) |
| `packages/appstein_protocol/lib/src/map/symbols_map.dart` | `SymbolKind`, `MapSymbol`, `SymbolsMap` |
| `packages/appstein_protocol/lib/src/map/layers_map.dart` | `MapFileEntry`, `LayerViolation`, `LayersMap` |
| `packages/appstein_protocol/lib/src/map/deps_map.dart` | `PackageDependency`, `DepsMap` |
| `packages/appstein_protocol/lib/src/map/features_map.dart` | `Feature`, `FeaturesMap` |
| `packages/appstein_protocol/lib/src/map/routes_map.dart` | `MapRoute`, `MapRouter`, `RoutesMap` |
| `packages/appstein_lints/lib/src/layer_imports/interface_library.dart` | `isInterfaceLibrary` (lint copy) |
| `packages/appstein_lints/lib/src/layer_imports/layer_imports_rule.dart` | honours `interfaces` |
| `packages/appstein_engine/lib/src/host/process_runner.dart` | + `workingDirectory` |
| `packages/appstein_engine/lib/src/map/project_packages.dart` | `PackagesStatus`, `checkPackages`, `fetchPackages` |
| `packages/appstein_engine/lib/src/map/project_analysis.dart` | `ProjectAnalysis`, `AnalyzedLibrary`, `ProjectImport`, `ProjectAnalysisException` |
| `packages/appstein_engine/lib/src/map/interface_library.dart` | `isInterfaceLibrary` (engine copy) |
| `packages/appstein_engine/lib/src/map/ast_values.dart` | `constantString`, `NamedArguments` |
| `packages/appstein_engine/lib/src/map/map_extractor.dart` | `MapExtractor` |
| `packages/appstein_engine/lib/src/map/symbols.dart` | `buildSymbols`, `docSummary` |
| `packages/appstein_engine/lib/src/map/layers.dart` | `buildLayers` |
| `packages/appstein_engine/lib/src/map/dependencies.dart` | `buildDeps` |
| `packages/appstein_engine/lib/src/map/map_sync.dart` | `MapSync`, `MapBuild`, `MapReport`, `PackagesAction` |
| `packages/appstein_engine/lib/src/packs/pack.dart` | `PackKind`, `Pack` |
| `packages/appstein_engine/lib/src/packs/official_mvvm/layer_rules.dart` | `officialMvvmLayerRules` |
| `packages/appstein_engine/lib/src/packs/official_mvvm/routes.dart` | `readRoutes`, `joinRoutePath` |
| `packages/appstein_engine/lib/src/packs/official_mvvm/features.dart` | `readFeatures` |
| `packages/appstein_engine/lib/src/packs/official_mvvm/official_mvvm_pack.dart` | `OfficialMvvmPack`, `OfficialMvvmExtractor` |
| `packages/appstein_engine/lib/official_mvvm.dart` | the pack's public library |
| `packages/appstein_engine/lib/src/knowledge/generated_file.dart` | `GeneratedFile` |
| `packages/appstein_engine/lib/src/knowledge/knowledge_store.dart` | + `writeAll` |
| `packages/appstein_engine/lib/src/knowledge/platform_sync.dart` | + `build` / `PlatformBuild`; `SyncReport.map` |
| `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart` | `KnowledgeSync` |
| `packages/appstein_engine/test/fixtures/apps/mvvm_app/**.fixture` | The fixture app |
| `packages/appstein_engine/test/fixtures/apps/stubs/**.fixture` | Stand-in `flutter`, `flutter_test`, `go_router`, and the lock file |
| `packages/appstein_engine/test/fixtures/apps/goldens/*.golden` | Expected map files |
| `packages/appstein_engine/test/support/fixture_app.dart` | `copyFixtureApp`, `writeStubPackages`, `testDartSdk`, `lineOf`, `expectGolden` |
| `packages/appstein_engine/test/support/machine_sdk.dart` | `machineSdk` (shared by the integration tests) |
| `packages/appstein_engine/test/integration/map_real_sdk_test.dart` | The fixture with real Flutter and go_router |
| `packages/appstein_cli/lib/src/sync_command.dart` | uses `KnowledgeSync` and the pack; reports the map |
| `tool/measure_sync.dart` | Full sync of a generated 200-file app (§15) |
| `docs/guide/project-map.md` | New guide page |

---

### Task 1: Layer rules: `interfaces`, a shared matcher, and the lint

**Files:**
- Modify: `packages/appstein_protocol/lib/src/layer_rules.dart`
- Create: `packages/appstein_protocol/lib/src/layer_matcher.dart`
- Delete: `packages/appstein_lints/lib/src/layer_imports/layer_matcher.dart`
- Modify: `packages/appstein_protocol/lib/appstein_protocol.dart`, `packages/appstein_protocol/pubspec.yaml`, `packages/appstein_lints/pubspec.yaml`
- Create: `packages/appstein_lints/lib/src/layer_imports/interface_library.dart`
- Modify: `packages/appstein_lints/lib/src/layer_imports/layer_config.dart`, `packages/appstein_lints/lib/src/layer_imports/layer_imports_rule.dart`
- Move: `packages/appstein_lints/test/layer_matcher_test.dart` → `packages/appstein_protocol/test/layer_matcher_test.dart`
- Test: `packages/appstein_protocol/test/layer_rules_test.dart`, `packages/appstein_lints/test/layer_imports_rule_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `LayerRules({required layers, required allow, interfaces = const {}})`, with `Map<String, List<String>> interfaces`.
  - `bool mayImport(String fromTag, String toTag, {bool interfaceOnly = false})`.
  - `String describeAllowed(String fromTag)`.
  - `LayerMatcher(LayerRules rules)` with `String? tagFor(String relativePosixPath)`, exported from `package:appstein_protocol/appstein_protocol.dart`.

- [ ] **Step 1: Write the failing protocol tests**

Append to `packages/appstein_protocol/test/layer_rules_test.dart`, inside `main()`, after the existing tests:

```dart
  final withInterfaces = {
    ...valid,
    'interfaces': {
      'ui': ['data.repository'],
    },
  };

  test('a layer may import interface files of the tags under its '
      'interfaces', () {
    final rules = LayerRules.fromJson(withInterfaces);
    expect(rules.mayImport('ui', 'data.repository'), isFalse);
    expect(
      rules.mayImport('ui', 'data.repository', interfaceOnly: true),
      isTrue,
    );
    expect(
      rules.mayImport('domain', 'data.repository', interfaceOnly: true),
      isFalse,
    );
  });

  test('describes what a layer may import', () {
    final rules = LayerRules.fromJson(withInterfaces);
    expect(
      rules.describeAllowed('ui'),
      'ui, domain, and the interfaces of data.repository',
    );
    expect(rules.describeAllowed('domain'), 'domain');
    expect(rules.describeAllowed('data.repository'), 'any layer');
  });

  test('rejects an interfaces entry that names an undeclared tag', () {
    expect(
      () => LayerRules.fromJson({
        ...valid,
        'interfaces': {
          'ui': ['nowhere'],
        },
      }),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'interfaces: "ui" lists "nowhere", which is not declared under '
              'layers.',
        ),
      ),
    );
  });

  test('toJson leaves out an empty interfaces section', () {
    expect(LayerRules.fromJson(valid).toJson().containsKey('interfaces'), isFalse);
    expect(LayerRules.fromJson(withInterfaces).toJson()['interfaces'], {
      'ui': ['data.repository'],
    });
  });

  test('the unknown-key message lists interfaces', () {
    expect(
      () => LayerRules.fromJson(<String, Object?>{'layer': <String, Object?>{}}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Allowed: layers, allow, interfaces.'),
        ),
      ),
    );
  });
```

Move `packages/appstein_lints/test/layer_matcher_test.dart` to `packages/appstein_protocol/test/layer_matcher_test.dart` (`git mv`). In it, delete the line `import 'package:appstein_lints/src/layer_imports/layer_matcher.dart';`. `LayerMatcher` now comes from `package:appstein_protocol/appstein_protocol.dart`, which the file already imports.

- [ ] **Step 2: Run the protocol tests to see them fail**

Run: `cd packages/appstein_protocol && fvm dart test`
Expected: FAIL. There is no named parameter `interfaceOnly`, no `describeAllowed`, and no `LayerMatcher` in the protocol.

- [ ] **Step 3: Implement `LayerRules.interfaces`**

Replace the whole of `packages/appstein_protocol/lib/src/layer_rules.dart` with:

```dart
/// Which layer may import which, as declared by a stack pack (spec §9.6).
///
/// It is written into a project's `analysis_options.yaml` as a top-level
/// `appstein_lints:` section and read by the `layer_imports` lint rule.
/// `appstein sync` applies the same rules to `.appstein/map/layers.json`.
///
/// ```yaml
/// appstein_lints:
///   layers:          # tag: path globs, relative to analysis_options.yaml
///     ui: [lib/ui/**]
///     domain: [lib/domain/**]
///     data.repository: [lib/data/repositories/**]
///   allow:           # tag: the other tags it may import
///     ui: [domain]
///     domain: []
///   interfaces:      # tag: the tags whose interface files it may import
///     ui: [data.repository]
/// ```
///
/// A file gets the first tag, in declaration order, whose globs match it. A
/// layer may always import itself. A tag with no `allow` entry is
/// unrestricted. An interface file is one whose classes are all abstract,
/// such as a repository's interface; its implementation is not one.
final class LayerRules {
  /// Creates layer rules. Prefer [LayerRules.fromJson], which validates.
  const LayerRules({
    required this.layers,
    required this.allow,
    this.interfaces = const {},
  });

  /// Parses and validates an `appstein_lints:` section.
  ///
  /// Throws a [FormatException] whose message is written for the person
  /// editing the file.
  factory LayerRules.fromJson(Object? json) {
    if (json is! Map<Object?, Object?>) {
      throw const FormatException(
        'appstein_lints must be a map with "layers" and "allow".',
      );
    }
    for (final key in json.keys) {
      if (key != 'layers' && key != 'allow' && key != 'interfaces') {
        throw FormatException(
          'Unknown key "$key" in appstein_lints. '
          'Allowed: layers, allow, interfaces.',
        );
      }
    }
    final layers = _stringListMap(json['layers'], 'layers');
    for (final MapEntry(key: tag, value: globs) in layers.entries) {
      if (!_tagPattern.hasMatch(tag)) {
        throw FormatException(
          'Layer tag "$tag" is not valid. Use lowercase '
          'words separated by dots, like "data.repository".',
        );
      }
      if (globs.isEmpty) {
        throw FormatException('Layer "$tag" needs at least one path glob.');
      }
    }
    return LayerRules(
      layers: layers,
      allow: _targets(json['allow'], 'allow', layers),
      interfaces: _targets(json['interfaces'], 'interfaces', layers),
    );
  }

  static final _tagPattern = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$');

  /// Reads an `allow`- or `interfaces`-shaped section: every key and every
  /// listed tag must be declared under [layers].
  static Map<String, List<String>> _targets(
    Object? value,
    String name,
    Map<String, List<String>> layers,
  ) {
    final targets = _stringListMap(value, name);
    for (final MapEntry(key: tag, value: listed) in targets.entries) {
      if (!layers.containsKey(tag)) {
        throw FormatException('$name: "$tag" is not declared under layers.');
      }
      for (final target in listed) {
        if (!layers.containsKey(target)) {
          throw FormatException(
            '$name: "$tag" lists "$target", which is '
            'not declared under layers.',
          );
        }
      }
    }
    return targets;
  }

  static Map<String, List<String>> _stringListMap(Object? value, String name) {
    if (value == null) return const {};
    if (value is! Map<Object?, Object?>) {
      throw FormatException('appstein_lints.$name must be a map.');
    }
    final result = <String, List<String>>{};
    for (final MapEntry(:key, value: list) in value.entries) {
      if (key is! String) {
        throw FormatException(
          'appstein_lints.$name: every key must be a string.',
        );
      }
      if (list is! List<Object?> ||
          list.any((item) => item is! String || item.isEmpty)) {
        throw FormatException(
          'appstein_lints.$name.$key must be a list of non-empty strings.',
        );
      }
      result[key] = List.unmodifiable(list.cast<String>());
    }
    return Map.unmodifiable(result);
  }

  /// Layer tag → path globs, in match order.
  final Map<String, List<String>> layers;

  /// Layer tag → the other tags it may import.
  final Map<String, List<String>> allow;

  /// Layer tag → the tags whose interface files it may import, though it
  /// may not import their other files.
  final Map<String, List<String>> interfaces;

  /// Whether code in [fromTag] may import a file in [toTag].
  /// [interfaceOnly] says whether that file is an interface file (all of
  /// its classes are abstract), which [interfaces] may allow.
  bool mayImport(String fromTag, String toTag, {bool interfaceOnly = false}) {
    if (fromTag == toTag) return true;
    final allowed = allow[fromTag];
    if (allowed == null || allowed.contains(toTag)) return true;
    return interfaceOnly && (interfaces[fromTag]?.contains(toTag) ?? false);
  }

  /// What [fromTag] may import, in words, for messages: "ui, domain, and
  /// the interfaces of data.repository", or "any layer".
  String describeAllowed(String fromTag) {
    final allowed = allow[fromTag];
    if (allowed == null) return 'any layer';
    final tags = [fromTag, ...allowed].join(', ');
    final viaInterfaces = interfaces[fromTag] ?? const [];
    return viaInterfaces.isEmpty
        ? tags
        : '$tags, and the interfaces of ${viaInterfaces.join(', ')}';
  }

  /// The JSON form, which is also the YAML form. An empty [interfaces]
  /// section is left out.
  Map<String, Object?> toJson() => {
    'layers': layers,
    'allow': allow,
    if (interfaces.isNotEmpty) 'interfaces': interfaces,
  };
}
```

- [ ] **Step 4: Move `LayerMatcher` into the protocol**

Create `packages/appstein_protocol/lib/src/layer_matcher.dart`:

```dart
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'layer_rules.dart';

/// Gives files their layer tag using the globs in [LayerRules].
///
/// The `layer_imports` lint and `appstein sync` (for `layers.json`) both
/// use it, so a file gets the same tag in the editor and in the map. Paths
/// are relative to the folder whose rules apply (the `analysis_options.yaml`
/// folder for the lint, the project folder for sync), with `/` on every OS.
final class LayerMatcher {
  /// Creates a matcher for [rules]. Throws a [FormatException] for an
  /// invalid glob.
  LayerMatcher(this.rules)
    : _globs = {
        for (final MapEntry(key: tag, value: patterns) in rules.layers.entries)
          tag: [for (final g in patterns) Glob(g, context: p.posix)],
      };

  /// The rules being matched.
  final LayerRules rules;

  final Map<String, List<Glob>> _globs;

  /// The first tag, in declaration order, whose globs match
  /// [relativePosixPath]. Null when none match.
  String? tagFor(String relativePosixPath) {
    for (final MapEntry(key: tag, value: globs) in _globs.entries) {
      if (globs.any((glob) => glob.matches(relativePosixPath))) return tag;
    }
    return null;
  }
}
```

Delete `packages/appstein_lints/lib/src/layer_imports/layer_matcher.dart` (`git rm`).

In `packages/appstein_protocol/lib/appstein_protocol.dart`, add `export 'src/layer_matcher.dart';` after `export 'src/knowledge/toolchain.dart';`.

In `packages/appstein_protocol/pubspec.yaml`, add a `dependencies:` section after `resolution: workspace` (the same constraints the lints package uses):

```yaml
dependencies:
  glob: ^2.2.0
  path: ^1.9.1
```

In `packages/appstein_lints/pubspec.yaml`, delete the line `  glob: ^2.2.0`. The lints package no longer uses it, and `dependency_validator` would flag it.

In `packages/appstein_lints/lib/src/layer_imports/layer_config.dart`, delete `import 'layer_matcher.dart';`. `LayerMatcher` now comes through the existing `package:appstein_protocol/appstein_protocol.dart` import.

Run: `fvm dart pub get` (repo root). If `pubspec.lock` changes, keep the change. CI runs `pub get --enforce-lockfile`.

- [ ] **Step 5: Run the protocol tests to see them pass**

Run: `cd packages/appstein_protocol && fvm dart test`
Expected: PASS.

- [ ] **Step 6: Write the failing lint tests**

Append to the class `LayerImportsRuleTest` in `packages/appstein_lints/test/layer_imports_rule_test.dart`:

```dart
  static const _interfaceLayers = '''
appstein_lints:
  layers:
    ui: [lib/ui/**]
    data: [lib/data/**]
  allow:
    ui: []
  interfaces:
    ui: [data]
''';

  Future<void> test_interfaceFileIsAllowed() async {
    _options(_interfaceLayers);
    newFile(
      '$testPackageLibPath/data/api.dart',
      'abstract class Api {}\nabstract interface class Other {}\n',
    );
    newFile(_ui, "import '../data/api.dart';\nApi? a;\n");
    await assertNoDiagnosticsInFile(_ui);
  }

  Future<void> test_implementationFileIsNotAllowed() async {
    _options(_interfaceLayers);
    newFile(_ui, "import '../data/repo.dart';\nRepo? r;\n");
    await assertDiagnosticsInFile(_ui, [
      lint(7, 19, messageContainsAll: ["'ui' layer can't import"]),
    ]);
  }

  Future<void> test_fileWithAConcreteClassIsNotAnInterface() async {
    _options(_interfaceLayers);
    newFile(
      '$testPackageLibPath/data/mixed.dart',
      'abstract class Api {}\nclass ApiImpl implements Api {}\n',
    );
    newFile(_ui, "import '../data/mixed.dart';\nApi? a;\n");
    await assertDiagnosticsInFile(_ui, [lint(7, 20)]);
  }

  Future<void> test_fileWithNoClassesIsNotAnInterface() async {
    _options(_interfaceLayers);
    newFile('$testPackageLibPath/data/helpers.dart', 'int one() => 1;\n');
    newFile(_ui, "import '../data/helpers.dart';\nint x = one();\n");
    await assertDiagnosticsInFile(_ui, [lint(7, 22)]);
  }
```

(Offsets: the URI starts at 7. `'../data/mixed.dart'` is 20 characters with its quotes, and `'../data/helpers.dart'` is 22.)

- [ ] **Step 7: Run the lint tests to see them fail**

Run: `cd packages/appstein_lints && fvm dart test`
Expected: `test_interfaceFileIsAllowed` FAILS, because the rule still reports the import. The others pass.

- [ ] **Step 8: Teach the rule about interface files**

Create `packages/appstein_lints/lib/src/layer_imports/interface_library.dart`:

```dart
import 'package:analyzer/dart/element/element.dart';

/// Whether [library] is an interface file for the `interfaces` layer rule
/// (spec §9.6). It must declare at least one class, and every class it
/// declares must be abstract, like a repository's interface.
///
/// Appstein's engine has the same rule for `layers.json`
/// (`appstein_engine/lib/src/map/interface_library.dart`). The lints can't
/// import the engine, so keep the two in step.
bool isInterfaceLibrary(LibraryElement library) {
  final classes = library.classes;
  return classes.isNotEmpty && classes.every((c) => c.isAbstract);
}
```

In `packages/appstein_lints/lib/src/layer_imports/layer_imports_rule.dart`:
- add `import 'interface_library.dart';` after `import 'layer_config.dart';`;
- replace the end of `_check`, from `final fromTag = matcher.tagFor(fromPath);` to the end of the method, with:

```dart
    final fromTag = matcher.tagFor(fromPath);
    final toTag = matcher.tagFor(toPath);
    if (fromTag == null || toTag == null) return;
    if (rules.mayImport(
      fromTag,
      toTag,
      interfaceOnly: isInterfaceLibrary(target),
    )) {
      return;
    }
    rule.reportAtNode(
      node.uri,
      diagnosticCode: LayerImportsRule.forbiddenImport,
      arguments: [fromTag, toTag, toPath, rules.describeAllowed(fromTag)],
    );
  }
```

- [ ] **Step 9: Run every affected test**

Run: `cd packages/appstein_lints && fvm dart test` and `cd packages/appstein_protocol && fvm dart test`
Expected: PASS.

Then from the repo root run `fvm dart analyze --fatal-infos` and `fvm dart run dependency_validator`. Expected: no issues. The repo's own `analysis_options.yaml` still parses, because `interfaces` is optional.

- [ ] **Step 10: Commit**

```bash
git add packages/appstein_protocol packages/appstein_lints pubspec.lock
git commit -m "feat(lints): interfaces in layer rules, and one LayerMatcher in the protocol"
```

---

### Task 2: Protocol — the map file formats

**Files:**
- Modify: `packages/appstein_protocol/lib/src/json_fields.dart`
- Create: `packages/appstein_protocol/lib/src/map/map_files.dart`, `code_ref.dart`, `symbols_map.dart`, `layers_map.dart`, `deps_map.dart`, `features_map.dart`, `routes_map.dart`
- Modify: `packages/appstein_protocol/lib/appstein_protocol.dart`
- Test: `packages/appstein_protocol/test/json_fields_test.dart`, `packages/appstein_protocol/test/project_map_test.dart`

**Interfaces:**
- Consumes: `JsonFields` (internal to the protocol).
- Produces, all exported:
  - `abstract final class MapFiles { symbols, layers, deps, features, routes }` (paths inside `.appstein/`).
  - `CodeRef({name, file})`.
  - `enum SymbolKind` with `jsonName`; `MapSymbol({name, kind, file, line, layer?, feature?, summary?})`; `SymbolsMap({symbols})`.
  - `MapFileEntry({layer?, feature?, imports})`; `LayerViolation({file, line, import, from, to})`; `LayersMap({files, violations})`.
  - `PackageDependency({constraint?, version, dependency, source, usages})`; `DepsMap({packages})`.
  - `Feature({folder, viewModels, screens, repositories, services, models, tests, files})`; `FeaturesMap({features})` with `String? featureOf(String path)`.
  - `MapRoute({path?, name?, screen?, parent?, redirect, file, line, unresolved, reason?})`; `MapRouter({file, line, redirect})`; `RoutesMap({routes, routers})`.
  - Every map class has `toJson()`. The five top-level maps have `factory X.fromJson(Map<String, Object?> json)`, which ignores the `meta` key.

- [ ] **Step 1: Write the failing tests**

Append to `packages/appstein_protocol/test/json_fields_test.dart`, inside `main()`:

```dart
  test('reads booleans, optional integers, string lists and object maps', () {
    const more = JsonFields('y.json', {
      'yes': true,
      'n': 4,
      'none': null,
      'names': ['a', 'b'],
      'byName': {
        'a': {'k': 1},
      },
    });
    expect(more.boolean('yes'), isTrue);
    expect(more.optionalInteger('n'), 4);
    expect(more.optionalInteger('none'), isNull);
    expect(more.strings('names'), ['a', 'b']);
    expect(more.objectMap('byName')['a']!.integer('k'), 1);
    expect(
      () => more.boolean('n'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'y.json: "n" must be true or false.',
        ),
      ),
    );
    expect(
      () => more.strings('byName'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'y.json: "byName" must be a list of strings.',
        ),
      ),
    );
  });
```

Create `packages/appstein_protocol/test/project_map_test.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('the map files live under map/', () {
    expect(MapFiles.all, [
      'map/deps.json',
      'map/features.json',
      'map/layers.json',
      'map/routes.json',
      'map/symbols.json',
    ]);
  });

  test('symbols round-trip, with null summaries kept', () {
    const map = SymbolsMap(
      symbols: [
        MapSymbol(
          name: 'HomeViewModel',
          kind: SymbolKind.classKind,
          file: 'lib/ui/home/view_models/home_viewmodel.dart',
          line: 7,
          layer: 'ui',
          feature: 'home',
          summary: "Loads the user's bookings for the home screen.",
        ),
        MapSymbol(
          name: 'Json',
          kind: SymbolKind.typedef,
          file: 'lib/utils/result.dart',
          line: 3,
        ),
      ],
    );
    final json = map.toJson();
    expect((json['symbols']! as List).first, {
      'name': 'HomeViewModel',
      'kind': 'class',
      'file': 'lib/ui/home/view_models/home_viewmodel.dart',
      'line': 7,
      'layer': 'ui',
      'feature': 'home',
      'summary': "Loads the user's bookings for the home screen.",
    });
    expect((json['symbols']! as List).last, containsPair('summary', null));
    expect(SymbolsMap.fromJson({...json, 'meta': {}}).toJson(), json);
  });

  test('every symbol kind has its JSON name', () {
    expect(SymbolKind.values.map((k) => k.jsonName), [
      'class',
      'mixin',
      'enum',
      'extension',
      'extensionType',
      'typedef',
      'function',
    ]);
  });

  test('an unknown symbol kind is a FormatException naming the file', () {
    expect(
      () => SymbolsMap.fromJson({
        'symbols': [
          {'name': 'A', 'kind': 'struct', 'file': 'lib/a.dart', 'line': 1},
        ],
      }),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'symbols.json: unknown symbol kind "struct".',
        ),
      ),
    );
  });

  test('layers round-trip', () {
    const map = LayersMap(
      files: {
        'lib/ui/a.dart': MapFileEntry(
          layer: 'ui',
          feature: 'a',
          imports: ['lib/data/b.dart'],
        ),
        'lib/main.dart': MapFileEntry(imports: []),
      },
      violations: [
        LayerViolation(
          file: 'lib/ui/a.dart',
          line: 3,
          import: 'lib/data/b.dart',
          from: 'ui',
          to: 'data.repository',
        ),
      ],
    );
    final json = map.toJson();
    expect(json['files'], containsPair('lib/main.dart', {
      'layer': null,
      'feature': null,
      'imports': <String>[],
    }));
    expect(LayersMap.fromJson(json).toJson(), json);
  });

  test('deps round-trip', () {
    const map = DepsMap(
      packages: {
        'go_router': PackageDependency(
          constraint: '^18.0.0',
          version: '18.0.2',
          dependency: 'direct main',
          source: 'hosted',
          usages: ['lib/routing/router.dart'],
        ),
        'collection': PackageDependency(
          version: '1.19.1',
          dependency: 'transitive',
          source: 'hosted',
          usages: [],
        ),
      },
    );
    final json = map.toJson();
    expect(json['packages'], containsPair('collection', {
      'constraint': null,
      'version': '1.19.1',
      'dependency': 'transitive',
      'source': 'hosted',
      'usages': <String>[],
    }));
    expect(DepsMap.fromJson(json).toJson(), json);
  });

  test('features round-trip, and featureOf finds files and tests', () {
    const map = FeaturesMap(
      features: {
        'home': Feature(
          folder: 'lib/ui/home',
          viewModels: [
            CodeRef(name: 'HomeViewModel', file: 'lib/ui/home/view_models/h.dart'),
          ],
          screens: [],
          repositories: [],
          services: [],
          models: [],
          tests: ['test/ui/home/h_test.dart'],
          files: ['lib/ui/home/view_models/h.dart'],
        ),
      },
    );
    final json = map.toJson();
    expect(FeaturesMap.fromJson(json).toJson(), json);
    expect(map.featureOf('lib/ui/home/view_models/h.dart'), 'home');
    expect(map.featureOf('test/ui/home/h_test.dart'), 'home');
    expect(map.featureOf('lib/main.dart'), isNull);
  });

  test('routes round-trip, resolved and unresolved', () {
    const map = RoutesMap(
      routes: [
        MapRoute(
          path: '/booking',
          screen: CodeRef(name: 'BookingScreen', file: 'lib/ui/booking/widgets/b.dart'),
          parent: '/',
          file: 'lib/routing/router.dart',
          line: 40,
        ),
        MapRoute(
          file: 'lib/routing/router.dart',
          line: 50,
          parent: '/',
          unresolved: true,
          reason: 'the path is not a constant string',
        ),
      ],
      routers: [MapRouter(file: 'lib/routing/router.dart', line: 20, redirect: true)],
    );
    final json = map.toJson();
    expect((json['routes']! as List).last, {
      'path': null,
      'name': null,
      'screen': null,
      'parent': '/',
      'redirect': false,
      'file': 'lib/routing/router.dart',
      'line': 50,
      'unresolved': true,
      'reason': 'the path is not a constant string',
    });
    expect(RoutesMap.fromJson(json).toJson(), json);
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_protocol && fvm dart test`
Expected: FAIL, because nothing in the test exists yet.

- [ ] **Step 3: Add the `JsonFields` readers**

In `packages/appstein_protocol/lib/src/json_fields.dart`, add these methods before `_wrong`:

```dart
  /// The boolean at [key].
  bool boolean(String key) => switch (json[key]) {
    final bool value => value,
    _ => throw _wrong(key, 'true or false'),
  };

  /// The integer at [key], or null when it is missing or null.
  int? optionalInteger(String key) => switch (json[key]) {
    null => null,
    final int value => value,
    _ => throw _wrong(key, 'an integer or null'),
  };

  /// The list of strings at [key].
  List<String> strings(String key) {
    final value = json[key];
    if (value is List<Object?> && value.every((item) => item is String)) {
      return value.cast<String>();
    }
    throw _wrong(key, 'a list of strings');
  }

  /// The object of objects at [key], by key.
  Map<String, JsonFields> objectMap(String key) {
    final value = json[key];
    if (value is Map<String, Object?> &&
        value.values.every((item) => item is Map<String, Object?>)) {
      return {
        for (final MapEntry(key: name, value: item) in value.entries)
          name: JsonFields(file, item! as Map<String, Object?>),
      };
    }
    throw _wrong(key, 'an object of objects');
  }
```

- [ ] **Step 4: Create the map models**

`packages/appstein_protocol/lib/src/map/map_files.dart`:

```dart
/// The project map's files, by their path inside `.appstein/` (spec §6.2).
abstract final class MapFiles {
  /// Public declarations in `lib/`.
  static const symbols = 'map/symbols.json';

  /// Each file's layer tag and imports, and the forbidden imports.
  static const layers = 'map/layers.json';

  /// The packages and where they are imported.
  static const deps = 'map/deps.json';

  /// The features under `lib/ui/` (written by the stack pack).
  static const features = 'map/features.json';

  /// The go_router routes (written by the stack pack).
  static const routes = 'map/routes.json';

  /// All of them, sorted.
  static const all = [deps, features, layers, routes, symbols];
}
```

`packages/appstein_protocol/lib/src/map/code_ref.dart`:

```dart
import '../json_fields.dart';

/// A named declaration and the file that declares it, such as a screen or
/// a repository.
final class CodeRef {
  /// Creates a reference.
  const CodeRef({required this.name, required this.file});

  /// Reads a reference from [fields].
  factory CodeRef.read(JsonFields fields) =>
      CodeRef(name: fields.string('name'), file: fields.string('file'));

  /// The declaration's name, such as `HomeScreen`.
  final String name;

  /// Its file, relative to the project, with `/`.
  final String file;

  /// The JSON form.
  Map<String, Object?> toJson() => {'name': name, 'file': file};
}
```

`JsonFields` isn't exported, so `CodeRef.read` is reachable only inside the protocol. That's intended: other packages use the top-level `fromJson` factories.

`packages/appstein_protocol/lib/src/map/symbols_map.dart`:

```dart
import '../json_fields.dart';

/// What kind of declaration a symbol is.
enum SymbolKind {
  /// A class, including a mixin application (`class A = B with C;`).
  classKind('class'),

  /// A mixin.
  mixinKind('mixin'),

  /// An enum.
  enumKind('enum'),

  /// A named extension.
  extension('extension'),

  /// An extension type.
  extensionType('extensionType'),

  /// A typedef.
  typedef('typedef'),

  /// A top-level function.
  function('function');

  const SymbolKind(this.jsonName);

  /// The kind's name in `symbols.json`.
  final String jsonName;
}

/// One public top-level declaration in `lib/` (spec §6.5).
final class MapSymbol {
  /// Creates a symbol.
  const MapSymbol({
    required this.name,
    required this.kind,
    required this.file,
    required this.line,
    this.layer,
    this.feature,
    this.summary,
  });

  factory MapSymbol._read(JsonFields fields) {
    final kindName = fields.string('kind');
    final kind = SymbolKind.values.where((k) => k.jsonName == kindName);
    if (kind.isEmpty) {
      throw FormatException(
        '${fields.file}: unknown symbol kind "$kindName".',
      );
    }
    return MapSymbol(
      name: fields.string('name'),
      kind: kind.single,
      file: fields.string('file'),
      line: fields.integer('line'),
      layer: fields.optionalString('layer'),
      feature: fields.optionalString('feature'),
      summary: fields.optionalString('summary'),
    );
  }

  /// The declared name.
  final String name;

  /// What kind of declaration it is.
  final SymbolKind kind;

  /// Its file, relative to the project, with `/`.
  final String file;

  /// The 1-based line of its name.
  final int line;

  /// Its file's layer tag, if the stack pack's rules give it one.
  final String? layer;

  /// The feature its file belongs to, if any.
  final String? feature;

  /// The first sentence of its doc comment, if it has one.
  final String? summary;

  /// The JSON form. Null fields are written as `null`, so every symbol has
  /// the same keys.
  Map<String, Object?> toJson() => {
    'name': name,
    'kind': kind.jsonName,
    'file': file,
    'line': line,
    'layer': layer,
    'feature': feature,
    'summary': summary,
  };
}

/// The contents of `map/symbols.json`.
final class SymbolsMap {
  /// Creates the map. [symbols] are sorted by file, then line, then name.
  const SymbolsMap({required this.symbols});

  /// Reads the map from its JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory SymbolsMap.fromJson(Map<String, Object?> json) => SymbolsMap(
    symbols: [
      for (final symbol in JsonFields('symbols.json', json).objects('symbols'))
        MapSymbol._read(symbol),
    ],
  );

  /// The symbols.
  final List<MapSymbol> symbols;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'symbols': [for (final symbol in symbols) symbol.toJson()],
  };
}
```

`packages/appstein_protocol/lib/src/map/layers_map.dart`:

```dart
import '../json_fields.dart';

/// One project file in `layers.json`.
final class MapFileEntry {
  /// Creates an entry.
  const MapFileEntry({this.layer, this.feature, required this.imports});

  factory MapFileEntry._read(JsonFields fields) => MapFileEntry(
    layer: fields.optionalString('layer'),
    feature: fields.optionalString('feature'),
    imports: fields.strings('imports'),
  );

  /// The file's layer tag, or null when no glob matches it.
  final String? layer;

  /// The feature the file belongs to, if any.
  final String? feature;

  /// The project files it imports or exports, sorted.
  final List<String> imports;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'layer': layer,
    'feature': feature,
    'imports': imports,
  };
}

/// An import that the layer rules forbid (spec §9.6).
final class LayerViolation {
  /// Creates a violation.
  const LayerViolation({
    required this.file,
    required this.line,
    required this.import,
    required this.from,
    required this.to,
  });

  factory LayerViolation._read(JsonFields fields) => LayerViolation(
    file: fields.string('file'),
    line: fields.integer('line'),
    import: fields.string('import'),
    from: fields.string('from'),
    to: fields.string('to'),
  );

  /// The importing file.
  final String file;

  /// The 1-based line of the import's URI.
  final int line;

  /// The imported file.
  final String import;

  /// The importing file's layer.
  final String from;

  /// The imported file's layer.
  final String to;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'file': file,
    'line': line,
    'import': import,
    'from': from,
    'to': to,
  };
}

/// The contents of `map/layers.json`.
final class LayersMap {
  /// Creates the map. [violations] are sorted by file, then line, then
  /// import.
  const LayersMap({required this.files, required this.violations});

  /// Reads the map from its JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory LayersMap.fromJson(Map<String, Object?> json) {
    final fields = JsonFields('layers.json', json);
    return LayersMap(
      files: {
        for (final MapEntry(:key, :value) in fields.objectMap('files').entries)
          key: MapFileEntry._read(value),
      },
      violations: [
        for (final v in fields.objects('violations')) LayerViolation._read(v),
      ],
    );
  }

  /// Every analyzed file, by its project-relative path.
  final Map<String, MapFileEntry> files;

  /// The forbidden imports.
  final List<LayerViolation> violations;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'files': {
      for (final MapEntry(:key, :value) in files.entries) key: value.toJson(),
    },
    'violations': [for (final v in violations) v.toJson()],
  };
}
```

`packages/appstein_protocol/lib/src/map/deps_map.dart`:

```dart
import '../json_fields.dart';

/// One package in `deps.json`.
final class PackageDependency {
  /// Creates an entry.
  const PackageDependency({
    this.constraint,
    required this.version,
    required this.dependency,
    required this.source,
    required this.usages,
  });

  factory PackageDependency._read(JsonFields fields) => PackageDependency(
    constraint: fields.optionalString('constraint'),
    version: fields.string('version'),
    dependency: fields.string('dependency'),
    source: fields.string('source'),
    usages: fields.strings('usages'),
  );

  /// The version constraint in `pubspec.yaml`, such as `^18.0.0`. It is null
  /// for a transitive package, or for one given as an SDK, path or git
  /// dependency without a version.
  final String? constraint;

  /// The resolved version, from `pubspec.lock`.
  final String version;

  /// How it is depended on, as `pubspec.lock` says: `direct main`,
  /// `direct dev`, `direct overridden` or `transitive`.
  final String dependency;

  /// Where it comes from, as `pubspec.lock` says: `hosted`, `sdk`, `path` or
  /// `git`.
  final String source;

  /// The project files that import it, sorted.
  final List<String> usages;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'constraint': constraint,
    'version': version,
    'dependency': dependency,
    'source': source,
    'usages': usages,
  };
}

/// The contents of `map/deps.json` (spec §6.5). The health snapshot and
/// advisories are added once the package gate exists (§9.4).
final class DepsMap {
  /// Creates the map.
  const DepsMap({required this.packages});

  /// Reads the map from its JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory DepsMap.fromJson(Map<String, Object?> json) => DepsMap(
    packages: {
      for (final MapEntry(:key, :value) in JsonFields(
        'deps.json',
        json,
      ).objectMap('packages').entries)
        key: PackageDependency._read(value),
    },
  );

  /// Every package in `pubspec.lock`, by name.
  final Map<String, PackageDependency> packages;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'packages': {
      for (final MapEntry(:key, :value) in packages.entries)
        key: value.toJson(),
    },
  };
}
```

`packages/appstein_protocol/lib/src/map/features_map.dart`:

```dart
import '../json_fields.dart';
import 'code_ref.dart';

/// One feature: a folder under `lib/ui/` with `view_models/` or `widgets/`
/// (spec §6.5).
final class Feature {
  /// Creates a feature. Every list is sorted: references by name, then
  /// file; paths alphabetically.
  const Feature({
    required this.folder,
    required this.viewModels,
    required this.screens,
    required this.repositories,
    required this.services,
    required this.models,
    required this.tests,
    required this.files,
  });

  factory Feature._read(JsonFields fields) {
    List<CodeRef> refs(String key) => [
      for (final ref in fields.objects(key)) CodeRef.read(ref),
    ];
    return Feature(
      folder: fields.string('folder'),
      viewModels: refs('viewModels'),
      screens: refs('screens'),
      repositories: refs('repositories'),
      services: refs('services'),
      models: refs('models'),
      tests: fields.strings('tests'),
      files: fields.strings('files'),
    );
  }

  /// The feature's folder, such as `lib/ui/auth/login`.
  final String folder;

  /// Its view models: the classes in `view_models/` that extend
  /// `ChangeNotifier`.
  final List<CodeRef> viewModels;

  /// Its screens: the widgets in `widgets/` that routes build.
  final List<CodeRef> screens;

  /// The repositories its view models' constructors take.
  final List<CodeRef> repositories;

  /// The services its view models' constructors take.
  final List<CodeRef> services;

  /// The public classes in `domain` files that its files import.
  final List<CodeRef> models;

  /// Its tests under `test/ui/<feature>/`.
  final List<String> tests;

  /// Its files.
  final List<String> files;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'folder': folder,
    'viewModels': [for (final r in viewModels) r.toJson()],
    'screens': [for (final r in screens) r.toJson()],
    'repositories': [for (final r in repositories) r.toJson()],
    'services': [for (final r in services) r.toJson()],
    'models': [for (final r in models) r.toJson()],
    'tests': tests,
    'files': files,
  };
}

/// The contents of `map/features.json`.
final class FeaturesMap {
  /// Creates the map.
  const FeaturesMap({required this.features});

  /// Reads the map from its JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory FeaturesMap.fromJson(Map<String, Object?> json) => FeaturesMap(
    features: {
      for (final MapEntry(:key, :value) in JsonFields(
        'features.json',
        json,
      ).objectMap('features').entries)
        key: Feature._read(value),
    },
  );

  /// The features, by name: the folder's path below `lib/ui/`, such as
  /// `auth/login`.
  final Map<String, Feature> features;

  /// The feature whose files or tests include [path], or null.
  String? featureOf(String path) {
    for (final MapEntry(:key, :value) in features.entries) {
      if (value.files.contains(path) || value.tests.contains(path)) return key;
    }
    return null;
  }

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'features': {
      for (final MapEntry(:key, :value) in features.entries)
        key: value.toJson(),
    },
  };
}
```

`packages/appstein_protocol/lib/src/map/routes_map.dart`:

```dart
import '../json_fields.dart';
import 'code_ref.dart';

/// One go_router route in `routes.json` (spec §6.5).
final class MapRoute {
  /// Creates a route.
  const MapRoute({
    this.path,
    this.name,
    this.screen,
    this.parent,
    this.redirect = false,
    required this.file,
    required this.line,
    this.unresolved = false,
    this.reason,
  });

  factory MapRoute._read(JsonFields fields) {
    final screen = fields.optionalObject('screen');
    return MapRoute(
      path: fields.optionalString('path'),
      name: fields.optionalString('name'),
      screen: screen == null ? null : CodeRef.read(screen),
      parent: fields.optionalString('parent'),
      redirect: fields.boolean('redirect'),
      file: fields.string('file'),
      line: fields.integer('line'),
      unresolved: fields.boolean('unresolved'),
      reason: fields.optionalString('reason'),
    );
  }

  /// The full path, with the parents' paths joined in, or null when it
  /// can't be resolved statically.
  final String? path;

  /// The route's `name:`, when it is a constant string.
  final String? name;

  /// The widget the builder returns, when that is a widget declared in the
  /// project.
  final CodeRef? screen;

  /// The full path of the enclosing `GoRoute`, or null at the top.
  final String? parent;

  /// Whether the route has its own `redirect:`.
  final bool redirect;

  /// The file that declares the route.
  final String file;

  /// The 1-based line where the route's constructor call starts.
  final int line;

  /// Whether the path or the screen couldn't be resolved statically.
  final bool unresolved;

  /// Why it is [unresolved].
  final String? reason;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'path': path,
    'name': name,
    'screen': screen?.toJson(),
    'parent': parent,
    'redirect': redirect,
    'file': file,
    'line': line,
    'unresolved': unresolved,
    'reason': reason,
  };
}

/// One `GoRouter(...)` in the project.
final class MapRouter {
  /// Creates a router entry.
  const MapRouter({
    required this.file,
    required this.line,
    required this.redirect,
  });

  factory MapRouter._read(JsonFields fields) => MapRouter(
    file: fields.string('file'),
    line: fields.integer('line'),
    redirect: fields.boolean('redirect'),
  );

  /// The file that creates the router.
  final String file;

  /// The 1-based line where the constructor call starts.
  final int line;

  /// Whether the router has a top-level `redirect:`.
  final bool redirect;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'file': file,
    'line': line,
    'redirect': redirect,
  };
}

/// The contents of `map/routes.json`.
final class RoutesMap {
  /// Creates the map. Both lists are sorted by file, then line.
  const RoutesMap({required this.routes, required this.routers});

  /// Reads the map from its JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory RoutesMap.fromJson(Map<String, Object?> json) {
    final fields = JsonFields('routes.json', json);
    return RoutesMap(
      routes: [for (final r in fields.objects('routes')) MapRoute._read(r)],
      routers: [for (final r in fields.objects('routers')) MapRouter._read(r)],
    );
  }

  /// The routes.
  final List<MapRoute> routes;

  /// The routers.
  final List<MapRouter> routers;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'routes': [for (final r in routes) r.toJson()],
    'routers': [for (final r in routers) r.toJson()],
  };
}
```

In `packages/appstein_protocol/lib/appstein_protocol.dart`, add after `export 'src/layer_rules.dart';` (keeping the list alphabetical):

```dart
export 'src/map/code_ref.dart';
export 'src/map/deps_map.dart';
export 'src/map/features_map.dart';
export 'src/map/layers_map.dart';
export 'src/map/map_files.dart';
export 'src/map/routes_map.dart';
export 'src/map/symbols_map.dart';
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd packages/appstein_protocol && fvm dart test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add packages/appstein_protocol
git commit -m "feat(protocol): the project map's file formats"
```

---

### Task 3: Packages — Flutter's freshness rule and `flutter pub get`

**Files:**
- Modify: `packages/appstein_engine/lib/src/host/process_runner.dart`
- Modify: `packages/appstein_engine/test/support/fake_process_runner.dart`
- Create: `packages/appstein_engine/lib/src/map/project_packages.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart`
- Test: `packages/appstein_engine/test/host/process_runner_test.dart`, `packages/appstein_engine/test/map/project_packages_test.dart`

**Interfaces:**
- Consumes: `ProcessRunner`, `RunResult`, `HostOs`, `fileErrorReason`.
- Produces:
  - `ProcessRunner.run(executable, arguments, {timeout, environment, String? workingDirectory})`.
  - `FakeProcessRunner.workingDirectories` (`List<String?>`, one per call).
  - `PackagesStatus({required bool fresh, required String reason, required String workspaceRoot})`.
  - `PackagesStatus checkPackages(String projectRoot, {required String flutterVersion})`.
  - `Future<String?> fetchPackages(String projectRoot, {required String flutterRoot, required HostOs os, required ProcessRunner runner, Duration timeout})`. It returns null on success, or why it failed.

This is Flutter's rule from `packages/flutter_tools/lib/src/dart/pub.dart` (`get` with `checkUpToDate: true`, which every `FlutterCommand` uses). `pub get` is skipped when:
- `package_config.json` was written by a tool other than pub (used as it is); or
- **all** of these hold: `pubspec.lock` exists; `pubspec.yaml` is older than both it and `package_config.json`; and `.dart_tool/version` equals the Flutter framework version exactly (no trimming).

Flutter writes `.dart_tool/version` without a newline. The workspace lookup follows ruling P1.

- [ ] **Step 1: Write the failing tests**

Append to `packages/appstein_engine/test/host/process_runner_test.dart`, inside `main()` (it already imports `dart:io`, `package:path/path.dart as p`, the engine and `../support/temp.dart`; add any of them that are missing):

```dart
  test('runs the tool in the working directory it is given', () async {
    final dir = tempDir();
    final work = Directory(p.join(dir.path, 'work folder'))..createSync();
    final String script;
    if (Platform.isWindows) {
      script = p.join(dir.path, 'mark.bat');
      File(script).writeAsStringSync('@echo off\r\necho here> marker.txt\r\n');
    } else {
      script = p.join(dir.path, 'mark');
      File(script).writeAsStringSync('#!/bin/sh\necho here > marker.txt\n');
      Process.runSync('chmod', ['+x', script]);
    }
    final result = await const SystemProcessRunner().run(
      script,
      const [],
      workingDirectory: work.path,
    );
    expect(result.ok, isTrue, reason: result.stderr);
    expect(File(p.join(work.path, 'marker.txt')).existsSync(), isTrue);
  });
```

(A marker file rather than printing the folder: `cmd.exe` would print the `ë` in the temp path in the console's code page, not UTF-8.)

Create `packages/appstein_engine/test/map/project_packages_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/temp.dart';

void main() {
  late String project;

  setUp(() {
    project = p.join(tempDir().path, 'my app');
    Directory(p.join(project, '.dart_tool')).createSync(recursive: true);
    File(p.join(project, 'pubspec.yaml')).writeAsStringSync('name: my_app\n');
  });

  /// Writes what `flutter pub get` leaves behind, after an older pubspec.
  void writeFetched(
    String root, {
    String version = '3.47.5',
    String generator = 'pub',
    String? pubspecFolder,
  }) {
    File(
      p.join(pubspecFolder ?? root, 'pubspec.yaml'),
    ).setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
    File(p.join(root, 'pubspec.lock')).writeAsStringSync('packages: {}\n');
    File(p.join(root, '.dart_tool', 'package_config.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': <Object>[],
          'generator': generator,
        }),
      );
    File(p.join(root, '.dart_tool', 'version')).writeAsStringSync(version);
  }

  PackagesStatus check() => checkPackages(project, flutterVersion: '3.47.5');

  test('packages fetched by this Flutter after the last pubspec change are '
      'fresh', () {
    writeFetched(project);
    final status = check();
    expect(status.fresh, isTrue);
    expect(status.reason, 'they are up to date');
    expect(status.workspaceRoot, project);
  });

  test('no package config means pub get', () {
    final status = check();
    expect(status.fresh, isFalse);
    expect(
      status.reason,
      'they had not been fetched (there was no '
      '.dart_tool/package_config.json)',
    );
  });

  test('a package config another tool wrote is used as it is', () {
    writeFetched(project, generator: 'bazel');
    File(p.join(project, 'pubspec.lock')).deleteSync();
    final status = check();
    expect(status.fresh, isTrue);
    expect(status.reason, contains('written by bazel'));
  });

  test('no pubspec.lock means pub get', () {
    writeFetched(project);
    File(p.join(project, 'pubspec.lock')).deleteSync();
    expect(check().reason, 'there was no pubspec.lock');
  });

  test('a pubspec.yaml changed after the fetch means pub get', () {
    writeFetched(project);
    File(
      p.join(project, 'pubspec.yaml'),
    ).setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
    final status = check();
    expect(status.fresh, isFalse);
    expect(status.reason, 'pubspec.yaml changed after they were fetched');
  });

  test('packages fetched by another Flutter mean pub get', () {
    writeFetched(project, version: '3.44.9');
    expect(
      check().reason,
      'they were fetched with Flutter 3.44.9, not 3.47.5',
    );
  });

  test('the version must match exactly, as in Flutter', () {
    writeFetched(project, version: '3.47.5\n');
    expect(check().fresh, isFalse);
  });

  test('no .dart_tool/version means pub get', () {
    writeFetched(project);
    File(p.join(project, '.dart_tool', 'version')).deleteSync();
    expect(
      check().reason,
      'they were not fetched by Flutter (there was no .dart_tool/version)',
    );
  });

  test("a pub workspace member reads the workspace root's files", () {
    final root = p.join(tempDir().path, 'work space');
    final member = p.join(root, 'packages', 'app');
    Directory(p.join(member, '.dart_tool', 'pub')).createSync(recursive: true);
    File(p.join(member, 'pubspec.yaml')).writeAsStringSync('name: app\n');
    File(
      p.join(member, '.dart_tool', 'pub', 'workspace_ref.json'),
    ).writeAsStringSync(
      jsonEncode({'workspaceRoot': p.join('..', '..', '..', '..')}),
    );
    writeFetched(root, pubspecFolder: member);
    final status = checkPackages(member, flutterVersion: '3.47.5');
    expect(status.fresh, isTrue, reason: status.reason);
    expect(status.workspaceRoot, p.normalize(root));
  });

  test('a damaged workspace reference falls back to the project', () {
    Directory(p.join(project, '.dart_tool', 'pub')).createSync();
    File(
      p.join(project, '.dart_tool', 'pub', 'workspace_ref.json'),
    ).writeAsStringSync('{not json');
    writeFetched(project);
    final status = check();
    expect(status.fresh, isTrue);
    expect(status.workspaceRoot, project);
  });

  group('fetchPackages', () {
    final flutter = p.join(
      'sdk',
      'bin',
      Platform.isWindows ? 'flutter.bat' : 'flutter',
    );

    Future<String?> fetch(FakeProcessRunner runner) => fetchPackages(
      project,
      flutterRoot: 'sdk',
      os: HostOs.current,
      runner: runner,
    );

    test('runs flutter pub get in the project', () async {
      final runner = FakeProcessRunner()
        ..when(flutter, ['pub', 'get'], const RunResult(exitCode: 0));
      writeFetched(project);
      expect(await fetch(runner), isNull);
      expect(runner.calls, ['$flutter pub get']);
      expect(runner.workingDirectories, [project]);
    });

    test('a failed pub get says so, with the end of its output', () async {
      final output = [for (var i = 1; i <= 15; i++) 'e${'$i'.padLeft(2, '0')}'];
      final runner = FakeProcessRunner()
        ..when(
          flutter,
          ['pub', 'get'],
          RunResult(exitCode: 69, stderr: output.join('\n')),
        );
      final failure = await fetch(runner);
      expect(failure, startsWith('`flutter pub get` failed with exit code 69:'));
      expect(failure, contains('e06\n'));
      expect(failure, endsWith('e15'));
      expect(failure, isNot(contains('e05')));
    });

    test('a Flutter that cannot start is reported', () async {
      expect(
        await fetch(FakeProcessRunner()),
        startsWith('Flutter could not be started'),
      );
    });

    test('a pub get that runs too long is reported', () async {
      final runner = FakeProcessRunner()
        ..when(
          flutter,
          ['pub', 'get'],
          const RunResult.timedOut(stdout: '', stderr: ''),
        );
      expect(
        await fetch(runner),
        '`flutter pub get` did not finish within 5 minutes',
      );
    });

    test('a pub get that leaves no package config is a failure', () async {
      final runner = FakeProcessRunner()
        ..when(flutter, ['pub', 'get'], const RunResult(exitCode: 0));
      expect(
        await fetch(runner),
        '`flutter pub get` finished but did not create '
        '.dart_tool/package_config.json',
      );
    });
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/host/process_runner_test.dart test/map/project_packages_test.dart`
Expected: FAIL. There is no `workingDirectory` parameter, and no `checkPackages` or `fetchPackages`.

- [ ] **Step 3: Add `workingDirectory` to the process runner**

In `packages/appstein_engine/lib/src/host/process_runner.dart`:
- in the interface `ProcessRunner.run`, add the named parameter `String? workingDirectory,` after `environment`, and extend its doc comment with: "The tool runs in [workingDirectory], or in Appstein's own working folder when it is null.";
- in `SystemProcessRunner.run`, add the same parameter and pass `workingDirectory: workingDirectory,` to `Process.start`.

In `packages/appstein_engine/test/support/fake_process_runner.dart`, add the field and record each call's folder:

```dart
  /// The working directory of every command run, in the order of [calls].
  final List<String?> workingDirectories = [];
```

and change `run` to:

```dart
  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    final key = _key(executable, arguments);
    calls.add(key);
    workingDirectories.add(workingDirectory);
    return _results[key] ?? RunResult.notStarted('not faked: $key');
  }
```

- [ ] **Step 4: Implement the package check and the fetch**

Create `packages/appstein_engine/lib/src/map/project_packages.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../host/host_environment.dart';
import '../host/process_runner.dart';

/// Whether a project's packages can be used as they are (spec §6.5).
final class PackagesStatus {
  /// Creates the status.
  const PackagesStatus({
    required this.fresh,
    required this.reason,
    required this.workspaceRoot,
  });

  /// Whether `flutter pub get` can be skipped, by Flutter's own rule.
  final bool fresh;

  /// Why the packages are fresh or not, in words that follow "because",
  /// such as "pubspec.yaml changed after they were fetched".
  final String reason;

  /// The folder that holds `.dart_tool/package_config.json` and
  /// `pubspec.lock`: the project itself, or the root of its pub workspace.
  final String workspaceRoot;
}

/// Decides whether the project at [projectRoot] needs `flutter pub get`
/// before it can be analyzed. It uses the rule that `flutter run`,
/// `flutter analyze` and `flutter test` use (flutter_tools'
/// `pub.dart`, `get` with `checkUpToDate`), for the Flutter framework
/// version [flutterVersion].
///
/// In a pub workspace, the package config and lock file are read from the
/// workspace root that `.dart_tool/pub/workspace_ref.json` names. Flutter's
/// code joins that folder as if it were the file, so it always re-fetches
/// there; Appstein reads what the reference means (see the developer
/// guide's project-map page).
PackagesStatus checkPackages(
  String projectRoot, {
  required String flutterVersion,
}) {
  final workspaceRoot = _workspaceRoot(projectRoot);
  PackagesStatus status(bool fresh, String reason) => PackagesStatus(
    fresh: fresh,
    reason: reason,
    workspaceRoot: workspaceRoot,
  );
  try {
    final config = File(
      p.join(workspaceRoot, '.dart_tool', 'package_config.json'),
    );
    if (!config.existsSync()) {
      return status(
        false,
        'they had not been fetched (there was no '
        '.dart_tool/package_config.json)',
      );
    }
    final generator = _generator(config);
    if (generator != null && generator != 'pub') {
      return status(
        true,
        'the package config was written by $generator, so it is used as '
        'it is',
      );
    }
    final lock = File(p.join(workspaceRoot, 'pubspec.lock'));
    if (!lock.existsSync()) return status(false, 'there was no pubspec.lock');
    final pubspecTime = File(
      p.join(projectRoot, 'pubspec.yaml'),
    ).lastModifiedSync();
    if (!pubspecTime.isBefore(lock.lastModifiedSync()) ||
        !pubspecTime.isBefore(config.lastModifiedSync())) {
      return status(false, 'pubspec.yaml changed after they were fetched');
    }
    final version = File(p.join(workspaceRoot, '.dart_tool', 'version'));
    if (!version.existsSync()) {
      return status(
        false,
        'they were not fetched by Flutter (there was no .dart_tool/version)',
      );
    }
    // Compared exactly, as Flutter does: it writes the file without a
    // newline.
    final fetchedWith = version.readAsStringSync();
    if (fetchedWith != flutterVersion) {
      return status(
        false,
        'they were fetched with Flutter ${fetchedWith.trim()}, not '
        '$flutterVersion',
      );
    }
    return status(true, 'they are up to date');
  } on FileSystemException catch (error) {
    return status(
      false,
      'they could not be checked (${fileErrorReason(error)})',
    );
  }
}

/// Runs `flutter pub get` in [projectRoot] with the Flutter SDK at
/// [flutterRoot], as `flutter run` does when the packages are stale.
///
/// Returns null when it worked. Otherwise it returns why it didn't, ending
/// with the last lines Flutter printed.
Future<String?> fetchPackages(
  String projectRoot, {
  required String flutterRoot,
  required HostOs os,
  required ProcessRunner runner,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final flutter = p.join(
    flutterRoot,
    'bin',
    os == HostOs.windows ? 'flutter.bat' : 'flutter',
  );
  final result = await runner.run(
    flutter,
    const ['pub', 'get'],
    timeout: timeout,
    workingDirectory: projectRoot,
  );
  if (!result.started) {
    return 'Flutter could not be started (${result.stderr.trim()})';
  }
  if (result.timedOut) {
    return '`flutter pub get` did not finish within ${timeout.inMinutes} '
        'minutes';
  }
  if (result.exitCode != 0) {
    final output = result.stderr.trim().isEmpty
        ? result.stdout.trim()
        : result.stderr.trim();
    return '`flutter pub get` failed with exit code ${result.exitCode}'
        '${output.isEmpty ? '' : ':\n${_lastLines(output, 10)}'}';
  }
  final config = File(
    p.join(_workspaceRoot(projectRoot), '.dart_tool', 'package_config.json'),
  );
  if (!config.existsSync()) {
    return '`flutter pub get` finished but did not create '
        '.dart_tool/package_config.json';
  }
  return null;
}

String _workspaceRoot(String projectRoot) {
  final reference = File(
    p.join(projectRoot, '.dart_tool', 'pub', 'workspace_ref.json'),
  );
  if (!reference.existsSync()) return projectRoot;
  try {
    if (jsonDecode(reference.readAsStringSync()) case {
      'workspaceRoot': final String root,
    }) {
      return p.normalize(p.join(reference.parent.path, root));
    }
  } on FormatException {
    // A damaged reference: like Flutter, use the project's own files.
  } on FileSystemException {
    // Unreadable: the same.
  }
  return projectRoot;
}

String? _generator(File config) {
  try {
    if (jsonDecode(config.readAsStringSync()) case {
      'generator': final String generator,
    }) {
      return generator;
    }
  } on FormatException {
    // Flutter treats a damaged config as one that pub wrote.
  }
  return null;
}

String _lastLines(String text, int count) {
  final lines = const LineSplitter().convert(text);
  return lines.skip(lines.length > count ? lines.length - count : 0).join('\n');
}
```

In `packages/appstein_engine/lib/appstein_engine.dart`, add `export 'src/map/project_packages.dart';` after the `src/knowledge/...` exports.

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/host/process_runner_test.dart test/map/project_packages_test.dart`
Expected: PASS. Then run the whole engine suite (`fvm dart test`): nothing else should change.

- [ ] **Step 6: Commit**

```bash
git add packages/appstein_engine
git commit -m "feat(map): decide when to run flutter pub get, as Flutter does"
```

---

### Task 4: The fixture app, and the resolved project analysis

**Files:**
- Create: every fixture file listed in Step 1, under `packages/appstein_engine/test/fixtures/apps/`
- Create: `packages/appstein_engine/test/support/fixture_app.dart`
- Create: `packages/appstein_engine/lib/src/map/project_analysis.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart`
- Test: `packages/appstein_engine/test/map/project_analysis_test.dart`

**Interfaces:**
- Consumes: `tempDir()`.
- Produces:
  - Test support:
    - `String copyFixtureApp({bool stubs = true, String flutterVersion = '3.47.5'})`: the copied app's folder, `<temp>/mvvm app`.
    - `void writeStubPackages(String project, {List<String> packages, String flutterVersion})`.
    - `String get testDartSdk`.
    - `int lineOf(String project, String file, String text)`.
    - `String get fixtureAppsDir`.
  - `ProjectAnalysis.analyze(String projectRoot, {required String dartSdkPath})` → `Future<ProjectAnalysis>`.
  - `ProjectAnalysis` members:
    - `projectRoot`, `packageName` (`String?`), `libraries` (`List<AnalyzedLibrary>`);
    - `relativePath(String) → String?`;
    - `locationOf(Fragment) → ({String file, int line})?`;
    - `importsOf(ResolvedUnitResult) → List<ProjectImport>`;
    - `dispose()`;
    - `static const folders = ['lib', 'test', 'testing']`.
  - `AnalyzedLibrary(path, result)`; `ProjectImport({file, line, library})`; `ProjectAnalysisException(message)`.

The fixture app is shaped like Flutter's compass_app (`lib/ui/<feature>/{view_models,widgets}`, `ui/core`, `data/{repositories,services,model}`, `domain/{models,use_cases}`, `routing`, `config`, `utils`, `test/`, `testing/`). It also has what compass_app lacks:
- a nested feature (`auth/login`), a feature without a view model (`settings`), and a view model behind an abstract base class;
- a layer violation;
- routes that can't be resolved: a non-constant path, a builder with two returns, and a builder that returns a Flutter widget;
- a shell route and a stateful shell route.

Its code must be valid with **both** the stand-in packages and the real `flutter` and `go_router` 18 (Task 12 runs it with the real ones). So it uses only API the stand-ins also declare.

- [ ] **Step 1: Create the fixture files**

Every file below ends in `.fixture`, and its content is exactly the code block. Paths are relative to `packages/appstein_engine/test/fixtures/apps/`.

`stubs/flutter/lib/foundation.dart.fixture`:

```dart
// A stand-in for package:flutter, with only what the project-map tests
// read. Same names as the real Flutter.
class ChangeNotifier {
  void notifyListeners() {}

  void dispose() {}
}

class Key {
  const Key(this.value);

  final String value;
}
```

`stubs/flutter/lib/widgets.dart.fixture`:

```dart
export 'foundation.dart';

import 'foundation.dart';

abstract class BuildContext {}

abstract class Widget {
  const Widget({this.key});

  final Key? key;
}

abstract class StatelessWidget extends Widget {
  const StatelessWidget({super.key});

  Widget build(BuildContext context);
}

class Text extends StatelessWidget {
  const Text(this.data, {super.key});

  final String data;

  @override
  Widget build(BuildContext context) => this;
}

abstract class Page<T> {
  const Page({this.key});

  final Key? key;
}
```

`stubs/flutter_test/lib/flutter_test.dart.fixture`:

```dart
// A stand-in for package:flutter_test.
abstract class WidgetTester {}

typedef WidgetTesterCallback = Future<void> Function(WidgetTester tester);

void testWidgets(String description, WidgetTesterCallback callback) {}

void test(Object? description, dynamic Function() body) {}

void expect(Object? actual, Object? matcher) {}

const Object isNotNull = 'isNotNull';

const Object isEmpty = 'isEmpty';
```

`stubs/go_router/lib/go_router.dart.fixture`:

```dart
// A stand-in for package:go_router 18, with the constructors the fixture
// app uses. Same names and parameters as the real package.
import 'dart:async';

import 'package:flutter/widgets.dart';

abstract class GoRouterState {}

typedef GoRouterWidgetBuilder =
    Widget Function(BuildContext context, GoRouterState state);
typedef GoRouterPageBuilder =
    Page<dynamic> Function(BuildContext context, GoRouterState state);
typedef GoRouterRedirect =
    FutureOr<String?> Function(BuildContext context, GoRouterState state);
typedef ShellRouteBuilder =
    Widget Function(BuildContext context, GoRouterState state, Widget child);
typedef StatefulShellRouteBuilder =
    Widget Function(
      BuildContext context,
      GoRouterState state,
      StatefulNavigationShell navigationShell,
    );

abstract class RouteBase {
  const RouteBase({this.routes = const []});

  final List<RouteBase> routes;
}

class GoRoute extends RouteBase {
  const GoRoute({
    required this.path,
    this.name,
    this.builder,
    this.pageBuilder,
    this.redirect,
    super.routes,
  });

  final String path;
  final String? name;
  final GoRouterWidgetBuilder? builder;
  final GoRouterPageBuilder? pageBuilder;
  final GoRouterRedirect? redirect;
}

class ShellRoute extends RouteBase {
  const ShellRoute({this.builder, required super.routes});

  final ShellRouteBuilder? builder;
}

class StatefulNavigationShell extends StatelessWidget {
  const StatefulNavigationShell({super.key});

  @override
  Widget build(BuildContext context) => this;
}

class StatefulShellBranch {
  const StatefulShellBranch({required this.routes});

  final List<RouteBase> routes;
}

class StatefulShellRoute extends RouteBase {
  const StatefulShellRoute.indexedStack({required this.branches, this.builder});

  final List<StatefulShellBranch> branches;
  final StatefulShellRouteBuilder? builder;
}

class NoTransitionPage<T> extends Page<T> {
  const NoTransitionPage({required this.child, super.key});

  final Widget child;
}

class RoutingConfig {
  const RoutingConfig({required this.routes});

  final List<RouteBase> routes;
}

class GoRouter {
  GoRouter({
    required List<RouteBase> routes,
    String? initialLocation,
    GoRouterRedirect? redirect,
  });

  GoRouter.routingConfig({required Object routingConfig});
}
```

`stubs/pubspec.lock.fixture`:

```yaml
# The lock file the stand-in packages pretend pub wrote.
packages:
  collection:
    dependency: transitive
    description:
      name: collection
      sha256: "0000000000000000000000000000000000000000000000000000000000000000"
      url: "https://pub.dev"
    source: hosted
    version: "1.19.1"
  flutter:
    dependency: "direct main"
    description: flutter
    source: sdk
    version: "0.0.0"
  flutter_test:
    dependency: "direct dev"
    description: flutter
    source: sdk
    version: "0.0.0"
  go_router:
    dependency: "direct main"
    description:
      name: go_router
      sha256: "0000000000000000000000000000000000000000000000000000000000000000"
      url: "https://pub.dev"
    source: hosted
    version: "18.0.2"
sdks:
  dart: ">=3.12.0 <4.0.0"
  flutter: ">=3.44.0"
```

`mvvm_app/pubspec.yaml.fixture`:

```yaml
name: fixture_app
description: The app Appstein's project-map tests read.
publish_to: none

environment:
  sdk: ^3.12.0

dependencies:
  flutter:
    sdk: flutter
  go_router: ^18.0.0

dev_dependencies:
  flutter_test:
    sdk: flutter
```

`mvvm_app/lib/main.dart.fixture`:

```dart
import 'config/dependencies.dart';
import 'routing/router.dart';

/// Starts the fixture app: builds its dependencies and its router.
void main() {
  router(Dependencies());
}
```

`mvvm_app/lib/config/dependencies.dart.fixture`:

```dart
import '../data/repositories/auth/auth_repository.dart';
import '../data/repositories/auth/auth_repository_remote.dart';
import '../data/repositories/booking/booking_repository.dart';
import '../data/repositories/booking/booking_repository_remote.dart';
import '../data/services/analytics_service.dart';
import '../data/services/api/api_client.dart';
import '../domain/use_cases/booking_create_use_case.dart';

/// Builds the app's repositories, services and use cases once.
final class Dependencies {
  /// Creates them, all talking to one [ApiClient].
  Dependencies() : _apiClient = ApiClient();

  final ApiClient _apiClient;

  /// Signs the user in and out.
  late final AuthRepository authRepository = AuthRepositoryRemote(
    apiClient: _apiClient,
  );

  /// Reads and writes bookings.
  late final BookingRepository bookingRepository = BookingRepositoryRemote(
    apiClient: _apiClient,
  );

  /// Records what the user does.
  late final AnalyticsService analytics = _NoAnalytics();

  /// Books trips.
  late final BookingCreateUseCase createBooking = BookingCreateUseCase(
    bookingRepository: bookingRepository,
  );

  /// Whether the settings tab shows the profile instead.
  bool showProfileInSettings = false;
}

final class _NoAnalytics implements AnalyticsService {
  @override
  void record(String event) {}
}
```

`mvvm_app/lib/data/model/booking_api_model.dart.fixture`:

```dart
/// A booking as the server sends it.
class BookingApiModel {
  /// Creates a booking with its server [id].
  const BookingApiModel({required this.id});

  /// The server's id for the booking.
  final int id;
}
```

`mvvm_app/lib/data/services/api/api_client.dart.fixture`:

```dart
import '../../model/booking_api_model.dart';

/// Talks to the booking server.
class ApiClient {
  /// The bookings the server has.
  Future<List<BookingApiModel>> getBookings() async => const [];

  /// Whether a user is signed in on the server.
  bool get hasSession => false;
}
```

`mvvm_app/lib/data/services/analytics_service.dart.fixture`:

```dart
/// Records what the user does in the app.
abstract interface class AnalyticsService {
  /// Records [event].
  void record(String event);
}
```

`mvvm_app/lib/data/repositories/auth/auth_repository.dart.fixture`:

```dart
/// Signs the user in and out.
abstract class AuthRepository {
  /// Whether a user is signed in.
  bool get isSignedIn;

  /// Signs in with [email] and [password].
  Future<void> login({required String email, required String password});
}
```

`mvvm_app/lib/data/repositories/auth/auth_repository_remote.dart.fixture`:

```dart
import '../../services/api/api_client.dart';
import 'auth_repository.dart';

/// Signs the user in and out through the booking server.
class AuthRepositoryRemote implements AuthRepository {
  /// Creates the repository on top of [apiClient].
  AuthRepositoryRemote({required ApiClient apiClient})
    : _apiClient = apiClient;

  final ApiClient _apiClient;

  @override
  bool get isSignedIn => _apiClient.hasSession;

  @override
  Future<void> login({required String email, required String password}) async {}
}
```

`mvvm_app/lib/data/repositories/booking/booking_repository.dart.fixture`:

```dart
import '../../../domain/models/booking.dart';

/// Reads and writes the user's bookings.
abstract interface class BookingRepository {
  /// The user's bookings, newest first.
  Future<List<Booking>> getBookings();

  /// Saves [booking].
  Future<void> createBooking(Booking booking);
}
```

`mvvm_app/lib/data/repositories/booking/booking_repository_remote.dart.fixture`:

```dart
import '../../../domain/models/booking.dart';
import '../../services/api/api_client.dart';
import 'booking_repository.dart';

/// Reads and writes bookings on the booking server.
class BookingRepositoryRemote implements BookingRepository {
  /// Creates the repository on top of [apiClient].
  BookingRepositoryRemote({required ApiClient apiClient})
    : _apiClient = apiClient;

  final ApiClient _apiClient;

  @override
  Future<List<Booking>> getBookings() async => [
    for (final booking in await _apiClient.getBookings())
      Booking(id: booking.id, destination: ''),
  ];

  @override
  Future<void> createBooking(Booking booking) async {}
}
```

`mvvm_app/lib/domain/models/booking.dart.fixture` (a two-line first sentence, and a second paragraph):

```dart
/// A trip the user has booked. It holds where they go,
/// and the server's id for it.
///
/// Bookings are created by a use case.
class Booking {
  /// Creates a booking.
  const Booking({required this.id, required this.destination});

  /// The server's id for the booking.
  final int id;

  /// Where the trip goes.
  final String destination;
}
```

`mvvm_app/lib/domain/models/user.dart.fixture` (a summary without a full stop):

```dart
/// The signed-in user
class User {
  /// Creates a user called [name].
  const User({required this.name});

  /// The user's name.
  final String name;
}
```

`mvvm_app/lib/domain/use_cases/booking_create_use_case.dart.fixture` (a use case that imports a repository's *interface*: allowed):

```dart
import '../../data/repositories/booking/booking_repository.dart';
import '../models/booking.dart';

/// Creates a booking and saves it.
class BookingCreateUseCase {
  /// Creates the use case on top of [bookingRepository].
  BookingCreateUseCase({required BookingRepository bookingRepository})
    : _bookingRepository = bookingRepository;

  final BookingRepository _bookingRepository;

  /// Books a trip to [destination].
  Future<Booking> call(String destination) async {
    final booking = Booking(id: 0, destination: destination);
    await _bookingRepository.createBooking(booking);
    return booking;
  }
}
```

`mvvm_app/lib/routing/routes.dart.fixture`:

```dart
/// The app's route paths.
abstract final class Routes {
  /// The home screen.
  static const home = '/';

  /// The login screen.
  static const login = '/login';

  /// The booking screen, below home.
  static const bookingRelative = 'booking';

  /// The booking screen's full path.
  static const booking = '/$bookingRelative';

  /// The settings tab.
  static const settings = '/settings';

  /// The profile tab.
  static const profile = '/profile';
}
```

`mvvm_app/lib/routing/router.dart.fixture`:

```dart
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../config/dependencies.dart';
import '../ui/auth/login/view_models/login_viewmodel.dart';
import '../ui/auth/login/widgets/login_screen.dart';
import '../ui/booking/view_models/booking_viewmodel.dart';
import '../ui/booking/widgets/booking_screen.dart';
import '../ui/home/view_models/home_viewmodel.dart';
import '../ui/home/widgets/home_screen.dart';
import '../ui/profile/widgets/profile_screen.dart';
import '../ui/settings/widgets/settings_screen.dart';
import 'routes.dart';

/// The app's router: login, home with its booking pages, settings in a
/// shell, and profile in a tab.
GoRouter router(Dependencies dependencies) => GoRouter(
  initialLocation: Routes.home,
  redirect: (context, state) =>
      dependencies.authRepository.isSignedIn ? null : Routes.login,
  routes: [
    GoRoute(
      path: Routes.login,
      name: 'login',
      pageBuilder: (context, state) => NoTransitionPage(
        child: LoginScreen(
          viewModel: LoginViewModel(
            authRepository: dependencies.authRepository,
          ),
        ),
      ),
    ),
    GoRoute(
      path: Routes.home,
      builder: (context, state) {
        final viewModel = HomeViewModel(
          bookingRepository: dependencies.bookingRepository,
          analytics: dependencies.analytics,
        );
        return HomeScreen(viewModel: viewModel);
      },
      routes: [
        GoRoute(
          path: Routes.bookingRelative,
          builder: (context, state) => BookingScreen(
            viewModel: BookingViewModel(
              createBooking: dependencies.createBooking,
              bookingRepository: dependencies.bookingRepository,
            ),
          ),
          routes: [
            GoRoute(
              path: ':id',
              redirect: (context, state) => Routes.booking,
            ),
          ],
        ),
        GoRoute(
          path: _searchPath(),
          builder: (context, state) => const SettingsScreen(),
        ),
      ],
    ),
    ShellRoute(
      builder: (context, state, child) => child,
      routes: [
        GoRoute(
          path: Routes.settings,
          builder: (context, state) {
            if (dependencies.showProfileInSettings) {
              return const ProfileScreen();
            }
            return const SettingsScreen();
          },
        ),
      ],
    ),
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) => navigationShell,
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: Routes.profile,
              builder: (context, state) => const ProfileScreen(),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/about',
      builder: (context, state) => const Text('About'),
    ),
  ],
);

String _searchPath() => 'search';
```

`mvvm_app/lib/ui/core/themes/colors.dart.fixture`:

```dart
/// The app's colours, as ARGB values.
abstract final class AppColors {
  /// The main colour.
  static const primary = 0xFF00897B;
}
```

`mvvm_app/lib/ui/core/ui/app_button.dart.fixture`:

```dart
import 'package:flutter/widgets.dart';

import '../themes/colors.dart';

/// The app's button.
class AppButton extends StatelessWidget {
  /// Creates a button that shows [label].
  const AppButton({super.key, required this.label});

  /// The button's text.
  final String label;

  @override
  Widget build(BuildContext context) => Text('$label ${AppColors.primary}');
}
```

`mvvm_app/lib/ui/home/view_models/home_viewmodel.dart.fixture`:

```dart
import 'package:flutter/foundation.dart';

import '../../../data/repositories/booking/booking_repository.dart';
import '../../../data/services/analytics_service.dart';
import '../../../domain/models/booking.dart';

/// Loads the user's bookings for the home screen.
class HomeViewModel extends ChangeNotifier {
  /// Creates the view model on top of [bookingRepository] and [analytics].
  HomeViewModel({
    required BookingRepository bookingRepository,
    required AnalyticsService analytics,
  }) : _bookingRepository = bookingRepository,
       _analytics = analytics;

  final BookingRepository _bookingRepository;
  final AnalyticsService _analytics;

  /// The bookings the home screen shows.
  List<Booking> bookings = const [];

  /// Loads [bookings] again.
  Future<void> load() async {
    _analytics.record('home.load');
    bookings = await _bookingRepository.getBookings();
    notifyListeners();
  }
}
```

`mvvm_app/lib/ui/home/widgets/booking_tile.dart.fixture`:

```dart
import 'package:flutter/widgets.dart';

import '../../../domain/models/booking.dart';

/// One booking in the home screen's list.
class BookingTile extends StatelessWidget {
  /// Creates the tile for [booking].
  const BookingTile({super.key, required this.booking});

  /// The booking it shows.
  final Booking booking;

  @override
  Widget build(BuildContext context) => Text(booking.destination);
}
```

`mvvm_app/lib/ui/home/widgets/home_screen.dart.fixture`:

```dart
import 'package:flutter/widgets.dart';

import '../../../routing/routes.dart';
import '../view_models/home_viewmodel.dart';
import 'booking_tile.dart';

/// Lists the user's bookings.
class HomeScreen extends StatelessWidget {
  /// Creates the screen for [viewModel].
  const HomeScreen({super.key, required this.viewModel});

  /// The screen's state.
  final HomeViewModel viewModel;

  @override
  Widget build(BuildContext context) => viewModel.bookings.isEmpty
      ? const Text(Routes.booking)
      : BookingTile(booking: viewModel.bookings.first);
}
```

`mvvm_app/lib/ui/booking/view_models/base_view_model.dart.fixture`:

```dart
import 'package:flutter/foundation.dart';

/// What every booking view model shares: a busy flag.
abstract class BaseViewModel extends ChangeNotifier {
  /// Whether the view model is waiting for data.
  bool busy = false;
}
```

`mvvm_app/lib/ui/booking/view_models/booking_viewmodel.dart.fixture`:

```dart
import '../../../data/repositories/booking/booking_repository.dart';
import '../../../domain/models/booking.dart';
import '../../../domain/use_cases/booking_create_use_case.dart';
import 'base_view_model.dart';

/// Books a trip and shows the result.
class BookingViewModel extends BaseViewModel {
  /// Creates the view model on top of [createBooking] and
  /// [bookingRepository].
  BookingViewModel({
    required BookingCreateUseCase createBooking,
    required BookingRepository bookingRepository,
  }) : _createBooking = createBooking,
       _bookingRepository = bookingRepository;

  final BookingCreateUseCase _createBooking;
  final BookingRepository _bookingRepository;

  /// The booking just made, if any.
  Booking? booking;

  /// Books a trip to [destination].
  Future<void> book(String destination) async {
    busy = true;
    booking = await _createBooking(destination);
    await _bookingRepository.getBookings();
    busy = false;
    notifyListeners();
  }
}
```

`mvvm_app/lib/ui/booking/widgets/booking_screen.dart.fixture` (the deliberate layer violation):

```dart
import 'package:flutter/widgets.dart';

// A layer violation on purpose: ui may use a repository's interface, and
// this imports its implementation.
import '../../../data/repositories/booking/booking_repository_remote.dart';
import '../view_models/booking_viewmodel.dart';

/// Shows a new booking.
class BookingScreen extends StatelessWidget {
  /// Creates the screen for [viewModel].
  const BookingScreen({
    super.key,
    required this.viewModel,
    this.debugRepository,
  });

  /// The screen's state.
  final BookingViewModel viewModel;

  /// A repository for debugging, which a screen should not hold.
  final BookingRepositoryRemote? debugRepository;

  @override
  Widget build(BuildContext context) =>
      Text(viewModel.booking?.destination ?? '');
}
```

`mvvm_app/lib/ui/auth/login/view_models/login_viewmodel.dart.fixture`:

```dart
import 'package:flutter/foundation.dart';

import '../../../../data/repositories/auth/auth_repository.dart';

/// Signs the user in.
class LoginViewModel extends ChangeNotifier {
  /// Creates the view model on top of [authRepository].
  LoginViewModel({required AuthRepository authRepository})
    : _authRepository = authRepository;

  final AuthRepository _authRepository;

  /// Signs in with [email] and [password].
  Future<void> login(String email, String password) async {
    await _authRepository.login(email: email, password: password);
    notifyListeners();
  }
}
```

`mvvm_app/lib/ui/auth/login/widgets/login_screen.dart.fixture`:

```dart
import 'package:flutter/widgets.dart';

import '../view_models/login_viewmodel.dart';

/// Asks for the user's email and password.
class LoginScreen extends StatelessWidget {
  /// Creates the screen for [viewModel].
  const LoginScreen({super.key, required this.viewModel});

  /// The screen's state.
  final LoginViewModel viewModel;

  @override
  Widget build(BuildContext context) => const Text('Log in');
}
```

`mvvm_app/lib/ui/settings/widgets/settings_screen.dart.fixture`:

```dart
import 'package:flutter/widgets.dart';

import '../../core/ui/app_button.dart';

/// The app's settings.
class SettingsScreen extends StatelessWidget {
  /// Creates the screen.
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => const AppButton(label: 'Sign out');
}
```

`mvvm_app/lib/ui/profile/widgets/profile_screen.dart.fixture`:

```dart
import 'package:flutter/widgets.dart';

/// The user's profile.
class ProfileScreen extends StatelessWidget {
  /// Creates the screen.
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) => const Text('Profile');
}
```

`mvvm_app/lib/utils/result.dart.fixture` (one of each symbol kind, plus declarations the map must skip):

```dart
/// The result of an operation that can fail.
sealed class Result<T> {
  const Result();
}

/// A result with a value.
final class Ok<T> extends Result<T> {
  /// Creates a result holding [value].
  const Ok(this.value);

  /// The value.
  final T value;
}

/// A result with an error.
final class Failure<T> extends Result<T> {
  /// Creates a result holding [error].
  const Failure(this.error);

  /// What went wrong.
  final Object error;
}

/// Logs what a class does.
mixin Loggable {
  /// The log lines so far.
  final List<String> log = [];
}

/// Where a booking stands.
enum BookingStatus {
  /// Waiting for the server.
  pending,

  /// Confirmed by the server.
  confirmed,
}

/// Turns a booking status into words.
extension StatusWords on BookingStatus {
  /// The status in words.
  String get words => name;
}

/// A booking's id, kept apart from other integers.
extension type BookingId(int value) {}

/// A decoded JSON object.
typedef Json = Map<String, Object?>;

/// Describes [status] for the user! Then more.
String describe(BookingStatus status) => status.words;

/// The app's name: a getter, which is not a symbol kind.
String get appName => 'Fixture';

extension on int {
  int get doubled => this * 2;
}

class _Hidden {}

/// Uses the private declarations, so they aren't unused.
int useHidden() => [_Hidden()].length + 1.doubled;
```

`mvvm_app/test/ui/home/widgets/home_screen_test.dart.fixture`:

```dart
import 'package:fixture_app/ui/home/widgets/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the screen exists', (tester) async {
    expect(HomeScreen, isNotNull);
  });
}
```

`mvvm_app/test/ui/booking/view_models/booking_viewmodel_test.dart.fixture`:

```dart
import 'package:fixture_app/domain/use_cases/booking_create_use_case.dart';
import 'package:fixture_app/ui/booking/view_models/booking_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../testing/fakes/fake_booking_repository.dart';

void main() {
  test('books a trip', () async {
    final repository = FakeBookingRepository();
    final viewModel = BookingViewModel(
      createBooking: BookingCreateUseCase(bookingRepository: repository),
      bookingRepository: repository,
    );
    await viewModel.book('Lisbon');
    expect(viewModel.booking, isNotNull);
  });
}
```

`mvvm_app/test/data/booking_repository_test.dart.fixture`:

```dart
import 'package:fixture_app/data/repositories/booking/booking_repository_remote.dart';
import 'package:fixture_app/data/services/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts with no bookings', () async {
    final repository = BookingRepositoryRemote(apiClient: ApiClient());
    expect(await repository.getBookings(), isEmpty);
  });
}
```

`mvvm_app/testing/fakes/fake_booking_repository.dart.fixture`:

```dart
import 'package:fixture_app/data/repositories/booking/booking_repository.dart';
import 'package:fixture_app/domain/models/booking.dart';

/// A booking repository that keeps bookings in memory.
class FakeBookingRepository implements BookingRepository {
  final List<Booking> _bookings = [];

  @override
  Future<List<Booking>> getBookings() async => _bookings;

  @override
  Future<void> createBooking(Booking booking) async => _bookings.add(booking);
}
```

- [ ] **Step 2: Create the test support**

`packages/appstein_engine/test/support/fixture_app.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'temp.dart';

/// `test/fixtures/apps`, found from the package itself, not from
/// `Directory.current` (other test files change the working folder).
String get fixtureAppsDir {
  final library = Isolate.resolvePackageUriSync(
    Uri.parse('package:appstein_engine/appstein_engine.dart'),
  )!;
  return p.join(
    p.dirname(p.dirname(library.toFilePath())),
    'test',
    'fixtures',
    'apps',
  );
}

/// The Dart SDK running the tests. The analyzer reads `dart:` libraries
/// from its `lib/`.
String get testDartSdk => p.dirname(p.dirname(Platform.resolvedExecutable));

/// Copies the files under [from] into [to], dropping the `.fixture` suffix
/// from their names.
void copyFixtureTree(String from, String to) {
  for (final entity in Directory(from).listSync(recursive: true)) {
    if (entity is! File) continue;
    var relative = p.relative(entity.path, from: from);
    if (relative.endsWith('.fixture')) {
      relative = relative.substring(0, relative.length - '.fixture'.length);
    }
    final target = File(p.join(to, relative))..parent.createSync(recursive: true);
    entity.copySync(target.path);
  }
}

/// Copies the fixture app into a new temp folder, as `mvvm app`, and
/// returns that folder.
///
/// With [stubs], the stand-in `flutter`, `flutter_test` and `go_router`
/// packages are copied beside it into `stubs/`, and the app gets a lock file
/// and a package config that point at them. Its packages then count as
/// fresh for Flutter [flutterVersion], so it analyzes like a real app
/// without a Flutter SDK or the network. Without [stubs], only the app is
/// copied, for a real `flutter pub get`.
String copyFixtureApp({bool stubs = true, String flutterVersion = '3.47.5'}) {
  final work = tempDir().path;
  final app = p.join(work, 'mvvm app');
  copyFixtureTree(p.join(fixtureAppsDir, 'mvvm_app'), app);
  if (!stubs) return app;
  final stubFolder = p.join(work, 'stubs');
  copyFixtureTree(p.join(fixtureAppsDir, 'stubs'), stubFolder);
  File(
    p.join(stubFolder, 'pubspec.lock'),
  ).copySync(p.join(app, 'pubspec.lock'));
  writeStubPackages(
    app,
    packages: const ['flutter', 'flutter_test', 'go_router'],
    flutterVersion: flutterVersion,
  );
  return app;
}

/// Makes [project] count as having fresh packages:
/// - `.dart_tool/package_config.json` maps the project's own package (its
///   pubspec `name:`) and each of [packages], which live in `../stubs/`;
/// - `.dart_tool/version` is [flutterVersion];
/// - `pubspec.yaml` gets an older time than `pubspec.lock` (created empty
///   when missing) and the package config.
void writeStubPackages(
  String project, {
  List<String> packages = const [],
  String flutterVersion = '3.47.5',
}) {
  final name = RegExp(r'^name:\s*(\S+)', multiLine: true)
      .firstMatch(File(p.join(project, 'pubspec.yaml')).readAsStringSync())!
      .group(1)!;
  Map<String, Object?> entry(String package, String rootUri) => {
    'name': package,
    'rootUri': rootUri,
    'packageUri': 'lib/',
    'languageVersion': '3.12',
  };
  final config = File(p.join(project, '.dart_tool', 'package_config.json'))
    ..parent.createSync(recursive: true);
  config.writeAsStringSync(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        entry(name, '../'),
        for (final package in packages) entry(package, '../../stubs/$package'),
      ],
      'generator': 'pub',
    }),
  );
  File(
    p.join(project, '.dart_tool', 'version'),
  ).writeAsStringSync(flutterVersion);
  final lock = File(p.join(project, 'pubspec.lock'));
  if (!lock.existsSync()) lock.writeAsStringSync('packages: {}\n');
  final now = DateTime.now();
  File(
    p.join(project, 'pubspec.yaml'),
  ).setLastModifiedSync(now.subtract(const Duration(hours: 1)));
  lock.setLastModifiedSync(now);
  config.setLastModifiedSync(now);
}

/// The 1-based line of the first line of [file] (relative to [project],
/// with `/`) that contains [text]. Tests use it instead of hard-coding line
/// numbers.
int lineOf(String project, String file, String text) {
  final lines = File(
    p.joinAll([project, ...file.split('/')]),
  ).readAsLinesSync();
  final index = lines.indexWhere((line) => line.contains(text));
  if (index < 0) throw StateError('"$text" is not in $file');
  return index + 1;
}
```

- [ ] **Step 3: Write the failing tests**

Create `packages/appstein_engine/test/map/project_analysis_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/temp.dart';

void main() {
  Future<ProjectAnalysis> analyze(String project) async {
    final analysis = await ProjectAnalysis.analyze(
      project,
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    return analysis;
  }

  AnalyzedLibrary library(ProjectAnalysis analysis, String path) =>
      analysis.libraries.singleWhere((l) => l.path == path);

  test("the tests' Dart SDK has dart:core", () {
    expect(
      File(p.join(testDartSdk, 'lib', 'core', 'core.dart')).existsSync(),
      isTrue,
    );
  });

  test('analyzes lib/, test/ and testing/, sorted, with the package '
      'name', () async {
    final analysis = await analyze(copyFixtureApp());
    expect(analysis.packageName, 'fixture_app');
    final paths = [for (final l in analysis.libraries) l.path];
    expect(paths, hasLength(31));
    expect(paths, containsAll([
      'lib/main.dart',
      'test/ui/home/widgets/home_screen_test.dart',
      'testing/fakes/fake_booking_repository.dart',
    ]));
    expect(paths, orderedEquals([...paths]..sort()));
  });

  test('names resolve through the stand-in packages, and locations are '
      'project-relative and 1-based', () async {
    final app = copyFixtureApp();
    final analysis = await analyze(app);
    const file = 'lib/ui/home/view_models/home_viewmodel.dart';
    final viewModel = library(analysis, file).result.element.classes.single;
    expect(
      viewModel.allSupertypes.map((t) => t.element.name),
      contains('ChangeNotifier'),
    );
    final location = analysis.locationOf(viewModel.firstFragment)!;
    expect(location.file, file);
    expect(location.line, lineOf(app, file, 'class HomeViewModel'));
  });

  test('imports of project files resolve to project paths, package: URIs '
      'included', () async {
    final app = copyFixtureApp();
    final analysis = await analyze(app);
    const file = 'test/ui/home/widgets/home_screen_test.dart';
    final unit = library(analysis, file).result.units.single;
    final imports = analysis.importsOf(unit);
    // package:flutter_test is outside the project, so it isn't listed.
    expect([for (final i in imports) i.file], [
      'lib/ui/home/widgets/home_screen.dart',
    ]);
    expect(imports.single.line, lineOf(app, file, 'home_screen.dart'));
    expect(imports.single.library.classes.single.name, 'HomeScreen');
  });

  test('code with errors still resolves', () async {
    final app = copyFixtureApp();
    File(p.join(app, 'lib', 'broken.dart')).writeAsStringSync(
      "import 'nowhere.dart';\n\nclass Broken extends Missing {}\n",
    );
    final analysis = await analyze(app);
    final broken = library(analysis, 'lib/broken.dart').result;
    expect(broken.units.single.diagnostics, isNotEmpty);
    expect(broken.element.classes.single.name, 'Broken');
  });

  test('a project without lib/, test/ or testing/ has no libraries', () async {
    final project = p.join(tempDir().path, 'empty app');
    Directory(project).createSync();
    File(
      p.join(project, 'pubspec.yaml'),
    ).writeAsStringSync('name: empty_app\n');
    final analysis = await analyze(project);
    expect(analysis.libraries, isEmpty);
    expect(analysis.packageName, 'empty_app');
  });

  test('an incomplete Dart SDK is a ProjectAnalysisException', () async {
    final sdk = p.join(tempDir().path, 'dart-sdk');
    Directory(sdk).createSync();
    await expectLater(
      ProjectAnalysis.analyze(copyFixtureApp(), dartSdkPath: sdk),
      throwsA(
        isA<ProjectAnalysisException>().having(
          (e) => e.message,
          'message',
          contains('lib/core/core.dart'),
        ),
      ),
    );
  });

  test('relativePath uses / and rejects files outside the project', () async {
    final app = copyFixtureApp();
    final analysis = await analyze(app);
    expect(
      analysis.relativePath(p.join(app, 'lib', 'routing', 'router.dart')),
      'lib/routing/router.dart',
    );
    expect(analysis.relativePath(p.join(app, '..', 'stubs')), isNull);
  });
}
```

- [ ] **Step 4: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/map/project_analysis_test.dart`
Expected: FAIL. `ProjectAnalysis` doesn't exist.

- [ ] **Step 5: Implement `ProjectAnalysis`**

Create `packages/appstein_engine/lib/src/map/project_analysis.dart`:

```dart
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// One analyzed Dart library of the project, with its parts.
final class AnalyzedLibrary {
  /// Creates the entry.
  const AnalyzedLibrary(this.path, this.result);

  /// The library's file, relative to the project, with `/`.
  final String path;

  /// The analyzer's resolved library: its element and every unit's AST.
  final ResolvedLibraryResult result;
}

/// An import or export of another file of the project.
final class ProjectImport {
  /// Creates the entry.
  const ProjectImport({
    required this.file,
    required this.line,
    required this.library,
  });

  /// The imported file, relative to the project, with `/`.
  final String file;

  /// The 1-based line of the directive's URI.
  final int line;

  /// The imported library.
  final LibraryElement library;
}

/// Thrown when the project can't be analyzed at all, for example because
/// the Dart SDK is incomplete.
final class ProjectAnalysisException implements Exception {
  /// Creates the exception.
  const ProjectAnalysisException(this.message);

  /// What is wrong, for the person running `appstein sync`.
  final String message;

  @override
  String toString() => message;
}

/// The resolved Dart code of a project (spec §6.5): every library under
/// [folders], resolved by `package:analyzer` against the project's packages.
///
/// The project's `.dart_tool/package_config.json` must exist, so check the
/// packages first (`checkPackages`). Code with errors still resolves as far
/// as it can. Call [dispose] when done.
final class ProjectAnalysis {
  ProjectAnalysis._(
    this.projectRoot,
    this.packageName,
    this.libraries,
    this._collection,
  );

  /// The folders whose Dart files are analyzed.
  static const folders = ['lib', 'test', 'testing'];

  /// Analyzes the project at [projectRoot], reading `dart:` libraries from
  /// the Dart SDK at [dartSdkPath] (inside a Flutter SDK, that is
  /// `bin/cache/dart-sdk`).
  ///
  /// Throws a [ProjectAnalysisException] when that SDK has no
  /// `lib/core/core.dart`.
  static Future<ProjectAnalysis> analyze(
    String projectRoot, {
    required String dartSdkPath,
  }) async {
    // The analyzer accepts only absolute, normalized paths.
    final root = p.normalize(p.absolute(projectRoot));
    final sdk = p.normalize(p.absolute(dartSdkPath));
    if (!File(p.join(sdk, 'lib', 'core', 'core.dart')).existsSync()) {
      throw ProjectAnalysisException(
        'The Dart SDK at $sdk is incomplete: it has no lib/core/core.dart.',
      );
    }
    final included = [
      for (final folder in folders)
        if (Directory(p.join(root, folder)).existsSync()) p.join(root, folder),
    ];
    final name = _packageName(root);
    if (included.isEmpty) return ProjectAnalysis._(root, name, const [], null);
    final collection = AnalysisContextCollection(
      includedPaths: included,
      sdkPath: sdk,
    );
    final libraries = <String, AnalyzedLibrary>{};
    for (final context in collection.contexts) {
      final files =
          context.contextRoot
              .analyzedFiles()
              .where((file) => file.endsWith('.dart'))
              .toList()
            ..sort();
      for (final file in files) {
        final result = await context.currentSession.getResolvedLibrary(file);
        // A part file isn't a library: its library lists it in `units`.
        if (result is! ResolvedLibraryResult) continue;
        final path = _relative(root, file);
        if (path == null) continue;
        libraries[path] = AnalyzedLibrary(path, result);
      }
    }
    final sorted = libraries.keys.toList()..sort();
    return ProjectAnalysis._(
      root,
      name,
      [for (final path in sorted) libraries[path]!],
      collection,
    );
  }

  /// The project folder, absolute and normalized.
  final String projectRoot;

  /// The package's `name:` from `pubspec.yaml`, or null.
  final String? packageName;

  /// The analyzed libraries, sorted by path.
  final List<AnalyzedLibrary> libraries;

  final AnalysisContextCollection? _collection;

  /// [absolutePath] relative to the project, with `/`, or null when it is
  /// outside the project (the SDK, the pub cache).
  String? relativePath(String absolutePath) =>
      _relative(projectRoot, absolutePath);

  /// Where [fragment]'s name is: its file, relative to the project, and the
  /// 1-based line. Null when it is outside the project or has no name.
  ({String file, int line})? locationOf(Fragment fragment) {
    final library = fragment.libraryFragment;
    final offset = fragment.nameOffset;
    if (library == null || offset == null) return null;
    final file = relativePath(library.source.fullName);
    if (file == null) return null;
    return (file: file, line: library.lineInfo.getLocation(offset).lineNumber);
  }

  /// The imports and exports in [unit] that resolve to a file of the
  /// project, in source order. A conditional import counts by its main
  /// URI, as in the `layer_imports` lint.
  List<ProjectImport> importsOf(ResolvedUnitResult unit) => [
    for (final directive in unit.unit.directives)
      if (_imported(directive) case final library?)
        if (relativePath(library.firstFragment.source.fullName)
            case final file?)
          ProjectImport(
            file: file,
            line: unit.lineInfo
                .getLocation((directive as UriBasedDirective).uri.offset)
                .lineNumber,
            library: library,
          ),
  ];

  /// Releases the analyzer.
  Future<void> dispose() async => _collection?.dispose();

  static LibraryElement? _imported(Directive directive) => switch (directive) {
    ImportDirective(:final libraryImport) => libraryImport?.importedLibrary,
    ExportDirective(:final libraryExport) => libraryExport?.exportedLibrary,
    _ => null,
  };

  static String? _relative(String root, String path) {
    final normalized = p.normalize(path);
    if (!p.isWithin(root, normalized)) return null;
    return p.split(p.relative(normalized, from: root)).join('/');
  }

  static String? _packageName(String root) {
    try {
      final pubspec = loadYaml(
        File(p.join(root, 'pubspec.yaml')).readAsStringSync(),
      );
      return pubspec is Map && pubspec['name'] is String
          ? pubspec['name'] as String
          : null;
    } on FileSystemException {
      return null;
    } on YamlException {
      return null;
    }
  }
}
```

In `packages/appstein_engine/lib/appstein_engine.dart`, add `export 'src/map/project_analysis.dart';`.

- [ ] **Step 6: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/map/project_analysis_test.dart`
Expected: PASS. If an analyzer 14.4 name differs from this code (for example `libraryFragment` or `nameOffset` on `Fragment`), look it up in `analyzer-14.4.0/lib/dart/element/element.dart` in the pub cache and use the real name. Record the difference in your report.

- [ ] **Step 7: Commit**

```bash
git add packages/appstein_engine
git commit -m "feat(map): the fixture app, and resolved analysis of a project"
```

---

### Task 5: The pack interface, and `symbols.json`

**Files:**
- Create: `packages/appstein_engine/lib/src/packs/pack.dart`
- Create: `packages/appstein_engine/lib/src/map/map_extractor.dart`
- Create: `packages/appstein_engine/lib/src/map/symbols.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart`
- Test: `packages/appstein_engine/test/map/symbols_test.dart`

**Interfaces:**
- Consumes: `ProjectAnalysis` (Task 4); `MapSymbol`, `SymbolKind`, `SymbolsMap` (Task 2).
- Produces:
  - `enum PackKind { stack, platform }`.
  - `abstract interface class Pack { String get id; PackKind get kind; String get version; List<MapExtractor> get extractors; LayerRules? get layerRules; }`.
  - `abstract interface class MapExtractor { Map<String, Map<String, Object?>> extract(ProjectAnalysis analysis); }`.
  - `SymbolsMap buildSymbols(ProjectAnalysis analysis, {required String? Function(String file) layerOf, required String? Function(String file) featureOf})`.
  - `String? docSummary(String? comment)`.

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/map/symbols_test.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../support/fixture_app.dart';

void main() {
  group('docSummary', () {
    test('takes the first sentence of the first paragraph', () {
      expect(
        docSummary(
          '/// A trip the user has booked. It holds where they go,\n'
          '/// and more.\n///\n/// Second paragraph.',
        ),
        'A trip the user has booked.',
      );
    });

    test('joins a sentence that spans lines', () {
      expect(
        docSummary('/// Loads the bookings\n/// for the home screen. More.'),
        'Loads the bookings for the home screen.',
      );
    });

    test('ends a sentence at ! and ?', () {
      expect(
        docSummary('/// Describes [status] for the user! Then more.'),
        'Describes [status] for the user!',
      );
      expect(docSummary('/// Is it ready? Yes.'), 'Is it ready?');
    });

    test('keeps a paragraph without a full stop whole', () {
      expect(docSummary('/// The signed-in user'), 'The signed-in user');
    });

    test('a full stop inside a word ends nothing', () {
      expect(
        docSummary('/// Uses v1.2 of the API. More.'),
        'Uses v1.2 of the API.',
      );
    });

    test('reads block comments', () {
      expect(docSummary('/**\n * Block style. Rest.\n */'), 'Block style.');
    });

    test('reads CRLF comments', () {
      expect(docSummary('/// One.\r\n/// Two.'), 'One.');
    });

    test('a missing or empty comment has no summary', () {
      expect(docSummary(null), isNull);
      expect(docSummary('///\n///'), isNull);
    });
  });

  test('symbols: the public top-level declarations in lib/, sorted, with '
      'layer, feature and summary', () async {
    final app = copyFixtureApp();
    final analysis = await ProjectAnalysis.analyze(
      app,
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    final symbols = buildSymbols(
      analysis,
      layerOf: (file) => file.startsWith('lib/utils/') ? 'utils' : null,
      featureOf: (file) => file.startsWith('lib/ui/home/') ? 'home' : null,
    ).symbols;

    const utils = 'lib/utils/result.dart';
    expect(
      [
        for (final s in symbols)
          if (s.file == utils) (s.name, s.kind),
      ],
      [
        ('Result', SymbolKind.classKind),
        ('Ok', SymbolKind.classKind),
        ('Failure', SymbolKind.classKind),
        ('Loggable', SymbolKind.mixinKind),
        ('BookingStatus', SymbolKind.enumKind),
        ('StatusWords', SymbolKind.extension),
        ('BookingId', SymbolKind.extensionType),
        ('Json', SymbolKind.typedef),
        ('describe', SymbolKind.function),
        ('useHidden', SymbolKind.function),
      ],
    );

    final describe = symbols.singleWhere((s) => s.name == 'describe');
    expect(describe.toJson(), {
      'name': 'describe',
      'kind': 'function',
      'file': utils,
      'line': lineOf(app, utils, 'String describe('),
      'layer': 'utils',
      'feature': null,
      'summary': 'Describes [status] for the user!',
    });

    final home = symbols.singleWhere((s) => s.name == 'HomeViewModel');
    expect(home.feature, 'home');
    expect(home.layer, isNull);
    expect(home.summary, "Loads the user's bookings for the home screen.");

    expect(
      symbols.singleWhere((s) => s.name == 'Booking').summary,
      'A trip the user has booked.',
    );
    expect(
      symbols.singleWhere((s) => s.name == 'User').summary,
      'The signed-in user',
    );
    expect(
      symbols.singleWhere((s) => s.name == 'main').kind,
      SymbolKind.function,
    );

    final names = symbols.map((s) => s.name);
    // A getter, a private class and an unnamed extension aren't symbols.
    expect(names, isNot(contains('appName')));
    expect(names, isNot(contains('_Hidden')));
    expect(symbols.where((s) => !s.file.startsWith('lib/')), isEmpty);
    // _NoAnalytics is private; FakeBookingRepository is in testing/.
    expect(names, isNot(contains('FakeBookingRepository')));

    final sorted = [...symbols]
      ..sort((a, b) {
        final byFile = a.file.compareTo(b.file);
        if (byFile != 0) return byFile;
        final byLine = a.line.compareTo(b.line);
        return byLine != 0 ? byLine : a.name.compareTo(b.name);
      });
    expect(symbols, orderedEquals(sorted));
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/map/symbols_test.dart`
Expected: FAIL. `buildSymbols` and `docSummary` don't exist.

- [ ] **Step 3: Implement the pack interface, the extractor interface and the symbols**

Create `packages/appstein_engine/lib/src/packs/pack.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import '../map/map_extractor.dart';

/// Whether a pack describes how an app is built (its architecture) or a
/// platform it runs on (spec §10).
enum PackKind {
  /// An app architecture, such as `official_mvvm`.
  stack,

  /// A target platform, such as `android`.
  platform,
}

/// A pack (spec §10). Packs contribute what is specific to one stack or
/// platform; the engine core never imports one (§5.1), so the CLI hands
/// them in.
///
/// The interface grows with the slices: each member is added in the slice
/// that first uses it.
abstract interface class Pack {
  /// The pack's id, such as `official_mvvm`.
  String get id;

  /// Whether it is a stack or a platform pack.
  PackKind get kind;

  /// The pack's version. It is part of the map's input hash, so a new pack
  /// rebuilds the map.
  String get version;

  /// What it adds to `.appstein/map/`.
  List<MapExtractor> get extractors;

  /// The layer rules a stack pack declares (spec §9.6), or null.
  LayerRules? get layerRules;
}
```

Create `packages/appstein_engine/lib/src/map/map_extractor.dart`:

```dart
import 'project_analysis.dart';

/// Builds files of `.appstein/map/` from the resolved project (spec §6.5,
/// §10).
abstract interface class MapExtractor {
  /// The bodies of the files it builds, by their path inside `.appstein/`,
  /// such as `map/routes.json`. Each body is written with its `meta`.
  Map<String, Map<String, Object?>> extract(ProjectAnalysis analysis);
}
```

Create `packages/appstein_engine/lib/src/map/symbols.dart`:

```dart
import 'package:analyzer/dart/element/element.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

import 'project_analysis.dart';

/// Builds `symbols.json` (spec §6.5). It lists every public top-level class,
/// mixin, enum, named extension, extension type, typedef and function
/// declared in `lib/`, sorted by file, then line, then name.
///
/// [layerOf] and [featureOf] give each symbol's file its layer tag and
/// feature.
SymbolsMap buildSymbols(
  ProjectAnalysis analysis, {
  required String? Function(String file) layerOf,
  required String? Function(String file) featureOf,
}) {
  final symbols = <MapSymbol>[];
  void add(Element element, SymbolKind kind) {
    final name = element.name;
    if (name == null || !element.isPublic) return;
    final location = analysis.locationOf(element.firstFragment);
    if (location == null || !location.file.startsWith('lib/')) return;
    symbols.add(
      MapSymbol(
        name: name,
        kind: kind,
        file: location.file,
        line: location.line,
        layer: layerOf(location.file),
        feature: featureOf(location.file),
        summary: docSummary(element.documentationComment),
      ),
    );
  }

  for (final library in analysis.libraries) {
    if (!library.path.startsWith('lib/')) continue;
    final element = library.result.element;
    for (final e in element.classes) {
      add(e, SymbolKind.classKind);
    }
    for (final e in element.mixins) {
      add(e, SymbolKind.mixinKind);
    }
    for (final e in element.enums) {
      add(e, SymbolKind.enumKind);
    }
    for (final e in element.extensions) {
      add(e, SymbolKind.extension);
    }
    for (final e in element.extensionTypes) {
      add(e, SymbolKind.extensionType);
    }
    for (final e in element.typeAliases) {
      add(e, SymbolKind.typedef);
    }
    for (final e in element.topLevelFunctions) {
      add(e, SymbolKind.function);
    }
  }
  symbols.sort((a, b) {
    final byFile = a.file.compareTo(b.file);
    if (byFile != 0) return byFile;
    final byLine = a.line.compareTo(b.line);
    return byLine != 0 ? byLine : a.name.compareTo(b.name);
  });
  return SymbolsMap(symbols: symbols);
}

/// The summary `symbols.json` records for a doc [comment] (spec §6.5): the
/// first sentence of its first paragraph, or null when there is no comment
/// or it is empty.
///
/// A sentence ends at `.`, `!` or `?` followed by a space or the end, so
/// "v1.2" doesn't end one. Both `///` and `/** */` comments are read.
String? docSummary(String? comment) {
  if (comment == null) return null;
  final lines = <String>[];
  for (final raw in comment.split('\n')) {
    var line = raw.trim();
    if (line.startsWith('///')) {
      line = line.substring(3);
    } else {
      if (line.startsWith('/**')) line = line.substring(3);
      if (line.endsWith('*/')) line = line.substring(0, line.length - 2);
      line = line.trim();
      if (line.startsWith('*')) line = line.substring(1);
    }
    line = line.trim();
    if (line.isEmpty) {
      if (lines.isNotEmpty) break;
      continue;
    }
    lines.add(line);
  }
  if (lines.isEmpty) return null;
  final paragraph = lines.join(' ');
  final end = RegExp(r'[.!?](?=\s|$)').firstMatch(paragraph);
  return end == null ? paragraph : paragraph.substring(0, end.end);
}
```

In `packages/appstein_engine/lib/appstein_engine.dart`, add `export 'src/map/map_extractor.dart';`, `export 'src/map/symbols.dart';` and `export 'src/packs/pack.dart';`.

(`pack.dart` is in `lib/src/packs/` but not in a pack's folder, so our lint tags it `engine`, like the rest of the core.)

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/map/symbols_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/appstein_engine
git commit -m "feat(map): the pack interface, and symbols.json with doc summaries"
```

---

### Task 6: `layers.json`

**Files:**
- Create: `packages/appstein_engine/lib/src/map/interface_library.dart`
- Create: `packages/appstein_engine/lib/src/map/layers.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart`
- Test: `packages/appstein_engine/test/map/layers_test.dart`

**Interfaces:**
- Consumes: `ProjectAnalysis.importsOf` (Task 4); `LayerRules`, `LayerMatcher` (Task 1); `LayersMap`, `MapFileEntry`, `LayerViolation` (Task 2).
- Produces:
  - `bool isInterfaceLibrary(LibraryElement library)`.
  - `LayersMap buildLayers(ProjectAnalysis analysis, {required LayerRules? rules, required String? Function(String file) featureOf})`.

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/map/layers_test.dart`:

```dart
import 'dart:io';

import 'package:analyzer/dart/element/element.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';

void main() {
  // official_mvvm's shape, written out here so this test doesn't depend on
  // the pack (Task 9).
  final rules = LayerRules.fromJson({
    'layers': {
      'test': ['test/**', 'testing/**'],
      'ui': ['lib/ui/**'],
      'data.repository': ['lib/data/repositories/**'],
      'data.service': ['lib/data/services/**'],
      'domain': ['lib/domain/**'],
    },
    'allow': {
      'ui': ['domain'],
      'domain': <String>[],
    },
    'interfaces': {
      'ui': ['data.repository', 'data.service'],
      'domain': ['data.repository'],
    },
  });

  late String app;
  late ProjectAnalysis analysis;

  setUp(() async {
    app = copyFixtureApp();
    File(
      p.join(app, 'lib', 'only_functions.dart'),
    ).writeAsStringSync('int one() => 1;\n');
    analysis = await ProjectAnalysis.analyze(app, dartSdkPath: testDartSdk);
    addTearDown(analysis.dispose);
  });

  LibraryElement library(String path) =>
      analysis.libraries.singleWhere((l) => l.path == path).result.element;

  test('an interface file is one whose classes are all abstract', () {
    expect(
      isInterfaceLibrary(
        library('lib/data/repositories/booking/booking_repository.dart'),
      ),
      isTrue,
    );
    expect(
      isInterfaceLibrary(
        library('lib/data/repositories/auth/auth_repository.dart'),
      ),
      isTrue,
    );
    expect(
      isInterfaceLibrary(
        library('lib/data/repositories/booking/booking_repository_remote.dart'),
      ),
      isFalse,
    );
    expect(isInterfaceLibrary(library('lib/only_functions.dart')), isFalse);
  });

  test('every file gets its tag, feature and project imports, and the one '
      'forbidden import is reported', () {
    final layers = buildLayers(
      analysis,
      rules: rules,
      featureOf: (file) => file.contains('/home/') ? 'home' : null,
    );
    expect(layers.files, hasLength(32));
    expect(layers.files.keys, orderedEquals([...layers.files.keys]..sort()));
    expect(
      layers.files['test/ui/home/widgets/home_screen_test.dart']!.toJson(),
      {
        'layer': 'test',
        'feature': 'home',
        'imports': ['lib/ui/home/widgets/home_screen.dart'],
      },
    );
    expect(layers.files['lib/main.dart']!.toJson(), {
      'layer': null,
      'feature': null,
      'imports': ['lib/config/dependencies.dart', 'lib/routing/router.dart'],
    });
    const screen = 'lib/ui/booking/widgets/booking_screen.dart';
    expect([for (final v in layers.violations) v.toJson()], [
      {
        'file': screen,
        'line': lineOf(app, screen, 'booking_repository_remote.dart'),
        'import':
            'lib/data/repositories/booking/booking_repository_remote.dart',
        'from': 'ui',
        'to': 'data.repository',
      },
    ]);
  });

  test('without layer rules, files have no tags and nothing is '
      'forbidden', () {
    final layers = buildLayers(analysis, rules: null, featureOf: (_) => null);
    expect(layers.files.values.map((f) => f.layer), everyElement(isNull));
    expect(layers.violations, isEmpty);
    expect(
      layers.files['lib/ui/booking/widgets/booking_screen.dart']!.imports,
      [
        'lib/data/repositories/booking/booking_repository_remote.dart',
        'lib/ui/booking/view_models/booking_viewmodel.dart',
      ],
    );
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/map/layers_test.dart`
Expected: FAIL. `isInterfaceLibrary` and `buildLayers` don't exist.

- [ ] **Step 3: Implement**

Create `packages/appstein_engine/lib/src/map/interface_library.dart`:

```dart
import 'package:analyzer/dart/element/element.dart';

/// Whether [library] is an interface file for the `interfaces` layer rule
/// (spec §9.6). It must declare at least one class, and every class it
/// declares must be abstract, like a repository's interface.
///
/// The `layer_imports` lint has the same rule
/// (`appstein_lints/lib/src/layer_imports/interface_library.dart`). The
/// lints can't import the engine, so keep the two in step.
bool isInterfaceLibrary(LibraryElement library) {
  final classes = library.classes;
  return classes.isNotEmpty && classes.every((c) => c.isAbstract);
}
```

Create `packages/appstein_engine/lib/src/map/layers.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import 'interface_library.dart';
import 'project_analysis.dart';

/// Builds `layers.json` (spec §6.5, §9.6). It lists every analyzed file
/// (libraries and their parts) with its layer tag from [rules], its feature
/// from [featureOf], and the project files it imports or exports.
/// Violations are the imports [rules] forbid: exactly what the
/// `layer_imports` lint reports, because both use [LayerMatcher] and the
/// same interface rule.
LayersMap buildLayers(
  ProjectAnalysis analysis, {
  required LayerRules? rules,
  required String? Function(String file) featureOf,
}) {
  final matcher = rules == null ? null : LayerMatcher(rules);
  final files = <String, MapFileEntry>{};
  final violations = <LayerViolation>[];
  for (final library in analysis.libraries) {
    for (final unit in library.result.units) {
      final file = analysis.relativePath(unit.path);
      if (file == null) continue;
      final from = matcher?.tagFor(file);
      final imports = <String>{};
      for (final import in analysis.importsOf(unit)) {
        imports.add(import.file);
        final to = matcher?.tagFor(import.file);
        if (rules == null || from == null || to == null) continue;
        if (rules.mayImport(
          from,
          to,
          interfaceOnly: isInterfaceLibrary(import.library),
        )) {
          continue;
        }
        violations.add(
          LayerViolation(
            file: file,
            line: import.line,
            import: import.file,
            from: from,
            to: to,
          ),
        );
      }
      files[file] = MapFileEntry(
        layer: from,
        feature: featureOf(file),
        imports: imports.toList()..sort(),
      );
    }
  }
  violations.sort((a, b) {
    final byFile = a.file.compareTo(b.file);
    if (byFile != 0) return byFile;
    final byLine = a.line.compareTo(b.line);
    return byLine != 0 ? byLine : a.import.compareTo(b.import);
  });
  final paths = files.keys.toList()..sort();
  return LayersMap(
    files: {for (final path in paths) path: files[path]!},
    violations: violations,
  );
}
```

In `packages/appstein_engine/lib/appstein_engine.dart`, add `export 'src/map/interface_library.dart';` and `export 'src/map/layers.dart';`.

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/map/layers_test.dart`
Expected: PASS (32 files: the fixture's 31 plus `lib/only_functions.dart`).

- [ ] **Step 5: Commit**

```bash
git add packages/appstein_engine
git commit -m "feat(map): layers.json with the same interface rule as layer_imports"
```

---

### Task 7: `deps.json`

**Files:**
- Create: `packages/appstein_engine/lib/src/map/dependencies.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart`
- Test: `packages/appstein_engine/test/map/dependencies_test.dart`

**Interfaces:**
- Consumes: `ProjectAnalysis` (Task 4); `DepsMap`, `PackageDependency` (Task 2).
- Produces: `DepsMap buildDeps(ProjectAnalysis analysis, {required String lockFile})`.

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/map/dependencies_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';

void main() {
  Future<ProjectAnalysis> analyze(String app) async {
    final analysis = await ProjectAnalysis.analyze(
      app,
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    return analysis;
  }

  test('every locked package, with its constraint and the files that '
      'import it', () async {
    final app = copyFixtureApp();
    final deps = buildDeps(
      await analyze(app),
      lockFile: p.join(app, 'pubspec.lock'),
    );
    expect(deps.toJson(), {
      'packages': {
        'collection': {
          'constraint': null,
          'version': '1.19.1',
          'dependency': 'transitive',
          'source': 'hosted',
          'usages': <String>[],
        },
        'flutter': {
          'constraint': null,
          'version': '0.0.0',
          'dependency': 'direct main',
          'source': 'sdk',
          'usages': [
            'lib/routing/router.dart',
            'lib/ui/auth/login/view_models/login_viewmodel.dart',
            'lib/ui/auth/login/widgets/login_screen.dart',
            'lib/ui/booking/view_models/base_view_model.dart',
            'lib/ui/booking/widgets/booking_screen.dart',
            'lib/ui/core/ui/app_button.dart',
            'lib/ui/home/view_models/home_viewmodel.dart',
            'lib/ui/home/widgets/booking_tile.dart',
            'lib/ui/home/widgets/home_screen.dart',
            'lib/ui/profile/widgets/profile_screen.dart',
            'lib/ui/settings/widgets/settings_screen.dart',
          ],
        },
        'flutter_test': {
          'constraint': null,
          'version': '0.0.0',
          'dependency': 'direct dev',
          'source': 'sdk',
          'usages': [
            'test/data/booking_repository_test.dart',
            'test/ui/booking/view_models/booking_viewmodel_test.dart',
            'test/ui/home/widgets/home_screen_test.dart',
          ],
        },
        'go_router': {
          'constraint': '^18.0.0',
          'version': '18.0.2',
          'dependency': 'direct main',
          'source': 'hosted',
          'usages': ['lib/routing/router.dart'],
        },
      },
    });
  });

  test('an override gives the constraint; a version inside a map is '
      'read', () async {
    final app = copyFixtureApp();
    final pubspec = File(p.join(app, 'pubspec.yaml'));
    pubspec.writeAsStringSync(
      '${pubspec.readAsStringSync()}\n'
      'dependency_overrides:\n'
      '  collection: 1.19.0\n',
    );
    final analysis = await analyze(app);
    final deps = buildDeps(analysis, lockFile: p.join(app, 'pubspec.lock'));
    expect(deps.packages['collection']!.constraint, '1.19.0');
  });

  test('a missing lock file gives no packages', () async {
    final app = copyFixtureApp();
    final deps = buildDeps(
      await analyze(app),
      lockFile: p.join(app, 'nowhere.lock'),
    );
    expect(deps.packages, isEmpty);
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/map/dependencies_test.dart`
Expected: FAIL. `buildDeps` doesn't exist.

- [ ] **Step 3: Implement**

Create `packages/appstein_engine/lib/src/map/dependencies.dart`:

```dart
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'project_analysis.dart';

/// Builds `deps.json` (spec §6.5). It lists every package in [lockFile]
/// (the project's `pubspec.lock`, or its pub workspace's), with:
/// - the constraint `pubspec.yaml` gives it (an override wins);
/// - the resolved version, dependency kind and source the lock file
///   records;
/// - the project files that import or export it.
///
/// A missing or unreadable lock file gives no packages.
DepsMap buildDeps(ProjectAnalysis analysis, {required String lockFile}) {
  final constraints = <String, String?>{};
  final pubspec = _readYaml(p.join(analysis.projectRoot, 'pubspec.yaml'));
  for (final section in const [
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  ]) {
    if (pubspec?[section] case final Map<Object?, Object?> entries) {
      for (final MapEntry(:key, :value) in entries.entries) {
        if (key is String) constraints[key] = _constraint(value);
      }
    }
  }

  final usages = <String, Set<String>>{};
  for (final library in analysis.libraries) {
    for (final unit in library.result.units) {
      final file = analysis.relativePath(unit.path);
      if (file == null) continue;
      for (final directive
          in unit.unit.directives.whereType<NamespaceDirective>()) {
        final uri = directive.uri.stringValue;
        if (uri == null || !uri.startsWith('package:')) continue;
        final slash = uri.indexOf('/');
        if (slash < 0) continue;
        final package = uri.substring('package:'.length, slash);
        if (package == analysis.packageName) continue;
        (usages[package] ??= {}).add(file);
      }
    }
  }

  final packages = <String, PackageDependency>{};
  if (_readYaml(lockFile)?['packages']
      case final Map<Object?, Object?> locked) {
    for (final name in locked.keys.whereType<String>().toList()..sort()) {
      if (locked[name] case {
        'dependency': final String dependency,
        'source': final String source,
        'version': final String version,
      }) {
        packages[name] = PackageDependency(
          constraint: constraints[name],
          version: version,
          dependency: dependency,
          source: source,
          usages: (usages[name]?.toList() ?? [])..sort(),
        );
      }
    }
  }
  return DepsMap(packages: packages);
}

String? _constraint(Object? value) => switch (value) {
  final String text => text,
  {'version': final String version} => version,
  _ => null,
};

Map<Object?, Object?>? _readYaml(String path) {
  try {
    final yaml = loadYaml(File(path).readAsStringSync());
    return yaml is Map<Object?, Object?> ? yaml : null;
  } on FileSystemException {
    return null;
  } on YamlException {
    return null;
  }
}
```

In `packages/appstein_engine/lib/appstein_engine.dart`, add `export 'src/map/dependencies.dart';`.

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/map/dependencies_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/appstein_engine
git commit -m "feat(map): deps.json from pubspec, the lock file and the imports"
```

---

### Task 8: official_mvvm — `routes.json`

**Files:**
- Create: `packages/appstein_engine/lib/src/map/ast_values.dart`
- Create: `packages/appstein_engine/lib/src/packs/official_mvvm/routes.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart` (exports `ast_values.dart` only; the pack's files are never exported from the core library)
- Test: `packages/appstein_engine/test/packs/official_mvvm/routes_test.dart`

**Interfaces:**
- Consumes: `ProjectAnalysis` (Task 4); `RoutesMap`, `MapRoute`, `MapRouter`, `CodeRef` (Task 2).
- Produces:
  - `String? constantString(Expression? expression)`.
  - `Expression? singleReturn(FunctionBody body)`.
  - `final class NamedArguments`: `NamedArguments(ArgumentList)`, `operator [](String name) → Expression?`, `bool has(String name)`.
  - `RoutesMap readRoutes(ProjectAnalysis analysis)`.
  - `String joinRoutePath(String? parent, String child)`.

The rules (spec §6.5 as edited):
- **Routers:** every `GoRouter(...)` in `lib/` whose class comes from `package:go_router` is a router. Its `routes:` list is read.
- **Shells:** `ShellRoute` children and `StatefulShellRoute` branches' routes belong to the enclosing route (or the top).
- **Paths:** a nested path is joined the way go_router's `concatenatePaths` joins it (the non-empty segments of both, after one `/`).
- **Screens:** a screen is the project widget the builder returns, when the builder is a single plain return. With `pageBuilder` (which go_router prefers when both are given), it is the page's `child:`.
- **Unresolved:** anything else gets `unresolved: true` and one of these exact reasons:

| Situation | `reason` |
|---|---|
| `routes:` is a `$appRoutes` identifier | `typed routes (go_router_builder) are not read yet` |
| `routes:` is any other non-list expression | `the routes are not a list literal` |
| a spread, `if` or `for` element in a routes list | `a spread or a condition in a routes list is not read` |
| a list element that isn't a go_router route constructor call | `the route is not a GoRoute, ShellRoute or StatefulShellRoute constructor call` |
| `branches:` isn't a list literal | `the branches are not a list literal` |
| a branch that isn't `StatefulShellBranch(...)` | `the branch is not a StatefulShellBranch constructor call` |
| a `GoRouter` with no `routes:` (`GoRouter.routingConfig`) | `this GoRouter has no routes list` |
| `path:` isn't a constant string | `the path is not a constant string` |
| an enclosing `GoRoute`'s path isn't constant | `the parent route's path is not a constant string` |
| the builder isn't a function literal | `the builder is not a function literal` |
| the builder has more than one `return`, or its `return` isn't last | `the builder is not a single plain return` |
| a page builder's page has no `child:` | `the page builder doesn't return a page with a child: argument` |
| the builder returns something other than a constructor call | `the builder doesn't return a widget constructor call` |
| the builder returns a widget not declared in `lib/` | `the builder returns <Name>, which is not declared in this project` |

A path problem is reported before a screen problem. A route with neither builder (a redirect-only route) has `screen: null` and is **not** unresolved.

Routes are listed by file (sorted), then in source order. That is the order in which a depth-first read meets them, so a parent comes before its children.

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/packs/official_mvvm/routes_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/src/packs/official_mvvm/routes.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/fixture_app.dart';

void main() {
  const router = 'lib/routing/router.dart';

  Future<RoutesMap> routesOf(String app) async {
    final analysis = await ProjectAnalysis.analyze(
      app,
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    return readRoutes(analysis);
  }

  Map<String, Object?> route({
    required int line,
    String? path,
    String? name,
    (String, String)? screen,
    String? parent,
    bool redirect = false,
    String? reason,
  }) => MapRoute(
    path: path,
    name: name,
    screen: screen == null ? null : CodeRef(name: screen.$1, file: screen.$2),
    parent: parent,
    redirect: redirect,
    file: router,
    line: line,
    unresolved: reason != null,
    reason: reason,
  ).toJson();

  test("the fixture's routes, in source order", () async {
    final app = copyFixtureApp();
    // Each GoRoute( line comes just before its path: line.
    int at(String pathLine) => lineOf(app, router, pathLine) - 1;
    final routes = await routesOf(app);
    expect([for (final r in routes.routes) r.toJson()], [
      route(
        line: at('path: Routes.login'),
        path: '/login',
        name: 'login',
        screen: ('LoginScreen', 'lib/ui/auth/login/widgets/login_screen.dart'),
      ),
      route(
        line: at('path: Routes.home'),
        path: '/',
        screen: ('HomeScreen', 'lib/ui/home/widgets/home_screen.dart'),
      ),
      route(
        line: at('path: Routes.bookingRelative'),
        path: '/booking',
        parent: '/',
        screen: ('BookingScreen', 'lib/ui/booking/widgets/booking_screen.dart'),
      ),
      route(
        line: at("path: ':id'"),
        path: '/booking/:id',
        parent: '/booking',
        redirect: true,
      ),
      route(
        line: at('path: _searchPath()'),
        parent: '/',
        screen: (
          'SettingsScreen',
          'lib/ui/settings/widgets/settings_screen.dart',
        ),
        reason: 'the path is not a constant string',
      ),
      route(
        line: at('path: Routes.settings'),
        path: '/settings',
        reason: 'the builder is not a single plain return',
      ),
      route(
        line: at('path: Routes.profile'),
        path: '/profile',
        screen: ('ProfileScreen', 'lib/ui/profile/widgets/profile_screen.dart'),
      ),
      route(
        line: at("path: '/about'"),
        path: '/about',
        reason: 'the builder returns Text, which is not declared in this '
            'project',
      ),
    ]);
    expect([for (final r in routes.routers) r.toJson()], [
      {'file': router, 'line': lineOf(app, router, '=> GoRouter('), 'redirect': true},
    ]);
  });

  test('routes that cannot be read are recorded unresolved, never '
      'guessed', () async {
    final app = copyFixtureApp();
    const extra = 'lib/routing/extra_routes.dart';
    File(p.join(app, 'lib', 'routing', 'extra_routes.dart')).writeAsStringSync(
      r'''
import 'package:go_router/go_router.dart';

import '../ui/profile/widgets/profile_screen.dart';
import 'routes.dart';

final List<RouteBase> _more = [];
final String _notConst = '/not-const';

List<RouteBase> get $appRoutes => const [];

GoRouter typedRouter() => GoRouter(routes: $appRoutes);

GoRouter listRouter() => GoRouter(routes: _more);

GoRouter spreadRouter() => GoRouter(routes: [..._more, _route()]);

GoRouter configRouter() => GoRouter.routingConfig(routingConfig: Object());

GoRouter valuesRouter() => GoRouter(
  routes: [
    GoRoute(
      path: '/x/${Routes.bookingRelative}',
      builder: (context, state) => const ProfileScreen(),
    ),
    GoRoute(path: _notConst),
    GoRoute(
      path: _dynamic(),
      routes: [
        GoRoute(
          path: 'child',
          builder: (context, state) => const ProfileScreen(),
        ),
      ],
    ),
  ],
);

RouteBase _route() => const GoRoute(path: '/x');

String _dynamic() => '/dynamic';
''',
    );
    // A class named GoRouter that isn't go_router's is not a router.
    File(p.join(app, 'lib', 'routing', 'own_router.dart')).writeAsStringSync(
      'class GoRouter {\n'
      '  GoRouter({required List<Object> routes});\n'
      '}\n\n'
      'GoRouter ownRouter() => GoRouter(routes: const []);\n',
    );
    final routes = await routesOf(app);
    final extras = [
      for (final r in routes.routes)
        if (r.file == extra) r,
    ];
    expect([for (final r in extras) (r.path, r.reason)], [
      (null, 'typed routes (go_router_builder) are not read yet'),
      (null, 'the routes are not a list literal'),
      (null, 'a spread or a condition in a routes list is not read'),
      (
        null,
        'the route is not a GoRoute, ShellRoute or StatefulShellRoute '
            'constructor call',
      ),
      (null, 'this GoRouter has no routes list'),
      ('/x/booking', null),
      (null, 'the path is not a constant string'),
      (null, 'the path is not a constant string'),
      (null, "the parent route's path is not a constant string"),
    ]);
    expect(
      [for (final r in extras) r.unresolved],
      [true, true, true, true, true, false, true, true, true],
    );
    expect(extras.last.screen?.name, 'ProfileScreen');
    expect(extras.last.parent, isNull);
    expect(
      routes.routers.map((r) => r.file).toSet(),
      {router, extra},
      reason: 'own_router.dart has no go_router GoRouter',
    );
    expect(routes.routers.where((r) => r.file == extra), hasLength(5));
  });

  test('a CRLF router gives the same routes', () async {
    final lf = await routesOf(copyFixtureApp());
    final crlfApp = copyFixtureApp();
    final file = File(p.join(crlfApp, 'lib', 'routing', 'router.dart'));
    file.writeAsStringSync(file.readAsStringSync().replaceAll('\n', '\r\n'));
    final crlf = await routesOf(crlfApp);
    expect(crlf.toJson(), lf.toJson());
  });

  test('nested paths are joined as go_router joins them', () {
    expect(joinRoutePath(null, '/login'), '/login');
    expect(joinRoutePath('/', 'booking'), '/booking');
    expect(joinRoutePath('/booking', ':id'), '/booking/:id');
    expect(joinRoutePath('/', '/settings'), '/settings');
    expect(joinRoutePath('/a/', 'b/'), '/a/b');
  });
}
```

(The test imports the pack's `routes.dart` through `package:appstein_engine/src/…`. Test files are tagged `test`, which may import anything. `implementation_imports` doesn't apply inside the package's own tests.)

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/packs/official_mvvm/routes_test.dart`
Expected: FAIL. `readRoutes` doesn't exist.

- [ ] **Step 3: Implement the AST helpers**

Create `packages/appstein_engine/lib/src/map/ast_values.dart`:

```dart
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

/// The value of [expression] when it is a compile-time constant string,
/// else null. It reads literals, adjacent literals, interpolations of
/// constants, and references to `const` variables and fields (such as
/// `Routes.home`), which the analyzer evaluates.
String? constantString(Expression? expression) {
  switch (expression) {
    case SimpleStringLiteral(:final value):
      return value;
    case AdjacentStrings(:final strings):
      final buffer = StringBuffer();
      for (final part in strings) {
        final value = constantString(part);
        if (value == null) return null;
        buffer.write(value);
      }
      return buffer.toString();
    case StringInterpolation(:final elements):
      final buffer = StringBuffer();
      for (final element in elements) {
        switch (element) {
          case InterpolationString(:final value):
            buffer.write(value);
          case InterpolationExpression(:final expression):
            final value = constantString(expression);
            if (value == null) return null;
            buffer.write(value);
        }
      }
      return buffer.toString();
    case ParenthesizedExpression(:final expression):
      return constantString(expression);
    case Identifier(:final element):
      return _constantValue(element);
    case PropertyAccess(:final propertyName):
      return _constantValue(propertyName.element);
    default:
      return null;
  }
}

String? _constantValue(Element? element) {
  final variable = switch (element) {
    GetterElement(:final variable) => variable,
    final VariableElement variable => variable,
    _ => null,
  };
  if (variable == null || !variable.isConst) return null;
  return variable.computeConstantValue()?.toStringValue();
}

/// The expression [body] returns when it is a single plain return: `=> x`,
/// or a block whose only `return` is its last statement. A `return` inside
/// a nested function belongs to that function, so it doesn't count.
Expression? singleReturn(FunctionBody body) {
  if (body is ExpressionFunctionBody) return body.expression;
  if (body is! BlockFunctionBody) return null;
  final finder = _ReturnFinder();
  body.block.accept(finder);
  final statements = body.block.statements;
  if (finder.returns.length != 1 ||
      statements.isEmpty ||
      !identical(statements.last, finder.returns.single)) {
    return null;
  }
  return finder.returns.single.expression;
}

final class _ReturnFinder extends RecursiveAstVisitor<void> {
  final returns = <ReturnStatement>[];

  @override
  void visitReturnStatement(ReturnStatement node) {
    returns.add(node);
    super.visitReturnStatement(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // Its returns are its own.
  }
}

/// The named arguments of a call, by name.
final class NamedArguments {
  /// Reads the named arguments in [list].
  NamedArguments(ArgumentList list)
    : _values = {
        for (final argument in list.arguments.whereType<NamedArgument>())
          argument.name.lexeme: argument.argumentExpression,
      };

  final Map<String, Expression> _values;

  /// The expression passed as [name], or null.
  Expression? operator [](String name) => _values[name];

  /// Whether [name] was passed.
  bool has(String name) => _values.containsKey(name);
}
```

The analyzer 14.4 names used here were checked in a spike on 2026-10-01: `NamedArgument.name.lexeme`, `Argument.argumentExpression`, `GetterElement.variable` and `VariableElement.computeConstantValue`. If one of the pattern fields above has a different name in 14.4 (such as `Identifier.element`), look it up in the pub cache's `analyzer-14.4.0/lib/src/dart/ast/ast.dart` and adjust.

In `packages/appstein_engine/lib/appstein_engine.dart`, add `export 'src/map/ast_values.dart';`.

- [ ] **Step 4: Implement the routes**

Create `packages/appstein_engine/lib/src/packs/official_mvvm/routes.dart`:

```dart
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

import '../../map/ast_values.dart';
import '../../map/project_analysis.dart';

/// Reads the go_router routes reachable from every `GoRouter(...)` in `lib/`
/// (spec §6.5). It reads nested routes and the routes inside shells, joins
/// nested paths, and records each route's screen. What can't be resolved
/// statically is marked unresolved with a reason, never guessed.
///
/// Routes and routers are listed by file, then in source order.
RoutesMap readRoutes(ProjectAnalysis analysis) {
  final routes = <MapRoute>[];
  final routers = <MapRouter>[];
  for (final library in analysis.libraries) {
    if (!library.path.startsWith('lib/')) continue;
    for (final unit in library.result.units) {
      final file = analysis.relativePath(unit.path);
      if (file == null) continue;
      final finder = _RouterFinder();
      unit.unit.accept(finder);
      final reader = _RouteReader(analysis, file, unit.lineInfo, routes);
      for (final router in finder.routers) {
        final arguments = NamedArguments(router.argumentList);
        routers.add(
          MapRouter(
            file: file,
            line: reader.lineOf(router),
            redirect: arguments.has('redirect'),
          ),
        );
        final list = arguments['routes'];
        if (list == null) {
          reader.unresolved(
            router,
            const _Parent.top(),
            'this GoRouter has no routes list',
          );
        } else {
          reader.readList(list, const _Parent.top());
        }
      }
    }
  }
  return RoutesMap(
    routes: _byFile(routes, (r) => r.file),
    routers: _byFile(routers, (r) => r.file),
  );
}

/// Joins a nested route's [child] path to its [parent]'s, as go_router's
/// `concatenatePaths` does: the non-empty segments of both, after one `/`.
/// A top-level path ([parent] null) is kept as written.
String joinRoutePath(String? parent, String child) {
  if (parent == null) return child;
  final segments = [
    ...parent.split('/'),
    ...child.split('/'),
  ].where((segment) => segment.isNotEmpty);
  return '/${segments.join('/')}';
}

/// [items] grouped by their file, files sorted, each file's items in their
/// original (source) order.
List<T> _byFile<T>(List<T> items, String Function(T) fileOf) {
  final groups = <String, List<T>>{};
  for (final item in items) {
    (groups[fileOf(item)] ??= []).add(item);
  }
  return [
    for (final file in groups.keys.toList()..sort()) ...groups[file]!,
  ];
}

/// The name of [node]'s class when that class comes from
/// `package:go_router`, such as `GoRoute`; null for any other class.
String? _goRouterClass(InstanceCreationExpression node) {
  final element = node.constructorName.type.element;
  if (element is! ClassElement) return null;
  final uri = element.library.uri;
  final fromGoRouter =
      uri.scheme == 'package' &&
      uri.pathSegments.isNotEmpty &&
      uri.pathSegments.first == 'go_router';
  return fromGoRouter ? element.name : null;
}

final class _RouterFinder extends RecursiveAstVisitor<void> {
  final routers = <InstanceCreationExpression>[];

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (_goRouterClass(node) == 'GoRouter') routers.add(node);
    super.visitInstanceCreationExpression(node);
  }
}

/// The enclosing `GoRoute`'s full path, if any.
final class _Parent {
  const _Parent(this.path, {required this.unresolved});

  const _Parent.top() : path = null, unresolved = false;

  final String? path;

  /// Whether the enclosing route's path couldn't be resolved.
  final bool unresolved;
}

final class _RouteReader {
  _RouteReader(this.analysis, this.file, this.lineInfo, this.routes);

  final ProjectAnalysis analysis;
  final String file;
  final LineInfo lineInfo;
  final List<MapRoute> routes;

  int lineOf(AstNode node) => lineInfo.getLocation(node.offset).lineNumber;

  void unresolved(AstNode node, _Parent parent, String reason) => routes.add(
    MapRoute(
      parent: parent.path,
      file: file,
      line: lineOf(node),
      unresolved: true,
      reason: reason,
    ),
  );

  void readList(Expression list, _Parent parent) {
    if (list is! ListLiteral) {
      final typed = list is SimpleIdentifier && list.name == r'$appRoutes';
      unresolved(
        list,
        parent,
        typed
            ? 'typed routes (go_router_builder) are not read yet'
            : 'the routes are not a list literal',
      );
      return;
    }
    for (final element in list.elements) {
      if (element is Expression) {
        readRoute(element, parent);
      } else {
        unresolved(
          element,
          parent,
          'a spread or a condition in a routes list is not read',
        );
      }
    }
  }

  void readRoute(Expression route, _Parent parent) {
    const notARoute =
        'the route is not a GoRoute, ShellRoute or StatefulShellRoute '
        'constructor call';
    if (route is! InstanceCreationExpression) {
      unresolved(route, parent, notARoute);
      return;
    }
    final arguments = NamedArguments(route.argumentList);
    switch (_goRouterClass(route)) {
      case 'GoRoute':
        _goRoute(route, arguments, parent);
      case 'ShellRoute':
        if (arguments['routes'] case final list?) readList(list, parent);
      case 'StatefulShellRoute':
        _branches(route, arguments['branches'], parent);
      default:
        unresolved(route, parent, notARoute);
    }
  }

  void _branches(AstNode at, Expression? branches, _Parent parent) {
    if (branches is! ListLiteral) {
      unresolved(branches ?? at, parent, 'the branches are not a list literal');
      return;
    }
    for (final branch in branches.elements) {
      if (branch is InstanceCreationExpression &&
          _goRouterClass(branch) == 'StatefulShellBranch') {
        if (NamedArguments(branch.argumentList)['routes'] case final list?) {
          readList(list, parent);
        }
      } else {
        unresolved(
          branch,
          parent,
          'the branch is not a StatefulShellBranch constructor call',
        );
      }
    }
  }

  void _goRoute(
    InstanceCreationExpression route,
    NamedArguments arguments,
    _Parent parent,
  ) {
    final declared = constantString(arguments['path']);
    final path = parent.unresolved || declared == null
        ? null
        : joinRoutePath(parent.path, declared);
    final screen = _screen(arguments);
    final reason = parent.unresolved
        ? "the parent route's path is not a constant string"
        : declared == null
        ? 'the path is not a constant string'
        : screen.reason;
    routes.add(
      MapRoute(
        path: path,
        name: constantString(arguments['name']),
        screen: screen.ref,
        parent: parent.path,
        redirect: arguments.has('redirect'),
        file: file,
        line: lineOf(route),
        unresolved: reason != null,
        reason: reason,
      ),
    );
    if (arguments['routes'] case final children?) {
      readList(children, _Parent(path, unresolved: path == null));
    }
  }

  ({CodeRef? ref, String? reason}) _screen(NamedArguments arguments) {
    // go_router uses pageBuilder when both are given.
    final pageBuilder = arguments['pageBuilder'];
    final builder = pageBuilder ?? arguments['builder'];
    if (builder == null) return (ref: null, reason: null);
    if (builder is! FunctionExpression) {
      return (ref: null, reason: 'the builder is not a function literal');
    }
    final returned = singleReturn(builder.body);
    if (returned == null) {
      return (ref: null, reason: 'the builder is not a single plain return');
    }
    var widget = returned;
    if (pageBuilder != null) {
      final child = returned is InstanceCreationExpression
          ? NamedArguments(returned.argumentList)['child']
          : null;
      if (child == null) {
        return (
          ref: null,
          reason: "the page builder doesn't return a page with a child: "
              'argument',
        );
      }
      widget = child;
    }
    if (widget is! InstanceCreationExpression) {
      return (
        ref: null,
        reason: "the builder doesn't return a widget constructor call",
      );
    }
    final element = widget.constructorName.type.element;
    final name = element?.name;
    final location = element == null
        ? null
        : analysis.locationOf(element.firstFragment);
    if (name == null || location == null || !location.file.startsWith('lib/')) {
      return (
        ref: null,
        reason:
            'the builder returns ${name ?? 'a widget'}, which is not declared '
            'in this project',
      );
    }
    return (ref: CodeRef(name: name, file: location.file), reason: null);
  }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/packs/official_mvvm/routes_test.dart`
Expected: PASS.

Also run `fvm dart analyze --fatal-infos` from the repo root. The `layer_imports` lint must accept `routes.dart` (pack.official_mvvm may import engine and protocol), and nothing in the core may import the pack.

- [ ] **Step 6: Commit**

```bash
git add packages/appstein_engine
git commit -m "feat(official_mvvm): routes.json from go_router, unresolved never guessed"
```

---

### Task 9: official_mvvm — `features.json`, the layer rules and the pack

**Files:**
- Create: `packages/appstein_engine/lib/src/packs/official_mvvm/layer_rules.dart`
- Create: `packages/appstein_engine/lib/src/packs/official_mvvm/features.dart`
- Create: `packages/appstein_engine/lib/src/packs/official_mvvm/official_mvvm_pack.dart`
- Create: `packages/appstein_engine/lib/official_mvvm.dart`
- Modify: `analysis_options.yaml` (repo root)
- Test: `packages/appstein_engine/test/packs/official_mvvm/features_test.dart`, `packages/appstein_engine/test/packs/official_mvvm/official_mvvm_pack_test.dart`

**Interfaces:**
- Consumes: `readRoutes` (Task 8); `ProjectAnalysis.importsOf` (Task 4); `LayerMatcher` (Task 1); `Pack`, `PackKind`, `MapExtractor` (Task 5); `FeaturesMap`, `Feature`, `CodeRef`, `MapFiles` (Task 2).
- Produces:
  - `const LayerRules officialMvvmLayerRules`.
  - `FeaturesMap readFeatures(ProjectAnalysis analysis, {required RoutesMap routes, required LayerMatcher matcher})`.
  - `final class OfficialMvvmPack implements Pack` (`const OfficialMvvmPack()`): `id` is `official_mvvm`, `kind` is `PackKind.stack`, `version` is `'1'`.
  - `final class OfficialMvvmExtractor implements MapExtractor`. It returns `{MapFiles.features: …, MapFiles.routes: …}`.
  - `package:appstein_engine/official_mvvm.dart` exports `official_mvvm_pack.dart` and `layer_rules.dart`.

- [ ] **Step 1: Write the failing tests**

Create `packages/appstein_engine/test/packs/official_mvvm/features_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_engine/src/packs/official_mvvm/features.dart';
import 'package:appstein_engine/src/packs/official_mvvm/routes.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/fixture_app.dart';

void main() {
  Future<FeaturesMap> featuresOf(String app) async {
    final analysis = await ProjectAnalysis.analyze(
      app,
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    return readFeatures(
      analysis,
      routes: readRoutes(analysis),
      matcher: LayerMatcher(officialMvvmLayerRules),
    );
  }

  Map<String, Object?> ref(String name, String file) =>
      CodeRef(name: name, file: file).toJson();

  test("the fixture's features", () async {
    final features = await featuresOf(copyFixtureApp());
    expect(features.toJson(), {
      'features': {
        'auth/login': {
          'folder': 'lib/ui/auth/login',
          'viewModels': [
            ref(
              'LoginViewModel',
              'lib/ui/auth/login/view_models/login_viewmodel.dart',
            ),
          ],
          'screens': [
            ref('LoginScreen', 'lib/ui/auth/login/widgets/login_screen.dart'),
          ],
          'repositories': [
            ref(
              'AuthRepository',
              'lib/data/repositories/auth/auth_repository.dart',
            ),
          ],
          'services': <Object>[],
          'models': <Object>[],
          'tests': <String>[],
          'files': [
            'lib/ui/auth/login/view_models/login_viewmodel.dart',
            'lib/ui/auth/login/widgets/login_screen.dart',
          ],
        },
        'booking': {
          'folder': 'lib/ui/booking',
          // BaseViewModel is abstract, so it isn't a view model (P3).
          'viewModels': [
            ref(
              'BookingViewModel',
              'lib/ui/booking/view_models/booking_viewmodel.dart',
            ),
          ],
          'screens': [
            ref('BookingScreen', 'lib/ui/booking/widgets/booking_screen.dart'),
          ],
          'repositories': [
            ref(
              'BookingRepository',
              'lib/data/repositories/booking/booking_repository.dart',
            ),
          ],
          'services': <Object>[],
          // The view model imports the use case too, but use cases aren't
          // models (P4).
          'models': [ref('Booking', 'lib/domain/models/booking.dart')],
          'tests': ['test/ui/booking/view_models/booking_viewmodel_test.dart'],
          'files': [
            'lib/ui/booking/view_models/base_view_model.dart',
            'lib/ui/booking/view_models/booking_viewmodel.dart',
            'lib/ui/booking/widgets/booking_screen.dart',
          ],
        },
        'home': {
          'folder': 'lib/ui/home',
          'viewModels': [
            ref(
              'HomeViewModel',
              'lib/ui/home/view_models/home_viewmodel.dart',
            ),
          ],
          'screens': [
            ref('HomeScreen', 'lib/ui/home/widgets/home_screen.dart'),
          ],
          'repositories': [
            ref(
              'BookingRepository',
              'lib/data/repositories/booking/booking_repository.dart',
            ),
          ],
          'services': [
            ref('AnalyticsService', 'lib/data/services/analytics_service.dart'),
          ],
          'models': [ref('Booking', 'lib/domain/models/booking.dart')],
          'tests': ['test/ui/home/widgets/home_screen_test.dart'],
          'files': [
            'lib/ui/home/view_models/home_viewmodel.dart',
            'lib/ui/home/widgets/booking_tile.dart',
            'lib/ui/home/widgets/home_screen.dart',
          ],
        },
        'profile': {
          'folder': 'lib/ui/profile',
          'viewModels': <Object>[],
          'screens': [
            ref('ProfileScreen', 'lib/ui/profile/widgets/profile_screen.dart'),
          ],
          'repositories': <Object>[],
          'services': <Object>[],
          'models': <Object>[],
          'tests': <String>[],
          'files': ['lib/ui/profile/widgets/profile_screen.dart'],
        },
        'settings': {
          'folder': 'lib/ui/settings',
          'viewModels': <Object>[],
          // From the route whose path isn't constant: its screen is known.
          'screens': [
            ref(
              'SettingsScreen',
              'lib/ui/settings/widgets/settings_screen.dart',
            ),
          ],
          'repositories': <Object>[],
          'services': <Object>[],
          'models': <Object>[],
          'tests': <String>[],
          'files': ['lib/ui/settings/widgets/settings_screen.dart'],
        },
      },
    });
  });

  test('a feature folder inside another owns only its own files', () async {
    final app = copyFixtureApp();
    File(p.join(app, 'lib', 'ui', 'auth', 'widgets', 'auth_shell.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        "import 'package:flutter/widgets.dart';\n\n"
        'class AuthShell extends StatelessWidget {\n'
        '  const AuthShell({super.key});\n\n'
        '  @override\n'
        "  Widget build(BuildContext context) => const Text('auth');\n"
        '}\n',
      );
    final features = (await featuresOf(app)).features;
    expect(features['auth']!.files, ['lib/ui/auth/widgets/auth_shell.dart']);
    expect(features['auth']!.screens, isEmpty);
    expect(features['auth/login']!.files, hasLength(2));
  });

  test('ui/core is shared UI, not a feature', () async {
    final features = await featuresOf(copyFixtureApp());
    expect(features.features.keys, isNot(contains('core')));
    expect(features.featureOf('lib/ui/core/ui/app_button.dart'), isNull);
  });
}
```

Create `packages/appstein_engine/test/packs/official_mvvm/official_mvvm_pack_test.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../../support/fixture_app.dart';

void main() {
  test('the pack describes itself', () {
    const pack = OfficialMvvmPack();
    expect(pack.id, 'official_mvvm');
    expect(pack.kind, PackKind.stack);
    expect(pack.version, '1');
    expect(pack.layerRules, same(officialMvvmLayerRules));
    expect(pack.extractors, hasLength(1));
  });

  test('its layer rules are valid and follow spec §9.6', () {
    final rules = LayerRules.fromJson(officialMvvmLayerRules.toJson());
    expect(rules.layers.keys, [
      'test',
      'ui',
      'data.repository',
      'data.service',
      'data.model',
      'domain',
      'routing',
      'config',
      'utils',
    ]);
    // ui reaches data only through interfaces.
    expect(rules.mayImport('ui', 'data.repository'), isFalse);
    expect(rules.mayImport('ui', 'data.repository', interfaceOnly: true), isTrue);
    expect(rules.mayImport('ui', 'data.service', interfaceOnly: true), isTrue);
    expect(rules.mayImport('ui', 'routing'), isTrue);
    // Use cases in domain call repositories through their interfaces.
    expect(rules.mayImport('domain', 'data.repository', interfaceOnly: true), isTrue);
    expect(rules.mayImport('domain', 'data.service', interfaceOnly: true), isFalse);
    expect(rules.mayImport('domain', 'ui'), isFalse);
    // data.* may import anything but ui.
    for (final data in ['data.repository', 'data.service', 'data.model']) {
      for (final tag in rules.layers.keys) {
        expect(
          rules.mayImport(data, tag),
          tag != 'ui',
          reason: '$data → $tag',
        );
      }
    }
    // routing, config, utils and tests are unrestricted.
    for (final free in ['routing', 'config', 'utils', 'test']) {
      expect(rules.mayImport(free, 'ui'), isTrue, reason: free);
    }
  });

  test('the extractor writes features.json and routes.json', () async {
    final analysis = await ProjectAnalysis.analyze(
      copyFixtureApp(),
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    final files = const OfficialMvvmPack().extractors.single.extract(analysis);
    expect(files.keys.toSet(), {MapFiles.features, MapFiles.routes});
    expect(
      FeaturesMap.fromJson(files[MapFiles.features]!).features.keys,
      containsAll(['home', 'booking', 'auth/login']),
    );
    expect(RoutesMap.fromJson(files[MapFiles.routes]!).routes, hasLength(8));
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/packs/official_mvvm/`
Expected: FAIL. There is no `official_mvvm.dart` library, and no `readFeatures`.

- [ ] **Step 3: Implement the layer rules, the features and the pack**

Create `packages/appstein_engine/lib/src/packs/official_mvvm/layer_rules.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

/// official_mvvm's layer tags (spec §6.5) and rules (§9.6), matching
/// Flutter's architecture guide and its compass_app sample:
/// - ui may import domain, routing, config and utils, plus the interfaces
///   of repositories and services;
/// - domain may import utils, plus the interfaces of repositories (use
///   cases call repositories);
/// - data.* may import anything but ui;
/// - routing, config, utils and tests are unrestricted.
///
/// Tests come first, so a file under `test/` is never tagged by a `lib/`
/// glob.
const officialMvvmLayerRules = LayerRules(
  layers: {
    'test': ['test/**', 'testing/**'],
    'ui': ['lib/ui/**'],
    'data.repository': ['lib/data/repositories/**'],
    'data.service': ['lib/data/services/**'],
    'data.model': ['lib/data/model/**'],
    'domain': ['lib/domain/**'],
    'routing': ['lib/routing/**'],
    'config': ['lib/config/**'],
    'utils': ['lib/utils/**'],
  },
  allow: {
    'ui': ['domain', 'routing', 'config', 'utils'],
    'domain': ['utils'],
    'data.repository': [
      'test',
      'data.service',
      'data.model',
      'domain',
      'routing',
      'config',
      'utils',
    ],
    'data.service': [
      'test',
      'data.repository',
      'data.model',
      'domain',
      'routing',
      'config',
      'utils',
    ],
    'data.model': [
      'test',
      'data.repository',
      'data.service',
      'domain',
      'routing',
      'config',
      'utils',
    ],
  },
  interfaces: {
    'ui': ['data.repository', 'data.service'],
    'domain': ['data.repository'],
  },
);
```

Create `packages/appstein_engine/lib/src/packs/official_mvvm/features.dart`:

```dart
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

import '../../map/project_analysis.dart';

/// Builds `features.json` for the official_mvvm layout (spec §6.5).
///
/// A feature is a folder under `lib/ui/` (except `core/`) that has a
/// `view_models/` or `widgets/` folder. Its name is its path below
/// `lib/ui/`. A file belongs to the deepest feature folder that holds it,
/// and its tests are under `test/ui/<feature>/`. Screens come from
/// [routes]; [matcher] sorts the view models' constructor types into
/// repositories and services and finds the `domain` files the feature
/// imports.
FeaturesMap readFeatures(
  ProjectAnalysis analysis, {
  required RoutesMap routes,
  required LayerMatcher matcher,
}) {
  final libFiles = <String>[];
  final testFiles = <String>[];
  for (final library in analysis.libraries) {
    for (final unit in library.result.units) {
      final file = analysis.relativePath(unit.path);
      if (file == null) continue;
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

  CodeRef? refOf(Element element) {
    final name = element.name;
    final location = analysis.locationOf(element.firstFragment);
    if (name == null || location == null) return null;
    return CodeRef(name: name, file: location.file);
  }

  final features = <String, Feature>{};
  for (final name in names.toList()..sort()) {
    final files = [
      for (final file in libFiles)
        if (owner(file, 'lib/ui') == name) file,
    ]..sort();
    final tests = [
      for (final file in testFiles)
        if (owner(file, 'test/ui') == name) file,
    ]..sort();

    final viewModels = <ClassElement>[];
    for (final library in analysis.libraries) {
      for (final element in library.result.element.classes) {
        final location = analysis.locationOf(element.firstFragment);
        if (location != null &&
            files.contains(location.file) &&
            location.file.startsWith('lib/ui/$name/view_models/') &&
            _isViewModel(element)) {
          viewModels.add(element);
        }
      }
    }

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
    for (final library in analysis.libraries) {
      for (final unit in library.result.units) {
        final file = analysis.relativePath(unit.path);
        if (file == null || !files.contains(file)) continue;
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
            when files.contains(screen.file) &&
                screen.file.startsWith('lib/ui/$name/widgets/'))
          screen,
    ];

    features[name] = Feature(
      folder: 'lib/ui/$name',
      viewModels: _sorted([
        for (final element in viewModels) ?refOf(element),
      ]),
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

/// The feature [file] sits in: the path below `lib/ui/` up to the first
/// `view_models` or `widgets` folder. Null for `lib/ui/core/`, and for files
/// with no feature folder.
String? _featureName(String file) {
  final segments = file.split('/');
  final marker = segments.indexWhere(
    (segment) => segment == 'view_models' || segment == 'widgets',
    2,
  );
  if (marker <= 2 || segments[2] == 'core') return null;
  return segments.sublist(2, marker).join('/');
}

/// Whether [element] is a view model: a concrete class that extends
/// Flutter's `ChangeNotifier`, directly or through other classes. Abstract
/// base classes don't count (P3).
bool _isViewModel(ClassElement element) =>
    !element.isAbstract &&
    element.allSupertypes.any((type) {
      final uri = type.element.library.uri;
      return type.element.name == 'ChangeNotifier' &&
          uri.scheme == 'package' &&
          uri.pathSegments.isNotEmpty &&
          uri.pathSegments.first == 'flutter';
    });

/// [refs] without duplicates, sorted by name, then file.
List<CodeRef> _sorted(Iterable<CodeRef> refs) {
  final unique = {for (final ref in refs) '${ref.name}\n${ref.file}': ref};
  return unique.values.toList()..sort((a, b) {
    final byName = a.name.compareTo(b.name);
    return byName != 0 ? byName : a.file.compareTo(b.file);
  });
}
```

Create `packages/appstein_engine/lib/src/packs/official_mvvm/official_mvvm_pack.dart`:

```dart
import 'package:appstein_protocol/appstein_protocol.dart';

import '../../map/map_extractor.dart';
import '../../map/project_analysis.dart';
import '../pack.dart';
import 'features.dart';
import 'layer_rules.dart';
import 'routes.dart';

/// The official_mvvm stack pack (spec §10): Flutter's recommended app
/// architecture, as in its compass_app sample.
final class OfficialMvvmPack implements Pack {
  /// Creates the pack.
  const OfficialMvvmPack();

  @override
  String get id => 'official_mvvm';

  @override
  PackKind get kind => PackKind.stack;

  @override
  String get version => '1';

  @override
  List<MapExtractor> get extractors => const [OfficialMvvmExtractor()];

  @override
  LayerRules get layerRules => officialMvvmLayerRules;
}

/// Writes official_mvvm's part of the map: `routes.json` and
/// `features.json`, whose screens come from the routes.
final class OfficialMvvmExtractor implements MapExtractor {
  /// Creates the extractor.
  const OfficialMvvmExtractor();

  @override
  Map<String, Map<String, Object?>> extract(ProjectAnalysis analysis) {
    final routes = readRoutes(analysis);
    final features = readFeatures(
      analysis,
      routes: routes,
      matcher: LayerMatcher(officialMvvmLayerRules),
    );
    return {
      MapFiles.routes: routes.toJson(),
      MapFiles.features: features.toJson(),
    };
  }
}
```

Create `packages/appstein_engine/lib/official_mvvm.dart`:

```dart
/// The official_mvvm stack pack (spec §10), for the CLI to register. It is a
/// library of its own because the engine core never imports a pack (§5.1).
library;

export 'src/packs/official_mvvm/layer_rules.dart';
export 'src/packs/official_mvvm/official_mvvm_pack.dart';
```

In the repo root's `analysis_options.yaml`, give that library the pack's tag. Change the line

```yaml
    pack.official_mvvm: [packages/appstein_engine/lib/src/packs/official_mvvm/**]
```

to

```yaml
    pack.official_mvvm: [packages/appstein_engine/lib/src/packs/official_mvvm/**, packages/appstein_engine/lib/official_mvvm.dart]
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test test/packs/official_mvvm/`
Expected: PASS.

Run `fvm dart analyze --fatal-infos` from the repo root. Expected: no issues; in particular, no `layer_imports` finding for `official_mvvm.dart`.

- [ ] **Step 5: Commit**

```bash
git add packages/appstein_engine analysis_options.yaml
git commit -m "feat(official_mvvm): features.json, the layer rules, and the pack"
```

---

### Task 10: `KnowledgeSync` — the platform layer and the map, under one lock, with goldens

**Files:**
- Create: `packages/appstein_engine/lib/src/knowledge/generated_file.dart`
- Modify: `packages/appstein_engine/lib/src/knowledge/knowledge_store.dart`
- Modify: `packages/appstein_engine/lib/src/knowledge/platform_sync.dart`
- Create: `packages/appstein_engine/lib/src/map/map_sync.dart`
- Create: `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart`
- Modify: `packages/appstein_engine/lib/appstein_engine.dart`
- Modify: `packages/appstein_engine/test/support/fixture_app.dart` (+ `expectGolden`, `readMapBody`, `goldenText`)
- Create: `packages/appstein_engine/test/fixtures/apps/goldens/{deps,features,layers,routes,symbols}.json.golden` (generated, then reviewed)
- Test: `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart`

**Interfaces:**
- Consumes: everything from Tasks 2–9; `PlatformSync`, `KnowledgeStore`, `inputHash`, `knowledgeFormatVersion` (slice 1b.2).
- Produces:
  - `GeneratedFile({required String path, required Map<String, Object?> body, required String inputHash})`.
  - `KnowledgeStore.writeAll(List<GeneratedFile> files, {required String appsteinVersion, required String sdkVersion}) → Future<Map<String, bool>>`. It writes each file, then a `state.json` listing exactly these files.
  - `PlatformSync.build(String projectRoot, {SdkDetection? sdk}) → PlatformBuild`, with `PlatformBuild({sdk, location, files, newestNotes, fallbacks})`. `PlatformSync.run` keeps its behaviour.
  - `SyncReport.map` (`MapReport?`, null for `PlatformSync.run`).
  - `enum PackagesAction { upToDate, fetched, fetchFailed }`.
  - `MapReport({required PackagesAction packages, required String packagesReason, String? skipped})`.
  - `MapBuild({files, report})`; `MapSync({environment, appsteinVersion, packs, runner})` with `build(projectRoot, {required flutterVersion, required flutterRoot, String? dartSdkPath}) → Future<MapBuild>`.
  - `KnowledgeSync({required environment, required appsteinVersion, List<Pack> packs = const [], CuratedNotes? notes, ProcessRunner? runner, clock, lockTimeout})` with `run(String projectRoot, {SdkDetection? sdk, String? dartSdkPath}) → Future<SyncReport>`.

- [ ] **Step 1: Add the golden helpers to the test support**

Append to `packages/appstein_engine/test/support/fixture_app.dart`, and add `import 'package:appstein_engine/appstein_engine.dart';` and `import 'package:test/test.dart';` to its imports:

```dart
/// The body of `.appstein/map/<name>` in [project], without its `meta`.
Map<String, Object?> readMapBody(String project, String name) =>
    (jsonDecode(
              File(
                p.join(project, '.appstein', 'map', name),
              ).readAsStringSync(),
            )
            as Map<String, Object?>)
        ..remove('meta');

/// The text of the golden for the map file [name].
String goldenText(String name) => File(
  p.join(fixtureAppsDir, 'goldens', '$name.golden'),
).readAsStringSync().replaceAll('\r\n', '\n');

/// Checks [body] (a map file without its `meta`) against the golden file
/// `test/fixtures/apps/goldens/<name>.golden`.
///
/// With the environment variable `APPSTEIN_UPDATE_GOLDENS=1` it writes the
/// golden instead. That is the one time a test writes into the repo: review
/// the diff before committing it (see the developer guide's testing page).
void expectGolden(String name, Map<String, Object?> body) {
  final golden = File(p.join(fixtureAppsDir, 'goldens', '$name.golden'));
  final actual = canonicalJson(body);
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
        'The map differs from ${golden.path}. If the change is intended, '
        'rerun with APPSTEIN_UPDATE_GOLDENS=1 and review the diff.',
  );
}
```

- [ ] **Step 2: Write the failing tests**

Create `packages/appstein_engine/test/knowledge/knowledge_sync_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/fake_sdk.dart';
import '../support/fixture_app.dart';
import '../support/flutter_fixtures.dart';
import '../support/temp.dart';

void main() {
  late String sdk;
  late FakeProcessRunner runner;

  setUp(() {
    sdk = createFakeSdk(p.join(tempDir().path, 'flutter'));
    addToolchainFiles(sdk, '3.47.5');
    runner = FakeProcessRunner();
  });

  String flutter() =>
      p.join(sdk, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter');

  KnowledgeSync sync({List<Pack> packs = const [OfficialMvvmPack()]}) =>
      KnowledgeSync(
        environment: fakeEnvironment({'FLUTTER_ROOT': sdk}),
        appsteinVersion: '0.1.0-dev',
        packs: packs,
        runner: runner,
        clock: () => DateTime.utc(2026, 10, 1, 9),
      );

  Map<String, Object?> state(String project) =>
      jsonDecode(
            File(p.join(project, '.appstein', 'state.json')).readAsStringSync(),
          )
          as Map<String, Object?>;

  test('the first sync writes the platform layer and the five map files, '
      'which match the goldens', () async {
    final app = copyFixtureApp();
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.files, {
      'platform/sdk.json': true,
      'platform/toolchain.json': true,
      for (final path in MapFiles.all) path: true,
    });
    expect(report.map!.packages, PackagesAction.upToDate);
    expect(report.map!.skipped, isNull);
    expect(runner.calls, isEmpty);
    for (final path in MapFiles.all) {
      final name = p.posix.basename(path);
      expectGolden(name, readMapBody(app, name));
    }
    expect(
      (state(app)['files']! as Map).keys,
      unorderedEquals(['platform/sdk.json', 'platform/toolchain.json', ...MapFiles.all]),
    );
    final meta = KnowledgeMeta.fromJson(
      (jsonDecode(
                File(
                  p.join(app, '.appstein', 'map', 'symbols.json'),
                ).readAsStringSync(),
              )
              as Map<String, Object?>)['meta']!
          as Map<String, Object?>,
    );
    expect(meta.sdkVersion, '3.47.5');
    expect(meta.generatedAt, '2026-10-01T09:00:00Z');
  });

  test('a second sync changes nothing', () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    final second = await sync().run(app, dartSdkPath: testDartSdk);
    expect(second.files.values, everyElement(isFalse));
  });

  test('stale packages are fetched with flutter pub get in the project '
      'first', () async {
    final app = copyFixtureApp();
    File(
      p.join(app, 'pubspec.yaml'),
    ).setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
    runner.when(flutter(), ['pub', 'get'], const RunResult(exitCode: 0));
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.map!.packages, PackagesAction.fetched);
    expect(
      report.map!.packagesReason,
      'pubspec.yaml changed after they were fetched',
    );
    expect(runner.calls, ['${flutter()} pub get']);
    expect(runner.workingDirectories, [app]);
    expect(report.files.keys, containsAll(MapFiles.all));
  });

  test('when pub get fails, the platform layer is written and the map is '
      'skipped', () async {
    final app = copyFixtureApp();
    File(p.join(app, '.dart_tool', 'package_config.json')).deleteSync();
    runner.when(
      flutter(),
      ['pub', 'get'],
      const RunResult(exitCode: 69, stderr: 'Could not reach pub.dev.'),
    );
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.files.keys, ['platform/sdk.json', 'platform/toolchain.json']);
    expect(report.map!.packages, PackagesAction.fetchFailed);
    expect(report.map!.packagesReason, contains('Could not reach pub.dev.'));
    expect(report.map!.skipped, 'the packages could not be fetched');
    expect(Directory(p.join(app, '.appstein', 'map')).existsSync(), isFalse);
    expect((state(app)['files']! as Map).keys, [
      'platform/sdk.json',
      'platform/toolchain.json',
    ]);
  });

  test('an incomplete Dart SDK skips the map, saying why', () async {
    final app = copyFixtureApp();
    final empty = Directory(p.join(tempDir().path, 'dart-sdk'))..createSync();
    final report = await sync().run(app, dartSdkPath: empty.path);
    expect(report.map!.skipped, contains('lib/core/core.dart'));
    expect(report.files.keys, isNot(contains(MapFiles.symbols)));
  });

  test('a project that is not official_mvvm still gets its map', () async {
    final project = p.join(tempDir().path, 'plain app');
    File(p.join(project, 'lib', 'plain.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync("/// Says hi.\nString hi() => 'hi';\n");
    File(p.join(project, 'pubspec.yaml')).writeAsStringSync(
      'name: plain_app\nenvironment:\n  sdk: ^3.12.0\n',
    );
    writeStubPackages(project);
    final report = await sync().run(project, dartSdkPath: testDartSdk);
    expect(report.map!.skipped, isNull);
    expect(readMapBody(project, 'features.json'), {'features': <String, Object?>{}});
    expect(readMapBody(project, 'routes.json'), {
      'routes': <Object>[],
      'routers': <Object>[],
    });
    expect(readMapBody(project, 'symbols.json'), {
      'symbols': [
        {
          'name': 'hi',
          'kind': 'function',
          'file': 'lib/plain.dart',
          'line': 2,
          'layer': null,
          'feature': null,
          'summary': 'Says hi.',
        },
      ],
    });
    expect(readMapBody(project, 'deps.json'), {'packages': <String, Object?>{}});
  });

  test('a hand-edited map file is put back, and only it', () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    File(p.join(app, '.appstein', 'map', 'routes.json')).writeAsStringSync('{}');
    final second = await sync().run(app, dartSdkPath: testDartSdk);
    expect(second.files[MapFiles.routes], isTrue);
    expect(
      {
        for (final MapEntry(:key, :value) in second.files.entries)
          if (key != MapFiles.routes) key: value,
      }.values,
      everyElement(isFalse),
    );
  });

  test('without packs, only the generic map files are written, with no '
      'layers', () async {
    final app = copyFixtureApp();
    final report = await sync(packs: const []).run(
      app,
      dartSdkPath: testDartSdk,
    );
    expect(report.files.keys, [
      'platform/sdk.json',
      'platform/toolchain.json',
      MapFiles.deps,
      MapFiles.layers,
      MapFiles.symbols,
    ]);
    final layers = LayersMap.fromJson(readMapBody(app, 'layers.json'));
    expect(layers.violations, isEmpty);
    expect(layers.files.values.map((f) => f.layer), everyElement(isNull));
  });
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd packages/appstein_engine && fvm dart test test/knowledge/knowledge_sync_test.dart`
Expected: FAIL. `KnowledgeSync` doesn't exist.

- [ ] **Step 4: Implement**

Create `packages/appstein_engine/lib/src/knowledge/generated_file.dart`:

```dart
/// A generated `.appstein/` file, built but not yet written.
final class GeneratedFile {
  /// Creates the file.
  const GeneratedFile({
    required this.path,
    required this.body,
    required this.inputHash,
  });

  /// Its path inside `.appstein/`, with `/`, such as `map/routes.json`.
  final String path;

  /// Its content, without `meta` (the store adds that).
  final Map<String, Object?> body;

  /// The hash of everything it was built from (spec §6.2).
  final String inputHash;
}
```

In `packages/appstein_engine/lib/src/knowledge/knowledge_store.dart`, add `import 'generated_file.dart';` and this method after `writeState`:

```dart
  /// Writes each of [files] with [writeGenerated], then `state.json` listing
  /// exactly these files' input hashes. Returns whether each file was
  /// written, in the order given. Call it inside [locked].
  Future<Map<String, bool>> writeAll(
    List<GeneratedFile> files, {
    required String appsteinVersion,
    required String sdkVersion,
  }) async {
    final written = <String, bool>{};
    for (final file in files) {
      written[file.path] = await writeGenerated(
        file.path,
        file.body,
        inputHash: file.inputHash,
        appsteinVersion: appsteinVersion,
        sdkVersion: sdkVersion,
      );
    }
    await writeState(
      KnowledgeState(
        formatVersion: knowledgeFormatVersion,
        appsteinVersion: appsteinVersion,
        lastSync: now(),
        files: {for (final file in files) file.path: file.inputHash},
      ),
    );
    return written;
  }
```

In `packages/appstein_engine/lib/src/knowledge/platform_sync.dart`:
- import `generated_file.dart`, `../map/map_sync.dart` and `../sdk/flutter_sdk_locator.dart`;
- add `this.map` to `SyncReport`'s constructor and this field:

```dart
  /// What the project-map part of the sync did; null when only the platform
  /// layer was synced ([PlatformSync.run]).
  final MapReport? map;
```

- add the class `PlatformBuild` before `PlatformSync`:

```dart
/// The platform layer, built but not yet written.
final class PlatformBuild {
  /// Creates the build.
  const PlatformBuild({
    required this.sdk,
    required this.location,
    required this.files,
    required this.newestNotes,
    required this.fallbacks,
  });

  /// The SDK facts, with the notes coverage.
  final SdkInfo sdk;

  /// Where the Flutter SDK is.
  final SdkLocation location;

  /// `platform/sdk.json` and `platform/toolchain.json`.
  final List<GeneratedFile> files;

  /// The newest Flutter minor version the curated notes cover.
  final String newestNotes;

  /// Why parts of the toolchain came from the notes or are unknown.
  final List<String> fallbacks;
}
```

- split `run` into `build` and a shorter `run`: move everything in `run` up to and including the `hashes` map into this new method (unchanged), ending with the `return` shown:

```dart
  /// Builds the platform layer of the project at [projectRoot] without
  /// writing it. [sdk] is the SDK detection to use; by default, the SDK is
  /// detected for the project.
  ///
  /// Throws [SyncException] when no usable SDK is found.
  PlatformBuild build(String projectRoot, {SdkDetection? sdk}) {
    // … the body of the old run(), from `final detection = …` through the
    // `hashes` map, unchanged …
    return PlatformBuild(
      sdk: sdkInfo,
      location: location,
      files: [
        GeneratedFile(
          path: sdkPath,
          body: sdkBody,
          inputHash: hashes[sdkPath]!,
        ),
        GeneratedFile(
          path: toolchainPath,
          body: toolchainBody,
          inputHash: hashes[toolchainPath]!,
        ),
      ],
      newestNotes: notes.newestMinor,
      fallbacks: reading.toolchain.fallbacks,
    );
  }

  /// Syncs only the platform layer of the project at [projectRoot]; `appstein
  /// sync` uses `KnowledgeSync`, which adds the project map. [sdk] is the SDK
  /// detection to use.
  ///
  /// Throws [SyncException] when no usable SDK is found, a
  /// `KnowledgeLockTimeout` when another writer holds the lock too long,
  /// and a `KnowledgeWriteException` when a file can't be written.
  Future<SyncReport> run(String projectRoot, {SdkDetection? sdk}) async {
    final layer = build(projectRoot, sdk: sdk);
    final store = KnowledgeStore(projectRoot, clock: _clock);
    return store.locked(
      () async => SyncReport(
        sdk: layer.sdk,
        files: await store.writeAll(
          layer.files,
          appsteinVersion: appsteinVersion,
          sdkVersion: layer.sdk.flutterVersion,
        ),
        newestNotes: layer.newestNotes,
        fallbacks: layer.fallbacks,
      ),
      timeout: lockTimeout,
    );
  }
```

(`KnowledgeSync` is in backticks, not brackets: `platform_sync.dart` doesn't import it, and an unresolved `[...]` link makes `dart doc` warn, which fails CI's docs job.)

Create `packages/appstein_engine/lib/src/map/map_sync.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../knowledge/generated_file.dart';
import '../knowledge/input_hash.dart';
import '../packs/pack.dart';
import 'dependencies.dart';
import 'layers.dart';
import 'project_analysis.dart';
import 'project_packages.dart';
import 'symbols.dart';

/// What was done about the project's packages before the map was built.
enum PackagesAction {
  /// They were fresh, so nothing was run.
  upToDate,

  /// `flutter pub get` ran and worked.
  fetched,

  /// `flutter pub get` ran and failed, so the map was skipped.
  fetchFailed,
}

/// What the project-map part of a sync did.
final class MapReport {
  /// Creates the report.
  const MapReport({
    required this.packages,
    required this.packagesReason,
    this.skipped,
  });

  /// What was done about the packages.
  final PackagesAction packages;

  /// Why: the packages' status (words that follow "because"), or, after a
  /// failed fetch, what went wrong, with the end of Flutter's output.
  final String packagesReason;

  /// Why the map wasn't written; null when it was.
  final String? skipped;
}

/// The project map, built but not yet written.
final class MapBuild {
  /// Creates the build.
  const MapBuild({required this.files, required this.report});

  /// The map files; empty when the map was skipped.
  final List<GeneratedFile> files;

  /// What happened.
  final MapReport report;
}

/// Builds the project map (spec §6.5).
///
/// First it makes sure the packages are fetched, the way Flutter does. Then
/// it resolves the project, runs the packs' extractors (official_mvvm's
/// features and routes), and builds the generic files: symbols, layers and
/// deps.
final class MapSync {
  /// Creates the sync. [runner] runs `flutter pub get` (a real process by
  /// default).
  MapSync({
    required this.environment,
    required this.appsteinVersion,
    required this.packs,
    ProcessRunner? runner,
  }) : runner = runner ?? const SystemProcessRunner();

  /// The machine.
  final HostEnvironment environment;

  /// The version of the running Appstein; part of every input hash.
  final String appsteinVersion;

  /// The packs whose extractors and layer rules apply.
  final List<Pack> packs;

  /// Runs `flutter pub get`.
  final ProcessRunner runner;

  /// Builds the map of the project at [projectRoot], for Flutter
  /// [flutterVersion] at [flutterRoot]. `dart:` libraries are read from
  /// [dartSdkPath], by default the Flutter SDK's `bin/cache/dart-sdk`.
  ///
  /// It never throws for the project's own problems: a failed fetch or an
  /// incomplete SDK is reported in [MapBuild.report], with no files.
  Future<MapBuild> build(
    String projectRoot, {
    required String flutterVersion,
    required String flutterRoot,
    String? dartSdkPath,
  }) async {
    var status = checkPackages(projectRoot, flutterVersion: flutterVersion);
    final reason = status.reason;
    var action = PackagesAction.upToDate;
    if (!status.fresh) {
      final failure = await fetchPackages(
        projectRoot,
        flutterRoot: flutterRoot,
        os: environment.os,
        runner: runner,
      );
      if (failure != null) {
        return MapBuild(
          files: const [],
          report: MapReport(
            packages: PackagesAction.fetchFailed,
            packagesReason: failure,
            skipped: 'the packages could not be fetched',
          ),
        );
      }
      action = PackagesAction.fetched;
      // A first fetch may have created the workspace reference.
      status = checkPackages(projectRoot, flutterVersion: flutterVersion);
    }

    final ProjectAnalysis analysis;
    try {
      analysis = await ProjectAnalysis.analyze(
        projectRoot,
        dartSdkPath:
            dartSdkPath ?? p.join(flutterRoot, 'bin', 'cache', 'dart-sdk'),
      );
    } on ProjectAnalysisException catch (error) {
      return MapBuild(
        files: const [],
        report: MapReport(
          packages: action,
          packagesReason: reason,
          skipped: error.message,
        ),
      );
    }
    try {
      final bodies = <String, Map<String, Object?>>{};
      for (final pack in packs) {
        for (final extractor in pack.extractors) {
          bodies.addAll(extractor.extract(analysis));
        }
      }
      final featuresBody = bodies[MapFiles.features];
      final features = featuresBody == null
          ? null
          : FeaturesMap.fromJson(featuresBody);
      String? featureOf(String file) => features?.featureOf(file);
      final rules = packs
          .where((pack) => pack.kind == PackKind.stack)
          .firstOrNull
          ?.layerRules;
      final matcher = rules == null ? null : LayerMatcher(rules);
      final lockFile = p.join(status.workspaceRoot, 'pubspec.lock');
      bodies[MapFiles.symbols] = buildSymbols(
        analysis,
        layerOf: (file) => matcher?.tagFor(file),
        featureOf: featureOf,
      ).toJson();
      bodies[MapFiles.layers] = buildLayers(
        analysis,
        rules: rules,
        featureOf: featureOf,
      ).toJson();
      bodies[MapFiles.deps] = buildDeps(analysis, lockFile: lockFile).toJson();

      final hash = _inputHash(
        projectRoot,
        lockFile: lockFile,
        flutterVersion: flutterVersion,
      );
      final paths = bodies.keys.toList()..sort();
      return MapBuild(
        files: [
          for (final path in paths)
            GeneratedFile(path: path, body: bodies[path]!, inputHash: hash),
        ],
        report: MapReport(packages: action, packagesReason: reason),
      );
    } finally {
      await analysis.dispose();
    }
  }

  /// One hash for every map file (P9): every `.dart` file under
  /// [ProjectAnalysis.folders], `pubspec.yaml`, the lock file, the Flutter
  /// version, and the packs' ids and versions.
  String _inputHash(
    String projectRoot, {
    required String lockFile,
    required String flutterVersion,
  }) {
    final inputs = <String, List<int>?>{
      'pubspec.yaml': _bytes(p.join(projectRoot, 'pubspec.yaml')),
      'pubspec.lock': _bytes(lockFile),
      'flutter': utf8.encode(flutterVersion),
      'packs': utf8.encode(
        [for (final pack in packs) '${pack.id}@${pack.version}'].join(','),
      ),
    };
    for (final folder in ProjectAnalysis.folders) {
      final directory = Directory(p.join(projectRoot, folder));
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && entity.path.endsWith('.dart')) {
          final relative = p.split(
            p.relative(entity.path, from: projectRoot),
          );
          inputs['project:${relative.join('/')}'] = _bytes(entity.path);
        }
      }
    }
    return inputHash(
      inputs,
      appsteinVersion: appsteinVersion,
      formatVersion: knowledgeFormatVersion,
    );
  }

  static List<int>? _bytes(String path) {
    try {
      return File(path).readAsBytesSync();
    } on FileSystemException {
      return null;
    }
  }
}
```

Create `packages/appstein_engine/lib/src/knowledge/knowledge_sync.dart`:

```dart
import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../map/map_sync.dart';
import '../notes/curated_notes.dart';
import '../packs/pack.dart';
import '../sdk/sdk_detector.dart';
import 'knowledge_store.dart';
import 'platform_sync.dart';

/// Everything `appstein sync` writes (spec §5.4, §6.2): the platform layer
/// and the project map. Both are built first, then written under one lock,
/// with a `state.json` that lists them.
final class KnowledgeSync {
  /// Creates the sync. [packs] are the project's packs (the CLI chooses
  /// them from `appstein.yaml`), [notes] default to the compiled-in curated
  /// notes, [runner] runs `flutter pub get`, and [clock] gives the time.
  KnowledgeSync({
    required this.environment,
    required this.appsteinVersion,
    this.packs = const [],
    CuratedNotes? notes,
    ProcessRunner? runner,
    this._clock,
    this.lockTimeout = const Duration(seconds: 10),
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

  final DateTime Function()? _clock;

  /// Syncs the project at [projectRoot]. [sdk] is the SDK detection to use
  /// (by default it is detected for the project); [dartSdkPath] overrides
  /// where `dart:` libraries are read from, for tests.
  ///
  /// The map is skipped, with the reason in [SyncReport.map], when the
  /// packages can't be fetched or the Dart SDK is incomplete. The platform
  /// layer is still written.
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
    final map = await MapSync(
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
    final store = KnowledgeStore(projectRoot, clock: _clock);
    return store.locked(
      () async => SyncReport(
        sdk: platform.sdk,
        files: await store.writeAll(
          [...platform.files, ...map.files],
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
}
```

In `packages/appstein_engine/lib/appstein_engine.dart`, add `export 'src/knowledge/generated_file.dart';`, `export 'src/knowledge/knowledge_sync.dart';` and `export 'src/map/map_sync.dart';`.

- [ ] **Step 5: Generate the goldens, then review them**

Run: `cd packages/appstein_engine && APPSTEIN_UPDATE_GOLDENS=1 fvm dart test test/knowledge/knowledge_sync_test.dart` (in PowerShell: `$env:APPSTEIN_UPDATE_GOLDENS='1'; fvm dart test test/knowledge/knowledge_sync_test.dart; Remove-Item Env:APPSTEIN_UPDATE_GOLDENS`).

Review every golden against the expectations already pinned in Tasks 5–9. Each must agree exactly:
- **`features.json.golden`:** the JSON in Task 9's "the fixture's features" test.
- **`routes.json.golden`:** the 8 routes and 1 router of Task 8's first test (paths, screens, reasons).
- **`deps.json.golden`:** Task 7's expected JSON.
- **`layers.json.golden`:**
  - 31 files;
  - official_mvvm tags (`lib/routing/**` is `routing`, `lib/main.dart` has no tag, `test/**` and `testing/**` are `test`);
  - exactly one violation, `booking_screen.dart` → `booking_repository_remote.dart` (`ui` → `data.repository`).
- **`symbols.json.golden`:**
  - the kinds of Task 5;
  - summaries such as "A trip the user has booked.";
  - each symbol's layer from official_mvvm's tags (`HomeViewModel` is `ui`, `Booking` is `domain`) and its feature (`HomeViewModel` is `home`).

If one disagrees, the code is wrong, not the expectation. Fix the code and regenerate.

- [ ] **Step 6: Run the tests to see them pass**

Run: `cd packages/appstein_engine && fvm dart test` (whole suite, without the variable).
Expected: PASS. The platform-sync tests still pass, because `PlatformSync.run` behaves as before.

- [ ] **Step 7: Commit**

```bash
git add packages/appstein_engine
git commit -m "feat(knowledge): sync builds the platform layer and the project map under one lock"
```

---

### Task 11: CLI — `appstein sync` writes the map

**Files:**
- Create: `packages/appstein_cli/lib/src/packs.dart`
- Modify: `packages/appstein_cli/lib/src/sync_command.dart`
- Modify: `packages/appstein_cli/lib/appstein_cli.dart` (export `packsFor` only if the existing exports list each public file; follow the file's pattern)
- Test: `packages/appstein_cli/test/sync_command_test.dart`

**Interfaces:**
- Consumes: `KnowledgeSync`, `MapReport`, `PackagesAction` (Task 10); `OfficialMvvmPack` (Task 9); `loadConfig`, `ConfigException`, `AppsteinConfig` (slice 1a).
- Produces:
  - `List<Pack> packsFor(AppsteinConfig config)`.
  - `formatSyncReport` prints the map's package and skip lines.

- [ ] **Step 1: Write the failing tests**

In `packages/appstein_cli/test/sync_command_test.dart`:

1. In the test `'writes the platform layer and says what it did'`, add after `expect(text, contains('Curated notes cover Flutter 3.47 and earlier.'));`. The fake SDK's `flutter` does nothing, so the fetch can't produce a package config:

```dart
    expect(
      text,
      contains('Project map skipped: the packages could not be fetched.'),
    );
    expect(
      text,
      contains(
        'Run `flutter pub get` in the project to see the whole error, then '
        '`appstein sync` again.',
      ),
    );
```

2. Append these tests inside `main()`:

```dart
  test('a broken appstein.yaml exits 3 and says what to fix', () async {
    File(
      p.join(project, 'appstein.yaml'),
    ).writeAsStringSync('packs:\n  stack: nope\n');
    expect(await run(['sync']), ExitCodes.appsteinFailed);
    expect(err.toString(), contains('Fix appstein.yaml'));
    expect(Directory(p.join(project, '.appstein')).existsSync(), isFalse);
  });

  SyncReport reportWith(MapReport map) => SyncReport(
    sdk: const SdkInfo(
      flutterVersion: '3.47.5',
      dartVersion: '3.13.4',
      channel: 'stable',
      notesCoverage: NotesCoverage.complete,
    ),
    files: const {'platform/sdk.json': true, 'map/symbols.json': true},
    newestNotes: '3.47',
    fallbacks: const [],
    map: map,
  );

  test('the report says when the packages were fetched', () {
    final text = formatSyncReport(
      reportWith(
        const MapReport(
          packages: PackagesAction.fetched,
          packagesReason: 'pubspec.yaml changed after they were fetched',
        ),
      ),
    );
    expect(
      text,
      contains(
        'Fetched the packages with `flutter pub get`, because pubspec.yaml '
        'changed after they were fetched.',
      ),
    );
    expect(text, isNot(contains('Project map skipped')));
  });

  test('the report shows a failed fetch, indented, and what to run', () {
    final text = formatSyncReport(
      reportWith(
        const MapReport(
          packages: PackagesAction.fetchFailed,
          packagesReason:
              '`flutter pub get` failed with exit code 69:\nNo network.',
          skipped: 'the packages could not be fetched',
        ),
      ),
    );
    expect(
      text,
      contains(
        'Could not fetch the packages:\n'
        '  `flutter pub get` failed with exit code 69:\n'
        '  No network.\n'
        'Project map skipped: the packages could not be fetched.\n',
      ),
    );
  });

  test('a skip reason that ends in a full stop is not doubled', () {
    final text = formatSyncReport(
      reportWith(
        const MapReport(
          packages: PackagesAction.upToDate,
          packagesReason: 'they are up to date',
          skipped: 'The Dart SDK at /x is incomplete: it has no '
              'lib/core/core.dart.',
        ),
      ),
    );
    expect(text, contains('lib/core/core.dart.\nFix that, then run'));
    expect(text, isNot(contains('core.dart..')));
  });
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd packages/appstein_cli && fvm dart test test/sync_command_test.dart`
Expected: FAIL. There is no `map` parameter yet, and no map lines in the report.

- [ ] **Step 3: Implement**

Create `packages/appstein_cli/lib/src/packs.dart`:

```dart
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

/// The packs a project's `appstein.yaml` names (spec §7, §10). The CLI
/// chooses them because the engine core never imports a pack (§5.1).
///
/// The config loader accepts only known stacks, so every stack here has a
/// pack. Platform packs arrive with the native map (slice 1b.4).
List<Pack> packsFor(AppsteinConfig config) => switch (config.packs.stack) {
  'official_mvvm' => const [OfficialMvvmPack()],
  final stack => throw StateError('No pack for the stack "$stack".'),
};
```

In `packages/appstein_cli/lib/src/sync_command.dart`:
- import `dart:convert` (for `LineSplitter`) and `packs.dart`;
- update the class doc: "It writes the platform layer (`sdk.json`, `toolchain.json`) and the project map (`map/*.json`), then `state.json`.";
- in `run()`, after the project-root check, load the config and use `KnowledgeSync`:

```dart
    final AppsteinConfig config;
    try {
      config = loadConfig(projectRoot) ?? const AppsteinConfig();
    } on ConfigException catch (error) {
      err
        ..writeln(error)
        ..writeln('Fix appstein.yaml, then run `appstein sync` again.');
      return ExitCodes.appsteinFailed;
    }
    try {
      final report = await KnowledgeSync(
        environment: environment,
        appsteinVersion: appsteinVersion,
        packs: packsFor(config),
      ).run(projectRoot);
```

  (the existing `on SyncException`, `on KnowledgeLockTimeout` and `on KnowledgeWriteException` handlers stay as they are);
- in `formatSyncReport`, add these lines after the loop that prints the file rows:

```dart
  final map = report.map;
  if (map != null) {
    switch (map.packages) {
      case PackagesAction.fetched:
        buffer.writeln(
          'Fetched the packages with `flutter pub get`, because '
          '${map.packagesReason}.',
        );
      case PackagesAction.fetchFailed:
        buffer.writeln('Could not fetch the packages:');
        for (final line in const LineSplitter().convert(map.packagesReason)) {
          buffer.writeln('  $line');
        }
      case PackagesAction.upToDate:
        break;
    }
    if (map.skipped case final skipped?) {
      final reason = skipped.endsWith('.')
          ? skipped.substring(0, skipped.length - 1)
          : skipped;
      buffer
        ..writeln('Project map skipped: $reason.')
        ..writeln(
          map.packages == PackagesAction.fetchFailed
              ? 'Run `flutter pub get` in the project to see the whole error, '
                    'then `appstein sync` again.'
              : 'Fix that, then run `appstein sync` again.',
        );
    }
  }
```

The exit code stays 0 when only the map was skipped (ruling P2).

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd packages/appstein_cli && fvm dart test`
Expected: PASS. Then from the repo root run `fvm dart run tool/gen_docs.dart`: the CLI help is unchanged, so it should report nothing new.

- [ ] **Step 5: Commit**

```bash
git add packages/appstein_cli
git commit -m "feat(cli): appstein sync writes the project map through the project's packs"
```

---

### Task 12: Prove it on real SDKs — the integration test, the 30 s budget and CI

**Files:**
- Create: `packages/appstein_engine/test/support/machine_sdk.dart`
- Modify: `packages/appstein_engine/test/integration/sync_real_environment_test.dart` (use `machineSdk`)
- Create: `packages/appstein_engine/test/integration/map_real_sdk_test.dart`
- Create: `tool/measure_sync.dart`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `KnowledgeSync`, `OfficialMvvmPack`, the fixture helpers and goldens (Task 10).
- Produces: `SdkDetection? machineSdk(HostEnvironment environment)` (test support).

- [ ] **Step 1: Share the machine-SDK lookup**

Create `packages/appstein_engine/test/support/machine_sdk.dart`:

```dart
import 'dart:isolate';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The Flutter SDK Appstein finds for the repo or, failing that, with no
/// project. The min-sdk CI job installs 3.44 while the repo pins 3.47.5, so
/// there only the second lookup works. With neither, the test fails in CI
/// and is skipped elsewhere, and this returns null.
SdkDetection? machineSdk(HostEnvironment environment) {
  // The repo root, from the package itself: other test files change the
  // working folder.
  final engineLibrary = Isolate.resolvePackageUriSync(
    Uri.parse('package:appstein_engine/appstein_engine.dart'),
  )!;
  final repoRoot = p.dirname(
    p.dirname(p.dirname(p.dirname(engineLibrary.toFilePath()))),
  );
  for (final projectRoot in [readFvmPin(repoRoot)?.pinDirectory, null]) {
    final detection = SdkDetector(
      environment,
    ).detect(projectRoot: projectRoot);
    if (detection.info != null && detection.location != null) {
      return detection;
    }
  }
  const reason = 'No usable Flutter SDK on this machine.';
  if (environment.variable('CI') != null) fail(reason);
  markTestSkipped(reason);
  return null;
}
```

In `packages/appstein_engine/test/integration/sync_real_environment_test.dart`:
- delete the local `repoRoot` and `machineSdk()` definitions;
- import `../support/machine_sdk.dart`;
- replace each `machineSdk()` call with `machineSdk(environment)`;
- remove imports that become unused.

- [ ] **Step 2: Write the real-SDK test**

Create `packages/appstein_engine/test/integration/map_real_sdk_test.dart`:

```dart
@Tags(['integration'])
library;

import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/machine_sdk.dart';

void main() {
  final environment = HostEnvironment.current();

  test('the fixture app with the real flutter and go_router gives the map '
      'the stand-ins give', () async {
    final sdk = machineSdk(environment);
    if (sdk == null) return;
    final app = copyFixtureApp(stubs: false);
    final sync = KnowledgeSync(
      environment: environment,
      appsteinVersion: 'integration-test',
      packs: const [OfficialMvvmPack()],
    );

    // No packages yet: sync fetches them with this Flutter (go_router comes
    // from pub.dev).
    final first = await sync.run(app, sdk: sdk);
    expect(
      first.map!.packages,
      PackagesAction.fetched,
      reason: first.map!.packagesReason,
    );
    expect(first.map!.skipped, isNull, reason: first.map!.packagesReason);

    for (final name in [
      'features.json',
      'layers.json',
      'routes.json',
      'symbols.json',
    ]) {
      expectGolden(name, readMapBody(app, name));
    }
    // Versions and transitive packages differ from the stand-ins'; the
    // direct packages' kinds, constraints and usages must not.
    final deps = DepsMap.fromJson(readMapBody(app, 'deps.json'));
    final golden = DepsMap.fromJson(
      jsonDecode(goldenText('deps.json')) as Map<String, Object?>,
    );
    for (final name in ['flutter', 'flutter_test', 'go_router']) {
      final real = deps.packages[name]!;
      final stand = golden.packages[name]!;
      expect(real.dependency, stand.dependency, reason: name);
      expect(real.constraint, stand.constraint, reason: name);
      expect(real.usages, stand.usages, reason: name);
    }
    expect(deps.packages['go_router']!.version, startsWith('18.'));

    // The fetch left fresh packages, so the next sync runs nothing and
    // changes nothing.
    final second = await sync.run(app, sdk: sdk);
    expect(
      second.map!.packages,
      PackagesAction.upToDate,
      reason: second.map!.packagesReason,
    );
    expect(second.files.values, everyElement(isFalse));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
```

Run it on this machine: `cd packages/appstein_engine && fvm dart test --run-skipped --tags integration test/integration/map_real_sdk_test.dart`
Expected: PASS. It needs the network once, for go_router.

If a golden differs only because the real `flutter` or `go_router` declares something the stand-ins declare differently, fix the stand-in, never the golden. For example, a real class might be abstract where the stand-in's isn't. Record the difference in your report.

- [ ] **Step 3: The 30 s budget**

Create `tool/measure_sync.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:path/path.dart' as p;

/// Measures a full `appstein sync` of a generated app with 200 Dart files,
/// against spec §15's target: under 30 s for a 200-file app.
///
/// Usage, from the repo root:
///   fvm dart run tool/measure_sync.dart
///
/// It finds Flutter as `appstein sync` does (FLUTTER_ROOT, FVM, PATH). The
/// first sync also fetches the packages (go_router needs the network), so
/// only the second, a full rebuild of `.appstein/` with fresh packages, is
/// held to the target. Prints a Markdown table and exits 1 when that sync
/// takes 30 s or more.
Future<void> main() async {
  final work = Directory.systemTemp.createTempSync('appstein measure sync ');
  final app = p.join(work.path, 'measure app');
  try {
    _generateApp(app, features: 99);
    final sync = KnowledgeSync(
      environment: HostEnvironment.current(),
      appsteinVersion: 'measure',
      packs: const [OfficialMvvmPack()],
    );
    final first = Stopwatch()..start();
    final report = await sync.run(app);
    first.stop();
    if (report.map?.skipped case final reason?) {
      stderr.writeln(
        'The map was skipped: $reason\n${report.map!.packagesReason}',
      );
      exitCode = 1;
      return;
    }
    Directory(p.join(app, '.appstein')).deleteSync(recursive: true);
    final full = Stopwatch()..start();
    await sync.run(app);
    full.stop();
    final files = Directory(p.join(app, 'lib'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .length;
    stdout.writeln('''
| Measurement (${Platform.operatingSystem}, $files Dart files) | Time |
|---|---|
| First sync, including `flutter pub get` | ${first.elapsedMilliseconds} ms |
| **Full sync with fresh packages (target under 30 s)** | **${full.elapsedMilliseconds} ms** |
''');
    if (full.elapsed >= const Duration(seconds: 30)) {
      stderr.writeln(
        'A full sync took ${full.elapsed.inSeconds} s; spec §15 allows '
        'under 30 s.',
      );
      exitCode = 1;
    }
  } finally {
    try {
      work.deleteSync(recursive: true);
    } on FileSystemException {
      stderr.writeln('warning: could not delete ${work.path}; remove it by hand');
    }
  }
}

/// Writes an official_mvvm app: [features] features with a view model and a
/// screen each, a router with one route per feature, and `main.dart`.
void _generateApp(String app, {required int features}) {
  void write(String relative, String content) => File(p.join(app, relative))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  write(
    'pubspec.yaml',
    'name: measure_app\npublish_to: none\n\nenvironment:\n  sdk: ^3.12.0\n\n'
        'dependencies:\n  flutter:\n    sdk: flutter\n  go_router: ^18.0.0\n',
  );
  final imports = StringBuffer();
  final routes = StringBuffer();
  for (var i = 0; i < features; i++) {
    write(
      'lib/ui/feature_$i/view_models/feature_${i}_view_model.dart',
      "import 'package:flutter/foundation.dart';\n\n"
          "/// Feature $i's state.\n"
          'class Feature${i}ViewModel extends ChangeNotifier {\n'
          '  /// How many times it was tapped.\n'
          '  int taps = 0;\n'
          '}\n',
    );
    write(
      'lib/ui/feature_$i/widgets/feature_${i}_screen.dart',
      "import 'package:flutter/widgets.dart';\n\n"
          "import '../view_models/feature_${i}_view_model.dart';\n\n"
          "/// Feature $i's screen.\n"
          'class Feature${i}Screen extends StatelessWidget {\n'
          '  /// Creates the screen.\n'
          '  const Feature${i}Screen({super.key, required this.viewModel});\n\n'
          '  /// Its state.\n'
          '  final Feature${i}ViewModel viewModel;\n\n'
          '  @override\n'
          "  Widget build(BuildContext context) => Text('\${viewModel.taps}');\n"
          '}\n',
    );
    imports
      ..writeln(
        "import '../ui/feature_$i/view_models/feature_${i}_view_model.dart';",
      )
      ..writeln("import '../ui/feature_$i/widgets/feature_${i}_screen.dart';");
    routes.writeln(
      "    GoRoute(path: '/feature-$i', builder: (context, state) => "
      'Feature${i}Screen(viewModel: Feature${i}ViewModel())),',
    );
  }
  write(
    'lib/routing/router.dart',
    "import 'package:go_router/go_router.dart';\n\n$imports\n"
        '/// The router.\n'
        'GoRouter router() => GoRouter(\n  routes: [\n$routes  ],\n);\n',
  );
  write(
    'lib/main.dart',
    "import 'routing/router.dart';\n\n/// Starts the app.\n"
        'void main() => router();\n',
  );
}
```

Run it here: `fvm dart run tool/measure_sync.dart`. Expected: the table, with the full sync well under 30 s (the spike measured 11 s JIT and 12 s AOT cold on the development machine). Paste the table into your report.

- [ ] **Step 4: CI**

In `.github/workflows/ci.yml`:
- **build job, "Run sync in a scratch project":** after the `test -f "$project/.appstein/platform/toolchain.json"` line, add a line proving the map was written. The scratch project is a plain Dart package, so sync fetches it with `flutter pub get` and maps it:

```yaml
          test -f "$project/.appstein/map/symbols.json"
```

- **min-sdk job:** rename the step "Read the toolchain from this real SDK (spec §12, risk 6)" to "Read the toolchain and map the fixture app with this real SDK (spec §6.5, §12, risk 6)". Change its `run:` to:

```yaml
        run: dart test --run-skipped --tags integration test/integration/sync_real_environment_test.dart test/integration/map_real_sdk_test.dart
```

- **measure job:** add a step after "Measure cold analysis with the plugin (spec §9.1)":

```yaml
      - name: Measure a full sync of a 200-file app (spec §15)
        shell: bash
        run: dart run tool/measure_sync.dart | tee -a "$GITHUB_STEP_SUMMARY"
```

(`tee` hides `measure_sync.dart`'s exit code unless the shell uses `pipefail`. GitHub's `bash` shell runs with `-eo pipefail`, so a slow sync fails the step.)

The test job already runs every integration test (`dart test --run-skipped --tags integration`), so `map_real_sdk_test.dart` runs on Linux, macOS and Windows with no change.

Run `fvm dart run tool/gen_docs.dart`: the CI section of the guide is generated from `ci.yml`.

- [ ] **Step 5: Verify**

From the repo root, run each of these:
- `fvm dart analyze --fatal-infos`;
- `fvm dart format --output=none --set-exit-if-changed .`;
- `fvm dart run dependency_validator`;
- `fvm dart test test`;
- each package's `fvm dart test`;
- `cd packages/appstein_engine && fvm dart test --run-skipped --tags integration`.

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add packages/appstein_engine tool/measure_sync.dart .github/workflows/ci.yml docs/guide
git commit -m "test: map the fixture app with real flutter and go_router; measure the 30 s full sync"
```

---

### Task 13: Docs — the developer guide

**Files:**
- Create: `docs/guide/project-map.md`
- Modify: `docs/guide/README.md`, `docs/guide/knowledge-store.md`, `docs/guide/lints.md`, `docs/guide/running-tools.md`, `docs/guide/cli.md`, `docs/guide/testing.md`, `docs/guide/ci.md`, `docs/guide/architecture.md`, `docs/guide/config.md`

Every page follows `docs/guide/how-to/add-a-guide-page.md`: plain words for a reader who is learning, short paragraphs, links to the code, and a `<!-- covers: … -->` comment. Describe only code that exists now.

- [ ] **Step 1: Write `docs/guide/project-map.md`**

Covers comment:

```
<!-- covers:
packages/appstein_engine/lib/src/map/**
packages/appstein_engine/lib/src/packs/**
packages/appstein_engine/lib/official_mvvm.dart
-->
```

Sections, in this order. Each is prose with small examples taken from the fixture app.

1. **What the map is.** Layer 2 of the knowledge (spec §6.1, §6.5). It lists the five files and what an agent asks of each, and says that `native.json` comes in slice 1b.4.
2. **How sync builds it.** The flow from `KnowledgeSync.run`: platform build, then map build (packages, analysis, extractors, generic files), then one lock and `writeAll`. Use a small ASCII diagram.
3. **Packages first.**
   - Flutter's freshness rule, quoted from `pub.dart`, and why sync copies it.
   - What the report says when it fetches.
   - A failed fetch: the map is skipped, the exit code is 0 (P2), and old map files stay (P10).
   - **Where Appstein differs from Flutter:** the `workspace_ref.json` reading (P1).
   - Flutter 3.47's `pub get` may also update the app's `analysis_options.yaml` (adding `build/` and the platform folders to `exclude:`). Sync triggers this only when `flutter run` would.
4. **Resolving the code.**
   - `ProjectAnalysis`: the `lib/`, `test/` and `testing/` folders, the Dart SDK inside the Flutter SDK, and absolute normalized paths.
   - Code with errors still maps.
   - The user's `exclude:` applies (P5).
   - Speed: the spike's numbers and `tool/measure_sync.dart`.
5. **The generic files.**
   - **symbols:** the kinds, `lib/` only, and the summary rule with examples.
   - **layers:** tags, imports (conditional imports by their main URI, P12) and violations, which equal the lint's (shared `LayerMatcher`, `isInterfaceLibrary` in two places, P7, P8).
   - **deps:** the lock file is the source; constraints come from `pubspec.yaml`, and an override wins; health arrives with the package gate.
6. **The official_mvvm pack.**
   - **The tag table and the allow/interfaces matrix.** Explain why `interfaces` exists, with compass_app's use case as the example.
   - **Features:** the folder rule; `ui/core` is not a feature; the deepest folder owns a file; view models (abstract bases excluded, P3); repositories and services from constructors; models, without use cases (P4); tests.
   - **Routes:** what is read, path joining, screens, and the full "unresolved reasons" table from Task 8; `pageBuilder` precedence (P11).
7. **Packs and the core.**
   - The `Pack` interface and why it is small (§10, E7).
   - `MapExtractor`.
   - Why the core never imports a pack, and how the CLI's `packsFor` wires one in.
8. **Determinism and freshness.** Sorted lists, canonical JSON, and the coarse input hash (P9), which 1b.6 will refine.
9. **Tests.** Links to [testing](testing.md#the-fixture-app-and-goldens).

- [ ] **Step 2: Update the other pages**

- **`README.md` (guide index):** add the project-map page in the reading order, after knowledge-store.
- **`knowledge-store.md`:**
  - `KnowledgeSync` vs `PlatformSync`, `PlatformBuild`, `GeneratedFile` and `writeAll`;
  - `state.json` now lists the map files; when the map is skipped it lists only the platform files (P10);
  - in the "Rewritten when" table, add the map rows (rewritten when any input in P9 changes), and add "or when the file was hand-edited or damaged" to every row. That closes the item parked in slice 1b.2.
- **`lints.md`:**
  - the `interfaces` key with a YAML example;
  - the new correction message ("may import: ui, domain, and the interfaces of data.repository");
  - `LayerMatcher` now lives in the protocol;
  - `isInterfaceLibrary` has an engine twin.
- **`running-tools.md`:** `ProcessRunner.run`'s `workingDirectory`, and why `flutter pub get` uses it instead of passing a path through `flutter.bat`.
- **`cli.md`:** `appstein sync` now reads `appstein.yaml` for the stack pack and writes the map. Show the new report lines (fetched; could not fetch; map skipped), exit 0 when only the map is skipped, and exit 3 for a broken `appstein.yaml`.
- **`testing.md`:** a section "The fixture app and goldens" covering:
  - the app's shape and what each odd file is for (the violation, the unresolved routes, the abstract base);
  - the `.fixture` suffix;
  - the stand-in packages and the hand-written lock file;
  - `copyFixtureApp`, `writeStubPackages`, `testDartSdk` and `lineOf`;
  - goldens: how to update them safely (`APPSTEIN_UPDATE_GOLDENS=1`, review the diff, the code is wrong until proven otherwise);
  - the real-SDK test that proves the stand-ins match real Flutter and go_router;
  - `machineSdk`.
- **`ci.md`:**
  - add `tool/measure_sync.dart` to its covers comment;
  - explain the measure step and the min-sdk step's new test;
  - re-run `gen_docs` so the generated job list is current.
- **`architecture.md`:**
  - the protocol now holds the map formats and `LayerMatcher`;
  - the engine's `map/` and `packs/` folders;
  - how a pack reaches the engine.
- **`config.md`:** `packs.stack` is now read by `sync`, to choose the stack pack.

- [ ] **Step 3: Check the guide**

Run: `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`
Expected: "Guide check passed." If it names a page as stale, that page's prose must change for the code it covers.

- [ ] **Step 4: Commit**

```bash
git add docs/guide
git commit -m "docs: the project map, the official_mvvm pack and the fixture app in the guide (spec §19.6)"
```

---

## Carried to later slices

- **1b.4 (native config):** `native.json` from the `android` and `ios` platform packs (spec §6.5 "Native config"); `packsFor` adds them from `packs.platforms`.
- **1b.5 (version delta):** the items carried from slice 1b.2. The releases manifest isn't in the SDK, and there is the baseline rule for pre-release deprecation messages; both need owner-approved spec wording.
- **1b.6 (incremental sync):**
  - `sync --changed` / `--detect`;
  - per-file project hashes in `state.json`;
  - finer map input hashes than P9;
  - an on-disk analyzer cache (`.dart_tool/appstein/`), needed for the 2 s incremental target (P6).
- **1c (MCP):**
  - `where_is`, `feature` and `route` read `symbols.json`, `features.json` and `routes.json`;
  - readers retry briefly on Windows sharing errors (carried from 1b.2).
- **1d (verify):**
  - `knowledge.stale` compares each map file's `meta.inputHash`;
  - `layer_imports` still ignores conditional-import URIs (carried from 1a).
- **1e (integrate):**
  - writes the `appstein_lints:` section, including `interfaces`, into the project's `analysis_options.yaml` (spec §9.6);
  - `sync` rewrites that section when the pack changes, using `yaml_edit` so the user's comments survive.
- **Unassigned:** reading go_router_builder's typed routes (today one unresolved entry).
- **Still carried from 1b.2:** `notes_parser`'s TypeError on a `0.x` version; the deferred minors listed there; the Android toolchain findings and FVM edge cases from 1b.1.

## Notes from execution

Built subagent-driven in quick mode on 2026-10-01, with PR #8.

- **How it ran:**
  - Tasks 1 and 2 were batched.
  - Each task's review ran alongside the next implementer when their files didn't overlap.
  - Opus reviewed the risky tasks (3, 8 and 10) and the whole branch. Task 13's review was folded into the final review.
  - The goldens were generated in Task 10 and checked against Tasks 5–9 by hand. They matched the real SDK unchanged in Task 12.
- **Owner rulings:**
  - Native config became its own slice.
  - Sync runs `flutter pub get` the way Flutter does.
  - Layer rules match Flutter, with an `interfaces` key.
  - The spec edits were approved before the plan.
  - P4 (use cases aren't feature models) was delegated to the controller and amended into §6.5.
- **Controller rulings during execution:**
  - **Routes tests (Task 8):** five of the fourteen unresolved reasons had no test in the plan, including the whole `StatefulShellRoute` error group. Tests were added for them, plus `pageBuilder` together with `builder`, a project class named `GoRoute`, and a `ShellRoute` under a `GoRoute`.
  - **`null` arguments:** an explicit `null` argument counts as absent, as in go_router. `redirect: null` is no redirect, and `pageBuilder: null` no longer hides a working `builder:`.
  - **A broken `pubspec.lock` or `pubspec.yaml` (Task 10):** a missing, unreadable, non-YAML or non-map file throws `DependenciesException`. The map is skipped with that reason and "run `flutter pub get`", and the old map files stay (P10).
    - Before, a merge-conflicted lock, which is newer than `pubspec.yaml` and so "fresh", gave a `deps.json` claiming no packages.
    - An unreadable folder while hashing the inputs is reported the same way.
    - Tests now pin P10's second half (a failed fetch keeps the old map) and P9 (editing a `lib/` file changes every map file's `meta.inputHash`, and `state.json` agrees).
  - **Final review:**
    - `ProjectAnalysis` now skips only part files. Any other library the analyzer can't resolve, or one outside the project, skips the map with a reason instead of vanishing. This path has no test, because no real project reaches it.
    - The map's input hash also covers the project's `analysis_options.yaml`, because its `exclude:` changes which files are in the map (P5, P9).
    - Guide text that said the lint and `layers.json` disagree on conditional imports was wrong: both read the main URI.
    - `PlatformSync.run` gets a doc note instead of `@visibleForTesting`, so there is no new dependency.
  - **Deferred:** an unexpected exception in the map build (an analyzer bug, say) still aborts the whole sync, platform layer included. A catch-all needs its own design.
- **Lessons:**
  - **Plans' test lists need a coverage check against their own tables.** Task 8's reason table had 14 rows, but its tests pinned 9.
  - **Ask the implementer what the code does at a seam the plan glossed over.** Asking where `flutterVersion` came from and what a malformed lock did surfaced the silent empty `deps.json`.
  - **Flutter's `pub.dart` is stricter than it looks.** Equal timestamps count as stale, and invalid `workspace_ref.json` JSON crashes `flutter`; Appstein falls back instead.
- **Verification:**
  - **Windows development machine:** engine 403 (3 integration tests skipped by default), CLI 28, lints 19, protocol 48, repo tools 211. The real-SDK map test passed with go_router 18.0.2 fetched from pub.dev, matching the goldens.
  - **Checks:** `analyze --fatal-infos`, format, `dependency_validator` and `check_guide` are all clean.
  - **`appstein sync` by hand:** on a bare Dart package in a folder with a space, it wrote all five map files and both platform files, with `"fallbacks": []`.
  - **`tool/measure_sync.dart`:** a full sync of a 200-file app took 9.5 s and 11.4 s on two runs, against 30 s. A first sync that also ran `flutter pub get` took 15 s to 33 s, depending on the network.
- **Still to prove in CI:**
  - the goldens on Linux and macOS;
  - go_router 18 resolving on Flutter 3.44 in the min-sdk job (if it doesn't, relax the fixture's constraint);
  - the build job's AOT sync writing `map/symbols.json` on all three OSes.
- **Carried to later slices** (from the task and final reviews, beyond the list above):
  - **1b.4:** duplicate extractor output paths become a `StateError` when a second pack arrives.
  - **1b.6:**
    - the linear scans in `FeaturesMap.featureOf` and `readFeatures`;
    - the missing `checkPackages` tests (an unreadable file, a reference without `workspaceRoot`, a fetch in a workspace member);
    - path-dependency sources in the input hash.
  - **1c:** `fromJson` failure tests for every map file.
  - **1d:** checking conditional imports' alternative URIs, in both the lint and `layers.json`.
  - **1e:**
    - validating an `interfaces` entry for a tag with no `allow` entry;
    - the lint is silent in a user's app until 1e writes the `appstein_lints:` section.
  - **Hooks slice:** a shorter `pub get` budget when offline at session start; an AOT cold measurement of sync.
  - **Unassigned:**
    - `docSummary` stops at "e.g.";
    - repositories in generic constructor types (`List<FooRepository>`);
    - a `routes:` list held in a variable;
    - a failed fetch dropping the reason it fetched;
    - `ast_values` unit tests;
    - a shared case table for the two `isInterfaceLibrary` copies.
