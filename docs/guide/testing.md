<!-- covers:
tool/test_all.dart
packages/appstein_engine/test/support/**
packages/appstein_cli/test/support/**
packages/appstein_engine/dart_test.yaml
test/support/**
-->

# How the tests work

Appstein's logic reads environment variables, looks for files and runs other tools. This page explains how the tests control all of that, and where they deliberately don't.

## Where the tests are, and how to run them

| Folder | What it tests |
|---|---|
| `packages/appstein_protocol/test/` | The data models |
| `packages/appstein_engine/test/` | The engine, one folder per `lib/src/` folder, plus `integration/` and `support/` |
| `packages/appstein_cli/test/` | The command line |
| `packages/appstein_lints/test/` | The analyzer plugin |
| `test/` (repo root) | The repo tools in `tool/`, one test file per `tool/src/` file |

The commands are in the start page's [Run the tests](README.md#run-the-tests).

### Run everything before a commit

`fvm dart run tool/test_all.dart`, from the repo root, runs what a commit needs, in order: the format check, the analyzer with infos fatal, `gen_docs --check`, `check_guide --since main`, then the suites of the four packages (the engine's twice, `--engine-runs N` to change it) and the repo tools' tests. It prints one line per step and ends with `ALL GREEN` and exit 0, or `FAILED: <steps>` and exit 1 with each failing test (the line `dart test` ends with `[E]`) and what it printed after it. The whole output of every step is kept in `.dart_tool/test_all/`, one file per step, replaced by the next run; a failing step names its file. `--only NAME` runs just the steps with NAME in their name, to run one suite again. It does not run everything [CI](ci.md) runs: the engine's `integration`-tagged tests, `dependency_validator`, `dart doc --dry-run`, the scan for byte order marks, the build of the compiled binary with `tool/startup_check.dart`, and the `measure` jobs are left to CI and to the close of a slice.

- **A step passes only when its exit code and its output agree** ([`judgeTestRun`](../../tool/src/suite_run.dart)): exit 0 and a last line that says `All tests passed!`. A script that only printed each suite's last line once exited 0 while an engine test failed, so neither alone is trusted. `test/suite_run_test.dart` holds both cases, and a run cut short.
- **The analyzer step gets a cache folder of its own.** `dart analyze` runs an analysis server, which keeps a cache on disk and leaves half-written files there when it ends (see [verify](verify.md#stopping)). So the step runs with `ANALYZER_STATE_LOCATION_OVERRIDE` set to `.dart_tool/test_all_analysis_cache` (`testAllAnalysisCache` in [`suite_run.dart`](../../tool/src/suite_run.dart)), inside `.dart_tool/`, which git ignores (a repo-tools test checks it). The folder is kept between runs, so the step starts warm: a fresh folder each run made it cold, 34.5 s against 13 to 14 s. At the start of each run, `clearHalfWrittenFiles` deletes what the last run's `dart analyze` left half-written there (only the `-temp-<ID>` files directly in its `.analysis-driver` folder). The run then leaves nothing in the cache the machine shares, as the suites don't (see [real analysis servers](#real-analysis-servers)). Two runs at once in one clone are not supported: one could delete a file the other's analyzer is writing.
- **A skipped test proves nothing**, so it sets `APPSTEIN_REQUIRE_GRAPHIFY=1`, as CI does: the graph check's tests fail instead of skipping when there is no Python with graphify. In a fresh worktree, which has no `graphify-out/`, set `APPSTEIN_GRAPHIFY_PYTHON` to such a Python first.
- It was checked both ways on 2026-10-14: a suite with a test failing on purpose gave `FAILED: repo tools` and exit 1, and a clean suite gave `ALL GREEN` and exit 0.

## Fakes for the machine

The engine reaches the machine through two types, `HostEnvironment` and `ProcessRunner` (see [running-tools](running-tools.md)). Tests pass fakes for both. The helpers live in `packages/appstein_engine/test/support/`:

| Helper | File | What it builds |
|---|---|---|
| `fakeEnvironment` | [`temp.dart`](../../packages/appstein_engine/test/support/temp.dart) | A `HostEnvironment` with only the variables you give it, for the real OS unless you pass one. A fake OS is for tests that touch no files, or whose files don't depend on the real OS, such as the macOS Android Studio tests, which pass their own folders to search. It also sets a fake `ProgramFiles`, so any future lookup can't stumble on the real machine's Android Studio (no lib code reads `ProgramFiles` today) |
| `fakeExecutable` | [`temp.dart`](../../packages/appstein_engine/test/support/temp.dart) | A tiny program in a folder that prints a fixed line: a `.bat` file on Windows, a `sh` script elsewhere. Put its folder on the fake PATH to make a tool "installed" |
| `FakeProcessRunner` | [`fake_process_runner.dart`](../../packages/appstein_engine/test/support/fake_process_runner.dart) | A runner that returns canned results set up with `when`, and records every call in `calls`, with its working folder and time limit. A command nobody set up "fails to start", just as a missing tool would. `onRun` is called when a command starts |
| `flutterTestOutput`, `scriptFlutterTest`, `fakeFlutterPrints` | [`flutter_test_output.dart`](../../packages/appstein_engine/test/support/flutter_test_output.dart) | What a full `verify` gets from `flutter test`. `flutterTestOutput` gives the real output of Flutter 3.47.5 kept in `packages/appstein_engine/test/fixtures/flutter_test/`, as if it had run in the project you name. `scriptFlutterTest` makes a `FakeProcessRunner` answer the test run (by default: every test passed). `fakeFlutterPrints` makes a fake SDK's `flutter` a real script that prints events, for a test that starts a real process |
| `createFakeSdk`, `fvmHomeVars`, `fvmSettingsFile` | [`fake_sdk.dart`](../../packages/appstein_engine/test/support/fake_sdk.dart) | The parts of a Flutter SDK folder Appstein reads, with version files that match Flutter 3.47.5's real ones. With `setUp: false` it leaves them out, like an SDK FVM downloaded but Flutter never ran. `fvmHomeVars` sets a home folder, and the folder FVM's global settings live under, for this OS; `fvmSettingsFile` says where that settings file then is |
| `fakeStudio`, `writeStudioRecord`, `writeInfoPlist` | [`fake_android.dart`](../../packages/appstein_engine/test/support/fake_android.dart) | An Android Studio folder with a bundled JDK, laid out for this OS or for the `os` you pass (a macOS `.app` bundle on any OS), the `.home` install record Android Studio writes, and a macOS `Info.plist` with a version or the JetBrains Toolbox key. `studioInstalledReason` skips a test when a real Android Studio in a default place would get in the way |
| `testContext`, `foundSdk` | [`doctor_support.dart`](../../packages/appstein_engine/test/support/doctor_support.dart) | A `DoctorContext` for testing one check. By default: Flutter 3.47.5 found through PATH, an empty environment, and a runner that knows no commands. `foundSdk` also takes an unmet FVM pin and the lookup's notes |

**Fake executables are made executable on macOS and Linux.** `findExecutable`, like a shell, skips a file on the PATH that has no execute bit there. So `fakeExecutable` and `createFakeSdk` run `chmod +x`; without it the fake tool would look "not installed" on those systems only.

## Real temporary folders

File checks aren't faked. Tests create real files in real temporary folders, because faking a file system would test the fake, not the code.

`tempDir()` in [`temp.dart`](../../packages/appstein_engine/test/support/temp.dart) creates a folder named `appstein tëst …`, with a space and a non-ASCII character, and deletes it after the test. Every engine test that touches files uses it. Real users have paths like `C:\Users\Jöhn Doe\my app`: a space breaks code that builds shell commands without quoting, and a non-ASCII character breaks code that assumes one text encoding. With these names, every test run exercises both, on every OS. The CLI tests and the tool tests name their folders the same way.

## Tests against the real machine

Fakes can only answer the way we expect Flutter to. Some tests therefore run against the real machine:

- **The `integration` tag.** [`dart_test.yaml`](../../packages/appstein_engine/dart_test.yaml) gives the tag a `skip` reason, so a plain `fvm dart test` skips these tests. Run them from `packages/appstein_engine` with `fvm dart test --run-skipped --tags integration`. CI runs them on all three OSes (see [ci](ci.md)).
- **`doctor_real_environment_test.dart`** in `packages/appstein_engine/test/integration/` runs the real doctor for the Appstein repo and compares it with Flutter's own answers. The repo is the folder whose `.fvmrc` the tests find above their working folder. The `flutter` they run is the one `SdkDetector` finds for the repo, so both sides describe the same SDK: FVM's pinned one on the development machine, and in CI the one CI installs, which must match the pin.
  - the Flutter version doctor reports must match `flutter --version --machine`, and no check may crash;
  - the JDK the Java check chooses must be the one `flutter doctor -v` names on its "Java binary at:" line;
  - the Android SDK check's summary must name the platform and build-tools on `flutter doctor -v`'s "Platform …, build-tools …" line.

  `flutter doctor -v` runs once, and its output is shared. When doctor finds no usable SDK for the repo, the tests skip themselves on a developer's machine but fail in CI (where the `CI` variable is set), because there it means CI itself is broken. The JDK test also skips when Flutter reports no Java, and the Android test when Flutter reports no Android SDK.
- **`test_run_real_sdk_test.dart`** in the same folder runs the real `flutter test` on the `tests_app` fixture (`packages/appstein_engine/test/fixtures/apps/tests_app/`: a passing test file, failing tests, a test file in a folder with a space and one that can't be loaded). It fetches the app's packages first, so it needs them in the pub cache or the network. One of its tests never ends on purpose and takes its 75 s limit. See [verify](verify.md#the-tests).

**The lesson.** The unit tests for the JDK lookup encode our model of how Flutter chooses a JDK. If that model is wrong, the tests are wrong in the same way, and they still pass. Only comparing with Flutter's own answer, on a real machine, can catch a wrong model. That is why the cross-check with `flutter doctor -v` exists.

## CLI tests

- **In-process runs.** `runAppstein` takes output sinks, an environment, a runner and the doctor's checks as parameters. `runner_test.dart` passes `StringBuffer`s, an environment with no variables and made-up checks, then checks the text and the returned code. An extra command that throws on purpose tests the crash path.
- **The CLI's Dart SDK.** The CLI tests use a fake Flutter SDK, which has no Dart SDK, so a run can't build the project's knowledge on its own. [`dart_sdk.dart`](../../packages/appstein_cli/test/support/dart_sdk.dart) has `testDartSdk` (the same definition as the engine's); a test passes it as `runAppstein`'s `dartSdkPath` when the knowledge must be built, as the healthy-project runs of `verify_command_test.dart` do.
- **The analysis server in CLI tests.** A fake Flutter SDK has no `dart` to run an analysis server with, so the `verify` and `mcp` tests pass `runAppstein` a scripted answer (`codeAnalysis: ScriptedCodeAnalysis().scope`). The stand-in is test support, not part of the engine's library: [one copy in the engine's tests](../../packages/appstein_engine/test/support/scripted_code_analysis.dart) and [one in the CLI's](../../packages/appstein_cli/test/support/scripted_code_analysis.dart), since one package's tests can't import another's. One test of `verify_command_test.dart` uses the real server and the real guard command. It compares [`childProcesses`](../../packages/appstein_cli/test/support/child_processes.dart) before and after (the processes this test process started that are still running, without the lister it starts itself), and it notes the process IDs each run's guard named and checks every one with `processAlive`: a server whose guard has ended is no longer a child of the test. Nothing may be left.
- **A process is known by its ID and its start.** Windows gives an ended process's ID to a new one within seconds, so `recordProcesses` notes each ID with its start, and `processAlive`, `goneWithin` and `survivorsAfter` count a process only while both still match. They ask through the engine's `lookUpProcess`, and on Linux through `/proc`, so asking starts no child process; only macOS runs `ps`, which `childProcesses` leaves out by name. `survivorsAfter` names each process still running with its program, start, command line and parent, so a failure says what survived.
- **A child must have started at or after its parent.** `processesUnder` walks the system's parent IDs, and Windows never clears one: when a parent ends, its children keep its ID, and once a new process is given that ID they look like its children (at idle, a machine has a dozen such processes with ended parents). So the listing carries each process's start (`listedProcesses`): on Windows its creation time in UTC from the product's `lookUpProcess` (a clock in the local zone is ambiguous in the hour that repeats when daylight saving ends, and a clock set back reorders two starts; a process that lookup finds gone is left out), elsewhere minus the seconds `ps` says it has run (every `etime` comes from one "now"). `descendantsOf` counts a process as a child only when it started at or after its parent, at every level of the walk. A process whose start is not known is counted, since a survivor must never be left out for want of a time. `child_processes_test.dart` tests the rule on listings made up by hand, with no real process.
- **Tests that count child processes take turns.** The CLI's test files run in one process, so one file's children would show up in another file's count. `withChildProcessesToItself` wraps those tests (in `mcp_command_test.dart`, `verify_command_test.dart`, `verify_hook_test.dart` and `run_guarded_test.dart`): it takes a turn file in the temp folder, created exclusively and naming its holder by ID and start. A file whose holder no longer runs is taken away, and a wait longer than 8 minutes fails with a message. [`child_processes_test.dart`](../../packages/appstein_cli/test/child_processes_test.dart) tests the turn on a file of its own.
- **`appstein mcp` as a process of its own.** [`mcp_process.dart`](../../packages/appstein_cli/test/support/mcp_process.dart) runs the CLI's `mcp` command as a separate Dart process, so `mcp_command_test.dart` can close its input or kill it and check that the analysis host it started, with its guard and analysis server, stays for the next session. Its fifth argument is the folder of the hosts' address files.
- **Analysis hosts of their own.** A test that starts an analysis host gives it an address-file folder of its own (`APPSTEIN_ANALYSIS_HOST_FOLDER` in the test's machine, or the folder argument of the engine's [`host_main.dart`](../../packages/appstein_engine/test/analysis/support/host_main.dart)) and a cache folder of its own, and kills it, with what runs under it, after the test (the CLI's [`analysis_hosts.dart`](../../packages/appstein_cli/test/support/analysis_hosts.dart), the engine's [`host_support.dart`](../../packages/appstein_engine/test/analysis/support/host_support.dart)), so no host is left running, on Windows too. A host is started detached, so it is not among the test process's children: the helpers find it through its address file.
- **The scripted code analysis** in both packages can also answer with notices (`notices`), the lines a reading carries about processes a stop could not end, so the CLI and MCP tests can check how `verify` shows them. Both copies can also say which files the server analyzed (`analyzedFiles`), the files `dart.deprecated` reads for hiding comments and `verify` reads for `// appstein:ignore` comments. Both copies can answer with files that could not be read (`unreadableFiles`, for `dart.unreadable`), and answer `canDartFix` true for the diagnostics in `fixable`; the engine's copy records each diagnostic it was asked about (`askedFixes`), can run a callback first (`onFixAsked`), so a test can check when and for which files the question is asked, and can make only that question fail (`fixFailure`). Both copies answer `formatChanges` true for the files in `unformatted`, and `canDartFix` and `formatChanges` take the `within` of the real interface; the engine's copy honours it as the server does (a `canDartFix` that runs out of time throws a `TimeoutException`, a `formatChanges` answers with nothing), can leave files unanswered (`formatSilent`, a server too slow for its time), refuse files (`formatRefused`, with why), run a callback first (`onFormatAsked`), make only that question fail (`formatFailure`), and records the files and the time of each question (`askedFormats`, `formatWithin`, `fixWithin`); the CLI's copy has `formatFailure` too. Both copies answer `pendingFixes` with `pending` (a `PendingFixes`), and `applyFixesAndFormat` with an `AppliedChanges` of `leftAlone` and `applied`, or of what `onApply` returns (a test may write files there; it is given the `leaveUnformatted` the caller passed); the engine's copy notes every question in order (`events`: `read`, `canDartFix`, `formatChanges`, `pendingFixes`, `applyFixesAndFormat`), so a test can check that the reading comes first and that nothing is rewritten without `--apply`, records the time of each (`pendingWithin`, `applyWithin`), runs a callback first (`onPendingAsked`) and can make either fail (`pendingFailure`, `applyFailure`); the CLI's copy counts the rewrites (`applyAsked`). The scripted server behind the guard has a `format` scenario for the formatting questions a real server can't be made to give (a refusal, a question never answered), and `fixes-<how>@<log file>` scenarios for the pending fixes (a pass that finds none, is refused, is never answered, or never ends; an overlay's `add` refused or never answered, and its `remove` never answered), which note every request in the log file so a test can see each overlay added and removed. The engine's tests of the server itself are described in [verify](verify.md#tests).
- **The async crash path.** `runGuarded` changes the process's own exit code, and it exists to catch an error that escapes every future. That can't be tested inside the test runner's process. So `run_guarded_test.dart` starts [`async_error_harness.dart`](../../packages/appstein_cli/test/support/async_error_harness.dart) as a separate Dart process, with the arguments it should act for. The harness throws from a timer, outside the awaited future. The test expects exit code 3 and the crash message on stderr, and, when the arguments are `verify --fast --hook claude`, exit code 0 with the failure JSON on stdout and the trace on stderr.
- **Hook mode.** `runAppstein` takes `hookInput`, a function that gives the text a hook would read on stdin, so [`verify_hook_test.dart`](../../packages/appstein_cli/test/verify_hook_test.dart) runs `verify --fast --hook claude` in process with the input a test chooses (Claude Code's JSON, nothing, broken text, a reader that throws), a scripted code analysis, and checks of the test's own (`verifyChecks`) that report what they are given, throw or name themselves not run. Its projects are made by [`healthy_project.dart`](../../packages/appstein_cli/test/support/healthy_project.dart), the one `verify_command_test.dart` uses too. What it asserts is what Claude Code sees: the exit code, the exact stderr text, and the stdout JSON decoded. [`hook_race_harness.dart`](../../packages/appstein_cli/test/support/hook_race_harness.dart) is a second process of this kind: it runs the command through `runGuarded` on a project the test made, with a crash that escapes every future before or after the command answers, and the test checks there is one answer and the first exit code stands. One test starts the script as two processes, one with stdin closed and one with stdin that never closes, to prove that stdin is read and that an open pipe does not keep the process alive (it takes its turn like the other tests that start processes).

## Flutter's own files as fixtures

`packages/appstein_engine/test/fixtures/flutter_sdk/<version>/` holds Flutter's toolchain files for 3.44.9 and 3.47.5, each ending in `.fixture`. [`flutter_fixtures.dart`](../../packages/appstein_engine/test/support/flutter_fixtures.dart) reads them (`fixtureText`) or copies them into a fake SDK under their real names (`addToolchainFiles`). The fixture folder is found from the package itself (`Isolate.resolvePackageUriSync`), not from `Directory.current`, for the reason given under "Finding the helper" below. Tests that need CRLF files convert the text in the test, because the repo stores everything with LF. See [toolchain](toolchain.md#tests-and-fixtures).

## The fixture app and goldens

The [project map](project-map.md) is tested on one small app, kept in `packages/appstein_engine/test/fixtures/apps/mvvm_app/`. It is a miniature of Flutter's `compass_app` sample, with five features and a router, and every odd file in it is there to test one rule:

| File | What it is for |
|---|---|
| `lib/ui/booking/widgets/booking_screen.dart` | The layer violation, on purpose: a screen that imports a repository's implementation, where `ui` may import only its interface |
| `lib/ui/booking/view_models/base_view_model.dart` | The abstract base class: a view model's parent that is not itself a view model |
| `lib/domain/use_cases/booking_create_use_case.dart` | A use case, which is `domain` code but not a feature's model |
| `lib/routing/router.dart` | The routes: nested, in a `ShellRoute`, in a `StatefulShellRoute`, with a `pageBuilder`, a redirect, a path from a `const` — and the unresolved ones: a path from a function (`search`), a builder with two `return`s (`/settings`), a `Text` as the screen (`/about`) |
| `lib/ui/core/ui/app_button.dart` | `ui/core`, which is shared UI and not a feature |
| `lib/data/repositories/`, `lib/data/services/`, `lib/data/model/` | An interface and its remote implementation, a service, and a model, one per data tag |
| The app's own `test` folder (`ui`, `data` and `fakes` inside it) | Tests that features claim by their folder (the `ui` ones, by feature), and tests that no feature owns (`data` and `fakes`) |

**The `.fixture` suffix.** Every file of the app ends in `.fixture` (`router.dart.fixture`). The repo's analyzer, formatter and knowledge graph then ignore it: the app imports `go_router`, which this repo doesn't depend on, and `booking_screen` breaks a lint rule on purpose. The test helper copies the files without the suffix.

**Stand-in packages.** Real `flutter` and `go_router` would need a Flutter SDK and the network in every unit test. So `fixtures/apps/stubs/` holds small packages, `flutter` (`widgets.dart`, `foundation.dart`), `flutter_test` and `go_router`, with just the classes the app uses (`GoRoute`, `ShellRoute`, `ChangeNotifier`, `StatelessWidget`, and so on), and a **hand-written `pubspec.lock`** that says what pub would have written for the app. [`writeStubPackages`](../../packages/appstein_engine/test/support/fixture_app.dart) then writes `.dart_tool/package_config.json` (mapping each package to the stand-in), `.dart_tool/version` and times on the files, so the packages count as **fresh** by Flutter's own rule. The analyzer resolves the app like a real one, offline.

`stubs/delta_kit/` is different: it's a package made for the version-delta tests, not a stand-in for a real one. It has one of each kind of deprecation and migration files in Flutter's format (see [version-delta](version-delta.md#tests)). `stubs/go_router/lib/fix_data.yaml` is go_router 18.0.2's real `location` migration. `analyzeDeltaApp` analyzes a small app that imports `delta_kit`.

**The helpers**, all in [`fixture_app.dart`](../../packages/appstein_engine/test/support/fixture_app.dart):

| Helper | What it does |
|---|---|
| `copyFixtureApp` | Copies the app into a `tempDir()` folder named `mvvm app` (a space, on purpose), and with `stubs: true`, the stand-ins and the lock file too. With `stubs: false` it copies only the app, for a real `flutter pub get` |
| `writeStubPackages` | Makes any project's packages look fresh, as above. Tests of other shapes of project (a pub workspace, a stale lock) use it too |
| `testDartSdk` | The Dart SDK running the tests. The analyzer reads `dart:` libraries from it, so the tests don't need Flutter's |
| `lineOf` | The line of a text in a project file. Tests ask for the line instead of writing `17`, so editing a fixture doesn't break them |
| `readMapBody`, `expectGolden` | Read a written map file without its `meta`, and compare it with a golden |

### The analyzer's cold start

Every test file runs in an isolate of its own, and the first analysis in an isolate is slower than the next ones. One library analyzed four times in one process, each time with a new `AnalysisContextCollection`, took 5.7 s, 1.8 s, 1.4 s and 1.5 s. Two costs make that:
- **Once per isolate, about 4 s:** `package:analyzer`'s own code is compiled on first use, and the operating system's file caches are cold. With the suite running this grows to 13 to 20 s, and to 35 s when many analyzing files start at once.
- **Every analysis, about 1.5 s:** each new collection resolves the Dart SDK again, in its own in-memory store. That is the work of the test that asks for it.

With the default 30 s limit per test, the first test of a file that analyzes could time out for no fault of its own, and its teardown, deleting the temp folder while the analysis still ran, then added a second error about an unreadable `pubspec.yaml`.

So every file whose tests analyze in the test's own isolate starts with `setUpAll(warmUpAnalyzer)` ([`analyzer_warm_up.dart`](../../packages/appstein_engine/test/support/analyzer_warm_up.dart); 25 files, found by searching for `setUpAll(warmUpAnalyzer)`): it analyzes the fixture app (with its stand-ins, see below) once. That pays the first cost only, so each test's 30 s covers its own work, the second cost included. Tests keep analyzing for themselves (a test that edits the files it analyzes would be wrong on a shared analysis).
- `setUpAll` has a fixed limit of 12 minutes that a test can't change, so the warm-up holds itself to 60 s (`analyzerWarmUpLimit`) and fails the file with a message that says so. The analysis it started then keeps running; a teardown waits for it (up to the same 60 s) and disposes it, before the fixture's folder is deleted under it. `analyzer_warm_up_test.dart` runs that path.
- A new test file that calls `ProjectAnalysis.analyze`, a knowledge sync, or `runVerify` on a real project gets the same line.
- Files that don't use it: `analysis/` and `mcp/mcp_stdio_test.dart`, whose slow part is an analysis server started as a process of its own (that cold start is another process's, see "Real analysis servers" below); and `mcp/mcp_warm_analysis_test.dart`, which syncs in its own isolate too, but whose tests carry limits of 3 to 5 minutes that cover the cold start.

### Real analysis servers

The files that start real analysis servers (`analysis/analysis_server_test.dart`, `kept_analysis_server_test.dart`, `analysis_freshness_test.dart`, `mcp/mcp_warm_analysis_test.dart`, and the groups of `verify/verify_dart_test.dart`) start a guard process and, behind it, a server that analyzes the project once before it answers. Started together, many of them slow each other down, and a server's start can take longer than a test's 30 s.
- **Limits.** The tests of the first four files that start a real or scripted server have a limit of minutes, their group's (`analysis_server_test.dart` gives its groups 5, 3 and 2 minutes, the limits its own longest tests already had; `kept_analysis_server_test.dart` gives its scripted-process test the 3 minutes of its real-server test). The product's own 180 s limit for a server's answer is not touched.
- **A cache folder of their own.** A server keeps its cache on disk, in a folder the whole machine shares, and a stop leaves files there (see [verify](verify.md#stopping)). So every test that starts a server gives it a cache folder under the system's temporary folder, through `ANALYZER_STATE_LOCATION_OVERRIDE` in the environment the guard passes on: `testAnalysisEnvironment()` in [`analysis_support.dart`](../../packages/appstein_engine/test/analysis/support/analysis_support.dart) makes the folder, deletes it after the test (or the group, when called in `setUpAll`), trying again for up to 10 s while an ending server still holds a file, and returns the variable for `AnalysisServer.environment`. `realAnalysisServer` passes it, and stops its server before the folder is deleted. Every other `AnalysisServer` and `ownAnalysisServer` of the tests passes it too, a scripted guard's included, so a test never touches the shared cache whichever guard it starts (the real guard deletes its server's half-written files there); so do `server_holder.dart`'s process and the real `dart fix` runs of `verify_dart_test.dart`, which start servers of their own. The CLI's tests do the same through the machine they give a command: [`testAnalysisCache()`](../../packages/appstein_cli/test/support/dart_sdk.dart) makes the folder, the test's `HostEnvironment` names it, and `verify` and `mcp` pass it on to their servers (`analysisServerEnvironment`); `mcp_process.dart` takes it as its fourth argument. Checked on 2026-10-15 with the package suites, while other worktrees' suites without this change ran on the same machine: of the 691 `-temp-` files the machine's cache gained, none carried the ID of one of the 102 analysis servers and `dart fix` runs a watcher saw under this run (two IDs matched, but their files were older than this run's servers with those IDs: the system had given the ID again).
- **No turns.** The servers of different test files start whenever their tests do, unlike the CLI's tests that count child processes (see "CLI tests"). Starts that took turns across files were tried: with three copies of these four files at once they took about 1.5 times as long (481 to 493 s against 312 to 316 s) and removed no failure that the limits above had not, so the limits are what is used.

### Goldens

A **golden** is a file holding the exact output a test expects: `symbols.json.golden`, `layers.json.golden` and the other three in `fixtures/apps/goldens/`. `delta.md.golden` is the version-delta renderer's output, compared with `expectTextGolden`. `native.json.golden` is the native config of the template app below, compared by `native_template_test.dart` and, on Flutter 3.47.5, by the real-SDK test. A golden test runs the real sync on the fixture app (`knowledge_sync_test.dart` with the stand-ins, `map_real_sdk_test.dart` with the real packages) and compares the canonical JSON, byte for byte, with the file. It catches the changes no one meant: an extra symbol, a route that lost its screen, an order that changed.

**To update goldens safely:**

1. Run the failing test and read the diff. **Assume the code is wrong until proven otherwise.** A golden that changes should be a change you meant to make.
2. If it is intended, run the tests once with `APPSTEIN_UPDATE_GOLDENS=1`. That is the one time a test writes into the repo.
   ```powershell
   cd packages/appstein_engine
   $env:APPSTEIN_UPDATE_GOLDENS = '1'; fvm dart test test/knowledge/knowledge_sync_test.dart; Remove-Item Env:APPSTEIN_UPDATE_GOLDENS
   ```
3. Review the golden's diff in git, line by line, like code. Commit it with the change that caused it.

### The real-SDK test

Stand-ins can lie. [`map_real_sdk_test.dart`](../../packages/appstein_engine/test/integration/map_real_sdk_test.dart) (tagged `integration`) syncs the same app against the **real** Flutter and the real `go_router` from pub.dev, and expects the same goldens. For `deps.json` it compares only what must match (each direct package's kind, constraint and usages), because real versions and transitive packages differ. It also syncs a second time and expects every file `unchanged`. If a stand-in drifts from the real package, this test fails, and the stand-ins are what is wrong: bring them back in line with the real package, and leave the goldens alone. CI runs it in the `test` job with the current Flutter and in the `min-sdk` job with the oldest (see [ci](ci.md#min-sdk)).

**`machineSdk`** ([`machine_sdk.dart`](../../packages/appstein_engine/test/support/machine_sdk.dart)) finds the Flutter that test uses: the repo's pinned one if there is one, else any on the machine. The `min-sdk` job installs 3.44 while the repo pins 3.47.5, so there only the second lookup works. With no Flutter, the test fails in CI and is skipped on a developer's machine, as the doctor's real-environment tests are.

## The native template and its golden

The [native config](native-config.md) is tested on the native files of a real Flutter app, kept in `packages/appstein_engine/test/fixtures/native/template_app/`. It is the output of Flutter 3.47.5's `flutter create --platforms=android,ios --org dev.sample --project-name probe_app`, after `flutter pub get` (which writes the generated `Package.swift`). Only the files the packs read are kept: `pubspec.yaml`, the three Gradle build files, `gradle.properties`, the wrapper properties, the three manifests, `Info.plist`, `project.pbxproj` and `Package.swift`. Each ends in `.fixture`, for the reason given above. `local.properties` is left out, because it holds machine paths. How to make the folder again is on the [native-config](native-config.md#tests) page.

The helpers are in [`native_support.dart`](../../packages/appstein_engine/test/support/native_support.dart):

| Helper | What it does |
|---|---|
| `copyNativeTemplate` | Copies the template into a `tempDir()` folder named `native app` (a space, on purpose) |
| `writeProjectFiles` | Writes files by their forward-slash paths, so a test changes one file of the copy to try one case |
| `flutterAndroidValues` | Flutter 3.47.5's Android values (what `flutter.minSdkVersion` and the others become), read the way `sync` reads them: from the SDK fixture's `gradle_utils.dart` |
| `nativeContext` | A `NativeContext` for a project on a machine with only the variables you give it. It points `APPDATA` and `HOME` at an empty temp folder, so the real machine's Flutter settings (the global SwiftPM setting) are never read |

`native_template_test.dart` syncs the template with both platform packs and compares the result with `native.json.golden`. The real-SDK counterpart, `native_real_sdk_test.dart`, is described on the [native-config](native-config.md#tests) page; CI runs it in the `test` job and in `min-sdk` (see [ci](ci.md#min-sdk)).

## A second process, for locks

`knowledge_lock_test.dart` starts [`lock_holder.dart`](../../packages/appstein_engine/test/knowledge/support/lock_holder.dart) as a separate `dart` process, the way `process_runner_test.dart` starts `timeout_harness.dart`. POSIX file locks belong to a process, so two handles in one test process can't stand for two writers. The holder exits without unlocking, to prove a crashed writer never leaves the lock stuck.

Three details about helper processes:
- **Stopping the holder.** Teardown closes the holder's stdin, and the holder exits by itself. It does not kill the holder. On Windows, `dart <script>` runs the script in a child `dartvm.exe`, and that child holds the lock. Killing `dart.exe` reports the exit while the child still has `.lock` open, so deleting the temp folder failed on CI ("being used by another process"). On a normal exit, the child ends first.
- **Finding the helper.** The lock tests locate `lock_holder.dart` with `Isolate.resolvePackageUri`, not a path relative to the working folder. `process_runner_test.dart` changes `Directory.current`, which is process-wide, while test files run concurrently, so a relative path could point at the wrong place.
- **Keep helpers small.** A helper process imports only the engine files it uses (`timeout_harness.dart` and `lock_holder.dart` do). Importing all of `appstein_engine` pulls in `package:analyzer`, which adds seconds of JIT start-up. It once broke `process_runner_test.dart`'s 8 s budget.

The CLI tests build their own minimal Flutter SDK with [`fake_flutter_sdk.dart`](../../packages/appstein_cli/test/support/fake_flutter_sdk.dart), because a package's tests can't import another package's test support.

## Lint tests

The rule's tests use `package:analyzer_testing` with `package:test_reflective_loader`, the setup the Dart team uses for analyzer rules:

- a test class extends `AnalysisRuleTest` and is marked `@reflectiveTest`;
- each method whose name starts with `test_` is one test, found by `defineReflectiveTests`;
- a test writes files and an `analysis_options.yaml` into an in-memory project, then asserts which diagnostics appear, and where.

See `packages/appstein_lints/test/layer_imports_rule_test.dart`, and [lints](lints.md) for the rule itself.

## Tool tests

The tests in the root `test/` folder cover `tool/`. Many need a real git repo, so [`test/support/temp_repo.dart`](../../test/support/temp_repo.dart) provides:

- **`tempFolder()`**: a temporary folder with a space and a non-ASCII character in its name. If Windows won't delete it (git marks its object files read-only), it is left behind, which is harmless.
- **`tempRepo()`**: an empty git repo on branch `main`, in a `tempFolder()`.
- **`runGit()`**: runs git in a repo with a fixed name and email, no commit signing and no line-ending conversion, so the tests behave the same whatever your own git settings are. `gitResult()` is the same, but returns the whole result without checking it.
- **`writeFile()`**: writes a file by a forward-slash path, creating its folders.

**Why `GIT_*` variables are stripped.** A git hook runs with `GIT_DIR` set. A git command that inherits it works on that repo, whatever folder it runs in. So tests started from inside a hook would change the Appstein repo instead of the temp repo. `runGit()` (through `gitEnvironment()`) drops every `GIT_*` variable. The guide check's `GitRepo` does the same, so the post-commit hook checks the right repo.

**The hook tests run real git hooks.** `hooks_test.dart` installs our blocks into a temp repo, next to a fake `post-checkout` hook that logs its arguments in graphify's place. It then merges and rebases with real git, and checks that git ran our blocks with the right commits. The docs block is switched off there with `APPSTEIN_SKIP_DOCS_HOOK=1`. The graph blocks run against a fake Python, named with a space, that logs its arguments. The tests check that the graph check runs after a commit, a merge and a rebase (once, not for every replayed commit), with `--skip-repairable` after a merge or rebase, stays silent without a graph, and prints one line when `.graphify_python` is missing. They also check that the background repair (`--detach`) starts, silently, on a branch switch and once after a merge or rebase. It must not start for a rebase's own checkouts, a file checkout, a new branch at the same commit, a skip variable, or a `check_graph.py` from before the repair. The fake `post-checkout` hook also logs `APPSTEIN_HOOK_REPLAY`, so the replay tests see that our blocks set it. `gitResult()` returns what git and its hooks printed, since hooks print to stderr. Every block is also run through `sh -n`, which parses it without running it; that test is skipped when `sh` isn't on the PATH. See [docs-tooling](docs-tooling.md) for what the hooks do.

**The graph check runs against real graphify.** `check_graph_test.dart` builds a temp repo with two docs and a Dart file, and fakes an update with [`graphify_fixture.py`](../../test/support/graphify_fixture.py), which writes real cache entries through graphify's own code. Like a real extraction, each fake one has a node for the doc itself, with the id graphify's heading node for the doc gets, and a concept node (`--only-heading` leaves the concept out). The check tests then write a small `graph.json` by hand. The repair tests build it with graphify's own code rebuild instead (`graphify_fixture.py --build`). They drop a doc the way a branch switch does (rebuild without the file, put it back, rebuild) and check that `--repair` puts it back and keeps everything else, a saved community name included. They also cover waiting: a Python process that holds graphify's lock (which `--repair` and `--after-rebuild` wait out), a lock file nobody holds (which it doesn't), a job that hits its time limit, and a merge in progress (which it waits out, or logs a skip when its wait runs out). The repair group allows 3 minutes per test. Edited cache entries cover the root placeholder in ids and an entry from another file. `APPSTEIN_REPAIR_START_WAIT`, `APPSTEIN_REPAIR_MAX_WAIT` and `APPSTEIN_REPAIR_TIMEOUT` (the job's whole limit) keep the waits short; `GRAPHIFY_REBUILD_TIMEOUT` of zero or less must set no limit, which a test checks, and `GRAPHIFY_REBUILD_LOG` sends the background log to a temp folder. A `sitecustomize.py` on `PYTHONPATH` stands in for a graphify release whose rebuild fails, or no longer takes the extraction. The file takes about a minute. It needs a Python that can import graphify. [`graphify.dart`](../../test/support/graphify.dart) tries `APPSTEIN_GRAPHIFY_PYTHON`, then the interpreter this repo's `graphify-out/.graphify_python` names, and takes the first that can import graphify. Without one, those tests are skipped, except when `APPSTEIN_REQUIRE_GRAPHIFY=1`: CI sets it after installing a pinned graphify (see [ci](ci.md)), so there a missing graphify fails the tests instead.

**The warm measurement runs against a stand-in server.** `mcp_session_test.dart` and `warm_measurement_test.dart` start [`fake_mcp_server.dart`](../../test/support/fake_mcp_server.dart) as a separate Dart process. It answers `initialize` and the tool calls `tool/measure_sync.dart` makes. Given `--file` and `--name`, its `verify` reads the edited Dart file from disk, as a correct analysis server does. A few tools misbehave on purpose: `die`, `hang`, `garbage` and `badresult`. So do some flags:
- `--blind` never reports the error;
- `--stale-after <n>` repeats its last answer from the nth `verify` call on;
- `--sticky-line` keeps reporting the first line it ever reported;
- `--error-reply-at <n>` answers the nth call with an error;
- `--slow-ms <n>` answers late;
- `--stubborn` doesn't end when its input closes.

Each case lets a test show that the measurement fails rather than passes. [`hold_open.dart`](../../test/support/hold_open.dart) is a process that does nothing until its input closes. The tests use it as a server that never answers `initialize`, and as a child to find in the real process list, for the process tree, start times and leftovers. [`hold_chain.dart`](../../test/support/hold_chain.dart) starts itself again, one level fewer each time, so `hold_chain.dart 3` gives a run, a "guard" and a Dart "server" under it, the shape of a terminal `appstein verify`. That makes the memory sampler's test the same on every system, whatever way `dart` itself runs a script. See [ci](ci.md) for the measurement itself.

**The stale-page check runs end to end too.** `guide_check_test.dart` builds a temp repo with a page covering a file, changes the file on a branch, and checks that `checkGuide` reports it until the page changes or a `Docs-Checked` commit names the page.
