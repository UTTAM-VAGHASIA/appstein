# How the code fits together

This page covers what exists after slice 1a. Packs, knowledge, the verifier and the MCP server join it in later slices.

## The four packages

```text
appstein_cli ──► appstein_engine ──► appstein_protocol
                                          ▲
appstein_lints ───────────────────────────┘
```

- **protocol** holds data only: `SdkInfo`, `AppsteinConfig`, `LayerRules` and `Severity`. It has no logic that touches the machine.
- **engine** holds all behaviour. It reaches the machine only through two small types in `packages/appstein_engine/lib/src/host/`:
  - `HostEnvironment` for environment variables, the PATH and the OS;
  - `ProcessRunner` for running tools.

  Tests swap them for fakes, which is why engine tests never depend on what is installed.
- **cli** parses arguments, calls the engine and prints. `runAppstein()` returns an exit code instead of exiting, so tests run the whole CLI in-process.
- **lints** runs inside the Dart analyzer, so its rules appear in every IDE and agent. It depends on protocol by a `path:` dependency, because the analysis server resolves a plugin's dependencies outside the workspace.

## How `appstein doctor` works

1. `bin/appstein.dart` calls `runAppstein()`, in `packages/appstein_cli/lib/src/runner.dart`.
2. The `doctor` command resolves the project: `--project`, or the nearest folder with a `pubspec.yaml`.
3. `Doctor.run()` detects the Flutter SDK **once**. The order is the FVM pin, then FLUTTER_ROOT, then PATH. If the project pins a version that FVM doesn't have installed, FLUTTER_ROOT and PATH are still tried, and the SDK they find is accepted only when its version equals the pin. The code is in `packages/appstein_engine/lib/src/sdk/`.
4. Every check in `packages/appstein_engine/lib/src/doctor/checks/` runs in parallel with that shared context. Each returns a `CheckResult`: ok, info, warning, error or skipped, with a fix hint.
5. The CLI prints the report and exits `1` if any check found an error, `0` otherwise, and `3` if Appstein itself failed (spec §9.5).

To add a check, write a class that implements `DoctorCheck`, test it with the fakes in `packages/appstein_engine/test/support/`, and add it to `defaultDoctorChecks()`.

## How `layer_imports` finds its rules

The analyzer only lets plugins have on/off switches, so the rules live in a **top-level** `appstein_lints:` section of `analysis_options.yaml`. See `LayerConfigFinder` in `packages/appstein_lints/lib/src/layer_imports/`: it walks up from the analyzed file to the nearest options file that has that section. It keeps walking past an options file that has no such section, but it stops at one that can't be read or parsed: no layer rules apply then, and the analyzer reports the broken file. Our own repo's boundaries are declared at the bottom of the root `analysis_options.yaml`.
