# The Stop hook and the loop guard

**What to build:** `appstein verify --full --apply --hook claude`, the one command Claude Code's Stop hook runs when the agent says it is done (design §5.4). Errors block "done" with exit 2. When the same errors have blocked three times in a row in one session, the loop guard lets the agent stop and shows the developer what is left. Warnings and Appstein's own failure at "done" go to the developer only, since context for the agent at Stop would keep it going (spec: "What reaches whom", "The loop guard").

**Blocked by:** 06.

Status: ready-for-agent

- [ ] A full run in hook mode answers as a Stop hook: errors exit 2 with stderr as in ticket 05 (errors only, cut at 30); warnings and no error exit 0 with a JSON message for the developer listing them; only info or nothing exit 0 and no output; Appstein failing exits 0 with the developer's message only.
- [ ] The Stop input's "already continuing because of a Stop hook" flag is read; missing input counts as not continuing.
- [ ] The loop guard counts, per session ID in the same record as ticket 06, how many times in a row the same set of (check ID, file, message) has blocked. Lines are left out: an error moved by an edit above it is the same error.
- [ ] The count starts again when the set of errors changes, or when the input says the agent is not already continuing.
- [ ] On the third identical block the run exits 0 and gives the developer a JSON message listing the remaining errors. Tested across several Stop calls with one session ID, with two sessions keeping separate counts, and with an error that moves between lines.
- [ ] `--apply` in hook mode works as without it (fix, format, then the checks; ticket 08 adds the docs render).
- [ ] The guide page for the verifier describes the Stop hook and the loop guard; the guide check passes.
