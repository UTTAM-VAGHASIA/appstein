# `dart.fix_pending` and `--apply`

**What to build:** a full run lists the fixes `dart fix` would apply. A full run with `--apply` applies them and formats the project first, then checks, and names each file it rewrote. Without `--apply`, `verify` changes no project file, so CI can run it on the code it checks.

**Blocked by:** 07.

Status: resolved

- [x] A full run reports one `dart.fix_pending` warning per file and code, with the count (`deprecated_member_use: 6 fixes`), on the file with no line. The totals equal what `dart fix --dry-run` of the pinned SDK prints for the same project.
- [x] The pending fixes are asked for in passes on the running server, each pass applied to an overlay in the server's memory and never to disk. The run's reading of the diagnostics is taken before the first pass, so no finding is judged against the fixed code, and the overlays are removed when the passes end, also when they fail. On a kept server, the next reading shows the code as it is on disk.
- [x] The passes run while gathering, never under the knowledge lock.
- [x] A fast run never runs this check and doesn't name it as not run.
- [x] `appstein verify --apply` (full run) applies the pending fixes to the whole project, formats the whole project, brings the knowledge up to date, then runs every check. A fix or a format it applied is no longer reported.
- [x] `--apply` rewrites files before the knowledge is brought up to date, in the terminal and in the tool, and the reading that follows is of the rewritten files (ticket 04's rule that a reading is never older than the files on disk).
- [x] Generated files (ticket 07's rule) are not formatted by `--apply`.
- [x] The result names each file `--apply` rewrote: an `applied` list in the JSON output, and a list before the findings in the text output. Without `--apply` the list is empty and the text output has no such section.
- [x] `--apply` with `--fast` is a usage error (exit 3) with a clear message.
- [x] The `verify` MCP tool has an `apply` input for the full scope with the same behaviour; its result has `applied`, its reply's text tells the agent to read those files again, and its schemas say so. `apply` with the fast scope is refused.
- [x] A test proves that a full run without `--apply` leaves every project file byte-identical, on a project with pending fixes and unformatted files.
- [x] After `--apply` on the fixture, a second run reports no `dart.fix_pending` and no `dart.unformatted`, and rewrites nothing.
- [x] The guide pages for the `verify` command, the tool and the checks are updated; the guide check passes.

Added by the owner's decisions of 2026-10-15, after the review (in the slice spec under "Pending fixes" and "`--apply`"):

- [x] At most four passes, as the pinned SDK's `dart fix` does; reaching the fourth counts as finished.
- [x] 120 s for the passes of a full run, 180 s for `--apply`, and a limit on each request to the server; unfinished passes report the counts so far and make the run partial; a server that dies or stops answering fails the run.
- [x] A rewritten file goes to a new file beside it, which is renamed over the original; a write in place only when that is safe.
- [x] A file outside the project, through a link included, is never counted, overlaid or written, and a notice names it.

## Comments

**2026-10-15: built, reviewed three times, fixed twice by the builder and once by me.**

- **How it works.**
  - `CodeAnalysis.pendingFixes` asks the running server for `edit.bulkFixes` in passes. Each pass is put on overlays in the server's memory, and the overlays are always removed afterwards.
  - `applyFixesAndFormat` fixes and formats the same way, then writes each changed file once.
  - The terminal and `appstein mcp` both run the rewrite before the knowledge refresh.
  - A real-SDK test agrees with `dart fix --dry-run` and `dart fix --apply` + `dart format`, including an eight-step rename chain that `dart fix` stops at four passes.
- **What the reviews found and changed:**
  - **Passes:** 10 passes instead of `dart fix`'s 4. That was proven by the chain, and the counts disagreed.
  - **Garbled writes:** a file whose text hash the reading forgot could be written with offsets computed for other text.
  - **Hangs:** overlay requests with no time limit could hang `--apply`, and with it every later `verify` call of `appstein mcp`.
  - **Unnamed files:** the terminal did not name rewritten files when the run then failed. The whole-call limit could fire mid-write and leave a written file unnamed.
  - **Atomic write:** the owner chose it. The reviews then found, and it now handles:
    - a failed or full-disk write never falls back to writing in place;
    - a crash leftover is removed by the next `--apply`;
    - file links stay links;
    - permissions are kept with one `chmod` when they differ.
  - **Linked files:** a file reached by two names inside the project was written once but then reported as "changed meanwhile". A link to outside the project was not checked.
- **My own fixes after the second round,** checked by the reviewer: a full disk when the new file is created leaves the original alone; one file under two names is written once and named under both; two guide lines.
- **Costs:**
  - Fixture: `pendingFixes` 0.45 s for two passes; a full run 4.7 s.
  - The 200-file app, before the review fixes: 15.8 s for three passes, 37 s on a server that had just started; `dart fix --dry-run` 20.7 s.
- **Not run:** Linux and macOS. The real `chmod` path and file-symlink tests are skipped on Windows; CI runs them. A real crash between the write and the rename, and a disk that is really full, are covered by injected failures only.
