<!-- covers:
packages/appstein_engine/lib/appstein_engine.dart
packages/appstein_protocol/lib/**
-->

# How Appstein works

This is the overview. It shows the parts and how they connect, then points to the page that explains each one.

## What exists now

Appstein is currently:

- a command line, `appstein`, with `--version` and two commands, `doctor` and `sync`;
- an engine behind it, which holds all the logic;
- shared data models;
- an analyzer plugin with one lint rule, `layer_imports`;
- the knowledge Appstein writes into a project's `.appstein/`: the platform layer, the version delta (see [version-delta](version-delta.md)) and the project map of the app's Dart code (see [project-map](project-map.md));
- one pack, `official_mvvm`, which knows Flutter's recommended app architecture.

Native config, the verifier, more packs and the MCP server come in later slices ([spec §18](../superpowers/specs/2026-09-29-appstein-design.md#18-milestones)).

## The four packages

<!-- generated:package-graph -->

```mermaid
graph LR
  appstein_cli --> appstein_engine
  appstein_cli --> appstein_protocol
  appstein_engine --> appstein_protocol
  appstein_lints --> appstein_protocol
```

An arrow means "depends on". Read from each package's `pubspec.yaml`; dev dependencies are left out.

<!-- /generated:package-graph -->

- **protocol** holds data only: `SdkInfo`, `AppsteinConfig` (with one class per section of `appstein.yaml`), `LayerRules`, `Severity` and the `protocolVersion` constant. It imports nothing that touches the machine. See [`appstein_protocol.dart`](../../packages/appstein_protocol/lib/appstein_protocol.dart). Since slice 1b.2 it also defines the `.appstein/` file formats (`KnowledgeMeta`, `KnowledgeState`, `SdkInfo` with notes coverage, `CuratedNote`, `Toolchain`), so the CLI, the future MCP server and the UIs read one format (spec §4 principle 4). Since slice 1b.3 it also defines the **map formats** (`SymbolsMap`, `LayersMap`, `DepsMap`, `FeaturesMap`, `RoutesMap`, in `src/map/`), and `LayerMatcher`, which both the `layer_imports` lint and the engine's `layers.json` use, so a file has the same layer tag in the editor and in the map.
- **engine** holds all behaviour. Environment variables and processes go through two small types in `packages/appstein_engine/lib/src/host/`:
  - `HostEnvironment` for environment variables, the PATH and the OS;
  - `ProcessRunner` for running tools.

  Tests swap them for fakes. File checks are different: tests give them real temporary folders. A few checks (`xcodebuild`, `pod`, `reg`) start a tool by bare name against the real PATH, and some tests skip themselves when a tool isn't installed.
- **cli** parses arguments, calls the engine and prints. `runAppstein()` returns an exit code instead of exiting, so tests run the whole CLI in-process. See [cli](cli.md).
- **lints** runs inside the Dart analyzer, so its rules appear in every IDE and agent. It depends on protocol by a `path:` dependency, because the analysis server resolves a plugin's dependencies outside the workspace. See [lints](lints.md), which also explains how `layer_imports` finds its rules.

Why split it this way: the engine has no command-line code, so the MCP server and agent hooks planned for later slices can call the same engine the CLI does (spec §5.1). The one-way dependencies keep that true, and the `layer_imports` rule enforces them on our own repo.

## One command, end to end

This is what happens when you run `appstein doctor`:

```mermaid
flowchart TD
  A["bin/appstein.dart"] --> B["runGuarded"]
  B --> C["runAppstein"]
  C --> D["command runner (package:args)"]
  D --> E["DoctorCommand.run"]
  E --> F["resolveProjectRoot"]
  F --> G["Doctor.run"]
  G --> H["SdkDetector.detect (once)"]
  H --> I["every DoctorCheck, in parallel"]
  I --> J["DoctorReport"]
  J --> K["formatDoctorReport"]
  K --> L["exit code"]
```

1. `bin/appstein.dart` hands the arguments to `runGuarded`. See [cli](cli.md).
2. `runGuarded` runs the CLI in a guarded zone, so even a stray async error ends with exit code 3. See [cli](cli.md).
3. `runAppstein` builds the command runner and turns any failure into exit code 3. See [cli](cli.md).
4. The command runner, from `package:args`, parses the global options and picks the `doctor` command. See [cli](cli.md).
5. `DoctorCommand.run` asks for the project folder, runs the doctor and prints the report. See [cli](cli.md).
6. `resolveProjectRoot` uses `--project`, or else the nearest folder upward with a `pubspec.yaml`. See [cli](cli.md).
7. `Doctor.run` builds one shared context for every check. See [doctor](doctor.md).
8. `SdkDetector.detect` finds the Flutter SDK **once**, and every check reuses the answer. See [sdk-lookups](sdk-lookups.md).
9. Every `DoctorCheck` runs in parallel. Checks run external tools through `ProcessRunner`. See [doctor](doctor.md) and [running-tools](running-tools.md).
10. The results come back as a `DoctorReport`, in check order. See [doctor](doctor.md).
11. `formatDoctorReport` turns the report into plain text. See [cli](cli.md).
12. The exit code is `1` if any check found an error, and `0` otherwise. See [cli](cli.md).

`appstein sync` follows the same shape: the CLI's `SyncCommand` loads `appstein.yaml`, chooses the packs with `packsFor`, and calls the engine's `KnowledgeSync`. That builds the platform layer (`PlatformSync`: SDK detection, `readToolchain`, `CuratedNotes`) and the project map (`MapSync`: packages, analysis, the packs' extractors), and the version delta (`collectDelta` inside `MapSync`, then `renderDelta`), and hands all of them to `KnowledgeStore`, which writes the files in `.appstein/`. See [knowledge-store](knowledge-store.md) and [project-map](project-map.md).

### How a pack reaches the engine

The engine's core (everything outside `lib/src/packs/official_mvvm/` and `lib/official_mvvm.dart`) never imports a pack: the rule in spec §5.1, enforced by `layer_imports` on this repo. Instead the engine defines a small `Pack` interface (in `lib/src/packs/pack.dart`, exported from the barrel) and the map's `MapExtractor`. A pack lives in its own folder and has its own entry file, `official_mvvm.dart`. The CLI, which may import both, calls `packsFor(config)` and passes the resulting `List<Pack>` into `KnowledgeSync`. From there `MapSync` sees only the interface. A new pack is therefore a new folder, a new entry file, and one line in `packsFor`.

## Where each part is explained

| Engine folder | What it does | Guide page |
|---|---|---|
| `host/` | Environment variables, the PATH, finding executables, running tools | [running-tools](running-tools.md) |
| `config/` | Loads and validates `appstein.yaml` | [config](config.md) |
| `text/` | Edit distance, for "did you mean" hints in config errors | [config](config.md) |
| `sdk/` | Finds the Flutter SDK and reads its versions, including FVM pins | [sdk-lookups](sdk-lookups.md) |
| `android/` | Finds the JDK Flutter uses and the Android SDK | [sdk-lookups](sdk-lookups.md) |
| `doctor/` | The doctor and its checks | [doctor](doctor.md) |
| `project/` | Finds the project folder | [doctor](doctor.md) |
| `knowledge/` | The `.appstein/` store: canonical JSON, input hashes, the lock, `sync` | [knowledge-store](knowledge-store.md) |
| `map/` | The project map: packages, analysis, symbols, layers, deps | [project-map](project-map.md) |
| `delta/` | The version delta: `fix_data` migrations, the deprecations the imports expose, the Markdown | [version-delta](version-delta.md) |
| `packs/` | The `Pack` interface, and `official_mvvm/`: its layer rules, features and routes | [project-map](project-map.md) |
| `notes/` | The curated notes, parsed and compiled in | [knowledge-store](knowledge-store.md) |
| `toolchain/` | Reads the native toolchain matrix from the Flutter SDK | [toolchain](toolchain.md) |

Outside the engine:

| Part | Guide page |
|---|---|
| The lints package, `packages/appstein_lints/` | [lints](lints.md) |
| The guide check, docs generator and hooks installer in `tool/` | [docs-tooling](docs-tooling.md) |
| The CI workflow, `tool/startup_check.dart` and `tool/measure_analyze.dart` | [ci](ci.md) |

## What the engine exports

The barrel file [`appstein_engine.dart`](../../packages/appstein_engine/lib/appstein_engine.dart) exports everything the CLI and the repo tools use: the host types, the config loader, the SDK and Android lookups, the project locator, the doctor and its checks, the knowledge sync and the map builders, the `Pack` interface, and the text helpers. There is one other public entry point, [`official_mvvm.dart`](../../packages/appstein_engine/lib/official_mvvm.dart), which exports the official_mvvm pack for the CLI to register; it is separate so that the core never imports a pack. The code itself lives under `lib/src/`, which by Dart convention is private to the package, and the barrel re-exports it. So a file can move inside `lib/src/` without breaking code that imports the barrel. A few helpers that only the engine itself uses, such as `readAndroidSdkContents` and `fileErrorReason`, live under `lib/src/` without an export; their tests import them from `src/` directly.

Some map helpers are exported even though only the engine uses them today: `ast_values`, `project_packages`, `interface_library` and the `build*` map functions. They are the building blocks of a pack. A pack outside the engine package, which will exist (the `Pack` and `MapExtractor` interface of spec §10), can import only the barrel, so it needs these to read the project's code the way the official_mvvm pack does.
