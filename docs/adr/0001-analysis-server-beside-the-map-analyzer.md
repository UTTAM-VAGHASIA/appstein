---
status: accepted
---

# Verify asks a Dart analysis server, kept beside the map's analyzer

The code checks of `appstein verify` (errors, deprecated use, lints, pending fixes, formatting) get their answers from a Dart analysis server that `appstein mcp` starts as a child process when a check first needs it and keeps running, although the engine already holds an in-process analyzer for the project map. A cold `dart analyze` on one file took 13.2 s on the 200-file app, against the 5 s limit for a fast run (design §9.1, §15); the running server answered about 0.1 s after an edit. A plain `appstein verify` starts its own server, uses it and stops it, so both routes run the same code.

Decided by the owner on 2026-10-12, during the design interview for slice 1d.2.

## Considered options

- **The in-process analyzer for verify too.** It answered in about 0.03 s and can name the files an edit affects, but it reported no `flutter_lints` lints, no `appstein_lints` plugin rules and no fixes, so verify would disagree with `dart analyze` and with the developer's IDE.
- **The analysis server for the map too.** The map needs the resolved code of every file, which the server's protocols don't hand out.
- **Cold `dart analyze`, `dart fix` and `dart format` on every run.** 8 to 23 s each on the 200-file app.

## The protocol: the legacy protocol, behind a guard

**Decided by the owner on 2026-10-12: option B.** Appstein speaks the legacy analyzer protocol to the server for everything, and starts the server behind a guard process. The reason is the row "The server says its first analysis is done" below: over LSP, verify could report "no problems" while the plugin's rules were still running, and nothing would tell it. A verifier that says "all clear" too early is the worst fault it can have. The guard is the `appstein` binary itself, started in a mode of its own, so no second program is installed.

The server speaks two protocols: LSP, and the legacy analyzer protocol that `dart analyze` and `dart fix` use. Ticket 02 of slice 1d.2 measured both and found that neither does everything by itself. It left two options.

- **Option A: LSP, with `dart fix --dry-run` as its own process.** The kept server is spoken to over LSP. A full run gets the pending fixes by running `dart fix --dry-run`.
- **Option B: the legacy protocol for everything, behind a guard process.** The guard is a small process of Appstein's own, in pure Dart. It starts the server, passes stdin and stdout through, and ends the server when its own stdin closes.

Measured with `tool/measure_analysis_server.dart` on the 200-file app with the `appstein_lints` plugin on (Windows development machine, 2026-10-12, median of three unless it says otherwise):

| | A: LSP and `dart fix --dry-run` | B: legacy behind a guard |
|---|---|---|
| Diagnostics after an edit, plugin rules included | yes | yes |
| Can this diagnostic be fixed automatically | yes (`quickfix.dataDriven`) | yes (`dart.fix.dataDriven`) |
| Pending fixes per file and code, with counts | not from the server; from `dart fix --dry-run`, whose text is read | yes, from the server, in passes |
| Would this file's formatting change | yes | yes |
| What it lacks | a sign that the plugin has finished (below); pending fixes from the server | nothing asked for; `analysis.getErrors` leaves the plugin's diagnostics out, so they must be taken from the notifications |
| Start until ready | 18.3 s | 18.6 s |
| The server says its first analysis is done | at 8.0 s, about 10 s before the plugin has finished | at 18.6 s, when the plugin has finished |
| An edit on disk until the file's and its importer's diagnostics arrive | 97 ms in one run of the tool, 472 ms in the next | 54 ms (80 ms without the guard) |
| An edit on disk until the plugin's diagnostic arrives (median of 10) | 67 ms | 30 ms (29 ms without the guard) |
| Would formatting change, one file | 1 ms | 15 ms |
| Memory at rest | 1.44 GB | 1.52 GB, of which the guard is 22 MB |
| Pending fixes in a full run | 29.3 s (21.0 s in an earlier run); `dart fix` starts a second server, whose processes held at most 0.75 GB | 17.2 s on the kept server, in 3 passes with edits and one that finds none |
| Most memory during a full run's fix check | about 2.2 GB (1.44 GB and 0.75 GB) | 1.67 GB |
| `appstein mcp` ends normally and asks the server to stop | ends in 0.1 s | ends in 0.1 s |
| `appstein mcp` is killed | the server is gone within 0.3 s (3 of 3) | the guard and the server are gone within 0.6 to 0.7 s (3 of 3) |
| Only the guard is killed | no guard | the server stays while it has nothing to do (20 s watched), and was gone within 0.3 s of the next edit of a project file (3 of 3) |

"Ready" is the moment every diagnostic of the first analysis has arrived, the plugin's included. Memory is the working set of the server's process tree. The map's analyzer holds about 0.8 GB more in either option.

What the measurement found:

- **The two protocols start equally.** The interview's measurement had LSP ready in 7.6 s with 0.56 GB and the legacy protocol in 20.5 s with 1.35 GB. That was the same work measured at two moments. The plugin runs inside the server's process and analyzes every file a second time, with no cache on disk (`analysis_server_plugin` gives it a memory-only store). That takes about 11 s and 0.8 GB more in either protocol: without the plugin both were ready in 7.2 to 7.5 s with 0.63 GB. The legacy protocol says "done" when the plugin has finished. LSP says "done" when the server's own analysis has finished, and the earlier measurement stopped there.
- **Over LSP nothing says the plugin has finished.** The plugin tells the server (`plugin.status`), and the legacy protocol's `server.status` reflects it, but LSP doesn't pass it on. LSP also publishes nothing for a file that has no diagnostics, so one can't tell from the diagnostics whether a file has been through the plugin. A verify in the seconds after a start can therefore miss a plugin diagnostic without knowing it.
- **After an edit** the server said "done" after the plugin's diagnostic, and sent no diagnostics later, in 10 of 10 edits in each arrangement. For the legacy protocol the start shows the same order with the plugin 10 s behind. For LSP the order after an edit is only what was seen: the start shows it isn't promised. The measurement couldn't make the plugin slow after an edit.
- **A legacy server without a guard outlives its parent, but not for ever.** It ignores its stdin closing, and when its parent was killed it was still running 30 s later with nothing to do. It was gone within 0.6 to 0.8 s of the next edit of a project file (3 of 3). Until such an edit it holds its 1.5 GB.
- **An LSP server ends when its stdin closes** (within 0.1 s), which is what a killed parent causes. It doesn't need to be told its parent's process ID.
- **The guard costs little when compiled:** 22 MB, and no time that could be measured at the start or after an edit. Run by `dart` instead it held 219 MB. Appstein's hooks and commands are a compiled binary already.
- **`dart fix --dry-run` and the legacy passes agree.** The passes apply each pass's edits to an overlay, not to disk, and ask again until a pass finds nothing. Their totals equalled what `dart fix --dry-run` printed: 8 fixes in 2 files. One LSP preview gave the text of the first pass only.
- **Not measured:** Linux, macOS, CI machines, a 1,000-file app, and a server stopped while it builds the plugin (the build runs as child processes).

## Memory: what was measured is not accepted as it is

With the plugin, one `appstein mcp` would hold about 2.3 GB for the 200-file app: 0.8 GB for the map's analyzer, 0.6 GB for the analysis server and 0.8 GB for the plugin's second analysis inside it. Appstein is meant to run beside several agent sessions at once (design §18, M4), so a cost per session is multiplied. The owner decided this direction on 2026-10-12; none of its three steps was measured when it was decided:

1. **Slice 1d.2:** the server is started by the first check that needs it, not when `appstein mcp` starts, and is stopped when it has not been asked anything for a while. A session that never verifies holds no server.
2. **Slice 1d.7:** one server per project, shared by every session that works on it, reached the way the hook reaches the running process. Decided in decision record 0002: an analysis host per project, reached over a local socket.
3. **Slice 1d.3:** Appstein's lint rules run on the analyzer the map already has, and the plugin stays out of the server verify uses. That removes the second analysis: about 0.8 GB and 11 s of the start.

## Consequences

- Two analyzers hold the same project in memory: about 0.8 GB in process for the map, and for the server 0.63 GB without the `appstein_lints` plugin or about 1.5 GB with it, on the 200-file app (Windows development machine, 2026-10-12). Worth measuring again on a larger app.
- The server takes 7 to 8 s to become ready without the plugin and 18 to 20 s with it, so the first verify after `appstein mcp` starts waits for it. The first start of a project with the plugin builds the plugin and took 54 to 66 s.
- The server re-reports the whole project after an edit and can't say which files it analyzed again. A fast run therefore reports errors wherever they are, not "the changed files and their dependents".
- A complete list of pending fixes took 17 to 19 s on a running legacy server and 21 to 29 s as a cold `dart fix --dry-run`, so the pending-fix check belongs to the full run.
- During the measurement a server tried to send its memory use to Google Analytics (seen in an error it printed when the connection was cut). This is the Dart tools' own reporting, which a developer switches off with `dart --disable-analytics`. The server accepts `--suppress-analytics`, which the measuring tool passes. The owner decided on 2026-10-12 that Appstein does not pass it: the server Appstein starts keeps the developer's own Dart setting, as the server their IDE starts does.
