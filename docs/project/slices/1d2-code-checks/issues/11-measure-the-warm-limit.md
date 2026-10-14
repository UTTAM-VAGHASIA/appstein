# Measure the warm limit

**What to build:** the 5 s limit for a fast run (design §15) is measured where an agent meets it: on the `verify` tool of a running `appstein mcp`, after one file is edited. CI holds that number to the limit on Linux, macOS and Windows. The terminal runs, which start their own analysis server, are timed and recorded with no limit.

**Blocked by:** 04, 06.

Status: claimed

- [x] The measurement tool starts the compiled `appstein mcp` on the 200-file app, waits until warm analysis is ready, edits one file, calls the `verify` tool with the fast scope, and takes the median of three. 5 s or more fails the run, with a message giving the measured time (the design's "< 5 s"; owner, 2026-10-15).
- [x] The edit in the measurement introduces a real error, and the measurement fails if the reply doesn't report it, so a fast answer that missed the change can't pass.
- [x] The terminal `appstein verify --fast` and the terminal full run are timed and recorded with no limit; the old 5 s limit on the terminal fast run is removed.
- [x] The analysis server's start-up time and its memory are recorded with them.
- [ ] CI runs the measurement on Linux, macOS and Windows, and the numbers of one green run on each are written into the slice's spec beside the interview's numbers.
- [x] If the warm fast run exceeds 5 s on any of the three, work stops and the owner is asked: the design's limit is not changed to fit.
- [x] The guide page that describes the measurements is updated; the guide check passes.

## Comments

**2026-10-15, built, reviewed three times, fixed twice. The CI box waits for one manual run (owner's yes, 2026-10-15).**

- **What is measured.**
  1. `tool/measure_sync.dart` starts the compiled `appstein mcp` on the 200-file app. Its first `verify` call is the wait for warm analysis, and that call's time is the server's start-up.
  2. It then edits `feature_9`'s view model three times. Each edit puts a real error on its own line, with its own size.
  3. After every edit, the fast reply must report `dart.error` on that file and line. After every fix, the reply must be clean. So a stale or blind answer fails whatever its time.
  4. The median is held to under 5 s. The logic lives in `tool/src/warm_measurement.dart` and `warm_verify.dart`, and is tested against a fake MCP server that can be blind, stale, slow, failing or stubborn.
- **Windows numbers** (development machine, loaded by other helpers' test runs):
  - Warm fast `verify`: median 1.63 s, 1.78 s and 1.85 s in three runs.
  - About 1.4-1.5 s of that is the knowledge refresh, since a view model is a map input. The look, the reading and the checks take about 0.25 s.
  - Server start-up: 5.1 s, or 15.7 s with the `appstein_lints` plugin (one run by hand).
  - Memory of the `appstein mcp` tree, when ready / after the calls: 1.0 / 1.2 GB, or 1.9 / 2.3 GB with the plugin.
  - The earlier reading of 6-7 s was not reproduced.
- **Owner's decisions, 2026-10-15:**
  - The limit follows the design's "< 5 s".
  - macOS joins the measurement job, so every existing limit runs there for the first time. If one fails, work stops and the owner is asked.
  - The slice spec's "about 0.1 s after an edit" is reworded when the CI numbers go in.
  - One manual CI run on the branch is allowed.
- **What the reviews changed:**
  - A failed process listing no longer passes the leftover check as "nothing left".
  - The process tree only takes a child that started at or after its parent, and a leftover must keep the start it was first seen with, so reused process IDs on Windows are not counted.
  - Every MCP call has a time limit, the start has its own longer one, and a bad reply gives a clear message.
  - The tables are printed before a failure.
  - A first call that hangs still gets the leftover check.
  - A failure while sampling memory no longer crashes the tool or leaves its folder behind.
- **Seen on the busy machine:** the existing `sync --detect` limit (under 2 s) was missed once at 2.5-2.6 s, while other test runs were going. CI will show whether this happens on a quiet runner.
- **Not run:** Linux and macOS. The `ps` paths are tested with fixed inputs only.
