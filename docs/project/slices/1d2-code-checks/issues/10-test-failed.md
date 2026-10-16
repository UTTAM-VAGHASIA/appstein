# `test.failed`

**What to build:** a full run runs the project's tests once and reports each failing test as its own error, with enough in it to go straight to the test. A suite that can't compile isn't waited for, and a suite that hangs is stopped.

**Blocked by:** 03.

Status: resolved

- [x] A full run runs `flutter test` on the whole project with the project's Flutter, once, and reads its machine-readable output.
- [x] Each failing test is a `test.failed` error on the test's file and line, with the test's full name (its groups included) and the first lines of the failure in the message. A test that threw is reported the same way as one whose expectation failed.
- [x] A test file that can't be loaded is one `test.failed` error on that file with the loader's message.
- [x] When the run's reading has an analyzer error, the tests are not run, and the check is named among the checks not run with that reason. It is the reading that counts, before overrides and suppressions: a hidden compile error still stops the tests from compiling. The frame lets a check name itself as not run with a reason of its own; today the only reason it can give is the stale map.
- [x] The test run happens while gathering, never under the knowledge lock, so another process is not kept waiting for minutes.
- [x] A project with no `test/` folder gives no `test.failed` finding and is not named as not run.
- [x] `verify.test_timeout_seconds` is a key of `appstein.yaml`, default 600; a value that isn't a positive whole number is a configuration error. A suite still running at the limit is stopped, its processes included, and reported as one `test.failed` error on the project, naming the limit and the key.
- [x] A fast run never runs the tests and doesn't name the check as not run.
- [x] `flutter test` that can't be started at all (no Flutter SDK) is Appstein failing: exit 3 with "run `appstein doctor`".
- [x] The check is tested with scripted output for: a passing run, a failing expectation, a thrown error, a file that can't load, and a run that never ends. One run of the real `flutter test` on a fixture app is made where a real Flutter SDK is present.
- [x] `test.failed` can be overridden with `verify.severity` and hidden by a suppression.
- [x] The guide pages for the checks and for `appstein.yaml` are updated; the guide check passes.

Added by the owner's decisions of 2026-10-14, after the first review:

- [x] When the tests are not run because the code has analyzer errors and none of them is still reported as an error (each is suppressed or lowered), one `test.failed` error on the project says so, with the count.
- [x] `flutter test` that started but named no failing test (a non-zero exit, or no end of run) is one `test.failed` error on the project with Flutter's own last lines, not exit 3. This replaces part of the exit-3 line above: exit 3 stays for a test run that can't be started at all.
- [x] A run that doesn't finish (the time limit, or output that ends early) reports the failures it saw, and one `test.failed` on the project that names the tests that were running. This replaces "reported as one `test.failed` error" in the time-limit line above.

## Comments

**2026-10-14, built in a copy of the repo beside ticket 04, reviewed twice, fixed once.**

- **The run.** `flutter test --machine --no-pub`, once, with the sync's process runner, while gathering. `--no-pub` keeps a verify run from rewriting `pubspec.lock`.
- **What the test run leaves in the project** (measured): `build/` on every run, and four images in `test/failures/` after a failing golden test. `pubspec.lock` and `.dart_tool/` are unchanged. The owner accepted it; the spec says so.
- **Facts from real output of Flutter 3.47.5:** a widget test's failure text is in a printed block (`EXCEPTION CAUGHT BY …`, any library) before the error event; a `testWidgets` test has `root_line`; a test file whose path from the project has a space gets no line on Windows (Flutter gives none); a file whose `main` throws puts the reason on the `Failed to load` line itself; a `test/` folder with no `*_test.dart` makes `flutter test` exit 1 with no event, so it is treated like no `test/` folder.
- **A check can add findings after the suppressions** (`FollowingCheck`), which is how the hidden-compile-error finding is judged. That finding has no file, so a suppression can't hide it; `verify.severity` can lower it. Lowering both `dart.error` and `test.failed` still gives a passing run with the tests never run: two explicit settings, and written in the guide.
- **Stopping a hung suite on Windows:** the process runner's `taskkill /T /F` on the process it started. In the reviewer's own count, 71 and 39 processes below two runs, none alive 12 s later. Linux and macOS not measured; CI will show it.
- **Checked on real runs through the CLI by the reviewer:** a run that ends part-way (the earlier failure listed, the running test named), no `flutter_test` dependency (a project finding with Flutter's words, no `appstein doctor`), a timeout with three earlier failures and 40 finished tests (none wrongly named as running).
- **Not fixed, small:** a golden failure's message keeps one absolute path (`/C:/…`); when the kill of a timed-out suite itself fails, the process runner (older code) doesn't say so.
- **CI:** the new integration file runs on all three systems and one of its tests takes 75 s.
- **Brought onto the branch after tickets 04 and 05** (2026-10-14). Ticket 04's `mcp_warm_analysis_test.dart` calls `verify` with full scope on a project with tests, which now runs `flutter test`; its fake process runner had none scripted, so the call failed with "tests could not be run" in both engine runs. It now scripts a run whose tests all pass, as ticket 10's other tests do. No product code changed for it.
