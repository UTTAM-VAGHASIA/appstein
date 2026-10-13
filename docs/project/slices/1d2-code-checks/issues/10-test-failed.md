# `test.failed`

**What to build:** a full run runs the project's tests once and reports each failing test as its own error, with enough in it to go straight to the test. A suite that can't compile isn't waited for, and a suite that hangs is stopped.

**Blocked by:** 03.

Status: ready-for-agent

- [ ] A full run runs `flutter test` on the whole project with the project's Flutter, once, and reads its machine-readable output.
- [ ] Each failing test is a `test.failed` error on the test's file and line, with the test's full name (its groups included) and the first lines of the failure in the message. A test that threw is reported the same way as one whose expectation failed.
- [ ] A test file that can't be loaded is one `test.failed` error on that file with the loader's message.
- [ ] When the run's reading has an analyzer error, the tests are not run, and the check is named among the checks not run with that reason. It is the reading that counts, before overrides and suppressions: a hidden compile error still stops the tests from compiling. The frame lets a check name itself as not run with a reason of its own; today the only reason it can give is the stale map.
- [ ] The test run happens while gathering, never under the knowledge lock, so another process is not kept waiting for minutes.
- [ ] A project with no `test/` folder gives no `test.failed` finding and is not named as not run.
- [ ] `verify.test_timeout_seconds` is a key of `appstein.yaml`, default 600; a value that isn't a positive whole number is a configuration error. A suite still running at the limit is stopped, its processes included, and reported as one `test.failed` error on the project, naming the limit and the key.
- [ ] A fast run never runs the tests and doesn't name the check as not run.
- [ ] `flutter test` that can't be started at all (no Flutter SDK) is Appstein failing: exit 3 with "run `appstein doctor`".
- [ ] The check is tested with scripted output for: a passing run, a failing expectation, a thrown error, a file that can't load, and a run that never ends. One run of the real `flutter test` on a fixture app is made where a real Flutter SDK is present.
- [ ] `test.failed` can be overridden with `verify.severity` and hidden by a suppression.
- [ ] The guide pages for the checks and for `appstein.yaml` are updated; the guide check passes.
