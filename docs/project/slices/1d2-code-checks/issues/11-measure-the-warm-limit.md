# Measure the warm limit

**What to build:** the 5 s limit for a fast run (design §15) is measured where an agent meets it: on the `verify` tool of a running `appstein mcp`, after one file is edited. CI holds that number to the limit on Linux, macOS and Windows. The terminal runs, which start their own analysis server, are timed and recorded with no limit.

**Blocked by:** 04, 06.

Status: resolved

- [x] The measurement tool starts the compiled `appstein mcp` on the 200-file app, waits until warm analysis is ready, edits one file, calls the `verify` tool with the fast scope, and takes the median of three. 5 s or more fails the run, with a message giving the measured time (the design's "< 5 s"; owner, 2026-10-15).
- [x] The edit in the measurement introduces a real error, and the measurement fails if the reply doesn't report it, so a fast answer that missed the change can't pass.
- [x] The terminal `appstein verify --fast` and the terminal full run are timed and recorded with no limit; the old 5 s limit on the terminal fast run is removed.
- [x] The analysis server's start-up time and its memory are recorded with them.
- [x] CI runs the measurement on Linux, macOS and Windows, and the numbers of one green run on each are written into the slice's spec beside the interview's numbers.
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

**2026-10-15, later: two CI runs, and the measurement fixed.**

- **First CI run (38630902740).** All three measurement jobs passed the 5 s limit, but two rows were wrong, both faults of the tool, not of `verify`:
  - Windows printed 0.00 GB for a terminal run's memory: the sampler had missed the run.
  - On Linux and macOS, terminal fast runs timed slower than full ones: the analysis cache started cold, and the fast runs went first and paid for filling it.
  - A test of ticket 04 also failed on Linux and macOS, because `ps` gives start times to the second; fixed in `f5af4c9`.
- **The tool now** gives the server a cache folder of its own and records both a cold and a warm time for the terminal runs (owner, 2026-10-15). Warm means after warm-up runs until the cache stops growing, at most 15, and the row says when the cap was hit. A memory sample counts only when it saw the guard and a Dart server; a run never seen is run again, then fails. This was reviewed three times and committed in `ebde68e`, with a last check that caught Linux's `dart:<script>` process names before any CI run.
- **Second CI run (38721583522).** All three measurement jobs passed; the numbers are in the slice spec's Further Notes. Warm fast `verify` took 1.00 s on Linux, 0.97 s on macOS and 1.30 s on Windows. The run failed elsewhere, in two older tests that had never run on those systems (a macOS process-identity test from ticket 04, a Linux test-time-limit test from ticket 10). They are being fixed separately; neither touches the measurement.
- **Found by the measurement, for the owner:** each end of the analysis server left half-written files in the machine's shared Dart cache; ticket 13 cleans them up. On Windows a terminal `verify` stays slow for 15 or more runs on a new machine, while Linux and macOS warm up in five.
