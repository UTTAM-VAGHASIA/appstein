# The guard cleans up after its own server

**What to build:** the guard that stands in front of the analysis server deletes that server's half-written cache files (`-temp-<the server's process ID>`) every time it ends the server: when its input closes because its parent ended in any way, and on a normal stop. The parent no longer does this clean-up. A killed `appstein mcp`, or a killed terminal run, leaves no such file behind (spec: "The guard cleans up after its server"; 1d.2 notes, decided at the close, 3).

**Blocked by:** None (can start immediately).

Status: resolved

- [x] When the guard's input closes (its parent killed), it ends the server, waits until the server is shown to be gone, and deletes only that server's `-temp-<pid>` files in the cache folder the server used. Tested by killing the parent of a real guard and server on a fixture app, on Windows too.
- [x] On a normal stop the guard does the same clean-up; the parent's own clean-up after `stop()` is removed, and nothing is deleted twice or left behind.
- [x] The rules of 1d.2's clean-up are kept: only files directly in the cache's analysis-driver folder, only that server's process ID, never following a link, never throwing.
- [x] A guard killed together with its server (both ended at once) leaves the files: written in the guide as a known limit, replacing the 1d.2 limit "a killed `appstein mcp` leaves its server's half-written files".
- [x] A terminal run still ends only after the clean-up is done, so tests that count files after a run stay valid.
- [x] The guide pages that cover the guard and the analysis server say who cleans up; the guide check passes.

## Comments

**2026-10-17, built and reviewed.** Built by a helper (Sonnet high), reviewed on two axes (standards: Sonnet high; spec: Opus high), one fix round, then a short check (Opus high).

- **How it works now.** The guard's clean-up is `removeServerFilesWhenGone`: after the server's exit, it waits until the system shows the server ended (`processHasEnded`, polled every 10 ms within `_serverEndWait`, 2 s), then deletes only that server's files. One budget, `analysisGuardEndBudget` (3 s), covers the exit wait, the polling and the deletion, and a test holds it at least 1 s below the parent's `analysisStopWait` (5 s), so the parent never kills the guard in the middle of it. The parent's clean-up (`trackCleanUp`, `analysisCleanUpsDone`, `AnalysisServer.cacheFolder`) is gone.
- **Tests.** Nine decision tests through the seam (ended → deleted; another process has the ID → nothing deleted after the wait; exit never seen; no cache folder; each step throwing; budget used up; a removal that never finishes), plus real-process tests on Windows: a killed parent leaves only other processes' files; a guard killed and then its server leaves the files (known limit). Two mutations (delete after the wait runs out; drop the budget) each failed a test.
- **Known limits, in the guide:** a hung kill (exit not seen within the wait) leaves the files, since the parent's kill by ID no longer cleans up; a guard killed with or without its server leaves them; a stop now includes the clean-up, so a terminal run prints its result after it, and an `appstein mcp` server replacement waits for the old server's clean-up (not measured). These were accepted by Claude, not asked of the owner: the process still ends at the moment 1d.2's close agreed.
- **OPEN, not explained: a failure under load.** The builder's first CLI run, made beside the engine suite, failed tests in `mcp_command_test.dart` about a killed `appstein mcp` and its input closing, plus `run_guarded_test.dart` and two more (the output was cut, so the full list and messages are not known). The check reran both suites at once twice on the change (CLI 149/149, engine 1881 passed) and the CLI suite on the base: no failure, and the same timings (the guard ends at most about 3 s after its input closes; the tests allow 10 s and 30 s + 5 s). So this change is an unlikely cause, but the failure was never reproduced and its cause is unknown; "tests waiting their turn for 8 minutes on a busy machine" is a guess. Watch those tests in CI on Linux and macOS; carried to the slice's notes.
- **Not verified:** Linux and macOS (CI will run them).
- **Full gate in the slice branch:** `tool/test_all.dart` passed: protocol 82, engine 1881 twice (8 skipped), CLI 149, lints 19, repo tools 378 (1 skipped); format, analyze, gen_docs and the guide check clean.
