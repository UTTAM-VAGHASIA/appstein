# The analysis server's cold start on Windows and macOS

**What to build:** two things the measurement of ticket 10 showed in CI, neither of them in the hook's 5 s (the hook asks the host's warm server), both found and fixed (the owner, 2026-10-22):

- **On Windows the analysis server's cache never settles.** Before the warm terminal rows, `tool/measure_sync.dart` runs full `verify` runs until one adds no cache entry. Linux settles in 2 runs and macOS in about 6; Windows stopped at the limit of 15 in every run (39649820222, 39687897383, 39755048394, 39763006737), each run adding 100 to 450 entries. So the cache on a Windows user's disk keeps growing, a terminal run or a host start never gets the warm cache's speed (the no-host hook took 5.9 s on Windows against 2.1 to 2.7 s elsewhere), and Windows' warm terminal rows are not measured warm.
- **On macOS a cold terminal `verify --fast` sometimes waits about 20 s for the server's first answer.** It took 8.3 to 12.1 s in the other runs, but in runs 39682826377 and 39687897383 it was cut by the 20 s cap: the question was asked at 0.2 s and the server did not answer in 19.8 s. A rerun of the same commit passed. The tool fails its row on a cut run, so CI fails for it; and a user's first terminal run on such a machine would be cut and exit 3.

**Blocked by:** None (can start immediately).

Status: ready-for-agent

- [ ] Why each Windows run adds cache entries is found and shown (which files, and what differs between two runs' entries for one file: their keys, the paths they name, the letter case of the drive or a folder, the SDK or the options), not guessed; the cause is fixed so the cache settles on Windows as on Linux and macOS, and the warm-up shows it in CI.
- [ ] Why the macOS server sometimes gives no answer for about 20 s is found from evidence the run leaves (when the server started, what it was doing, what the runner was doing), not guessed; the cause is fixed where it is Appstein's, and where it is the runner's, the measurement and a user's run are made not to fail for it without raising the cap (the cap is the owner's, 2026-10-20).
- [ ] Each fix has a test that fails without it, and a CI run shows both: Windows' warm-up settles within the 15 runs, and the macOS cold row passes in repeated runs.
- [ ] The guide (`docs/guide/ci.md`, and the pages for the code that changes) and the slice spec's Further Notes say what was found.

## Comments
