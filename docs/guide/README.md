# Appstein developer guide: start here

This guide is for people working on Appstein's code without an agent. It explains how the code works **now**, and each page is written in the slice that builds what it describes. For *what* was decided and *why*, read the [design spec](../superpowers/specs/2026-09-29-appstein-design.md). This guide links to it instead of repeating it.

## Set up

1. Install [FVM](https://fvm.app). The repo pins Flutter 3.47.5 in `.fvmrc`.
2. In the repo folder, run:
   ```powershell
   fvm install
   fvm dart pub get
   ```
3. Always use `fvm dart` and `fvm flutter`. A plain `dart` on your PATH may be a different, older SDK. `appstein doctor` warns you when that is the case.

On Windows, everything works in PowerShell, including paths with spaces.

## A tour of the repo

| Folder | What it holds |
|---|---|
| `packages/appstein_protocol/` | Shared data models ([README](../../packages/appstein_protocol/README.md)) |
| `packages/appstein_engine/` | All logic: host access, config, SDK detection, doctor ([README](../../packages/appstein_engine/README.md)) |
| `packages/appstein_cli/` | The `appstein` command, a thin layer over the engine ([README](../../packages/appstein_cli/README.md)) |
| `packages/appstein_lints/` | The analyzer plugin with our lint rules ([README](../../packages/appstein_lints/README.md)) |
| `tool/` | Repo scripts: start-up check, analyze measurement, guide check |
| `docs/` | Spec, plans, research and this guide |

The four packages form a [pub workspace](https://dart.dev/tools/pub/workspaces): one `pubspec.lock` and one `analysis_options.yaml` at the root. The packages may only depend on each other in one direction (spec §5.1), and the `layer_imports` rule enforces that. See [architecture](architecture.md).

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

The guide checker and its test run from the repo root:

```powershell
fvm dart test test/guide_checker_test.dart
fvm dart run tool/check_guide.dart
```

Before you commit, run `fvm dart format .` and `fvm dart analyze --fatal-infos` from the repo root.

## CI

`.github/workflows/ci.yml` runs on every push and pull request:

| Job | What it proves |
|---|---|
| `analyze` | Formatting, analyzer (including `layer_imports`), dependency hygiene |
| `test` | Unit tests on Windows, macOS and Linux, plus `doctor` against each real runner |
| `build` | The AOT binary on all three OSes, under the 200 ms start-up budget |
| `docs` | API docs build cleanly; this guide's links and paths are valid |
| `min-sdk` | Everything still works on the oldest supported Flutter (3.44) |
| `measure` | Cold-analysis timings for the fast-verify budget, in the job summary |
