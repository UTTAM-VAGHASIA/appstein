<!-- covers:
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

## Fakes for the machine

The engine reaches the machine through two types, `HostEnvironment` and `ProcessRunner` (see [running-tools](running-tools.md)). Tests pass fakes for both. The helpers live in `packages/appstein_engine/test/support/`:

| Helper | File | What it builds |
|---|---|---|
| `fakeEnvironment` | [`temp.dart`](../../packages/appstein_engine/test/support/temp.dart) | A `HostEnvironment` with only the variables you give it, for the real OS unless you pass one. A fake OS is for tests that touch no files, or whose files don't depend on the real OS, such as the macOS Android Studio tests, which pass their own folders to search. It also sets a fake `ProgramFiles`, so any future lookup can't stumble on the real machine's Android Studio (no lib code reads `ProgramFiles` today) |
| `fakeExecutable` | [`temp.dart`](../../packages/appstein_engine/test/support/temp.dart) | A tiny program in a folder that prints a fixed line: a `.bat` file on Windows, a `sh` script elsewhere. Put its folder on the fake PATH to make a tool "installed" |
| `FakeProcessRunner` | [`fake_process_runner.dart`](../../packages/appstein_engine/test/support/fake_process_runner.dart) | A runner that returns canned results set up with `when`, and records every call in `calls`. A command nobody set up "fails to start", just as a missing tool would |
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

**The lesson.** The unit tests for the JDK lookup encode our model of how Flutter chooses a JDK. If that model is wrong, the tests are wrong in the same way, and they still pass. Only comparing with Flutter's own answer, on a real machine, can catch a wrong model. That is why the cross-check with `flutter doctor -v` exists.

## CLI tests

- **In-process runs.** `runAppstein` takes output sinks, an environment, a runner and the doctor's checks as parameters. `runner_test.dart` passes `StringBuffer`s, an environment with no variables and made-up checks, then checks the text and the returned code. An extra command that throws on purpose tests the crash path.
- **The async crash path.** `runGuarded` changes the process's own exit code, and it exists to catch an error that escapes every future. That can't be tested inside the test runner's process. So `run_guarded_test.dart` starts [`async_error_harness.dart`](../../packages/appstein_cli/test/support/async_error_harness.dart) as a separate Dart process. The harness throws from a timer, outside the awaited future, and the test expects exit code 3 and the crash message on stderr.

## Flutter's own files as fixtures

`packages/appstein_engine/test/fixtures/flutter_sdk/<version>/` holds Flutter's toolchain files for 3.44.9 and 3.47.5, each ending in `.fixture`. [`flutter_fixtures.dart`](../../packages/appstein_engine/test/support/flutter_fixtures.dart) reads them (`fixtureText`) or copies them into a fake SDK under their real names (`addToolchainFiles`). The fixture folder is found from the package itself (`Isolate.resolvePackageUriSync`), not from `Directory.current`, for the reason given under "Finding the helper" below. Tests that need CRLF files convert the text in the test, because the repo stores everything with LF. See [toolchain](toolchain.md#tests-and-fixtures).

## A second process, for locks

`knowledge_lock_test.dart` starts [`lock_holder.dart`](../../packages/appstein_engine/test/knowledge/support/lock_holder.dart) as a separate `dart` process, the way `process_runner_test.dart` starts `timeout_harness.dart`. POSIX file locks belong to a process, so two handles in one test process can't stand for two writers. The holder exits without unlocking, to prove a crashed writer never leaves the lock stuck.

Two details about helper processes:
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

**The stale-page check runs end to end too.** `guide_check_test.dart` builds a temp repo with a page covering a file, changes the file on a branch, and checks that `checkGuide` reports it until the page changes or a `Docs-Checked` commit names the page.
