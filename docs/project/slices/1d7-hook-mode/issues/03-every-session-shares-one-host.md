# Every session shares one host

**What to build:** several sessions, hooks and tools working on one project share one analysis host and so one analysis server. The host survives the session that started it, replaces itself after an Appstein upgrade, recovers from a crash, and never mixes one client's question into another's (spec: "The analysis host", housekeeping and "One question at a time").

**Blocked by:** 02.

Status: resolved

- [x] Two `appstein mcp` processes on one project, both calling `verify`, leave exactly one host and one analysis server running. Ending the first leaves the second's answers warm.
- [x] Clients that start a host at the same moment end with one host: creating the address file is exclusive, and the one that loses waits for the winner's address and connects to it.
- [x] An address file whose host refuses the connection or has ended (a host that died) is deleted and a new host is started.
- [x] A client says its Appstein version when it connects. A host of an older version is asked to stop and a new one is started; the client's answer comes from the new one. A client older than the host leaves it alone, answers that run from its own analysis server, and says the session should be restarted (changed by the owner on 2026-10-18).
- [x] A change of the project's SDK (for example `fvm use` to another version) restarts the host's server; the next answer comes from the new SDK.
- [x] The host answers one question at a time, in the order they arrive, across clients. A question asked during another client's pending-fix passes waits and never sees their temporary edits (tested with a full run's passes and a fast question from another client). A question whose client has gone away is dropped.
- [x] A project path with spaces, letter-case differences and a long name works on Windows; two different projects get two hosts.
- [x] The developer guide says how to find a project's host and end it by hand, and what happens to its server then.
- [x] The guide check passes.

## Comments

**2026-10-18 to 10-19, built and reviewed.** Built by a helper (Opus medium) in its own worktree, reviewed on two axes (standards: Sonnet high; spec: Opus high), two fix rounds (Opus medium, then Sonnet medium), round 1 checked (Opus high), round 2 checked by Claude.

- **How it works.**
  - **One host per project.** Starting a host is guarded by a lock file beside the address file (`host-<hash>.lock`, `analysis_host_lock.dart`), made by an exclusive create and held for milliseconds. A new host writes its address only if none is there; otherwise it has lost the race and exits without starting a server, and its client connects to the winner.
  - **Stale locks.** A lock is cleared when its holder has ended, or when it is older than the stale time whatever process it names. A reused process ID on Windows can't wedge a project. The re-look before deleting compares both content and modified time.
  - **Dead hosts.** An address whose host refuses the connection, or whose process has ended, is deleted (only while it is still that host's) and a new host is started. A connect timeout against a live host is not death: that question fails and the address stays.
  - **Versions** (the owner's rule, below). A newer client sends `AnalysisHostStop`. A stopping or idly ending host takes no new question: it replies "ending", answers only what it already had, flushes unsent answers (at most 1 s) and ends. The client retries through the address file, at most 3 times, when it gets "ending" or its connection closes before the turn. It does so only for a reading, or when nothing was answered yet in the run; otherwise the question fails. A question whose turn began never runs twice.
  - **SDK changes.** The server compares the `dart` path and the SDK's `version` file at each reading and restarts on a difference, so `fvm use` and `flutter upgrade` in place are both seen.
  - **Ordering** was already ticket 02's per-question turn. The new test runs a real host with stand-in passes. It was shown failing with the queue bypassed ("answered during the passes") and passing with it.
- **Decided by the owner (2026-10-18):**
  - **One run's questions are not kept together.** Each question takes the server alone, so another session's question can land between a run's reading and its `dart fix` question. Nothing is lost; at worst a `dart fix` hint is out of date for that run. This is a known limit in the guide, and it closes what ticket 02 had left "until ticket 03".
  - **A newer version replaces an older host; an older client leaves a newer host alone.** The older client uses its own analysis server for that run and says the session should be restarted for fast answers. Changed in the slice spec and decision record 0002 from "a host of another version is asked to stop", under which two versions replaced each other's host over and over.
- **Review round 1 fixed:**
  - a stopping host that still took new questions (an `--apply` could have written after the stop);
  - a stale lock that a reused process ID kept alive for good;
  - the test clean-up, which could kill an unrelated process with a reused ID;
  - an ordering test that could not fail;
  - an SDK upgraded in place;
  - a connect timeout counted as a dead host;
  - the lock moved to its own file, plus renames, merged duplicates and a protocol test for the stop message.

  The fixer also found and fixed a host bug: answers not yet sent were dropped when a host ended.
- **Review round 2 fixed:**
  - a host ending after its idle time could still begin a question that arrived in its last moment;
  - the same process-ID-reuse guard for the CLI tests' clean-up;
  - an older client's own server's left-over-process notices now go to `appstein mcp`'s stderr log;
  - a stale doc comment and a test reason.
- **Decided by Claude, not asked of the owner:** an unparseable version counts as the older client (it stops nothing); the retry is limited to 3 tries and to questions that had no effect.
- **Not verified:** Linux and macOS (CI); the CLI clean-up's identity rule against a real reused process ID; the stderr notices end to end (making a server leave processes needs a real server that fails to stop); the compiled binary.
- **Full gate in the slice branch:** `tool/test_all.dart` passed: protocol 84, engine 1955 twice (10 skipped), CLI 222, lints 19, repo tools 378 (1 skipped); format, analyze, gen_docs and the guide check clean.
