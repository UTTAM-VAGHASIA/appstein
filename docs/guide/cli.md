<!-- covers:
packages/appstein_cli/lib/**
packages/appstein_cli/bin/**
-->

# The command line

The `appstein_cli` package is the `appstein` command. This page follows a run from start-up to exit code. For the whole system, see [architecture](architecture.md).

## What the CLI does and doesn't

The CLI is a thin layer. It:

- parses arguments;
- calls the engine;
- prints the result and returns an exit code.

It holds no logic of its own. The engine does the work, so later the MCP server and agent hooks can share exactly the same engine (spec §5.1). If you find yourself writing a decision in `packages/appstein_cli/`, it probably belongs in the engine.

| File | What it holds |
|---|---|
| [`bin/appstein.dart`](../../packages/appstein_cli/bin/appstein.dart) | `main`, which hands the arguments to `runGuarded` |
| [`lib/appstein_cli.dart`](../../packages/appstein_cli/lib/appstein_cli.dart) | The barrel: it exports every file below except `doctor_command.dart` and `project_option.dart`. `bin/appstein.dart` and the repo's `tool/src/generators.dart` import it |
| [`run_guarded.dart`](../../packages/appstein_cli/lib/src/run_guarded.dart) | `runGuarded`: crash safety and the process exit code |
| [`runner.dart`](../../packages/appstein_cli/lib/src/runner.dart) | `runAppstein`, the command runner and `reportCrash` |
| [`doctor_command.dart`](../../packages/appstein_cli/lib/src/doctor_command.dart) | The `doctor` command |
| [`sync_command.dart`](../../packages/appstein_cli/lib/src/sync_command.dart) | The `sync` command |
| [`project_option.dart`](../../packages/appstein_cli/lib/src/project_option.dart) | `resolveProjectRoot`, for `--project` |
| [`packs.dart`](../../packages/appstein_cli/lib/src/packs.dart) | `packsFor`: the packs a project's `appstein.yaml` names |
| [`doctor_printer.dart`](../../packages/appstein_cli/lib/src/doctor_printer.dart) | `formatDoctorReport` |
| [`version.dart`](../../packages/appstein_cli/lib/src/version.dart) | `appsteinVersion` and `versionText` |
| [`exit_codes.dart`](../../packages/appstein_cli/lib/src/exit_codes.dart) | `ExitCodes` |

## Start-up and crash safety

**`bin/appstein.dart` calls `runGuarded`.** Two things happen there:

- **It sets `exitCode` instead of calling `exit()`.** `exit()` ends the process at once, even if some of stdout hasn't been written yet. On Windows consoles that can cut off the end of the output. Setting `exitCode` lets the program finish normally, so every line is flushed first.
- **It catches errors nothing else catches.** `runGuarded` runs the CLI inside `runZonedGuarded`. An error thrown from a timer or a forgotten future escapes every `try`, and the Dart VM would exit with 255. The zone catches it instead, prints the crash message with `reportCrash`, and sets exit code 3. If the body finishes after that, it can't overwrite the 3.

**`runAppstein` returns a code instead of exiting.** It takes the arguments plus optional output sinks and fakes, and returns an `int`. Tests call it in-process, with `StringBuffer`s for the output and a made-up environment, so no subprocess is needed (see [testing](testing.md)).

**Every failure becomes exit code 3.** `runAppstein` wraps everything, including building the runner, in one `try`:

| Caught | What is printed (to stderr) | Exit code |
|---|---|---|
| `UsageException` (a bad option, an unknown command, a bad `--project`) | The message, a blank line, then the usage text | 3 |
| `ConfigException` | `Invalid appstein.yaml: ` and the error | 3 |
| Anything else | `reportCrash`: "Appstein failed unexpectedly", a hint to run `appstein doctor`, and the stack trace | 3 |

No command reaches the `ConfigException` handler today. `doctor` reports an invalid file as a check error, with exit code 1 (see [doctor](doctor.md)). `sync` catches the exception itself, prints it with a hint, and exits 3 (see [`appstein sync`](#appstein-sync)). The handler is a safety net for any command that loads the config and forgets to catch.

## Global options

The runner defines two global options:

- **`--version`** prints `versionText()`: the Appstein version, the protocol version and the supported Flutter range. It is checked before any command runs, then the CLI exits 0.
- **`--project <path>`** is read by `resolveProjectRoot`:
  - an explicit path is resolved against the working folder and must contain `pubspec.yaml`, or the CLI stops with a `UsageException` (exit 3);
  - without the option, it is the nearest folder at or above the working folder that has a `pubspec.yaml` (`findProjectRoot` in the engine);
  - if there is none, the project is `null`, and doctor skips its project checks.

## Output

`formatDoctorReport` in [`doctor_printer.dart`](../../packages/appstein_cli/lib/src/doctor_printer.dart) turns a `DoctorReport` into plain text:

- a header with the project folder, or a note that there is none;
- one line per check: a status label, the check's title and its summary;
- the check's detail lines, indented, and a `Fix:` line for warnings and errors;
- a summary line with the counts of errors and warnings, or `No problems found.`

The labels are plain ASCII: `[ok]`, `[info]`, `[warn]`, `[error]` and `[skip]`. Symbols such as ✓ or ✗ come out garbled on Windows consoles that use an older code page. ASCII reads correctly in any of them.

## `appstein sync`

`appstein sync` has one option, **`--detect`**: rebuild only when something the knowledge reads changed, found by content hash. It is what an agent's after-edit hook runs (see [incremental-sync](incremental-sync.md)). Without it, `sync` always rebuilds. There is no `--changed` option: the change list is found by hash, not given by the caller (spec §5.3), and passing `--changed` is a usage error.

A second flag, **`--timings`**, is a measuring aid and is hidden from the help. After the report, it adds one line per step of the sync, `timing <ms> ms  <step>`, from `SyncReport.timings` ([`formatTimings`](../../packages/appstein_cli/lib/src/sync_command.dart)). [`tool/measure_sync.dart`](../../tool/measure_sync.dart) passes it to break each sync's time down (see [incremental-sync](incremental-sync.md#where-the-time-goes)).

[`sync_command.dart`](../../packages/appstein_cli/lib/src/sync_command.dart) does four things:

1. **Finds the project** (`--project` or the nearest `pubspec.yaml`).
2. **Reads `appstein.yaml`** with `loadConfig` (a project with no file gets the defaults), to learn which packs the project uses and the delta's baseline (`delta.baseline`). [`packsFor`](../../packages/appstein_cli/lib/src/packs.dart) turns `packs.stack` **and `packs.platforms`** into a list of packs: `official_mvvm` gives `OfficialMvvmPack`, and `android` and `ios` give `AndroidPack` and `IosPack`. This is where a pack reaches the engine, which never imports one (see [project-map](project-map.md#packs-and-the-core)).
3. **Runs the engine's `KnowledgeSync`** with those packs and that baseline: `detect` with `--detect`, `run` without. It writes the platform layer, the version delta, the project map and the native config.
4. **Prints `formatSyncReport`.**

The report is one line for the SDK, one per file (`written` or `unchanged`, the map files and `map/native.json` included), then the lines about the packages and the map, a `Native config:` line, the notes coverage, and a `toolchain.fallback (info):` line for each part of the toolchain that came from the notes. The lines about the map appear only when something happened.

Three more kinds of line come from incremental sync:

- A `--detect` that finds nothing changed prints only this line (and writes nothing):

  ```text
  Knowledge is current for Flutter 3.47.5 (Dart 3.13.4, stable channel): nothing it reads changed since the last sync.
  ```

- After the `Synced .appstein/ …` line, a rebuild says what changed, with the first five input names (without the `project:` prefix) and how many more:

  ```text
  Changed since the last sync: lib/ui/home/view_models/home_view_model.dart, pubspec.yaml and 3 more.
  ```

  When nothing can be compared with (the first sync), or the change list is empty, a `--detect` that rebuilt says why instead, with the first reason and a count of the rest:

  ```text
  Rebuilt because no sync has run here yet.
  ```

- The analyzer cache adds a line only when something went wrong with it: it could not be used, the analyzer failed while reading it and the analysis ran again, or it could not be saved. The wording is in [incremental-sync](incremental-sync.md#the-analyzer-cache).

The map lines look like this:

```text
Fetched the packages with `flutter pub get`, because pubspec.yaml changed after they were fetched.
```

```text
Could not fetch the packages:
  `flutter pub get` failed with exit code 1:
  Because app depends on go_router ^99.0.0 which doesn't match any versions, version solving failed.
Project map skipped: the packages could not be fetched.
Run `flutter pub get` in the project to see the whole error, then `appstein sync` again.
```

```text
Project map skipped: pubspec.lock is not valid YAML (line 4); run `flutter pub get`.
Fix that, then run `appstein sync` again.
```

When the map was written but the version delta's API lists couldn't be collected, that is a bug in Appstein, not in the project. The output asks for a report and shows the whole error once, indented (the sync still exits 0, and `delta.md` holds the notes only and names just the error's type; see [version-delta](version-delta.md#how-sync-builds-it)):

```text
Version delta: deprecated and removed APIs are missing because of an internal error in Appstein. Please report it, with this error:
  Bad state: <the error's message, every line>
```

The `Native config:` line says how each platform went, in a few words, and appears whenever a platform pack ran. It is printed even when the map was skipped, since `native.json` is still written:

```text
Native config: android read; ios absent: no ios/ folder.
```

When a platform pack crashes, that is also a bug in Appstein. Its section of `native.json` holds only the error's type, the sync still exits 0, and the output asks for a report with the whole error, indented (see [native-config](native-config.md#how-sync-builds-it)):

```text
Native config (ios): missing because of an internal error in Appstein. Please report it, with this error:
  Bad state: <the error's message, every line>
```

**Exit codes.**
- **0 when only the map is skipped.** The platform layer was written, and a project whose packages won't fetch is a project problem, not an Appstein failure. The old map files are left as they were.
- **3 for a broken `appstein.yaml`.** The message is the `ConfigException` (with its file, line and column), then `Fix appstein.yaml, then run appstein sync again.` Nothing is written.
- **3 for the other failures it expects** (no project, no SDK, the lock, a write): each is an environment problem, so it prints a message and exits 3. A failed write adds a line saying what to check (the project folder is writable and `.appstein` is a folder), unless the message already says to run `appstein sync` again.

How the files are written is in [knowledge-store](knowledge-store.md), and how the map is built is in [project-map](project-map.md).

## Help text

This is the exact text `appstein` prints, generated from the CLI itself:

<!-- generated:cli-help -->

```text
$ appstein --help
A knowledge and verification layer for AI agents that build Flutter apps.

Usage: appstein <command> [arguments]

Global options:
-h, --help              Print this usage information.
    --version           Print the Appstein, protocol and supported Flutter versions.
    --project=<path>    The Flutter project to work on. Defaults to the nearest folder at or above the current one that contains pubspec.yaml.

Available commands:
  doctor   Check your environment and explain how to fix problems.
  sync     Regenerate the knowledge Appstein keeps in .appstein/.

Run "appstein help <command>" for more information about a command.
```

```text
$ appstein help doctor
Check your environment and explain how to fix problems.

Usage: appstein doctor [arguments]
-h, --help    Print this usage information.

Run "appstein help" to see global options.
```

```text
$ appstein help sync
Regenerate the knowledge Appstein keeps in .appstein/.

Usage: appstein sync [arguments]
-h, --help      Print this usage information.
    --detect    Rebuild only when something the knowledge reads changed, found by content hash (the after-edit hook).

Run "appstein help" to see global options.
```

<!-- /generated:cli-help -->

## Exit codes

<!-- generated:exit-codes -->

| Code | Name | Meaning |
|---|---|---|
| `0` | `ExitCodes.ok` | No errors. |
| `1` | `ExitCodes.errorsFound` | Errors found. Used by the CLI and CI. |
| `3` | `ExitCodes.appsteinFailed` | Appstein itself failed: bad usage, a bad environment or a crash. |

Defined in [exit_codes.dart](../../packages/appstein_cli/lib/src/exit_codes.dart).

<!-- /generated:exit-codes -->

[Spec §9.5](../superpowers/specs/2026-09-29-appstein-design.md#95-exit-codes) defines the codes, including `2`, which later slices use for agent hook mode.
