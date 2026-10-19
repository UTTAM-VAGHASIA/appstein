# Slice 1d.7: hook mode and fast verify in 5 s

Status: ready-for-agent (approved by the owner, 2026-10-17)

Implements parts of the product design (`docs/project/specs/2026-09-29-appstein-design.md`): §5.3, §5.4, §8, §9, §9.1, §9.2, §9.5, §11.1 and §15. Decision records: `docs/adr/0001-analysis-server-beside-the-map-analyzer.md` and `docs/adr/0002-one-analysis-host-per-project.md`. Words in **bold** on first use are defined in `GLOSSARY.md`.

Agreed with the owner in the design interview of 2026-10-17 (22 questions in four rounds, all answered "yes").

## Problem Statement

Slice 1d.2 gave `appstein verify` its code checks, and the `verify` tool of a running `appstein mcp` answers a **fast run** in 0.9 to 1.7 s. But an agent hears from Appstein only when it remembers to call that tool. The design's promise is that every change is checked by itself, through the agent's hooks, and that "done" is blocked while errors remain (§5.4). None of that exists: `verify` has no hook mode, no exit code 2, no loop guard, and a hook process has no way to reach a warm analysis server, so it would wait 9 to 16 s for a cold one, against the 5 s target.

Memory is the second problem. Each `appstein mcp` keeps its own analysis server (0.6 GB, about 1.5 GB with the plugin), so three agent sessions on one project hold three of them, which the owner did not accept (decision record 0001, "Memory"). And when an `appstein mcp` is killed, its server's half-written cache files stay on the machine.

## Solution

Each project gets one **analysis host**: a small background process, the `appstein` binary in a hidden mode, that owns the project's analysis server and answers the code questions of every session, hook and tool that works on the project, over a local socket (decision record 0002). The first thing that needs it starts it; it ends itself after 10 minutes with no questions. The guard in front of the server now cleans up after the server itself, so nothing is left behind when a parent is killed.

`appstein verify` gains `--hook claude`. After every edit, Claude Code's PostToolUse hook runs `appstein verify --fast --hook claude`: errors block with exit code 2 and are shown to the agent, warnings reach it without blocking, and an edit that changed nothing Appstein reads costs one hash scan and says nothing. When the agent says it is done, the Stop hook runs `appstein verify --full --apply --hook claude`, which fixes, formats and renders the human docs, then blocks "done" while errors remain, until the loop guard lets the agent go after the same errors blocked three times. When Appstein itself fails, both the developer and the agent are told, and the agent is never blocked by it.

`verify.fast_timeout_seconds` becomes a real cap on every fast run. The 5 s target is proven in CI on Linux, macOS and Windows, timed from the start of the hook's process to its end, against a ready analysis host.

## User Stories

**Checked after every change**

1. As an agent, I want my code checked after every edit without asking, so that I learn about an error before I build on it.
2. As an agent, I want the check after an edit to answer within 5 s, so that checking every change doesn't slow my work.
3. As an agent, I want errors shown to me with file, line, message, fix hint and knowledge reference, so that I can fix them without searching.
4. As an agent, I want an error to block me after the edit that caused it, so that I deal with it before I go on.
5. As an agent, I want warnings shown to me without blocking, so that I can tidy them where I am working without being stopped.
6. As an agent, I want info-level findings left out of the hook's output, so that my context isn't filled after every edit.
7. As an agent, I want a long list of errors cut at 30 with how many more there are and how to see them all, so that one broken file doesn't flood my context.
8. As an agent, I want a command that changed nothing (`ls`, `git status`) to give no output, so that I'm not shown the same errors after every harmless command.
9. As an agent, I want an edit to a file Appstein doesn't read, such as a README, to give no output, so that unrelated work isn't interrupted.
10. As an agent, I want "nothing changed" judged against my own session's last check, so that another session's work on the same project never makes me miss my own edit's errors.
11. As an agent, I want my edit's code checks named as pending when the analysis server is still starting, so that I don't take silence for "no errors".
12. As an agent, I want a fast run never to take longer than the project's cap, so that a slow start can't freeze my work.

**Done means done**

13. As an agent, I want "done" blocked while the project has errors, so that I never finish with code that doesn't build, uses a deprecated API or fails a test.
14. As an agent finishing a task, I want the project fixed, formatted and its human docs rendered before the last check, in one step, so that nothing fixable or stale is reported.
15. As a developer, I want the Stop hook to be one command, so that no two hooks race over the same files.
16. As a developer, I want the agent let go after the same errors blocked "done" three times, so that it doesn't burn tokens on errors it can't fix.
17. As a developer, I want the errors that remain when the agent is let go shown to me, so that I know what is left to fix.
18. As a developer, I want an error moved by an edit above it to count as the same error, so that the loop guard isn't fooled by line numbers.
19. As a developer, I want the loop guard counted per agent session, so that two sessions on one project don't share a count.
20. As a developer, I want warnings left at "done" shown to me without keeping the agent going, so that the task can end and I still see them.

**When Appstein can't check**

21. As an agent, I want to be told when Appstein could not check my edit and why, so that I don't believe unchecked code is clean.
22. As a developer, I want to be told when Appstein failed in a hook, with "run `appstein doctor`", so that I can repair my environment.
23. As an agent, I want Appstein's own failure never to block me, so that a broken tool can't stop my work.
24. As a developer, I want `--hook codex` refused with a clear message until Codex's hooks are checked, so that nobody relies on a guess.

**One analysis server per project**

25. As a developer running several agent sessions on one project, I want them to share one analysis server, so that memory doesn't grow with every session.
26. As a developer, I want the shared server to keep running when the session that started it ends, so that the other sessions keep their warm analysis.
27. As a developer, I want the analysis host to end by itself after 10 minutes with no questions, so that an idle project holds no memory.
28. As a developer, I want a host from an older Appstein replaced after I upgrade, so that I never get answers from code I replaced.
29. As a developer, I want the host to start again by itself after a crash, so that a dead host never blocks the next check.
30. As a developer, I want the host to answer only programs that can read my own user's files, so that nobody else on the machine can ask about my code.31. As a developer with a long project path, spaces included, I want the host to work, so that where my project lives doesn't matter.
32. As a developer, I want a terminal `appstein verify` to use a running host when there is one, so that I get warm answers too.
33. As a CI maintainer, I want a terminal `appstein verify` never to start a host, so that a CI run leaves no process behind.
34. As an agent, I want my session's `verify` tool calls answered by the same host the hooks use, so that the tool and the hooks never disagree.
35. As an agent, I want my question answered after another session's full run, not mixed into it, so that I never see that run's temporary edits.

**Nothing left behind**

36. As a developer, I want no half-written cache files left when an `appstein mcp`, a host or a terminal run is killed, so that my machine's Dart cache doesn't fill with them.
37. As a developer, I want the analysis server ended when its host ends in any way, so that no server outlives the process that owns it.

**Proof**

38. As the owner, I want the hook's time measured on every change on Linux, macOS and Windows, from its process start to its exit, so that the 5 s promise is proven where an agent meets it.
39. As the owner, I want the hook's time with no host running recorded, so that I know what the first edit after an idle stop costs.
40. As the owner, I want a test that two sessions and a hook leave exactly one analysis server, with the memory of two sessions recorded beside one, so that the sharing is proven.

## Implementation Decisions

**The hooks (§5.4, §11.1)**

- The PostToolUse hook is one command, `appstein verify --fast --hook claude`. `verify` already brings the knowledge up to date as its first step, so the design's separate `appstein sync --detect` before it goes: it did the same work twice inside the 5 s.
- The Stop hook is one command, `appstein verify --full --apply --hook claude`. Claude Code runs the hooks that match an event side by side, and hooks are never shell scripts (§11.1), so the steps at "done" can't be two hooks.
- `integrate`, which writes these hooks into `.claude/settings.json`, stays in slice 1e. This slice builds everything the hooks call.

**`--hook claude` (§5.3, §9.5)**

- `verify` gains `--hook claude`. `--hook codex` is a usage error (exit 3) that says Codex's hooks are checked in slice 1e. `--hook` with `--format` is a usage error: hook mode has its own output.
- In hook mode `verify` reads the hook's input from stdin, Claude Code's JSON: the session's ID and, at Stop, whether the agent is already continuing because of a Stop hook. Input that is missing or can't be read counts as no session: the run still checks, and the loop guard and "nothing changed" have no record to use.
- A fast run answers as a PostToolUse hook, a full run as a Stop hook.
- **What reaches whom** (Claude Code: exit 2 feeds stderr to the agent; any other non-zero code shows only the first line of stderr to the developer; exit 0 with JSON on stdout can pass context to the agent and a message to the developer):

| The run found | After an edit (fast run) | At "done" (full run) |
|---|---|---|
| Errors | exit 2; stderr lists the errors, and the checks that did not run, as the text output does, grouped by file with fix hint and knowledge reference | exit 2, the same |
| More than 30 errors | the first 30, then "…and N more: call the `verify` tool for all" | the same |
| Warnings and no error | exit 0; JSON context for the agent listing the warnings | exit 0; a JSON message for the developer listing them (context for the agent at Stop would keep it going) |
| Only info findings, or nothing | exit 0, no output | exit 0, no output |
| Code checks named as not run because the host was still starting | exit 0 (or 2 with errors found); JSON context telling the agent its edit's code checks are pending | does not happen: a full run waits for the host |
| Appstein failed (what is exit 3 in the terminal) | exit 0; JSON context telling the agent that verify could not run, why, and that its edit is unchecked; a JSON message telling the developer the same with "run `appstein doctor`" | exit 0; the developer's message only, so a broken tool never keeps the agent going |
| The loop guard lets the agent go | — | exit 0; a JSON message for the developer listing the remaining errors |

- §9.5 is reworded: exit 3 is the terminal's code for Appstein failing; in hook mode the same failure is told to both the agent and the developer, and never blocks.

**Nothing changed means no output**

- A fast hook run stays silent, with exit 0 and no checks, when nothing Appstein reads has changed since this session's last hook run. The hook keeps, per session, a fingerprint of the input hashes it last saw; one hash scan decides.
- The comparison is per session, not against the shared state: another session's `appstein mcp` refreshes the same knowledge, and could otherwise use up the change this session's hook needs to see.
- A session's first hook run always checks. Errors already reported stay for the Stop hook, and in the unverified files.

**The loop guard (§5.4)**

- "The same errors" is the same set of (check ID, file, message). Lines are left out: an edit above an error moves it without fixing it.
- The count is kept per session ID, beside the "nothing changed" fingerprint, in a git-ignored record under `.appstein/` like `state.json`. Records not touched for a day are deleted.
- The count starts again when the set of errors changes, or when the Stop input says the agent is not already continuing because of a Stop hook.
- The same errors block three times in a row; on the fourth Stop with the same errors the guard lets the agent stop (exit 0) and gives the developer the remaining errors (the owner, 2026-10-19). Claude Code's own cap, eight continuations in a row, is never reached.

**`--apply` renders the human docs (§5.3, §9.2)**

- `--apply` now means: apply `dart fix`, format the project, bring the knowledge up to date, render the human docs into `docs/app/` when `docs.enabled` is on, then run every check. Rendering is a safe write at "done", like fixing and formatting.
- The files rendered are named with the files rewritten, in the `applied` list and the text output.
- Without `--apply` nothing changes: `verify` writes no project file.

**The analysis host (decision record 0002)**

- A new hidden mode of the `appstein` binary, like the guard's. One host per project. It owns the guard and the analysis server, as `appstein mcp` did in 1d.2: the server is the project SDK's, started behind the guard, with the same restarts after a change to the analysis options, the package config or `pubspec.yaml`, the same start limit of 180 s and the same plugin and readiness rules.
- **The connection.** Loopback TCP on all three systems: the host listens on `127.0.0.1` only, on a port the system picks. It writes an **address file** (the port, a random secret, its process ID and its Appstein version) in a folder of the user's, outside the project: `%LOCALAPPDATA%\appstein\` on Windows, `$XDG_RUNTIME_DIR` or the temporary folder on Linux and macOS, readable by the user only. The file is named by a hash of the project root's full path and written whole or not at all. A client reads it and sends the secret first; the host closes a connection that doesn't, since every local program can reach a loopback port. Changed by the owner on 2026-10-17 from a Unix domain socket, which crashed Windows itself in its own driver on the owner's machine (decision record 0002). Whether Windows' firewall asks anything for a listener on `127.0.0.1` is checked on a real Windows machine first.
- **What crosses the connection** is Appstein's own small protocol, defined in `appstein_protocol`, carrying the questions of the **code analysis** interface 1d.2 built (diagnostics, can this be fixed, pending fixes, would formatting change, apply fixes and formatting) and their answers. The checks don't change: a client of the host is one more implementation of that interface.
- **Who starts it.** A fast hook run, a full hook run and the `verify` tool of `appstein mcp` start a host when none answers, as a detached process, and then wait for it. A terminal `appstein verify` (a person, CI) uses a host that answers but never starts one: without one it starts its own analysis server and stops it, as in 1d.2.
- **When it ends.** After 10 minutes with no questions, as 1d.2's idle stop. It ends its server through the guard, so a killed host takes its server with it.
- **One question at a time.** The host answers questions in the order they arrive, across sessions: a full run's pending-fix passes put edits that are not on disk into the server for 17 to 19 s, and no other client may see them. A fast run that arrives during another session's full run waits, and may reach the cap (accepted by the owner; written in the guide). A question whose client has gone away is dropped.
- **Housekeeping.**
  - A client says its Appstein version when it connects. A host of an older version is asked to stop, and a new one is started. A client older than the host leaves it alone: that run uses its own analysis server, as a terminal run without a host does, and says the session runs an older Appstein and should be restarted for fast answers. Changed by the owner on 2026-10-18 from "a host of another version is asked to stop", under which two sessions of two versions replaced each other's host over and over, each swap starting a server and able to break the other's run.
  - A change of the project's SDK (for example `fvm use`) restarts the host's server, as a change to the analysis options does.
  - Two clients that start a host at once: creating the address file is exclusive, so the one that loses waits for the winner's address and connects to it.
  - An address file whose host refuses the connection or has ended is left by a host that died: it is deleted, and a host is started.
- `--apply`'s fixes and formatting are written by the host's server, as by `appstein mcp`'s in 1d.2, with the same rules: atomic writes, files outside the project or changed since the reading left alone, and the files rewritten named in the result.
- **No command stops a host** in this slice. The idle stop and the guard are enough; the developer guide says how to find and end one by hand. `appstein doctor` listing hosts is left for later.
- **Memory.** Only the analysis server is shared. Each `appstein mcp` keeps its own map analyzer (about 0.8 GB). Moving it into the host too would save that per session, but reworks how the MCP tools keep the knowledge fresh: left for later (decision record 0002).

**The hook runs `verify` itself**

- A hook process runs `verify` in its own process, as a terminal run does: the knowledge refresh, the checks, the state. It asks the analysis host only for the code reading. Expected on the 200-file app: start-up under 0.2 s, the refresh as `sync --detect` after one edit (1.3 to 1.9 s on CI), and the reading through the host (about 0.1 to 0.2 s): 2 to 2.5 s against 5 s.
- The knowledge lock and the unverified files work as in 1d.2: two processes running `verify` at once are kept in order by the lock.

**The cap: `verify.fast_timeout_seconds` (§7, §15)**

- It caps every fast run, whatever started it (hook, tool, terminal), counted from the run's start. Waiting for a host to start counts. The default stays 20 s.
- At the cap, the checks that hadn't finished are named among the checks not run, with the reason (for example "the analysis server is starting"), and the run is partial, so no file leaves the unverified files. The next run asks again.
- A terminal run cut by the cap exits 3, "Appstein could not finish checking", with the pending checks and any errors the other checks found, so CI never reads a cut run as a pass. Checks not run for any other reason keep 1d.1's rule. A hook run keeps its own answer: exit 0, or 2 with errors, and the agent is told its code checks are pending (the owner, 2026-10-20).
- A fast hook run that finds no host starts one and waits for it up to the cap. A start takes 7 to 8 s without the plugin, about 19 s with it, and about a minute the first time a project builds the plugin.
- Full runs have no cap: they wait for the host as long as its start limit allows.

**The guard cleans up after its server**

- The guard deletes its own server's half-written cache files (`-temp-<the server's process ID>`) every time it ends the server: when its input closes because its parent ended in any way, and on a normal stop. The parent no longer does it.
- A guard killed together with its server (for example a whole process tree ended at once on Windows) leaves the files. That stays a known limit.

**Measuring (§15)**

- A new row in `tool/measure_sync.dart`, on Linux, macOS and Windows in CI: on the 200-file app with a ready analysis host, edit one file to add an error, then time the compiled `appstein verify --fast --hook claude` from its process start to its exit, with Claude Code's input on stdin. The median of three must be under 5 s (5.000 s or more fails), and every run must exit 2 and name the error.
- A row for the same hook with no host running (it starts one and waits), recorded with no limit other than the cap.
- A check that two `appstein mcp` processes and a hook on one project leave exactly one analysis server running, failing otherwise, with the memory of two sessions recorded beside that of one.
- The 1d.2 rows stay: the warm `verify` tool (now through the host) and the terminal runs.

## Testing Decisions

A good test here states what an agent, a developer or CI sees: given this project and this hook input, this exit code, this text on stderr, this JSON on stdout, this number of analysis servers running. It doesn't state how the host was asked or what crossed the connection. Each new piece is first written with an empty body, so its tests fail on behaviour, not at compile time (a lesson from 1d.1).

**Seams, highest first** (agreed with the owner, 2026-10-17)

1. **The CLI, in process, with scripted hook input and the scripted code analysis** (the seam of the CLI tests and 1d.2's scripted stand-in). All of hook mode: exit 2 and 0, stderr and JSON for each row of the table above, the cut at 30, the warnings-only context, silence when nothing changed (per session), Appstein's failure as exit 0 with JSON, the loop guard across several Stop calls with one session ID, input that is missing or broken, `--hook codex` and `--hook` with `--format` refused, the cap naming unfinished checks, and `--apply` rendering the docs.
2. **The code analysis interface, backed by a real analysis host.** No new seam: the host's client implements the interface the checks already use. Real processes on a fixture app: the first client starts the host and a second gets the same one (exactly one analysis server); a client of another version replaces it; a stale address file is cleared; a connection without the secret is refused; clients racing to start end with one host; the idle stop; a killed host takes its guard and server with it; one question at a time across clients; a long project path with spaces. The host's own protocol is tested only through this seam, never message by message.
3. **The guard**, as its tests do today: a killed parent leaves no `-temp-<pid>` file of its server.
4. **The MCP server**, as its tool tests do: the `verify` tool answers through the host; a terminal run uses a running host and never starts one.
5. **The compiled binary on the 200-file app**, in the existing measurement tool: the three rows above, and every line of real output read once by hand before the slice is called done.

**Also tested**

- No host, guard or analysis server is left running after a test, on Windows too. Each test gives its hosts their own address-file folder and cache folder, as 1d.2's suites have their own cache folders.
- Paths with spaces and letter case on Windows, for the address file's name and the project root.
- No test, probe or tool in this repo opens a Unix domain socket: on Windows build 26300 one crashed the machine (decision record 0002).

## Out of Scope

- **Slice 1e:** `integrate` writing the hooks into `.claude/settings.json`; `--hook codex` and Codex's blocking mechanism; the SessionStart hook.
- **Slice 1d.3:** the plugin leaving the analysis server, which removes about 0.8 GB and 11 s of each start.
- **Slice 1d.4:** the package gate, including what a fast run does when dependencies changed.
- **Later, not placed:** moving the map's analyzer into the analysis host; `appstein doctor` listing running hosts; a command to stop a host; a trailing `// appstein:ignore` covering the whole statement it ends; the margin on `sync --detect` (carried from 1d.2).
- Projects with several packages (pub workspaces).

## Further Notes

**Carried from 1d.2's notes, and where each lands.** `--hook claude` and exit code 2; the hook's route (now to the analysis host, not to `appstein mcp`); the loop guard; what a hook does with no `appstein mcp` running (the host is started, up to the cap); the `fast_timeout_seconds` cap and the 5 s proof on the hook's route; one analysis server per project (the host); the guard cleaning up after a killed `appstein mcp`. The order of the Stop hook's steps in §5.4 is settled by the one-command Stop hook.

**Decided by Claude while writing this spec, not asked** (the owner may change any of them at approval):

- Input on stdin that is missing or can't be read counts as no session.
- At Stop, warnings and Appstein's own failure go to the developer only, since context for the agent at Stop keeps it going (Claude Code's documented behaviour).
- A full hook run that finds no host starts one and waits for it.
- The per-session records are deleted after a day untouched.
- `--hook` with `--format` is a usage error.
- `--apply`'s writes are made by the host's server, as by `appstein mcp`'s in 1d.2.

**A consequence to watch.** The cap now applies to a terminal fast run too. A terminal fast run starts its own analysis server when no host runs, and with the plugin that start takes about 19 s on the development machine, so such a run can reach the 20 s cap, name its code checks as not run and exit 3 (Appstein could not finish checking; the owner, 2026-10-20). Without the plugin (CI's measurement app) it took 10.8 to 13.6 s cold. Slice 1d.3 takes the plugin out of the server.

**Facts this design rests on** (checked on 2026-10-17):

- Claude Code hooks: exit 2 on PostToolUse shows stderr to the agent after the tool has run; on Stop it keeps the agent going with stderr as the reason. Any other non-zero code shows the developer the first line of stderr and nothing to the agent. Exit 0 with JSON can carry context for the agent (at most 10,000 characters) and a message for the developer. Hooks that match an event run side by side; the default timeout is 600 s; Stop receives whether the agent is already continuing because of a Stop hook, and Claude Code ends the turn after eight such continuations in a row.
- Dart supports Unix domain sockets on Windows since 3.11, but on 2026-10-17 a compiled Dart program that connected to one and closed the connection crashed the owner's Windows (build 26300) twice, in Windows' own driver (`afunix.sys`, bugcheck 0xD1, fault `AfUnixTlConnectEndpointDisconnect`). So the host uses loopback TCP (decision record 0002).
- An analysis server over stdio serves one client and ends when that connection closes; it has no mode for several clients.
- The analysis cache is one folder per user on the machine, shared by every analysis server, with no lock; writes go to a temporary file named with the writer's process ID and are renamed into place.

**Edits this slice makes to the product design.** The owner approved them with this spec, and they are in the same commit, with the visual summary and `progress.yaml`. §5.2's `analysis/` row and §9.3's `applied` list were updated to match too.

- **§5.3:** the `verify` row: `--apply` (full runs only) applies `dart fix` and `dart format` and renders the human docs; `--hook claude` answers as a Claude Code hook (§9.5); `--hook codex` arrives in 1e.
- **§5.4:** the PostToolUse hook runs `appstein verify --fast --hook <agent>` alone; the Stop hook runs `appstein verify --full --apply --hook <agent>`; an edit that changed nothing Appstein reads gives no output; the loop guard counts the same errors ignoring lines, per session.
- **§8:** the `verify` tool's code checks answer from the project's analysis host.
- **§9, "Built in slices":** 1d.7 adds `--hook`, the analysis host shared by every session and hook, the cap, and the 5 s proof on the hook's route.
- **§9.1:** the warm-analysis paragraphs: the analysis host replaces "`appstein mcp` keeps a Dart analysis server" and "the hook contacts the running process over a local socket"; "when `appstein mcp` isn't running" becomes what a hook does with no host (start one, wait up to the cap); the memory step of 1d.7 names the host; "still to prove" is replaced by the measured numbers once ticket work has them.
- **§9.2:** `--apply` also renders the human docs.
- **§9.5:** exit 2 as built; exit 3 in hook mode becomes "told to the agent and the developer, never blocks", with exit 0.
- **§11.1:** the PostToolUse and Stop hook commands as above.
- **§15:** "measured on a running `appstein mcp`" becomes "timed from the start of the hook's process to its end, with the project's analysis host ready"; the cap applies to every fast run.
- **§22, risks 21 and 25:** the hook's route and the one-per-project step, as built.
- **Decision record 0001**, "Memory", step 2: points to decision record 0002.
