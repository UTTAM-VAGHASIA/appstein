# The cap, and hooks through the host

**What to build:** `verify.fast_timeout_seconds` becomes a real cap on every fast run, and the hooks ask the project's analysis host. A fast hook run that finds no host starts one and waits for it up to the cap; when the cap comes first, its code checks are named as not run and the agent is told its edit's code checks are pending. A full hook run starts a host when none runs and waits for it without the cap (spec: "The cap", "Who starts it").

**Blocked by:** 03, 05.

Status: ready-for-agent

- [ ] Every fast run (hook, `verify` tool, terminal) is capped by `verify.fast_timeout_seconds` (default 20 s), counted from the run's start; waiting for a host or a server to start counts.
- [ ] At the cap, the checks that hadn't finished are named among the checks not run with the reason (for example "the analysis server is starting"), the run is partial, and no file leaves the unverified files. The next run asks again. Tested with a scripted slow code analysis and a short cap.
- [ ] A fast hook run asks the project's host; with none answering, it starts one as a detached process (the same start as ticket 02's) and waits up to the cap.
- [ ] When the cap comes first: exit 0, or 2 when other checks found errors; the agent's context says the edit's code checks are pending because the analysis server is starting.
- [ ] The host a hook started keeps running after the hook ends, and the next hook gets warm answers from it.
- [ ] A full hook run starts a host when none runs and waits for it, limited only by the server's start limit.
- [ ] Full runs have no cap.
- [ ] The guide pages for the configuration and the verifier say what the cap does (the page that says the key is read by no command yet is corrected); the guide check passes.
