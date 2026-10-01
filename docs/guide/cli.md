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

No command reaches the `ConfigException` handler today. `doctor`, the only command that reads `appstein.yaml`, reports an invalid file as a check error, with exit code 1 (see [doctor](doctor.md)). The handler is a safety net for any command that loads the config itself.

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

[`sync_command.dart`](../../packages/appstein_cli/lib/src/sync_command.dart) finds the project (`--project` or the nearest `pubspec.yaml`), runs the engine's `PlatformSync` and prints `formatSyncReport`. That is one line for the SDK, one per file (`written` or `unchanged`), the notes coverage, and a `toolchain.fallback (info):` line for each part of the toolchain that came from the notes. Every failure it expects (no project, no SDK, the lock, a write) is an environment problem, so it prints a message and exits 3. A failed write adds a line saying what to check (the project folder is writable and `.appstein` is a folder), unless the message already says to run `appstein sync` again. How the files are written is in [knowledge-store](knowledge-store.md).

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
-h, --help    Print this usage information.

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
