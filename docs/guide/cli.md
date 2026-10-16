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
| [`lib/appstein_cli.dart`](../../packages/appstein_cli/lib/appstein_cli.dart) | The barrel: it exports every file below except `doctor_command.dart`, `project_option.dart`, `failure.dart` and `finding_text.dart`, and from `verify_hook.dart` only the input, the reply and the two reply functions. `bin/appstein.dart` and the repo's `tool/src/generators.dart` import it |
| [`run_guarded.dart`](../../packages/appstein_cli/lib/src/run_guarded.dart) | `runGuarded`: crash safety and the process exit code |
| [`runner.dart`](../../packages/appstein_cli/lib/src/runner.dart) | `runAppstein`, the command runner and `reportCrash` |
| [`doctor_command.dart`](../../packages/appstein_cli/lib/src/doctor_command.dart) | The `doctor` command |
| [`sync_command.dart`](../../packages/appstein_cli/lib/src/sync_command.dart) | The `sync` command |
| [`mcp_command.dart`](../../packages/appstein_cli/lib/src/mcp_command.dart) | The `mcp` command, `mcpSyncFactory` and `keptCodeAnalysis` |
| [`docs_command.dart`](../../packages/appstein_cli/lib/src/docs_command.dart) | The `docs` command and `formatDocs` |
| [`verify_command.dart`](../../packages/appstein_cli/lib/src/verify_command.dart) | The `verify` command, `terminalCodeAnalysis`, `formatVerify` (with `findingLines`, which it shares with hook mode) and `verifyExitCode` |
| [`verify_hook.dart`](../../packages/appstein_cli/lib/src/verify_hook.dart) | Hook mode of `verify`: `parseHookInput`, `readStdinText`, `isClaudeHookRun`, `claudePostToolUseReply`, `claudeFailureReply`, `answerHookFailure` and the `HookReply` they build |
| [`finding_text.dart`](../../packages/appstein_cli/lib/src/finding_text.dart) | `orderedFindings` and `findingLines`: how findings are grouped by file, for `formatVerify` and the hook |
| [`failure.dart`](../../packages/appstein_cli/lib/src/failure.dart) | `describeFailure`, `FailureDescription` and `CannotStart`: how Appstein's failure is worded, for the terminal and the hook |
| [`analysis_guard_command.dart`](../../packages/appstein_cli/lib/src/analysis_guard_command.dart) | The hidden `analysis-server-guard` command, and `analysisGuardCommand` (with `guardCommandFrom`), which says how this process starts it (see [verify](verify.md#the-guard)) |
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

**It returns only once the analysis servers' clean-ups have ended.** A stopped analysis server's half-written cache files are deleted by its guard before the guard ends, and a stop returns when the guard has ended, so the command returns, and the process ends, only after the deletion (see [verify](verify.md#stopping)). `runAppstein` has nothing of its own to wait for.

**Every failure becomes exit code 3.** `runAppstein` wraps everything, including building the runner, in one `try`:

| Caught | What is printed (to stderr) | Exit code |
|---|---|---|
| `UsageException` (a bad option, an unknown command, a bad `--project`) | The message, a blank line, then the usage text | 3 |
| `ConfigException` | `Invalid appstein.yaml: ` and the error | 3 |
| `CodeAnalysisException` (the analysis server of `verify` could not answer) | The reason, then ``Run `appstein doctor` to check your setup.`` No stack trace: it is a broken setup, not a bug to report | 3 |
| `TestRunException` (the project's tests could not be run at all by a full `verify`: no Flutter SDK, or `flutter test` could not be started; a `flutter test` that started and gave no result is a `test.failed` finding with exit 1; see [verify](verify.md#the-tests)) | The reason, then ``Run `appstein doctor` to check your setup.`` No stack trace, for the same reason | 3 |
| `VerifyCheckError` (a check of `verify` threw) | `reportCrash`, with the check's name in the message and the trace of where the check threw | 3 |
| Anything else | `reportCrash`: "Appstein failed unexpectedly", a hint to run `appstein doctor`, and the stack trace | 3 |

No command reaches the `ConfigException` handler today. `doctor` reports an invalid file as a check error, with exit code 1 (see [doctor](doctor.md)). `sync`, `docs` and `verify` catch the exception themselves, print it with a hint, and exit 3 (see [`appstein sync`](#appstein-sync)). The handler is a safety net for any command that loads the config and forgets to catch.

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
2. **Reads `appstein.yaml`** with `loadConfig` (a project with no file gets the defaults), to learn which packs the project uses, the delta's baseline (`delta.baseline`) and the agents (`integrations.agents`, for package skills). [`packsFor`](../../packages/appstein_cli/lib/src/packs.dart) turns `packs.stack` **and `packs.platforms`** into a list of packs: `official_mvvm` gives `OfficialMvvmPack`, and `android` and `ios` give `AndroidPack` and `IosPack`. This is where a pack reaches the engine, which never imports one (see [project-map](project-map.md#packs-and-the-core)).
3. **Runs the engine's `KnowledgeSync`** with those packs, that baseline and those agents: `detect` with `--detect`, `run` without. It writes the platform layer, the version delta, the project map and the native config, then refreshes package skills when they are due (see [package-skills](package-skills.md)).
4. **Prints `formatSyncReport`.**

The report is one line for the SDK, one per file (`written` or `unchanged`, the map files and `map/native.json` included), then the lines about the packages and the map, a `Native config:` line, a package skills line, the notes coverage, and a `toolchain.fallback (info):` line for each part of the toolchain that came from the notes. The lines about the map appear only when something happened, and so does the package skills line ([`formatPackageSkills`](../../packages/appstein_cli/lib/src/sync_command.dart)):

```text
Package skills: refreshed for claude, codex.
Package skills: skipped, because no agent in integrations.agents is set up in this project (claude needs .claude/; codex needs .agents/ or AGENTS.md).
warning: package skills could not be refreshed (the packages could not be fetched); the next appstein sync tries again.
```

A failure reason of several lines keeps its first line in the warning and prints the rest below it, indented. A record that couldn't be saved adds `warning: the package skills record could not be saved (<why>), so the next sync runs package:skills again.` See [package-skills](package-skills.md#what-sync-prints).

Three more kinds of line come from incremental sync:

- A `--detect` that finds nothing changed prints only this line (and writes no knowledge), plus the package skills line when they ran:

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

## `appstein mcp`

`appstein mcp` serves Appstein's tools to an agent over stdio, until the agent closes the connection. It takes no options of its own. Agents start it themselves, so a project's MCP config carries `--project <path>` when the agent's working folder isn't inside the project. What the server does on each call is in [mcp-server](mcp-server.md).

[`mcp_command.dart`](../../packages/appstein_cli/lib/src/mcp_command.dart) does three things:

1. **Finds the project** with `resolveProjectRoot`. There is no fallback: with no `pubspec.yaml` at or above the working folder, it prints two lines to stderr (what is missing, and to start it inside the project or pass `--project`) and exits **3**.
2. **Builds the server.** `mcpSyncFactory` returns a function that builds a new `KnowledgeSync` for every call. Each time it reads `appstein.yaml` with `loadConfig` (so an edited config takes effect at once, and an invalid one makes the replies `stale` instead of stopping the server), turns it into packs with `packsFor`, and sets two things that differ from `appstein sync`: `packageSkills: false`, and one `HeldAnalyzerCache` shared by every call.
3. **Waits** for the server to finish (`server.done`), closes the kept analysis server, then exits 0.

**The code analysis is kept.** `keptCodeAnalysis` builds a `KeptAnalysisServer` for the project, with the guard command, the project's own `dart`, and the analysis server's cache folder when the machine names one (`analysisServerEnvironment`, as `terminalCodeAnalysis` for `verify` does; the tests give their servers folders of their own this way), and the server gets its `use` as its code analysis. Nothing is started by that: the first `verify` call starts the analysis server, later calls share it, and it is stopped after 10 minutes without one (see [verify](verify.md#a-kept-server-warm-analysis)). The command closes it in a `finally` when the MCP server is done, so the analysis server and its guard have ended before the command returns. When the command's process is killed instead, the guard ends the analysis server.

**stdout belongs to the protocol.** The channel is made from the process's stdin and stdout (`stdioMcpChannel`). The command writes nothing else there, because the agent would try to read it as a message. `runAppstein` takes an `mcpChannel` for tests, so they run the command in-process with a fake connection.

## `appstein docs`

`appstein docs` renders the human docs into the project's docs folder (the folder `docs.path` names; by default `app` inside the project's `docs` folder), and `appstein docs --check` says whether they are behind without writing a page. What a run does is in [human-docs](human-docs.md); [`docs_command.dart`](../../packages/appstein_cli/lib/src/docs_command.dart) only starts it and prints.

1. **Finds the project and loads `appstein.yaml`**, as `sync` does: no project, or an invalid file, exits **3**.
2. **Calls `runDocs`** with the project's packs and a `KnowledgeSync` built as `sync` builds it, except `packageSkills: false`: package skills start a process and write agent folders, which belongs to `appstein sync`.
3. **Prints `formatDocs` of the outcome, and exits with `docsExitCode` of it:**

| Outcome | Printed | To | Exit code |
|---|---|---|---|
| The docs are turned off (`docs.enabled: false`) | One line saying so | stdout | 0 |
| Nothing needed writing | `docs/app/ is up to date (12 pages).` | stdout | 0 |
| Pages were written or removed | The counts, then a line for each page written or removed. A page whose hand edits were lost says so | stdout | 0 |
| A leftover page a person edited was kept | After the lines above: the page, and to delete it or remove its first line to keep it as a team note | stdout | 0 |
| `--check` found stale pages | Each page with why (`missing`, `behind the app`, `hand-edited`, `has a merge conflict`, `no longer rendered`), then `Run \`appstein docs\`` | stdout | 1 |
| Nothing could be rendered, or a file is in the way | `Nothing in docs/app/ was changed:` and why, any details, then what to do | stderr | 1 |
| A page couldn't be written or removed | The error, and that some pages may already be written | stderr | 3 |

A refusal is exit 1, not 3: the project has something to fix (fetch the packages, move a file), and Appstein itself didn't fail. Unchanged pages are counted and never listed, so a run after one edit prints one or two lines.

## `appstein verify`

`appstein verify` checks the project against its knowledge and prints the findings. What a run does, and every check, is in [verify](verify.md); [`verify_command.dart`](../../packages/appstein_cli/lib/src/verify_command.dart) only starts it and prints.

1. **Reads the flags.** `--fast` runs the fast checks, `--full` (the default) runs them all; both together is a usage error. `--format` is `text` (the default) or `json`. `--files <paths>` (comma-separated, or the option repeated; a folder stands for the Dart files under it) adds files to the [unverified files](verify.md#the-unverified-files); without `--fast` it is a usage error, exit **3**, since the default is a full run. `--apply` (full runs only) fixes and formats the project before the checks ([`--apply`](verify.md#--apply)); with `--fast` it is a usage error, exit **3**, and nothing is rewritten. `--hook claude` (with `--fast`) makes the command answer as an agent's hook instead of a terminal: it reads the hook's input on stdin and replies with its own exit codes and output ([hook mode](#hook-mode---hook-claude) below); `--hook codex`, `--hook` with `--format` and `--hook` without `--fast` are usage errors, exit **3**.
2. **Finds the project and loads `appstein.yaml`**, as `docs` does: no project, or an invalid file, exits **3**. The `--files` paths are then resolved against the project root (`resolveVerifyFiles`), not the folder `verify` runs in; a path outside the project is a usage error, exit **3**.
3. **Calls `runVerify`** with the project's packs, `checksFor(packs)`, the `--files` paths and a `KnowledgeSync` built as `docs` builds it, with `packageSkills: false`. The call is wrapped in `terminalCodeAnalysis`: the run gets an analysis server of its own, started behind the guard when a check first asks and stopped when the run ends, normally or with an error (see [verify](verify.md#the-analysis-server)). With `--apply`, `applyToProject` runs first, inside the same scope and on the same server, so the refresh `runVerify` starts with and its reading are of the rewritten files; the files it wrote are added to the result (`withApplied`).
4. **Prints the result to stdout**, as `formatVerify` (which starts with the files `--apply` rewrote, when there are any) or as indented JSON (whose `applied` lists them, empty without `--apply`), and exits with `verifyExitCode`: **1** when a finding is an error, else **0**.

Findings are the command's answer, so they go to stdout in both formats, errors included. stderr is for Appstein's own failures. A check that throws isn't caught here: `runAppstein` reports the `VerifyCheckError` and exits 3. An analysis server that can't answer isn't either: `runAppstein` prints the `CodeAnalysisException`'s reason and exits 3. Tests that can't be run at all (`TestRunException`: no Flutter SDK, or `flutter test` could not be started) are handled the same way. A `flutter test` that started and ended with a failing exit code without naming a failing test, a run that was stopped at its time limit, and a run whose output ended early are findings (`test.failed`), so they go to stdout and exit 1.

### Hook mode: `--hook claude`

`appstein verify --fast --hook claude` is the command Claude Code's PostToolUse hook runs after every edit (spec §5.4, §9.5). [`verify_command.dart`](../../packages/appstein_cli/lib/src/verify_command.dart) runs the same checks as without `--hook`, through the same `_check`; only what it reads and what it prints change, and those are in [`verify_hook.dart`](../../packages/appstein_cli/lib/src/verify_hook.dart). Hook mode answers the after-edit event (a fast run) so far; the Stop hook (`--full --hook claude`) is not built, and is refused. Three small files carry what hook mode shares with the terminal, so no file imports the other circularly: [`finding_text.dart`](../../packages/appstein_cli/lib/src/finding_text.dart) (`orderedFindings` and `findingLines`, the grouping of findings by file that `formatVerify` and the hook both print, grouped once), [`failure.dart`](../../packages/appstein_cli/lib/src/failure.dart) (`describeFailure`, `CannotStart` and `FailureDescription`: how Appstein's failure is worded, for the terminal and the hook alike) and [`exit_codes.dart`](../../packages/appstein_cli/lib/src/exit_codes.dart).

**The flags.** `--hook codex` is a usage error, exit **3**, saying Codex's hooks are checked in slice 1e. `--hook` with `--format` is a usage error: hook mode has its own output. `--hook claude` without `--fast` is a usage error too, until the Stop hook is built. A usage error is the one failure that keeps exit 3 in hook mode, because it is raised before anything runs and a person fixes it once.

**The input.** The hook's input is Claude Code's JSON on stdin. `readStdinText` reads it, for at most 2 s (`hookInputLimit`): Claude Code writes it and closes the pipe at once, and the limit only protects against a caller that never does, so the input is then taken as missing and the subscription is given up, which lets the process end. It is also empty when stdin is a terminal, closed or unreadable. `parseHookInput` takes the session's ID (`session_id`) and the event name (`hook_event_name`). Input that is empty, not JSON, not an object, or has a field that is not a non-empty string counts as no session, and the run **still checks**: nothing about the input can make a hook skip a check or fail. A leading byte order mark, which a Windows pipe may add, is ignored. The session ID is read and kept in `HookInput`, but nothing uses it yet: a hook run keeps no record per session. `runAppstein` takes `hookInput` for tests, a function that gives the text in place of stdin.

**The answer.** `claudePostToolUseReply` turns the result into a `HookReply` (exit code, stdout, stderr), and `_runAsHook` writes it:

| The run found | Exit | Output |
|---|---|---|
| Errors | **2** | stderr: the errors, grouped by file as the text output groups them (`findingLines`), each with its `fix:` line and a `knowledge:` line when it has a reference. At most 30 (`maxHookFindings`), then ``…and N more: call the `verify` tool for all``, then the checks that did not run (below). Stdout is empty, unless the run has notices (below) |
| Warnings, no error | 0 | stdout: Claude Code's PostToolUse JSON, the warnings (same list, same cut) as the context for the agent |
| Only info findings, or nothing | 0 | nothing at all |
| Appstein failed (what is exit 3 in the terminal) | 0 | stdout: JSON with context telling the agent that verify could not run, why, and that its edit is unchecked, and a `systemMessage` telling the developer the same with "run `appstein doctor`". Stderr has the failure as the terminal prints it, a crash's trace included, for a bug report. Never exit 2 or 3 |

Checks named as not run are said in the context, so silence never hides an unchecked edit: with only info findings or nothing the context is just that list; with warnings it follows them. At exit 2 the same list is appended to stderr, since stderr is the channel Claude Code's docs name as reaching the agent on that code ("shows stderr to Claude; the tool already ran"). The docs also say that a hook that exits 2 and prints valid JSON has its JSON fields read, which the notices rely on.

**Notices.** The run's notices (an analysis server a stop could not end, and how to end it by hand) are no finding. They go to the developer as the JSON `systemMessage`, "Appstein note: …", with exit 0 or beside the errors of exit 2, and they are the whole output when there is nothing else to say.

**The JSON** is the shape Claude Code documents for a PostToolUse hook, and a test pins it:

```json
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"…"},"systemMessage":"…"}
```

`additionalContext` is what the agent sees; `systemMessage` is the message shown to the developer, there for a failure and for notices. A warning after an edit goes to the agent only. Claude Code keeps at most 10,000 characters of any of these strings (`maxHookContextLength`); longer text is saved to a file and the agent gets a preview of it. So **no text of a hook passes the limit**: each finding's message and fix hint are cut at 1,500 characters and its ID, file and reference at 500, the list of checks not run at 2,500, a failure's reason at 4,000, the list of findings by length too (with the "…and N more" line), and the whole text a little under 10,000. A cut text ends with `…(cut)`, and a cut never falls between the two halves of a character outside the basic plane.

**Appstein's failure.** In hook mode every failure is told as in the table instead of reaching exit 3, wherever in the process it happens:

- inside the run, `_runAsHook` catches it (a project that can't be found or an invalid `appstein.yaml`, a `CodeAnalysisException`, a `TestRunException`, a check that threw, any other crash);
- before the command runs (`runAppstein` building the environment, say), the runner's catch-all does, when the arguments name `verify --hook claude` (`isClaudeHookRun`);
- in an error raised outside every future, `runGuarded` does the same for those arguments (it takes them from `bin/appstein.dart`).

All three use `describeFailure`, so the words are the terminal's: `runAppstein` prints the same `FailureDescription` for a terminal run. The details (the reason, `appstein doctor`, and a crash's trace) go to stderr, which Claude Code keeps at exit 0 in its debug log only. A usage error keeps exit 3 in every case, since it is raised before anything runs. Claude Code shows the developer only the first line of stderr for an exit code other than 0 and 2, and the agent nothing, which is why the failure is exit 0 with JSON. The `finally` of `runAppstein` still stops the run's analysis server and waits for its clean-up.

**One answer, ever.** `runGuarded`'s handler can fire while the command is still running (an unawaited future that throws), so a run could answer twice: two JSON documents on stdout, which Claude Code cannot parse, or a failure's exit 0 and then an exit 2 that never blocks. So every writer goes through one `HookAnswer` per run (`runGuarded` makes it and hands it on in the zone, `runAppstein` takes it from there and gives it to the command): `HookAnswer.write` writes the first reply whole, and that reply's exit code stands. A later writer sends nothing to stdout, and to stderr only the details of a failure, and not even those once the first reply was exit 2, because stderr is then what the agent reads and a late trace would push it past the limit. A test starts the command through `runGuarded` in a process of its own and has a crash escape both before and after the command answers: exit 2 with the errors alone, and exit 0 with one failure JSON, respectively.

The hook's code checks take the terminal's route: the run starts an analysis server of its own and stops it. A shared analysis host and a cap on a fast run are later work of slice 1d.7.

`runAppstein` takes `verifyChecks` for tests, which replaces the project's checks, as `doctorChecks` does for `doctor`. It also takes `dartSdkPath` (for `verify` and `mcp`), the Dart SDK the analysis reads `dart:` libraries from and whose `dart` runs the analysis server, and `codeAnalysis`, which replaces the analysis server for `verify` and for the `verify` tool of `mcp`.

**The guard mode.** `appstein analysis-server-guard` followed by a `dart` executable is the guard of an analysis server: Appstein starts it, and the help doesn't list it. What it does and how it is started are in [verify](verify.md#the-guard).

The CLI's own tests use a fake Flutter SDK, which has no Dart SDK, so a run that isn't given one can't build a project map and reports `knowledge.stale`. It couldn't start an analysis server either, so the tests' `run` helper passes `ScriptedCodeAnalysis().scope` unless a test asks for the real server. One test does, with `dartSdkPath: testDartSdk`: it runs the whole path (the command, the guard started as `dart bin/appstein.dart analysis-server-guard`, the server) on a project with a compile error and without it, and checks with [`child_processes.dart`](../../packages/appstein_cli/test/support/child_processes.dart) that no process is left. A test that needs the map passes `dartSdkPath: testDartSdk` (the Dart SDK running the tests; [`dart_sdk.dart`](../../packages/appstein_cli/test/support/dart_sdk.dart)). `verify_command_test.dart` does this for a small healthy project (fresh packages, default config, its docs rendered first with the engine's `runDocs`, which `appstein docs` uses) and sees exit 0 with the summary line alone, in text and in JSON. Runs on the fixture app are in the engine's [`verify_fixture_test.dart`](../../packages/appstein_engine/test/verify/verify_fixture_test.dart), and with the compiled binary in [`tool/measure_sync.dart`](../../tool/measure_sync.dart) (see [ci](ci.md)).

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
  docs     Render the human docs (docs/app/) from the knowledge.
  doctor   Check your environment and explain how to fix problems.
  mcp      Serve Appstein's MCP tools over stdio (started by agents).
  sync     Regenerate the knowledge Appstein keeps in .appstein/.
  verify   Check the project against its knowledge (fast or full).

Run "appstein help <command>" for more information about a command.
```

```text
$ appstein help docs
Render the human docs (docs/app/) from the knowledge.

Usage: appstein docs [arguments]
-h, --help     Print this usage information.
    --check    Write no page; exit 1 if a page is missing, behind the app, edited by hand or no longer rendered.

Run "appstein help" to see global options.
```

```text
$ appstein help doctor
Check your environment and explain how to fix problems.

Usage: appstein doctor [arguments]
-h, --help    Print this usage information.

Run "appstein help" to see global options.
```

```text
$ appstein help mcp
Serve Appstein's MCP tools over stdio (started by agents).

Usage: appstein mcp [arguments]
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

```text
$ appstein help verify
Check the project against its knowledge (fast or full).

Usage: appstein verify [arguments]
-h, --help             Print this usage information.
    --fast             Run only the fast checks, as after every change.
    --full             Run every check, as before a task is done (the default).
    --format           How the findings are printed.
                       [text (default), json]
    --files=<paths>    With --fast: add these files to the unverified files, for this run and after it. Paths are from the project root, or absolute inside the project; a folder stands for its Dart files. Separate them with commas, or repeat the option.
    --apply            With a full run: first apply the fixes `dart fix` would apply and format the whole project (generated files left out), then check. Names each file it rewrote. Without it, verify writes no project file.
    --hook             Answer as the hook of an agent: read its input on stdin and reply the way it reads hooks, with its own exit codes.

          [claude]     Answer as a Claude Code hook (with --fast).
          [codex]      Not available yet: Codex hooks come in a later release.

Run "appstein help" to see global options.
```

<!-- /generated:cli-help -->

## Exit codes

<!-- generated:exit-codes -->

| Code | Name | Meaning |
|---|---|---|
| `0` | `ExitCodes.ok` | No errors. |
| `1` | `ExitCodes.errorsFound` | Errors found. Used by the CLI and CI. |
| `2` | `ExitCodes.hookBlocked` | Errors found in `--hook claude` mode: Claude Code shows stderr to the agent on this code. |
| `3` | `ExitCodes.appsteinFailed` | Appstein itself failed: bad usage, a bad environment or a crash. |

Defined in [exit_codes.dart](../../packages/appstein_cli/lib/src/exit_codes.dart).

<!-- /generated:exit-codes -->

[Spec §9.5](../project/specs/2026-09-29-appstein-design.md#95-exit-codes) defines the codes. `2` is used only by `verify --hook claude`, to block with the errors on stderr ([hook mode](#hook-mode---hook-claude)); in hook mode a failure of Appstein itself is exit `0` with JSON, never `3`.
