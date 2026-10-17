# Nothing changed means no output

**What to build:** after a command that changed nothing Appstein reads (`ls`, `git status`, an edit to a README), the hook exits 0 with no output and runs no check, at the cost of one hash scan. "Nothing changed" is judged against this session's own last hook run, so another session's work on the project never makes this session miss its own edit (spec: "Nothing changed means no output").

**Blocked by:** 05.

Status: resolved

- [x] Per session, the hook keeps a fingerprint of the input hashes it last saw, in a git-ignored record under `.appstein/` (beside `state.json`). Records not touched for a day are deleted.
- [x] A fast hook run whose fingerprint equals the session's last one exits 0 with no output and runs no check.
- [x] A session's first hook run, and a run with no session (missing input), always check.
- [x] Tested: session A edits a file, session B's `appstein mcp` refreshes the knowledge (using up the change in `state.json`), then A's hook still checks and reports A's error.
- [x] An edit to a file Appstein doesn't read gives no output; an edit to a Dart file, `pubspec.yaml` or another file the knowledge reads gives a check.
- [x] Errors already reported stay in the unverified files; a silent run never lets a file leave them.
- [x] Two hooks of one session writing the record at once leave it whole (the record is replaced whole, under the knowledge lock or its own).
- [x] The guide page for the verifier describes the rule and why it is per session; the guide check passes.

## Comments

**2026-10-17, built and reviewed.** Built by a helper (Sonnet high) in its own worktree, reviewed on two axes (standards: Sonnet high; spec: Opus high), two fix rounds (Sonnet high), each checked (Opus high), then one change of mine.

- **How it works.** `KnowledgeSync.fingerprint` hashes everything the knowledge and the checks read, for a moment in time, and writes nothing, so it can't use up the change list in `state.json`. The hook keeps the last one per session in `.appstein/hook-sessions/records/<sha256(session)[:32]>.json` (`HookSessions`), replaced whole under the records' own lock. A hook run whose fingerprint equals its session's last one exits 0 with no output; any other run checks as before.
- **Review round 1 fixed:** the fingerprint missed inputs only the checks read: `appstein.yaml` (a suppression removed or a severity raised), nested `analysis_options.yaml` files and what they include, and the package configuration (new `check_inputs.dart`; `pubspec.lock` was already a map input). A change made during a check and undone after it could be saved as checked: the fingerprint is now taken again after the reply and saved only when both agree. The records had waited up to 2 s on the knowledge lock, so a hook's exit could sit behind another session's rebuild: they now have their own lock, 200 ms, and a busy lock skips the save. Other fixes: a test of two separate processes writing one record; a wrong guide sentence; `architecture.md`; small clean-ups.
- **Review round 2 fixed:** a code comment that still contradicted the guide; the options file in a folder above the project (which the analyzer applies when the project has none) is now in the fingerprint, through one lookup shared with `dart.deprecated`; the cross-process test now starts its three writers together (ready/go), takes 3 s instead of 13, and was shown to fail with the lock removed (twice) and pass with it.
- **My change after round 2:** the fingerprint followed an options file's `include:` only inside the project, though the analyzer follows it anywhere, so in a monorepo (`include: ../../analysis_options.yaml`) an edit to the shared file left the hook silent over new findings. It now follows includes wherever they lead; a file on another drive is named by its full path.
- **Decided by Claude, not asked of the owner:** a fingerprint that can't be taken means check; a run with `--files` is never silent; a suppressed `dart.plugin_failed` still counts as a completed run; a silent run doesn't refresh its record's age (at worst one extra check after a day); a busy records lock skips the save (the next run checks).
- **A known limit, documented in the guide:** a change made and undone entirely between the two fingerprints is not seen; that state stays unreported only until the next change to anything the knowledge reads, or the Stop hook's full run.
- **Not verified:** the fingerprint's cost against the 5 s budget (ticket 10 measures it; estimated 0.1 to 0.5 s per fingerprint, two on a checking run); Linux and macOS (CI).
- **Full gate in the slice branch:** `tool/test_all.dart` passed: protocol 82, engine 1936 twice (10 skipped), CLI 221, lints 19, repo tools 378 (1 skipped); format, analyze, gen_docs and the guide check clean.
