<!-- covers:
packages/appstein_lints/lib/**
packages/appstein_protocol/lib/src/layer_rules.dart
packages/appstein_protocol/lib/src/layer_matcher.dart
analysis_options.yaml
-->

# The analyzer plugin and `layer_imports`

The `appstein_lints` package is an analyzer plugin with one rule today, `layer_imports`. This page explains how the plugin is loaded, how the rule finds and applies its rules, and how our own repo uses it.

## Why a plugin

An analyzer plugin runs inside the Dart analysis server, the same process that gives your IDE its errors and warnings. So its diagnostics show up everywhere the analyzer runs: VS Code, IntelliJ, `dart analyze`, CI, and any agent that reads analyzer output. There is no separate tool to run and nothing extra for an agent to learn. The spec's reasons are in [spec §3](../project/specs/2026-09-29-appstein-design.md#3-what-the-research-changed-key-facts) (first-party analyzer plugins) and [§9.6](../project/specs/2026-09-29-appstein-design.md#96-lint-rules-in-m1-appstein_lints-one-test-file-per-rule).

## How the plugin is wired

1. **`analysis_options.yaml` names the plugin.** The root [`analysis_options.yaml`](../../analysis_options.yaml) has a `plugins:` entry for `appstein_lints`, with `path: packages/appstein_lints`, and turns the rule on under `diagnostics:` with `layer_imports: true`.
2. **The analysis server loads `lib/main.dart`.** [`main.dart`](../../packages/appstein_lints/lib/main.dart) has one top-level variable, `plugin`. The analysis server requires exactly that name.
3. **`AppsteinLintsPlugin` registers the rules.** [`appstein_lints_plugin.dart`](../../packages/appstein_lints/lib/src/appstein_lints_plugin.dart) names the plugin `appstein_lints` and, in `register`, calls `registry.registerLintRule` once per rule.
4. **Lint rules are off by default.** A rule registered with `registerLintRule` does nothing until a project lists it under `diagnostics:`. That is why step 1 has to turn it on.

For each file it analyzes, the rule first looks up the layer rules that apply. With none, it registers no visitors, so a project that doesn't use layers pays only for that lookup. With some, it visits the file's import and export directives. The rule is in [`layer_imports_rule.dart`](../../packages/appstein_lints/lib/src/layer_imports/layer_imports_rule.dart).

## `layer_imports`

### What it enforces

Code is divided into **layers**, each a tag with some path globs, and each layer may import only the layers it is allowed to. An `import` or `export` that crosses a forbidden boundary is reported at its URI. For a stack such as `official_mvvm`, this keeps UI code from reaching into data code directly ([spec §9.6](../project/specs/2026-09-29-appstein-design.md#96-lint-rules-in-m1-appstein_lints-one-test-file-per-rule)). On our own repo it enforces the package boundaries of [spec §5.1](../project/specs/2026-09-29-appstein-design.md#51-repository-layout-dart-pub-workspace).

The rule has two diagnostics, both under the name `layer_imports`:

| Unique name | When | Example message |
|---|---|---|
| `layer_imports_forbidden` | An import or export crosses a forbidden boundary | The 'ui' layer can't import 'lib/data/repo.dart', which is in the 'data' layer. The correction lists what 'ui' may import, such as "The 'ui' layer may import: ui, domain, and the interfaces of data.repository." |
| `layer_imports_invalid_config` | The `appstein_lints:` section is invalid, reported once per file | The appstein_lints layer rules in (file) are invalid: (reason) |

A lint's default severity is info, so CI's `dart analyze --fatal-infos` is what makes it fail the build ([ci](ci.md#analyze)).

### Where the rules live

The rules are a **top-level `appstein_lints:` section** in `analysis_options.yaml`, next to `plugins:`, not inside the plugin's `plugins:` entry. The analyzer accepts only a fixed set of keys under a `plugins:` entry and warns `unsupported_option` for any other, and plugins get no configuration API. A top-level section raises no warning, and the rule reads it itself.

### How `LayerConfigFinder` finds them

[`layer_config.dart`](../../packages/appstein_lints/lib/src/layer_imports/layer_config.dart) looks for the rules that apply to a file:

1. **It starts in the file's folder and walks up**, one parent at a time, to the file system root.
2. **In each folder with an `analysis_options.yaml`, it reads the file:**
   - **With a top-level `appstein_lints:` section, that file wins.** Its folder becomes the root that the globs are relative to.
   - **Without one, the walk goes on** to the parent folder.
   - **If the file is broken YAML, or can't be read, the walk stops** with no rules. Falling through to a parent's rules could apply rules the nearer file meant to replace, and the analyzer already reports the broken file.
3. **An invalid section still wins.** The section is parsed with `LayerRules.fromJson`, and the globs are compiled. If either fails, the config keeps the error message, and the rule reports it once per file instead of checking imports.

Two details:

- **It reads through the analyzer's file system**, not `dart:io`. So it sees unsaved changes in the editor, and tests can give it in-memory files.
- **Parsed results are cached** by path, and a cached result is used until the file's modification stamp changes. The walk runs for every analyzed file, so each options file is parsed once, not once per file.

Our repo has one `analysis_options.yaml`, at the root, so every file in it gets the root's rules.

### Matching files to layers

[`LayerMatcher`](../../packages/appstein_protocol/lib/src/layer_matcher.dart) gives each file a tag. It lives in the protocol package, not in the lints, because `appstein sync` uses it too: the lint and `layers.json` in the [project map](project-map.md#layersjson) must tag a file the same way, in the editor and in the map. It works like this:

- **Paths are relative to the options file's folder, with `/` on every OS,** and the globs are matched as POSIX globs (`package:glob`). So one set of rules works on Windows too.
- **The first matching tag wins,** in the order the section declares them. List narrow layers before the wide ones that contain them.
- **Files outside the root,** such as the Dart SDK or the pub cache, get no tag and are never checked. Neither is a file no glob matches.

For each import or export, the rule tags both the importing file and the imported library's file (a `package:` URI is resolved to its file first), then asks the rules whether the import is allowed.

### `LayerRules`

The rules themselves are `LayerRules`, in the protocol package: [`layer_rules.dart`](../../packages/appstein_protocol/lib/src/layer_rules.dart). It lives there because stack packs will produce the rules and the lints package reads them, and those two may only share the protocol package.

- **`layers`:** tag to path globs, in match order. A tag is lowercase words joined by dots, such as `data.repository`, and needs at least one glob.
- **`allow`:** tag to the other tags it may import. Every tag named here must be declared under `layers`.
- **`interfaces`:** tag to the tags whose *interface files* it may import, though not their other files. It is optional, and it follows the same rule as `allow`: every tag named must be declared under `layers`.
- **`mayImport`:** a layer may always import itself, and **a tag with no `allow` entry is unrestricted**. A tag with an empty list may import only itself. Otherwise the import is allowed when the target tag is in `allow`, or when the target file is an interface file and the target tag is in `interfaces`.
- `describeAllowed` writes what a tag may import in words, for the lint's message.
- `fromJson` rejects unknown keys and wrong types with messages written for the person editing the file.

### Interface files

A repository has two files in the official_mvvm layout: an abstract `BookingRepository`, and `BookingRepositoryRemote`, which talks to the network. A view model needs the first one's type, but code in `ui` must not use the second. The `interfaces` key says exactly that:

```yaml
appstein_lints:
  layers:
    ui: [lib/ui/**]
    domain: [lib/domain/**]
    data.repository: [lib/data/repositories/**]
  allow:
    ui: [domain]
  interfaces:
    ui: [data.repository]
```

Here `ui` may import `domain` freely, and a file under `data/repositories/` only when it is an **interface file**: it declares at least one class, and every class it declares is abstract. [`isInterfaceLibrary`](../../packages/appstein_lints/lib/src/layer_imports/interface_library.dart) is that test. It looks at the analyzer's element for the imported library, so it needs no naming convention.

**There are two copies of it.** The engine builds `layers.json` with the same rule, in [`map/interface_library.dart`](../../packages/appstein_engine/lib/src/map/interface_library.dart), because the lints package may not import the engine. Each copy's comment names the other. If you change one, change both, or the lint and the map will disagree about what is a violation.

### Our own boundaries

The bottom of the root [`analysis_options.yaml`](../../analysis_options.yaml) declares Appstein's own layers:

| Tag | Files | May import |
|---|---|---|
| `test` | `packages/*/test/**` | Anything (no `allow` entry) |
| `pack.official_mvvm`, `pack.android`, `pack.ios` | The pack folders under the engine's `lib/src/packs/`, and for `official_mvvm` also its public entry file `lib/official_mvvm.dart` | `engine`, `protocol` |
| `protocol` | `packages/appstein_protocol/**` | Only itself |
| `engine` | `packages/appstein_engine/**` | `protocol` |
| `cli` | `packages/appstein_cli/**` | `engine`, `protocol` and the packs |
| `lints` | `packages/appstein_lints/**` | `protocol` |

- **Order matters.** `test` comes first, so a test file is tagged `test`, not the package it sits in. The pack tags come before `engine` for the same reason.
- **Only the `official_mvvm` pack folder exists so far** (slice 1b.3). The other two tags are ready for the slices that add them. Because only the packs and the CLI may import a pack, the engine's core can't depend on one: see [project-map](project-map.md#packs-and-the-core).

## Why `path:` for the protocol dependency

`appstein_lints` depends on `appstein_protocol` with `path: ../appstein_protocol` in its [`pubspec.yaml`](../../packages/appstein_lints/pubspec.yaml), where the other packages use a version. The analysis server resolves a plugin's dependencies on its own, outside our pub workspace. There, a version constraint would be looked up on pub.dev, where `appstein_protocol` isn't published; a path points straight at the folder.

## Testing rules

Rules are tested with `package:analyzer_testing`, which analyzes small in-memory projects and asserts which diagnostics appear, and where. The tests are in `packages/appstein_lints/test/`: one for the rule and one for `LayerConfigFinder`. `LayerRules` and `LayerMatcher` are tested in the protocol package. [testing](testing.md#lint-tests) explains the setup.

## Debugging

`print` does nothing inside a plugin, and the analysis server must be restarted after a plugin change. See [debugging](debugging.md#the-analyzer-plugin).

## Known gaps

`layer_imports` checks a conditional import or export (`if (dart.library.io) '…'`) only by its main URI, and never checks the `if (...)` alternatives. `layers.json` does the same, with the same expression, so the lint and the map agree. Checking the alternatives is a known gap, carried to slice 1d. This and the plugin's cost are listed in the slice 1a plan's "Carried to later slices" section, in [`2026-09-29-slice-1a-workspace-cli-doctor.md`](../project/plans/2026-09-29-slice-1a-workspace-cli-doctor.md).

## Adding a rule

Follow [How to: add a lint rule](how-to/add-a-lint-rule.md).
