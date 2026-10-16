# The unverified files, with `dart.warning` and `dart.lint`

**What to build:** Appstein remembers the unverified files: the files changed since a verify run last found no error in them. A fast run reports the analyzer's warnings and lints only on those files, so an agent isn't shown old lints in files it never touched, and an earlier error can't scroll out of view after the next edit. A full run reports them everywhere. An agent or a person can add files with `--files` or the tool's `files` input.

**Blocked by:** 03.

Status: resolved

- [x] An analyzer warning is a `dart.warning` warning and an info-level diagnostic is a `dart.lint` info finding, each with the file, the line, the analyzer's message and its code. Plugin diagnostics are reported the same way, by their level.
- [x] A fast run reports them only on the unverified files; a full run reports them on every file.
- [x] A file joins the unverified files when the knowledge refresh sees its content changed. This holds for every Dart file the analysis server covers, test files included.
- [x] A file leaves them when a verify run, fast or full, reports no error on it. An error hidden by a suppression counts as none. A deleted file leaves after one run.
- [x] The scenario from the interview holds: break file A and run; fix nothing, edit file B correctly and run again. A is still among the unverified files, and its warnings and lints are still reported.
- [x] The unverified files survive between runs and between processes, in `.appstein/state.json`. A state file written before this ticket is read without an error, as no earlier state (changed by the owner on 2026-10-14, see below: every Dart file is then unverified).
- [x] `appstein verify --fast --files <paths>` adds the named files for that run and after it. Relative paths are taken from the project root; absolute paths inside the project are accepted. A path outside the project, and `--files` with a full run, are usage errors (exit 3) with a clear message. A path that isn't a Dart file or no longer exists is accepted.
- [x] The `verify` MCP tool has the same `files` input with the same rules, and its input schema says so.
- [x] On an unverified file, a `dart.deprecated` finding's fix hint says whether `dart fix` can migrate it. Elsewhere the hint stays general.
- [x] The unverified files are read once per run, before the knowledge lock, and the same set is used by everything in that run: what is gathered and what the checks judge never see two different sets.
- [x] A diagnostic carries what the server's "can this be fixed" question needs (its position in the file), and that question is asked while gathering, never under the knowledge lock.
- [x] Both checks can be overridden with `verify.severity` and hidden by a suppression.
- [x] The guide pages for the checks and for the knowledge store's state are updated; the guide check passes.

Added by the owner's decision of 2026-10-14, after the review of ticket 05:

- [x] A Dart file the analysis covers that can't be opened for reading (on Windows, one another program holds locked) is a `dart.unreadable` error on that file, in fast and full runs, saying it could not be read so nothing in it was checked. It is found by opening each file in the look that comes before every reading, so it costs no second walk of the project. Tested with a real lock on Windows: today that file reads as clean to every code check, `dart.error` included.
- [x] Such a file never leaves the unverified files, and it is never read as clean by any check.
- [x] `dart.unreadable` can be overridden with `verify.severity` and hidden by a suppression.

Added by the owner's decisions of 2026-10-14, after the review:

- [x] With no earlier state (the first sync of a project, or a `state.json` deleted or unreadable), every Dart file is unverified.
- [x] In a run that reports `dart.plugin_failed` or `knowledge.stale`, or in which a `dart.*` check was named as not run, no file leaves the unverified files. Tests not run (`test.failed` named as not run) don't count: they judge the project, not a file (owner, after the second review).

Added by the owner's decisions of 2026-10-14, after the second review:

- [x] A `state.json` written before this ticket, without the Dart file hashes, is read like a missing one: every Dart file is unverified.
- [x] The scan of the Dart files outside the map's inputs hashes a file again only when its time or size changed, with the same known limit as the analysis's look (an edit that keeps the size and puts the file time back is not seen until the file changes again).

## Comments

**2026-10-14, built beside ticket 09, reviewed twice, fixed twice.**

- **Where the unverified files live.** `state.json` keeps a hash of each Dart file (and, for the files outside the map's inputs, their time and size) and the unverified files. The refresh adds the changed files; a run reads the set once, before the lock, and writes what is left under the lock it holds, only when it changed. A file leaves when no error-severity finding names it after `verify.severity` and the suppressions (`appstein.yaml` entries and, since ticket 09, `// appstein:ignore` comments), and only when the run took a code reading and its hash did not change during the run.
- **What the reviews found and changed** (besides the owner's five decisions above): files behind folder and file links were missed (the server analyzes them; both walks now follow links as the server does, with cycles cut as it cuts them, and skip dot-named files as it does); the `dart fix` question cost up to 0.25 s each with no cap, every fast run (answers are now kept per text of the reading, with a hard 1 s budget per run; measured 15-68 ms for a first question, 0.02 ms for a kept one); the hash scan blocked the MCP isolate for up to 0.5 s with a large `build/` (now never more than one timer step, 16 ms, and unchanged files are not read: 104 ms for this repo's 449 files instead of 421 ms); every file was opened at once (now at most 32, and "too many open files" is never reported as unreadable); a lock past the first byte, or taken right after the look, read as clean (changed files are read whole before and after the reading); a failed fix question failed the whole run (now the general hint).
- **Known limit, in the guide:** a lock taken after the first whole read and released before the second still reads as clean for that reading. Giving the server the text as overlays would close it, but turns off the server's own file watcher, which a freshness test showed is what catches a same-size edit with its time put back; so it was not done.
- **Measured on small apps only.** The cost on the 200-file app, with and without a large `build/`, is ticket 11's to measure against the 5 s limit.
- **Linux and macOS** were not run; the open-file pool was tested on Windows by counting, not against a real 256-file limit.
