# `--hook claude` after an edit

**What to build:** `appstein verify --fast --hook claude`, the command Claude Code's PostToolUse hook runs after every edit (design §5.4, §9.5, §11.1). It reads the hook's input from stdin and answers the way Claude Code reads hooks: errors block with exit 2 and reach the agent, warnings reach the agent without blocking, info and nothing stay silent, and Appstein's own failure is told to both the agent and the developer without blocking. In this ticket the code checks take today's route (a server of the run's own); ticket 09 moves the hook to the analysis host.

**Blocked by:** None (can start immediately).

Status: ready-for-agent

- [ ] `verify` gains `--hook claude`. `--hook codex` is a usage error (exit 3) that says Codex's hooks come in slice 1e. `--hook` with `--format` is a usage error.
- [ ] The hook's input is read from stdin (Claude Code's JSON: the session's ID and the event name). Input that is missing, empty or not JSON counts as no session and the run still checks.
- [ ] Errors: exit 2; stderr lists the errors only, grouped by file as the text output does, with fix hint and knowledge reference. More than 30: the first 30, then "…and N more: call the `verify` tool for all".
- [ ] Warnings and no error: exit 0; stdout is Claude Code's PostToolUse JSON with context for the agent listing the warnings, under 10,000 characters.
- [ ] Only info findings, or nothing: exit 0 and no output.
- [ ] Appstein failing (what is exit 3 in the terminal: a crash, a bad environment, an invalid `appstein.yaml`, a server that can't answer): exit 0; JSON context telling the agent verify could not run, why, and that its edit is unchecked; a JSON message telling the developer the same with "run `appstein doctor`". Never exit 2 for it.
- [ ] Checks named as not run are said in the agent's context, so silence never hides an unchecked edit.
- [ ] The JSON matches Claude Code's documented hook output (the event name in the hook-specific part, the context and message fields); a test pins its shape.
- [ ] The guide page for the verifier and the CLI page describe hook mode; the design's §9.5 wording already matches (changed with the spec). The guide check passes.
