# Clean up after the analysis server

**What to build:** when Appstein ends its analysis server, it removes the half-written cache files that server left behind, so the Dart cache the whole machine shares does not fill with them. The test suites keep their analysis servers' caches in folders of their own.

**Blocked by:** 08.

Status: ready-for-agent

Added by the owner's decision of 2026-10-15, after ticket 11's measurement:

- [ ] After Appstein ends an analysis server it started, and only once that server is shown to be gone, it deletes the files in the server's cache folder whose names end in `-temp-<that server's process ID>`. Nothing else in the cache is touched. The stop stays as fast as it is today (the server is still ended without asking it to stop first: asking took about 4 s in review).
- [ ] The cache folder is the one the server used: the folder `ANALYZER_STATE_LOCATION_OVERRIDE` names when it is set, otherwise the SDK's default (`%LOCALAPPDATA%\.dartServer` on Windows, `~/.dartServer` on Linux and macOS). A missing folder, a file already gone, or a file that can't be deleted is never an error for the run.
- [ ] This holds for every way a server ends: a terminal run, `appstein mcp` stopping its kept server when it is idle or closing, a server replaced after a settings change, and a server that died.
- [ ] A test runs a real server, ends it the way a terminal run does, and shows that no `-temp-<its ID>` file is left, while another `-temp-` file and a complete cache entry placed there beforehand are still present.
- [ ] Every test suite that starts a real analysis server gives it a cache folder of its own under the test's temporary folder, so running the suites leaves nothing in the machine's shared cache. A check run before and after a suite shows the shared cache gains no `-temp-` file.
- [ ] The doc comment on stopping the server no longer says a kill is no harder on the cache than `dart analyze`'s end; it says what a kill leaves and what is cleaned up.
- [ ] The guide pages for the analysis server and for testing are updated; the guide check passes.

Known limit, kept by the owner: a terminal run still ends its server before the server has saved all it worked out, so a terminal `verify` on a new machine reaches its warm speed only after many runs (15 or more in ticket 11's measurement). The measurement says so in its warm row.
