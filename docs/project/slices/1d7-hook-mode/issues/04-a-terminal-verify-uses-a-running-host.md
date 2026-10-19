# A terminal `verify` uses a running host

**What to build:** a terminal `appstein verify` (a person, or CI) asks the project's analysis host when one is running, so it gets warm answers. When none is running it starts its own analysis server and stops it, as in 1d.2, and never starts a host, so a CI run leaves no process behind (spec: "Who starts it").

**Blocked by:** 02.

Status: resolved

- [x] With a host running for the project, a terminal fast run and full run ask it and start no server of their own; their findings equal the tool's.
- [x] With no host running, a terminal run starts its own server, stops it at the end, and leaves no host, guard or server running afterwards.
- [x] A host that stops answering during a terminal run is Appstein failing (exit 3 with the reason), as for its own server.
- [x] A host of another Appstein version is not used by a terminal run: the run uses its own server and leaves that host alone.
- [x] The guide page for the verifier says which route a terminal run takes; the guide check passes.

## Comments

**2026-10-19, built and reviewed.** Built by a helper (Sonnet high) in its own worktree, reviewed on two axes (standards: Sonnet high; spec: Opus high), one fix round (the same helper), checked (Opus high).

- **How it works.** The host's client has one flag, `startHost`. The `verify` tool keeps `true`; a terminal run calls `hostCodeAnalysis(startHost: false)` (moved into its own file, `host_code_analysis.dart`). With `false` the client looks at the address file and uses a host only if it welcomes the run with the same Appstein version; otherwise the run uses its own analysis server and stops it, as in 1d.2. It never starts a host, never asks one to stop and never deletes an address file, on any path, the retry through the address file included, so a CI run leaves nothing behind.
- **Decided by Claude, from the spec's "uses a host that answers", not asked of the owner:** until a host has answered anything in the run, a host the run can't use counts as no host. An address file that fails the trust check, a live host that doesn't take the connection within 5 s, or one that never sends its welcome: the run uses its own server and prints the reason as a notice, so a planted or stuck host stays visible in CI logs. A host that refuses the connection or has ended: the run uses its own server quietly (the terminal never deletes the stale file, so a notice would repeat on every run). A host that ends or is replaced before it answered anything: the run switches to its own server, with a notice. Once a host has answered, a host that fails is exit 3 with the reason, and the run never switches servers. A same-version host that welcomes the run and then drops every question has stopped answering: exit 3, as the box says (confirmed by the owner on 2026-10-19).
- **Review round 1 fixed:** an untrusted address file made every terminal run exit 3 (a run that worked in 1d.2); a host replaced before any answer gave a false exit 3 (the line moved from "connected" to "answered"); stale doc comments that still described a terminal run starting its own server directly; `hostCodeAnalysis` moved out of the MCP command's file, the one-line `terminalCodeAnalysis` removed, one shared helper for the console-host filter, names.
- **Known limits:** with `--apply` and no check that takes a reading, the notice about an unusable host is lost (nothing switches after an effect). Hook runs take this terminal route until ticket 09 moves them; a host that never sends its welcome can cost a hook run up to 10 s, carried to tickets 09 and 10.
- **Not verified:** the untrusted-folder test is skipped on Windows, where the trust check doesn't exist (it checks permission modes), so CI is its first run. The fallback path it takes was run on Windows through a host that doesn't take the connection, one that never welcomes and one replaced before answering, and the untrusted case was confirmed by reading. **CI must run and pass the untrusted-folder test on Linux and macOS before the slice closes; if it fails, this ticket reopens.** Also not verified: Linux, macOS and the compiled binary.
- **Full gate in the slice branch:** `tool/test_all.dart` passed: protocol 84, engine 1965 twice (11 skipped, the untrusted-folder test among them on Windows), CLI 226, lints 19, repo tools 378 (1 skipped); format, analyze, gen_docs and the guide check clean.
