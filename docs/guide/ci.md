<!-- covers:
.github/workflows/**
tool/startup_check.dart
tool/measure_analyze.dart
-->

# Continuous integration

CI is one GitHub Actions workflow, [`ci.yml`](../../.github/workflows/ci.yml). It is the gate: local hooks only warn, and CI fails the change. The spec's plan for CI is in §19.3 of the [spec](../superpowers/specs/2026-09-29-appstein-design.md#193-ci-github-actions); this page describes what runs today.

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
7. Doctor against this real machine

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
7. Read the toolchain from this real SDK (spec §12, risk 6)

**`measure`** runs on `ubuntu-latest`, `windows-latest`:

1. `actions/checkout@v4`
2. `subosito/flutter-action@v2`
3. `dart pub get --enforce-lockfile`
4. Measure cold analysis with the plugin (spec §9.1)

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
- **Doctor against this real machine:** the engine's `integration`-tagged tests run with `--run-skipped --tags integration`. They compare Appstein's answers with the runner's real Flutter (see [testing](testing.md)).

### build

- **Compile:** `dart compile exe` builds the AOT binary on each OS. Agent hooks will start this binary, not `dart run` ([spec §19.5](../superpowers/specs/2026-09-29-appstein-design.md#195-distribution-and-versioning): "Hooks use the compiled executable").
- **Start-up budget:** [`tool/startup_check.dart`](../../tool/startup_check.dart) runs `appstein --version` seven times and fails if the median is over 200 ms (spec §15). A hook that starts slowly slows down every agent action.
- **Run doctor (report only):** the binary runs `doctor` for real. Exit 0 or 1 is fine, because a CI runner may be missing tools such as the Android SDK. Exit 3 or 255 means Appstein crashed, and the step fails.
- **Run sync in a scratch project:** the binary runs `appstein sync`, and the step fails if any part of `toolchain.json` came from the notes. That proves the analyzer-based toolchain parser works in the AOT binary, not only under `dart run`.
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
- It runs `dart analyze --fatal-infos`, which also loads our analyzer plugin on the old SDK, and each package's unit tests. It then runs `sync_real_environment_test.dart` against the real Flutter 3.44, which proves the toolchain parsers on the oldest supported SDK (spec §22 risk 6). See [toolchain](toolchain.md).

### measure

- It runs [`tool/measure_analyze.dart`](../../tool/measure_analyze.dart) on Linux and Windows. The tool creates a fresh Flutter app with about 200 generated files and times `dart analyze`:
  - one file without the plugin;
  - the whole project, the first time with the plugin (this includes building the plugin);
  - the whole project with the plugin;
  - one file with the plugin.
- A deliberate layer violation, the canary, proves the plugin really ran: with the plugin on, the whole-project run must report `layer_imports`.
- The table goes to the job summary and, through `tee`, to the log.
- It reports numbers; it has no time budget to fail. The first numbers (9–16 s for one cold file with the plugin) led the spec to plan warm analysis for fast checks ([spec §9.1](../superpowers/specs/2026-09-29-appstein-design.md#91-fast-checks-after-every-change-changed-files-only-target--5-s)).
