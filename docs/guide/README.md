<!-- covers: none -->

# Appstein developer guide: start here

This guide is for people working on Appstein's code without an agent. It explains how the code works **now**, and each page is written in the slice that builds what it describes. For *what* was decided and *why*, read the [design spec](../superpowers/specs/2026-09-29-appstein-design.md); this guide is the current system, and it links to the spec instead of repeating it.

## Set up

1. Install [FVM](https://fvm.app). The repo pins Flutter 3.47.5 in `.fvmrc`.
2. In the repo folder, run:
   ```powershell
   fvm install
   fvm dart pub get
   ```
3. Always use `fvm dart` and `fvm flutter`. A plain `dart` on your PATH may be a different, older SDK. `appstein doctor` tells you when that is the case.
4. Install the git hooks: `fvm dart run tool/install_hooks.dart`. It installs graphify's graph rebuilds, a post-commit warning when this guide may have fallen behind the code, a warning when the knowledge graph lacks the current docs, and a background repair of docs a rebuild dropped from it. See [docs-tooling](docs-tooling.md).

On Windows, everything works in PowerShell, including paths with spaces.

## A tour of the repo

| Folder | What it holds |
|---|---|
| `packages/appstein_protocol/` | Shared data models ([README](../../packages/appstein_protocol/README.md)) |
| `packages/appstein_engine/` | All logic: host access, config, SDK detection, doctor, the knowledge store and `sync` ([README](../../packages/appstein_engine/README.md)) |
| `packages/appstein_cli/` | The `appstein` command, a thin layer over the engine ([README](../../packages/appstein_cli/README.md)) |
| `packages/appstein_lints/` | The analyzer plugin with our lint rules ([README](../../packages/appstein_lints/README.md)) |
| `notes/` | The curated notes, compiled into Appstein ([knowledge-store](knowledge-store.md#the-curated-notes)) |
| `tool/` | Repo scripts: start-up check, analyze measurement, the guide check, the docs generator, the hooks installer and the curated notes generator |
| `docs/` | Spec, plans, research and this guide |

The four packages form a [pub workspace](https://dart.dev/tools/pub/workspaces): one `pubspec.lock` and one `analysis_options.yaml` at the root. The packages may only depend on each other in one direction (spec §5.1), and the `layer_imports` rule enforces that. See [architecture](architecture.md).

## Guide map

| Page | Read it to learn |
|---|---|
| [architecture](architecture.md) | How the whole system fits together, and how one command flows through it |
| [cli](cli.md) | How the `appstein` command starts, parses options, prints and exits |
| [doctor](doctor.md) | How `appstein doctor` runs its checks, and what each one looks at |
| [sdk-lookups](sdk-lookups.md) | How Appstein finds the Flutter SDK, the JDK and the Android SDK |
| [knowledge-store](knowledge-store.md) | How `appstein sync` writes `.appstein/`: metadata, input hashes, the lock, and the curated notes |
| [toolchain](toolchain.md) | How the native toolchain matrix is read from the Flutter SDK, and when it falls back to the notes |
| [running-tools](running-tools.md) | How the engine reads the environment and runs external tools safely |
| [config](config.md) | How `appstein.yaml` is loaded and validated |
| [lints](lints.md) | How the analyzer plugin and the `layer_imports` rule work |
| [ci](ci.md) | What each CI job proves, and how to read its results |
| [docs-tooling](docs-tooling.md) | How this guide is checked and generated, and what the git hooks do |
| [testing](testing.md) | How the tests are built: fakes, temporary folders and real-machine tests |
| [debugging](debugging.md) | What to do when something goes wrong |
| [How to: add a doctor check](how-to/add-a-doctor-check.md) | The steps to add a check to `appstein doctor` |
| [How to: add a lint rule](how-to/add-a-lint-rule.md) | The steps to add a rule to the analyzer plugin |
| [How to: add a curated note](how-to/add-a-curated-note.md) | The steps to add or change a curated note |
| [How to: add a guide page](how-to/add-a-guide-page.md) | The steps to add a page to this guide |

## Build and run the CLI from source

```powershell
fvm dart run packages/appstein_cli/bin/appstein.dart --version
fvm dart run packages/appstein_cli/bin/appstein.dart doctor
```

To compile the fast, standalone binary that hooks use:

```powershell
fvm dart compile exe packages/appstein_cli/bin/appstein.dart -o build/appstein.exe
fvm dart run tool/startup_check.dart build/appstein.exe
```

## Run the tests

Tests live in each package. Run them from that package's folder:

```powershell
cd packages/appstein_engine
fvm dart test                      # unit tests
fvm dart test --run-skipped --tags integration   # checks your real machine
```

The tests for `tool/` live in the root `test/` folder. From the repo root, `fvm dart test test` runs all of them. To run one file and the guide check itself:

```powershell
fvm dart test test/guide_checker_test.dart
fvm dart run tool/check_guide.dart
```

See [testing](testing.md) for how the tests are built.

## Before you commit

Run these from the repo root:

```powershell
fvm dart format .
fvm dart analyze --fatal-infos
fvm dart run tool/gen_docs.dart
fvm dart run tool/check_guide.dart --since main
```

The last two keep this guide in step with the code. [docs-tooling](docs-tooling.md) explains what they check.

## CI

`.github/workflows/ci.yml` runs on every pull request, on pushes to `main` and on demand. [ci](ci.md) lists its jobs, generated from the workflow itself, and explains why each one exists.
