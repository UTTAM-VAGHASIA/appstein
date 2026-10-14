<!-- covers:
.github/workflows/**
tool/startup_check.dart
tool/measure_analyze.dart
tool/measure_sync.dart
tool/measure_analysis_server.dart
tool/src/large_build.dart
tool/src/mcp_session.dart
tool/src/process_memory.dart
tool/src/warm_measurement.dart
tool/src/warm_verify.dart
-->

# Continuous integration

CI is one GitHub Actions workflow, [`ci.yml`](../../.github/workflows/ci.yml). It is the gate: local hooks only warn, and CI fails the change. The spec's plan for CI is in §19.3 of the [spec](../project/specs/2026-09-29-appstein-design.md#193-ci-github-actions); this page describes what runs today.

## When CI runs, and how to run it on a branch

CI runs on:

- every pull request;
- every push to `main`;
- a manual run (`workflow_dispatch`).

A push to a feature branch alone doesn't start it. To get CI on a branch, open a **draft pull request**: every push to the branch then runs CI, and the docs job has a base branch to compare with. A one-off manual run also works (`gh workflow run ci.yml --ref <branch>`), but it has no base, so it skips the stale-page part of the guide check.

To read results from the terminal:

```powershell
gh run list
gh run view <run id> --log
```

Job summaries can't be read through `gh` or the API. That is why the `measure` job also `tee`s its table into the log.

## The jobs

<!-- generated:ci-jobs -->

Defined in [ci.yml](../../.github/workflows/ci.yml). Triggers: `push` (`main`), `pull_request`, `workflow_dispatch`.

**`analyze`** runs on `ubuntu-latest`:

1. `actions/checkout@v4`
2. FLUTTER_STABLE matches .fvmrc
3. No raw byte order marks in Dart files
4. `subosito/flutter-action@v2`
5. `dart pub get --enforce-lockfile`
6. `dart format --output=none --set-exit-if-changed .`
7. `dart analyze --fatal-infos`
8. `dart run dependency_validator`

**`test`** runs on `ubuntu-latest`, `windows-latest`, `macos-latest`:

1. `actions/checkout@v4`
2. `subosito/flutter-action@v2`
3. `actions/setup-python@v5`
4. Install graphify for the graph check's tests
5. `dart pub get --enforce-lockfile`
6. Unit tests
7. Doctor and sync against this real machine

**`build`** runs on `ubuntu-latest`, `windows-latest`, `macos-latest`:

1. `actions/checkout@v4`
2. `subosito/flutter-action@v2`
3. `dart pub get --enforce-lockfile`
4. Compile appstein
5. Start-up budget (spec §15)
6. Run doctor (report only)
7. Run sync in a scratch project (the AOT binary reads the SDK)
8. `actions/upload-artifact@v4`

**`docs`** runs on `ubuntu-latest`:

1. `actions/checkout@v4`
2. `subosito/flutter-action@v2`
3. `dart pub get --enforce-lockfile`
4. API docs build without warnings
5. Developer guide check

**`min-sdk`** runs on `ubuntu-latest`:

1. `actions/checkout@v4`
2. `subosito/flutter-action@v2`
3. `flutter --version`
4. `dart pub get`
5. Analyze, which also loads our analyzer plugin on the old SDK
6. Unit tests
7. Read the toolchain and map the fixture app with this real SDK (spec §6.5, §12, risk 6)

**`measure`** runs on `ubuntu-latest`, `windows-latest`, `macos-latest`:

1. `actions/checkout@v4`
2. `subosito/flutter-action@v2`
3. `dart pub get --enforce-lockfile`
4. Measure cold analysis with the plugin (spec §9.1)
5. Measure sync, docs and verify, with the warm 5 s limit (spec §9.1, §15)

<!-- /generated:ci-jobs -->

## Why each job exists

Every job except `min-sdk` uses `FLUTTER_STABLE`, the Flutter version set at the top of `ci.yml`, and runs `dart pub get --enforce-lockfile`. That flag fails if `pubspec.lock` would change, so CI tests exactly the dependency versions that are committed.

### analyze

- **`FLUTTER_STABLE` matches `.fvmrc`.** The Flutter version is written in two places: `.fvmrc` for developers, and `FLUTTER_STABLE` for CI's setup step. This step fails when they differ, so CI never tests a different Flutter from the one developers use.
- **No raw byte order marks.** It fails if any `.dart` file contains the raw U+FEFF character. That character is invisible, and a tool that strips it silently changes a string literal, so Dart code must write it as an escape: a backslash, then `uFEFF`. Editing tools that decode escapes in their input are known to turn the escape back into the raw character, so CI checks for it.
- **Format:** `dart format --set-exit-if-changed` fails on any file that isn't formatted.
- **Analyze:** `dart analyze --fatal-infos` fails on infos too, not only warnings and errors. That makes lints such as `public_member_api_docs` (every public API has a `///` comment) and our own `layer_imports` real gates.
- **Dependencies:** `dependency_validator` fails when a pubspec lists a package the code doesn't use, or the code uses one the pubspec doesn't list.

### test

- It runs on Linux, Windows and macOS, because Appstein must behave the same on all three. `fail-fast: false` lets every OS finish, so one failure doesn't hide another.
- **graphify for the graph check's tests:** it installs graphify, at the version pinned in `GRAPHIFY_VERSION` at the top of `ci.yml`, so the tests of [`tool/check_graph.py`](../../tool/check_graph.py) run on all three systems. It also sets `APPSTEIN_REQUIRE_GRAPHIFY=1`, which makes those tests fail instead of skip if graphify is missing. CI never builds this repo's graph (the repair tests build tiny ones in temp repos); see [docs-tooling](docs-tooling.md#is-the-graph-current) for why the graph itself isn't checked here.
- **Unit tests:** `dart test test` runs the `tool/` tests from the root, then `dart test` runs in each package.
- **Doctor and sync against this real machine:** the engine's `integration`-tagged tests run with `--run-skipped --tags integration`. They compare Appstein's answers with the runner's real Flutter (see [testing](testing.md)). That includes the map test, which runs a real `flutter pub get` for the fixture app and so needs the network (see [testing](testing.md#the-real-sdk-test)).

### build

- **Compile:** `dart compile exe` builds the AOT binary on each OS. Agent hooks will start this binary, not `dart run` ([spec §19.5](../project/specs/2026-09-29-appstein-design.md#195-distribution-and-versioning): "Hooks use the compiled executable").
- **Start-up budget:** [`tool/startup_check.dart`](../../tool/startup_check.dart) runs `appstein --version` seven times and fails if the median is over 200 ms (spec §15). A hook that starts slowly slows down every agent action.
- **Run doctor (report only):** the binary runs `doctor` for real. Exit 0 or 1 is fine, because a CI runner may be missing tools such as the Android SDK. Exit 3 or 255 means Appstein crashed, and the step fails.
- **Run sync in a scratch project:** the binary runs `appstein sync`, and the step fails unless `toolchain.json` has `"fallbacks": []`, so it fails when any part came from the notes and also when a part is unknown. A positive `grep` is used because a negated command (`! grep`) never fails a `bash -e` script unless it is the last command. That proves the analyzer-based toolchain parser works in the AOT binary, not only under `dart run`. The step also checks that `.appstein/map/symbols.json` exists. The scratch project has no `lib/` folder, so the map holds only empty lists. But the file can exist only if sync ran `flutter pub get` for the new project and built the map, so it proves that path works in the compiled binary.
- The binaries are uploaded as build artifacts.

### docs

- **Full history:** the checkout uses `fetch-depth: 0`, because the stale-page check needs the merge base with the base commit.
- **API docs:** `dart doc --dry-run` builds each package's API docs from the `///` comments without writing them. Each package's `dartdoc_options.yaml` (for example [`packages/appstein_cli/dartdoc_options.yaml`](../../packages/appstein_cli/dartdoc_options.yaml)) turns the `unresolved-doc-reference` and `broken-link` warnings into errors, so a doc comment that names something that doesn't exist, or links nowhere, fails the job.
- **Developer guide check:** `tool/check_guide.dart` runs with a `--since` that depends on the event:

  | Event | `--since` |
  |---|---|
  | Pull request | `origin/<base branch>` |
  | Push | The push's `before` commit, when it exists |
  | Manual run, new branch, force push | None: the stale-page part is skipped, with a message in the log |

  A new branch's `before` is all zeros, and a force push's `before` may no longer exist, so there is nothing to compare with. [docs-tooling](docs-tooling.md) explains every part of the check.

### min-sdk

- It uses `FLUTTER_MIN`, the oldest supported Flutter (3.44.x, spec §22 item 14).
- **No `--enforce-lockfile`:** an older SDK may need older versions of some dependencies, and finding that out is the point of this job.
- It runs `dart analyze --fatal-infos`, which also loads our analyzer plugin on the old SDK, and each package's unit tests. It then runs three integration tests against the real Flutter 3.44: `sync_real_environment_test.dart`, which proves the toolchain parsers on the oldest supported SDK (spec §22 risk 6; see [toolchain](toolchain.md)), and `map_real_sdk_test.dart`, which maps the fixture app with the real `flutter` and `go_router` and expects the same goldens as the unit tests. That proves the stand-in packages the unit tests use match the real ones on the oldest SDK (see [testing](testing.md#the-real-sdk-test)). The third is `native_real_sdk_test.dart`, which creates a real app with `flutter create` and checks the native config the packs read from it, on 3.44 (see [native-config](native-config.md#tests)).

### measure

- The job runs on Linux, macOS and Windows, because the warm `verify` limit is held on all three. [`tool/measure_analyze.dart`](../../tool/measure_analyze.dart) runs on Linux and Windows only (`if: runner.os != 'macOS'`): its table has no limit. The tool creates a fresh Flutter app with about 200 generated files and times `dart analyze`:
  - one file without the plugin;
  - the whole project, the first time with the plugin (this includes building the plugin);
  - the whole project with the plugin;
  - one file with the plugin.
- A deliberate layer violation, the canary, proves the plugin really ran: with the plugin on, the whole-project run must report `layer_imports`.
- The table goes to the job summary and, through `tee`, to the log.
- **Syncing a 200-file app, and `sync --detect`.** [`tool/measure_sync.dart`](../../tool/measure_sync.dart) generates an official_mvvm app with 200 Dart files, gives it a new app's `android/` and `ios/` files (copied from the engine's native template fixture) and runs `appstein sync` with the platform packs, so `native.json` is part of the time. It first **compiles the `appstein` command** and runs every sync as a new process with `FLUTTER_ROOT` set, the way an agent's hook does. CI passes `--work "$RUNNER_TEMP"`, so the apps are made on the disk that holds the checkout (see "The measured app's disk" below). It runs:
  1. a first sync as a new project, with a real `flutter pub get` (so it needs the network);
  2. a full sync after deleting `.appstein/` and the analyzer cache, with fresh packages;
  3. `sync --detect` with nothing changed, three times;
  4. `sync --detect` after each of three edits of a view model, and of the router;
  5. on the 200-file app only, each of the seven MCP tools, three times, in one `appstein mcp` process (see below);
  6. on the 200-file app only, `appstein docs`: once to write every page, then three times with nothing to write and three times with `--check`. Each must take under 2 s (the last two as the median of three), which is spec §15's target for `appstein docs` from fresh knowledge. It also checks what the real command does: the first run must write, the next ones must find the docs up to date, and after a line is added to `routes.md` by hand, `--check` must exit 1, name the page as hand-edited and leave it alone (see [human-docs](human-docs.md#testing-it));
  7. on the 200-file app only, the terminal `appstein verify --fast` and `appstein verify`, three times each, **with no limit**: each starts its own analysis server, so its time is mostly that server starting. They are printed, and one more run of each (not timed) is sampled for the most memory its process tree held, the guard and the server (see "The warm `verify` limit" below). It also checks what the real command does: both must exit 0 (the app's findings are warnings only: a feature without a test, the page edited by hand in step 6) and end with the summary line, and `verify --format json` must report `docs.stale` for the `routes.md` page and no other page (see [verify](verify.md));
  8. on the 200-file app only, the `verify` tool of a running `appstein mcp`, after one file is edited: **the 5 s limit of spec §9.1 and §15**, described below.

  Spec §15 sets the targets, and **this tool does fail**: it exits 1 when the full sync takes 30 s or more, when any `--detect` of 3 and 4 (nothing changed, the view model edit, the router edit) takes 2 s or more as the median of three runs (CI machines vary by about 2× in speed; see [incremental-sync](incremental-sync.md#measuring)), when the map was skipped, when any native section is not `read`, or when a `--detect` gives the wrong answer (it rebuilt with nothing changed, or didn't report the edit). Step 8 adds the warm `verify` limit. The same rows are measured for a 1,000-file app: their times are printed for information only and never held to a target, but a broken run there (a failed sync, a skipped map, a native section not `read`, a wrong `--detect` answer) still exits 1. A second table says where the time of each full sync and edit went, step by step (see [incremental-sync](incremental-sync.md#where-the-time-goes)), so a missed target shows its cause in the same log. A third holds the `verify` rows: the warm tool with its limit, the start-up and the memory (below). A fourth says what a reading of the project costs (below). The last holds the MCP answers (below), and an MCP median of 1 s or more also fails the run. So the tool prints **five tables**: the main one, the breakdown, `verify`, the reading and the MCP answers. They all go to the job summary and the log. When the warm measurement's own checks fail, the tables measured so far are printed before the run exits 1, so the log of that system keeps the numbers. On the Windows development machine:

  | Measurement | 200 files | 1,000 files (info) |
  |---|---|---|
  | First sync | 10,692 ms | 11,370 ms |
  | Full sync, no analyzer cache | 6,892 ms | 7,618 ms |
  | `sync --detect`, nothing changed | 77 ms | 165 ms |
  | `sync --detect` after a view model edit | 1,102 ms | 2,202 ms |
  | `sync --detect` after a router edit | 1,167 ms | 2,309 ms |

  See [incremental-sync](incremental-sync.md#measuring) for why each row is measured that way.

  **The time limit.** The `measure` job has `timeout-minutes: 30`; it normally takes five to ten (a local run on a busy Windows machine took about five). In slice 1c.1 a measuring tool printed its tables and then never exited, and both jobs ran for GitHub's default limit of six hours. The limit turns the next such bug into a failure after half an hour.

  **The MCP table.** The last table times the MCP server (see [mcp-server](mcp-server.md#testing-it)). After the last edit's `--detect` the knowledge is fresh. The tool starts one `appstein mcp --project <app>` process, which it talks to with a small JSON-RPC client: it sends `initialize`, then times each `tools/call`. A first `overview` call starts the server and isn't counted. Then each tool is called three times, with the same arguments on the generated app (`where_is` with `feature 5 view model`, `feature` with `feature_5`, `route` with `/feature-7`, `check_api` with `withOpacity`, and `what_changed` and `toolchain` with none). The table has one row per tool: the median in ms, and the three times beside it. Spec §15 sets the target, under 1 s, and the tool exits 1 when a tool's median reaches it, or when a call answers with an error. The 1,000-file app has no MCP rows.

  **The warm `verify` limit.** Spec §15's "fast verify under 5 s" is measured where an agent meets it: on the `verify` tool of a running `appstein mcp`, not on the terminal command, which starts its own analysis server and so spends its time on that (decision record [0001](../adr/0001-analysis-server-beside-the-map-analyzer.md)). After the terminal runs the tool starts a second `appstein mcp --project <app>` (the compiled binary, `McpSession` in [`mcp_session.dart`](../../tool/src/mcp_session.dart)) and:
  1. calls `verify` with `scope: fast` once. That first call starts the analysis server and waits for it, so it is the **start-up time**; the tool takes the memory of `appstein mcp`'s process tree then ([`process_memory.dart`](../../tool/src/process_memory.dart): the process, the guard and the server), and again after the last call. The reply must have no `dart.error`;
  2. three times, edits the view model of `feature_9` to add a real error ([`editWithError`](../../tool/src/warm_verify.dart): `int wrongN() => 'xxx';` at the end, a different length and on a different line each time, so a file system with a coarse clock can't hide an edit and a reply left from an earlier edit names the wrong line), calls `verify` with `scope: fast` and times it. **The reply must report a `dart.error` on that file and on the line written**, or the run fails whatever the time ([`missedError`](../../tool/src/warm_verify.dart)): a fast answer that missed the change can't pass. The median of the three must be **under 5 s** (the design says "< 5 s", so exactly 5 s fails; [`warmLimitMiss`](../../tool/src/warm_verify.dart)); at 5 s or more, the run fails with a message that gives the measured time. **The limit is not changed to fit a result**: a miss is a finding for the owner;
  3. after each of those, restores the file, calls `verify` again and times it (printed, no limit), and the reply must no longer report the error;
  4. three more times, edits the file and calls `overview` (every tool refreshes the knowledge first, so this call is that refresh) and then `verify`, which has nothing left to refresh: the two rows say **where the time of the call goes** (the refresh, against the look at the disk, the reading and the checks). The reply must report the error again, and after the file is restored, `verify` must report it gone again (untimed), so a stale reply fails in these rows too.

  The steps are `measureWarm` in [`warm_measurement.dart`](../../tool/src/warm_measurement.dart), which the root test `test/warm_measurement_test.dart` runs against a fake MCP server that reads the edited file from disk, or is made to miss every change, to repeat the answer of the call before from the 3rd, 4th or 9th call on (each hits a different check), to name the line of an earlier edit, to answer with an error, to answer too slowly, or not to end.

  A call that gets no answer within 120 s, a line that isn't JSON and a result that isn't an object are failed runs with a message that says so, not a stack trace or a wait for the job's limit. The first request, `initialize`, has a start timeout of its own (also 120 s), because it waits for the process to start; the shorter timeouts of the tests apply only to the calls under test.

  Then it closes `appstein mcp`'s input and checks that it ended by itself and that no process of the tree it saw is still running. The tree is listed after the first call, after the last, and once more just before the session is closed, whatever the end of the measurement was: a first call that hangs or fails is when a guard and a server are most likely left behind. Each process is recorded with the start it had when first seen. **A process counts as part of the tree, and as a leftover, only by ID and start together**: the system names a parent by ID and never clears it, and Windows gives the ID of an ended process to a new program within seconds, so a process that started before its named parent is not its child, and a process with the ID of a tree member whose start is not the recorded one (a program that started later, or one that was already running) is another program ([`processTree`](../../tool/src/process_memory.dart), `survivors`). The process list is checked too: a listing that fails, is empty or does not hold the tool's own process stops the run, instead of reading as no memory and nothing left. The tool ends one process only: `appstein mcp` itself, which it kills when its input closing has not ended it within 30 s (a slow CI runner gets time). That kill is reported and fails the run. A leftover is a bug to find, not something the tool cleans up: it is reported by ID with the command to end it by hand. Any of these fails the run.

  The app is the 200-file app of the other rows: no `analysis_options.yaml`, so no `appstein_lints` plugin and no `flutter_lints` in the analysis server. With the plugin the server takes longer to start and holds more memory (decision record 0001: 18 s and 1.4 GB, against 7.5 s and 0.6 GB); the warm call with it is not in the CI measurement. It was measured once by hand, with a temporary copy of the tool that wrote an `analysis_options.yaml` with the plugin into the 200-file app (the second column below).

  On the Windows development machine (2026-10-14, one run of each; other test runs were going on at the same time, which is why the `sync --detect` rows of the same runs were slower than in the table above):

  | Measurement, 200-file app | No plugin | With the plugin (by hand) |
  |---|---|---|
  | **Warm fast `verify`** after an edit that adds an error, median of 3 (limit: under 5 s) | 1,632 ms (1,727, 1,632, 1,519) | 1,670 ms (1,670, 1,671, 1,597) |
  | after the error is fixed, median of 3 | 1,566 ms | 1,628 ms |
  | of which the knowledge refresh (an `overview` call), median of 3 | 1,409 ms | 1,489 ms |
  | of which `verify` once the refresh is done, median of 3 | 248 ms | 249 ms |
  | First `verify` call (the analysis server starts and is ready) | 5,092 ms | 15,655 ms |
  | Memory of `appstein mcp`, guard and server, ready / after the calls | 0.98 GB / 1.11 GB | 1.88 GB / 2.27 GB |
  | Terminal `verify --fast`, three runs, no limit | 28,757 (the first), 4,971, 4,967 ms | 38,258, 29,354, 41,189 ms |
  | Terminal `verify` (full), three runs, no limit | 4,935, 4,865, 4,868 ms | 29,813, 21,796, 18,915 ms |
  | Most memory of a terminal fast / full run | 0.90 GB / 0.91 GB | 1.73 GB / 1.86 GB |

  The warm call is a knowledge refresh (the view model is a map input, so the map is rebuilt: about 1.4 s) and a quarter of a second for the rest: the look at the disk, the reading and the checks.

  **What a reading costs.** A warm `verify` call looks at the disk before it asks the analysis server (`DiskLook`, ticket 04), and scans the Dart files outside the map's inputs (`readDartFileHashes`, ticket 06). The tool times both in its own process, three times each, on the 200-file app with no `build/` folder and with a `build/` of 6,000 and of 26,000 files ([`large_build.dart`](../../tool/src/large_build.dart): nested folders, 50 files in each, one file in twenty a Dart file, so the project has 500 and 1,500 Dart files): the look, the first scan (every file is hashed) and a scan with nothing changed (the one a warm call makes). Printed only, with no limit. The look calls the engine's `DiskLook` directly, which the engine does not export. On the same machine and runs (median of three, in ms):

  | | No `build/` | 6,000 files | 26,000 files |
  |---|---|---|---|
  | Look at the disk, no plugin / plugin | 35 / 27 | 57 / 61 | 145 / 277 |
  | Dart-file scan, first (every file hashed), no plugin / plugin | 139 / 130 | 332 / 141 | 859 / 231 |
  | Dart-file scan, nothing changed, no plugin / plugin | 55 / 57 | 128 / 45 | 379 / 95 |

  The pairs are the same code on the same files, run at different moments on a busy machine, so they show how much these numbers move (the scan of 6,000 files: 128 and 45 ms). With a `build/` of 26,000 files the look and the scan together are about 0.4 to 0.5 s of a warm call; without one, about 0.1 s. That is not what the 1.6 s is made of.

  **The measured app's disk.** GitHub's standard Windows runners keep the checkout and `RUNNER_TEMP` on D:, a fast local disk, while the system temp folder (`%TEMP%`) is on C:, a remote disk that is much slower to write ([actions/runner-images#8755](https://github.com/actions/runner-images/issues/8755)). The first public CI runs of 1b.7 made the apps on C:, and writing the 57 MB analyzer cache took 0.6–3.8 s there, against 0.07 s on D:, so an edit's `--detect` missed 2 s on Windows only (1.7–4.9 s). With the apps on D: it took 1.6 s. A developer's project lives on their working disk, not on a cloud machine's system disk, so CI measures there. On Linux every folder is on one disk. Defender was ruled out: real-time protection is off on these runners.
- The analysis measurement reports numbers; it has no time budget to fail. The first numbers (9–16 s for one cold file with the plugin) led the spec to plan warm analysis for fast checks ([spec §9.1](../project/specs/2026-09-29-appstein-design.md#91-fast-checks-after-every-change-changed-files-only-target--5-s)).

## Measured by hand: the analysis server

One measuring tool is not part of CI. [`tool/measure_analysis_server.dart`](../../tool/measure_analysis_server.dart) measures the Dart analysis server that verify's code checks will ask (slice 1d.2, [decision record 0001](../adr/0001-analysis-server-beside-the-map-analyzer.md)). It was written to compare the ways Appstein could talk to that server, and is kept so the numbers can be taken again on another machine or SDK. It measures three arrangements: LSP, the legacy analyzer protocol, and the legacy protocol behind a **guard**. The guard is the tool's own `--guard` mode: a process that starts the server, passes stdin and stdout through, and ends the server when its own stdin closes. It is there because a legacy server doesn't end when its stdin closes or its parent is killed. From the repo root:

```powershell
fvm dart run tool/measure_analysis_server.dart
```

It takes about seventeen minutes and needs the network for `flutter pub get`. `--work <folder>` makes the app somewhere other than the system's temporary folder. It starts every server from the Dart executable that runs the tool, and never through a `.bat` wrapper.

What it does:

1. **Generates the app.** The 200 files of `measure_sync.dart`'s app, with `flutter_lints`, and six more Dart files for the findings: three canaries with a layer violation (the first also has an unused import), a file with six deprecated uses that `dart fix` can migrate and a line `dart format` would split, and a deprecated use with no migration.
2. **Compiles the guard** (itself, with `dart compile exe`), so the guard can be measured both compiled and run by `dart`.
3. **Times the start.** One first start, then three in each arrangement, first without and then with the `appstein_lints` plugin (the guard with the plugin only). It prints the median time until the server is ready, the memory of its process tree then (working set on Windows, resident set elsewhere), and how much of that is the guard's.
4. **Asks the four questions of the code analysis** on a ready server with the plugin on, over LSP, the legacy protocol and the legacy protocol behind the compiled guard: the diagnostics after an edit on disk (three edits that break a file, ten that add a plugin finding), whether one diagnostic can be fixed, the pending fixes, and whether a file's formatting would change. It records the most memory the server held while the fixes were asked, and checks that no file under `lib/` changed.
5. **Runs `dart fix --dry-run`** on the same app, compares its fixes with the legacy protocol's, and records the most memory its processes held.
6. **Stops the server:** by the protocol's own request, by closing its stdin, by killing its parent (three times), and, with a guard, by killing only the guard (three times). To kill a parent it starts itself again with `--hold`, as a process that holds a ready server, and ends that process. When a server is still running afterwards, it edits a project file and looks again, because a legacy server that has lost its parent ends the next time it has something to say.

**What "ready" means.** With the plugin on, a server is ready when it has said its analysis is done *and* the plugin's `layer_imports` has arrived for each canary. The second half matters. The plugin runs inside the server's process and analyzes every file again, and over LSP the server says "done" about 10 s before the plugin has finished. The table prints both moments. In the runs so far the plugin reported the canaries' folders first and last, so the last one arriving is the sign that it has been through the project.

It exits 1 when a measurement can't be trusted: a diagnostic it waits for never arrives (so the plugin didn't run), a server ends early, the complete pending fixes differ from `dart fix --dry-run`, or a question changed a file. A server that keeps running after its parent is killed is a result, not a failure: the tool prints it and ends that process itself.

**Cleaning up.** The tool records the process ID of everything it starts (servers, guards, holders, `dart fix`) and ends what is still running before it exits, whether it finished, failed or was interrupted with Ctrl+C. It never ends a process it didn't start. Ctrl+C was tried once on Windows with a server running: the server and the tool ended and the work folder was removed. Under `fvm`, whose `dart` is a batch file, the console then asks "Terminate batch job (Y/N)?". One thing stays behind: the server builds the plugin once per app folder and keeps the build (about 13 MB) in its own state folder, `.dartServer/.plugin_manager` under the user's local application data on Windows, so each run of the tool adds one.

On the Windows development machine (2026-10-12, median of three):

| Start | Ready | Said it was done | Memory when ready | Of which the guard |
|---|---|---|---|---|
| LSP, plugin off | 7.5 s | 7.5 s | 0.63 GB | |
| Legacy, plugin off | 7.2 s | 7.2 s | 0.63 GB | |
| LSP, plugin on | 18.3 s | 8.0 s | 1.44 GB | |
| Legacy, plugin on | 18.8 s | 18.8 s | 1.49 GB | |
| Legacy behind a compiled guard, plugin on | 18.6 s | 18.6 s | 1.52 GB | 22 MB |
| Legacy behind a guard run by `dart`, plugin on | 19.1 s | 19.1 s | 1.66 GB | 219 MB |
| Legacy, plugin on, the first start, which builds the plugin (one run) | 54.5 s | 54.5 s | 1.45 GB | |

The answers to the questions, and the two options they leave for the owner, are in the decision record.
