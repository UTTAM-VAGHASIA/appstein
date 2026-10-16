# `--hook claude` after an edit

**What to build:** `appstein verify --fast --hook claude`, the command Claude Code's PostToolUse hook runs after every edit (design §5.4, §9.5, §11.1). It reads the hook's input from stdin and answers the way Claude Code reads hooks: errors block with exit 2 and reach the agent, warnings reach the agent without blocking, info and nothing stay silent, and Appstein's own failure is told to both the agent and the developer without blocking. In this ticket the code checks take today's route (a server of the run's own); ticket 09 moves the hook to the analysis host.

**Blocked by:** None (can start immediately).

Status: resolved

- [x] `verify` gains `--hook claude`. `--hook codex` is a usage error (exit 3) that says Codex's hooks come in slice 1e. `--hook` with `--format` is a usage error.
- [x] The hook's input is read from stdin (Claude Code's JSON: the session's ID and the event name). Input that is missing, empty or not JSON counts as no session and the run still checks.
- [x] Errors: exit 2; stderr lists the errors, and the checks that did not run, grouped by file as the text output does, with fix hint and knowledge reference. More than 30: the first 30, then "…and N more: call the `verify` tool for all".
- [x] Warnings and no error: exit 0; stdout is Claude Code's PostToolUse JSON with context for the agent listing the warnings, under 10,000 characters.
- [x] Only info findings, or nothing: exit 0 and no output.
- [x] Appstein failing (what is exit 3 in the terminal: a crash, a bad environment, an invalid `appstein.yaml`, a server that can't answer): exit 0; JSON context telling the agent verify could not run, why, and that its edit is unchecked; a JSON message telling the developer the same with "run `appstein doctor`". Never exit 2 for it.
- [x] Checks named as not run are said in the agent's context, so silence never hides an unchecked edit.
- [x] The JSON matches Claude Code's documented hook output (the event name in the hook-specific part, the context and message fields); a test pins its shape.
- [x] The guide page for the verifier and the CLI page describe hook mode; the design's §9.5 wording already matches (changed with the spec). The guide check passes.

## Comments

**2026-10-17, built and reviewed.** Built by a helper (Sonnet high) in its own worktree, reviewed on two axes (standards and spec), two fix rounds, then two fixes of mine, each checked by a reviewer (Opus high).

- **Fix round 1:** a hard 10,000-character cap on the JSON; crash paths in hook mode answer exit 0 with the failure JSON instead of exit 3; the stack trace goes to stderr at exit 0; notices go to `systemMessage`; the claim that stdout is not read at exit 2 corrected; a 2 s limit on reading stdin; a circular import broken, with one shared function that describes a failure for the terminal and for a hook.
- **Fix round 2 and my fixes:** the run and `runGuarded`'s failure handler share one `HookAnswer`, so whichever speaks first is the only answer (never two JSON documents, never a changed exit code). A failure that can't even be written keeps the exit code of a reply already given, so a late crash never turns an exit 2 into 0 (a test with an error whose text throws was red before the fix). `isClaudeHookRun` reads only the options before `--`.
- **Decided by Claude, not asked of the owner:** at exit 2, stderr also names the checks that did not run, since that is the only text the agent gets then (the spec's "errors only" line is changed to match); stdin is read for at most 2 s, then the run checks as with no session; warnings in the agent's context are cut at 30 and at about 9,000 characters, leaving room under the cap; `--hook` without `--fast` is refused until ticket 07 builds the Stop hook.
- **Known edge, left:** stderr broken and a second crash before any reply ends with exit 0 and no output. Carried to the slice's notes.
- **Not verified:** Linux and macOS (CI will run them); a real Claude Code session reading the hook's output (the shape is pinned by a test against the documented fields).
- **Owner, 2026-10-17:** approved changing the design's §9.5 to match ("stderr lists the errors … and the checks that did not run").
- **Full gate in the slice branch, on top of ticket 01:** `tool/test_all.dart` passed: protocol 82, engine 1881 twice (8 skipped), CLI 198, lints 19, repo tools 378 (1 skipped); format, analyze, gen_docs and the guide check clean.
