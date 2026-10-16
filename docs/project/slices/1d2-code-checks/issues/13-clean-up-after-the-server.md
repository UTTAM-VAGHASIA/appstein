# Clean up after the analysis server

**What to build:** when Appstein ends its analysis server, it removes the half-written cache files that server left behind, so the Dart cache the whole machine shares does not fill with them. The test suites keep their analysis servers' caches in folders of their own.

**Blocked by:** 08.

Status: resolved

Added by the owner's decision of 2026-10-15, after ticket 11's measurement:

- [x] After Appstein ends an analysis server it started, and only once that server is shown to be gone, it deletes the files in the server's cache folder whose names end in `-temp-<that server's process ID>`. Nothing else in the cache is touched. The stop stays as fast as it is today (the server is still ended without asking it to stop first: asking took about 4 s in review). (The stop is 20–175 ms against 13–25 ms before, because the guard now waits for the killed server to finish ending, which "shown to be gone" needs. Accepted by the owner, 2026-10-16.)
- [x] The cache folder is the one the server used: the folder `ANALYZER_STATE_LOCATION_OVERRIDE` names when it is set, otherwise the SDK's default (`%LOCALAPPDATA%\.dartServer` on Windows, `~/.dartServer` on Linux and macOS). A missing folder, a file already gone, or a file that can't be deleted is never an error for the run.
- [x] This holds for every way a server ends: a terminal run, `appstein mcp` stopping its kept server when it is idle or closing, a server replaced after a settings change, and a server that died.
- [x] A test runs a real server, ends it the way a terminal run does, and shows that no `-temp-<its ID>` file is left, while another `-temp-` file and a complete cache entry placed there beforehand are still present.
- [x] Every test suite that starts a real analysis server gives it a cache folder of its own under the test's temporary folder, so running the suites leaves nothing in the machine's shared cache. A check run before and after a suite shows the shared cache gains no `-temp-` file.
- [x] The doc comment on stopping the server no longer says a kill is no harder on the cache than `dart analyze`'s end; it says what a kill leaves and what is cleaned up.
- [x] The guide pages for the analysis server and for testing are updated; the guide check passes.

Known limit, kept by the owner: a terminal run still ends its server before the server has saved all it worked out, so a terminal `verify` on a new machine reaches its warm speed only after many runs (15 or more in ticket 11's measurement). The measurement says so in its warm row.

## Comments

**2026-10-16, built, reviewed twice, fixed twice, a last check.**

- **What was built.**
  - After a stop, Appstein asks about the server's process every 10 ms, for up to 2 s. Only once the server is gone, and on Windows its handle shows it has ended, does it delete the files directly in `<cache>/.analysis-driver` whose names end in exactly `-temp-<that ID>`. It never follows or deletes a link, and never fails the run (`analysis_cache.dart`).
  - The cache folder follows the SDK's own rule: the override variable, otherwise `.dartServer` in `LOCALAPPDATA` or `HOME`.
  - Every way a server ends goes through the one stop.
- **Seen on a real server.** All of the files a killed server left carried the ID the guard named for it, never the guard's own. Five stops with the clean-up switched off left 14–20 files each; with it on, 0. In the review's timing runs, the old code left 30–37 files per run of two stops and the new one left 0.
- **Changed on the way:**
  - **The guard waits.** After the kill it now waits, at most 2 s, for the server to finish ending. Without that, on Windows a file the killed server was still creating could appear after the clean-up: 4 in 20 runs failed before the change, 0 in 30 after.
  - **The stop costs more.** A stop is 20–175 ms against 13–25 ms before (review, three versions interleaved). For a person watching, a terminal `verify` prints first and the clean-up runs after. The process still ends only after the clean-up, so an agent waiting on it pays the listing: 0.2–0.3 s with the 64,000 old leftovers on this machine, a few ms without them. The box "the stop stays as fast as it is today" was not met as written, because "shown to be gone" means waiting for the server to end; the owner accepted the cost on 2026-10-16.
  - **test_all keeps its own cache.** Its `dart analyze` step uses a git-ignored, warm cache under `.dart_tool/`.
- **Shared cache, checked on 2026-10-16:** a full `tool/test_all.dart` run, with nothing else running on the machine, left the shared cache's count of `-temp-` files at 67,619 before and after.
- **Not built (outside the ticket):** a killed `appstein mcp` still leaves its server's files, because no clean-up runs. The guard could clean up itself: carried to 1d.7 (owner, 2026-10-16).
- **Not verified:** Linux and macOS (read from the source only; CI run #3 is their first real check), and the rare stop paths with a real server.
