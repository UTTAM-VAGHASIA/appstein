# `dart.error` from a terminal run

**What to build:** `appstein verify`, run in a terminal, reports the project's analyzer errors. It starts the analysis server of the project's own SDK, waits for the first analysis, reports each error as a `dart.error` finding, and stops the server. This is the first complete path through every layer: the server, the code analysis interface, a check, the output and the exit codes. Later tickets add checks on top of it.

**Blocked by:** 01, 02.

Status: resolved

- [x] On a fixture app with a compile error, `appstein verify` (fast and full) reports a `dart.error` error with the file, the line, the analyzer's message and the analyzer's code, and exits 1. On the same app without the error it reports nothing for this check and exits 0.
- [x] An error in a file that depends on the edited one is reported too: breaking a class another file uses gives a `dart.error` in that other file.
- [x] Diagnostics that aren't errors are not reported by this ticket.
- [x] The check runs when the knowledge is stale: on a project whose code doesn't resolve, `dart.error` findings appear beside `knowledge.stale`.
- [x] The analysis server is the one of the project's SDK, started from the SDK's real executable, not a wrapper script, and spoken to over the legacy analyzer protocol (decision record 0001).
- [x] The server is started through a guard: the `appstein` binary in a mode of its own that isn't listed in the help, which starts the server, passes its input and output through, and ends it when its own input closes. Where Appstein isn't a compiled binary (its own tests), the guard is started the way the tests start Appstein.
- [x] "Ready" is the server's own word that its analysis is done. Diagnostics are taken from the notifications the server sends, so a plugin's diagnostics are included.
- [x] After the run ends, normally or with an error, no analysis server process and no guard is left running. When the process that started them is killed, both are gone within a few seconds. Checked on Windows.
- [x] A server that doesn't start, dies during the run, or isn't ready within 180 s makes the run exit 3 with the reason and "run `appstein doctor`". It is never reported as "no errors", and never as a finding.
- [x] The checks reach the server only through the code analysis interface, and a scripted stand-in for it exists for tests. The stand-in's tests cover the level-to-severity mapping and the server that fails.
- [x] `dart.error` is a known check ID: a suppression in `appstein.yaml` and a `verify.severity` override both work on it.
- [x] Paths with spaces work, and the file a finding names is relative to the project root with `/` separators on every system.
- [x] `///` comments on every new public API; the guide pages for the new component and the changed files are written or updated; the guide check passes.

## Comments

**2026-10-14, what two reviews changed, and what is not proven.**

- **Built beyond the checklist, on review findings:** each run takes one reading of the diagnostics before the knowledge lock, and a check with slow outside work gathers it there; a guard that dies alone no longer leaves its server; a plugin the server could not load is the finding `dart.plugin_failed` (the owner approved the ID); a question after the run's server was released throws; TODO comments are hidden as `dart analyze` hides them.
- **Three lines are met in part.** A plugin's diagnostic was not seen arriving through `runVerify` (the measuring tool of ticket 02 saw it on the same protocol). The 180 s limit was tested with a shortened limit, not waited for. The check running beside stale knowledge is tested with missing packages; a syntax error alone doesn't make the knowledge stale.
- **Carried into later tickets by the reviews:** tickets 04, 06, 07, 08 and 10 each gained lines.
- **Until ticket 04,** `appstein mcp` starts and stops a server for each `verify` call. **Until ticket 11,** `tool/measure_sync.dart` still holds the terminal fast run to 5 s and would fail.
- **Changed from 1d.1:** a machine with no usable Dart SDK now exits 3 from `verify` ("run `appstein doctor`"), where it reported `knowledge.stale`.

**2026-10-13, a test that failed once, and a change made on a guess.**

- **What happened.** In the last round of fixes, the engine test "a server that dies: the next question fails" failed once in a run of the whole engine suite. It had passed alone and in a three-file run. The failure message was not captured.
- **What was changed.** The builder believed that a question asked just after the guard's process exited was answered from the dead server's last reading, because the client takes up to 2 s to judge how the guard ended. A question now waits for that judgement before it answers. The cause was not proven.
- **What is known since.** The test file passed 5 times of 5 alone. The whole engine suite, where the failure had appeared, then passed 5 times of 5 on the Windows development machine (1,375 passed and 7 skipped each time, 2 min 53 s to 3 min 17 s). That makes the failure rare or gone; it does not prove the cause.
- **What may still be open.** The change covers the time after Appstein has noticed that the guard exited. Between the moment the process dies and the moment Appstein is told, a question can still be answered from the last reading. On a terminal run that can't matter: the server is started for the run and asked once. On a kept server (ticket 04) it can, and ticket 04's rule that a reading is taken only after the server has answered a fresh request closes it, since a dead server answers nothing.
- **Watch for it** in CI on all three systems. If this test fails again, the guess was wrong or incomplete, and the cause is found before anything else is built on it.
