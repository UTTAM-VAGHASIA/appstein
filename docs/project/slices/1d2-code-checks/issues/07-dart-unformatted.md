# `dart.unformatted`

**What to build:** a file whose formatting `dart format` would change is a warning. The answer comes from the project's own SDK through the analysis server, so verify can never ask for a format the developer's tools would undo. Generated files are left out.

**Blocked by:** 06.

Status: resolved

- [x] A Dart file that the formatter of the project's SDK would change is a `dart.unformatted` warning on the file, with a fix hint naming `appstein verify --apply`.
- [x] A fast run reports it only for the unverified files; a full run for every file.
- [x] The check agrees with `dart format --output=none --set-exit-if-changed` of the pinned SDK on a fixture with formatted and unformatted files, including the project's formatter settings in `analysis_options.yaml` (such as the page width).
- [x] A file that `analysis_options.yaml` excludes is never reported. A file that starts with a `GENERATED CODE - DO NOT MODIFY` header is never reported.
- [x] A full run knows every Dart file the analysis server covers, including files with no diagnostics; today a reading lists only diagnostics. The formatting questions are asked while gathering, never under the knowledge lock.
- [x] The check never writes a file.
- [x] A file that can't be parsed gives no `dart.unformatted` finding: its `dart.error` already says why.
- [x] The check can be overridden with `verify.severity` and hidden by a suppression.
- [x] The guide page for the checks is updated; the guide check passes.

Added by the owner's decision of 2026-10-15, after the review:

- [x] If the analysis server dies or fails while answering the formatting question, that is Appstein failing (slice spec, "a server that … dies"): exit 3 in the terminal and an error reply from the tool, with the reason and `appstein doctor`. A server that is alive but slow names the files it did not answer as not checked, and a file the server refuses alone is not checked alone.

## Comments

**2026-10-15: built, reviewed twice, fixed twice.**

- **How it asks.** `CodeAnalysis.formatChanges(files, within:)` sends the legacy protocol's `edit.format` for each file, 32 at a time, the look's open-file limit.
  - One question costs about 15 ms of server round trip. Asked in parallel, 200 files take 103-140 ms the first time and under 1 ms after that.
  - Answers are kept per file and text hash. An answer is used and kept only when the file still hashes to the reading's text once it arrives.
  - When the file has changed, the file is not checked in that run, and the next reading tells the server about it again. So a same-size edit with its time put back makes one run partial, not every run.
- **What a fast and a full run ask about.** A fast run asks about the run's unverified files; a full run asks about every `.dart` file in `analyzedFiles`. The answers are gathered before the knowledge lock.
  - Files not asked about: generated files (a `// GENERATED CODE - DO NOT MODIFY` header in the comments before the first code), unreadable and deleted files, and files whose name doesn't end in `.dart`.
  - A file the server can't parse (`FORMAT_WITH_ERRORS`) gives no finding.
- **Time budgets, which the spec doesn't name.** A fast run gives the questions 1 s and a full run 60 s, plus 1 s of grace, measured on the question itself and never on the wait for the MCP turn.
  - A file not answered in time is named in `notRun`, never read as formatted. That makes the run partial, so no file leaves the unverified files.
  - The budget was added by the builder; it goes into the slice notes for the owner.
- **What the reviews found and changed:**
  - In `appstein mcp`, the time limit also timed the wait for the call turn, so a parallel tool call could make every file "not checked" and let verify overlap the other call. The limit is now on the question only.
  - One refused file threw away every answer; now only that file is not checked.
  - A kept answer could be filed under a stale text, including after a syntax-error refusal.
  - The agreement test now also covers `trailing_commas: preserve` and a `// @dart=3.6` file.
- **The fixture app was reformatted.** Its `router.dart.fixture` and `auth_repository_remote.dart.fixture` were not in `dart format`'s form, so a healthy fixture reported `dart.unformatted`. The goldens moved by line numbers and body hashes only.
- **Left as it is:** `canDartFix` keeps its soft fallback (the general hint) when the server fails during a hint question. The formatting question asked after it still fails the run with exit 3.
- **The fix hint names `appstein verify --apply`**, which ticket 08 builds.
- **Not run:** Linux and macOS. A real `SERVER_ERROR` from the formatter can't be produced on demand, so it is tested with the scripted server only.
