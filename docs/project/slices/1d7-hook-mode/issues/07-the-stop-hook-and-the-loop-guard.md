# The Stop hook and the loop guard

**What to build:** `appstein verify --full --apply --hook claude`, the one command Claude Code's Stop hook runs when the agent says it is done (design §5.4). Errors block "done" with exit 2. When the same errors have blocked three times in a row in one session, the loop guard lets the agent stop and shows the developer what is left. Warnings and Appstein's own failure at "done" go to the developer only, since context for the agent at Stop would keep it going (spec: "What reaches whom", "The loop guard").

**Blocked by:** 06.

Status: resolved

- [x] A full run in hook mode answers as a Stop hook: errors exit 2 with stderr as in ticket 05 (the errors, cut at 30, and the checks that did not run); warnings and no error exit 0 with a JSON message for the developer listing them; only info or nothing exit 0 and no output; Appstein failing exits 0 with the developer's message only.
- [x] The Stop input's "already continuing because of a Stop hook" flag is read; missing input counts as not continuing.
- [x] The loop guard counts, per session ID in the same record as ticket 06, how many times in a row the same set of (check ID, file, message) has blocked. Lines are left out: an error moved by an edit above it is the same error.
- [x] The count starts again when the set of errors changes, or when the input says the agent is not already continuing.
- [x] The same errors block three times in a row; on the fourth Stop with the same errors the run exits 0 and gives the developer a JSON message listing the remaining errors (the owner, 2026-10-19). Tested across several Stop calls with one session ID, with two sessions keeping separate counts, and with an error that moves between lines.
- [x] `--apply` in hook mode works as without it (fix, format, render the human docs, then the checks).
- [x] The guide page for the verifier describes the Stop hook and the loop guard; the guide check passes.

## Comments

**2026-10-19, built and reviewed.** Built by a helper (Sonnet high) in its own worktree, reviewed on two axes (standards: Sonnet high; spec: Opus high), one fix round (the same helper), checked (Opus high); one wording slip in the guide fixed by Claude after the check.

- **How it works.** `--hook claude` picks the kind of run (`HookKind`): the input's `hook_event_name` decides when present (`Stop` is the Stop hook, any other event the after-edit hook); with no event the flags decide (`--fast` after-edit, otherwise Stop, so a bare `verify --hook claude` answers as Stop). A Stop run reads the session's count before the checks, decides with `decideLoopGuard` (a plain value: let go or not, and the count to save), then saves only the record's `guard` part under the records' lock; ticket 06's fingerprint is the record's other part, and neither save erases the other.
- **Decided by the owner (2026-10-19):** the same errors block three times; the fourth Stop lets the agent go (design §5.4 "have blocked 3 times in a row"). The count is kept at 4, so further Stops with the same errors keep letting go. Written into spec.md and this ticket's box 5.
- **Decided by Claude, not asked of the owner:** on exit 2, stderr first names the files `--apply` rewrote and tells the agent to read them again before editing (cut by file and length within ticket 05's budget), since the agent's view of those files is stale. A Stop save waits 2 s for the lock (`stopSaveLockWait`); the after-edit hook keeps 200 ms, since only it has the 5 s budget.
- **Review round 1 fixed:** the 3-block rule; an early release when removing a count was judged outside the lock; a PostToolUse hook set up without `--fast` could reset or add to the count (the event now decides); rewritten files not named on exit 2; `HookKind` in place of a bare `stop` bool across the CLI; `_runAsHook` collapsed into two run types; one reply shape for both hooks; `errorsKey`; an end-to-end test for bare `--hook claude`.
- **Known limits (all documented in the verify guide page):** the one early release left is a save of a *changed* count that fails after the full 2 s wait (an old, higher count then carries on). A line number inside a finding's message (`lib/a.dart:12:5`) changes the key; that direction keeps the agent blocked, bounded by Claude Code's own eight. Misconfigured hooks only: any non-Stop event (SubagentStop, for one) is answered as the after-edit hook; a hook that fails before its input is read is answered by its flags; a full run answered as after-edit with `--apply` does not name the rewritten files on warnings. A clean Stop creates the git-ignored `.appstein/hook-sessions/` folder.
- **Not verified:** a real Claude Code session; Linux, macOS and the compiled binary (CI, ticket 10). The engine suite's first run in the worktree had one timing failure in `analysis_host_test.dart` that passed alone and on rerun (load, as in ticket 01).
- **Gate in the worktree:** engine 1985 passed (11 skipped), CLI 271 passed; `analyze --fatal-infos`, format, gen_docs and `check_guide --since 609ee51` clean.
- **Full gate in the slice branch:** `tool/test_all.dart` passed: protocol 84, engine 1985 twice (11 skipped), CLI 271, lints 19, repo tools 379; format, analyze, gen_docs and the guide check clean.
