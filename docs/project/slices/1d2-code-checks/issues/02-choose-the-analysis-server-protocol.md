# Choose the analysis server's protocol

**What to build:** a measured choice of the protocol Appstein uses to talk to the Dart analysis server, made before any product code depends on it. The interview's measurement favoured LSP (7.6 s and 0.56 GB to become ready with the `appstein_lints` plugin on) over the legacy analyzer protocol (20.5 s and 1.35 GB), but only the legacy protocol gave pending fixes per file and code with a count. Nobody knows yet why the legacy start was so heavy, or whether one protocol can answer everything.

This ticket writes no product code. Its results are a measurement script kept in the repo, numbers, and a recorded choice.

**Blocked by:** None (can start immediately).

Status: resolved

- [x] A measurement script in the repo's tooling starts the analysis server of the pinned SDK on the 200-file app, in each protocol, with and without the plugin, and prints the time to become ready and the memory used. It can be run again by anyone with one command, which the developer guide names.
- [x] The cause of the legacy protocol's heavy start with the plugin is found, or the ticket states plainly that it wasn't and what was tried.
- [x] For each protocol it is established, by running it, whether it can answer the four questions of the code analysis: the project's diagnostics after an edit (plugin rules included), whether one diagnostic can be fixed automatically, the pending fixes per file and code with their counts, and whether a file's formatting would change. Where a protocol can't, the ticket says what is missing.
- [x] How a complete list of pending fixes is obtained is established: how many passes it needs, and that its totals equal what `dart fix --dry-run` prints for the same project.
- [x] How the server is told to stop, and that no process is left behind when its parent is killed, is checked on Windows.
- [x] The choice (one protocol, or a named split) is recorded in decision record 0001 with the numbers behind it, and the measurement table in the slice's spec is corrected where the new numbers differ.
- [x] A fixed limit for "the server did not become ready" is proposed from the measured start-up times and written into the spec.
- [x] If the result contradicts the spec (for example, no protocol can answer a question the spec relies on), work stops and the owner is asked.

## Comments

**Results, 2026-10-12** (Windows development machine, `fvm dart run tool/measure_analysis_server.dart`, the plugin on, median of three unless it says otherwise). The command is described in `docs/guide/ci.md`. The numbers are from one run of the tool after an independent review; where an earlier run differed, both are given.

**Two boxes are open on purpose.** No question is unanswerable, but no single protocol does everything by itself, so no choice is recorded. Decision record 0001 sets two options side by side under "The protocol", for the owner: LSP with `dart fix --dry-run` as its own process, or the legacy protocol for everything behind a guard process. The spec's table is corrected.

**The heavy legacy start.** Found, and it is not the protocol. With the plugin, both protocols need the same time and memory: LSP 18.3 s and 1.44 GB, legacy 18.8 s and 1.49 GB. Without it: 7.5 s and 0.63 GB, 7.2 s and 0.63 GB. The plugin runs inside the server's process and analyzes every file again with a memory-only store (`analysis_server_plugin`'s `plugin_server.dart`: `MemoryCachingByteStore(NullByteStore(), …)`, and `_analyzeAllFilesInContextCollection` adds every Dart file). The legacy protocol's status covers that work. LSP's `$/analyzerStatus` doesn't: it said "done" at 8.0 s, and the plugin's diagnostic for a file in the last folder arrived at 18.3 s. The interview's 7.6 s and 0.56 GB were taken at that early "done". The guess that the legacy script asked for more was wrong.

**The four questions.** "Guard" is the legacy protocol behind a compiled guard process: the tool's own `--guard` mode, which passes stdin and stdout through and ends the server when its own stdin closes.

| Question | LSP | Legacy | Legacy behind a guard |
|---|---|---|---|
| Diagnostics after an edit on disk: the file and its importer | Yes, 97 ms in one run and 472 ms in the next. Pushed as `textDocument/publishDiagnostics`; there is no request to pull them | Yes, 80 ms (58 ms in the earlier run). Pushed as `analysis.errors` | Yes, 54 ms |
| The same for a plugin rule (median of 10 edits) | Yes, 67 ms | Yes, 29 ms | Yes, 30 ms |
| Can one diagnostic be fixed automatically | Yes. `textDocument/codeAction` for the diagnostic gives `quickfix.dataDriven` (264 ms); for a deprecated use with no migration it names no fix but `ignore` ones (13 ms) | Yes. `edit.getFixes` at the offset gives `dart.fix.dataDriven` (262 ms); no fix for the other (24 ms) | The same (250 ms, 21 ms) |
| Pending fixes per file and code, with counts | **No.** `dart.edit.fixAllInWorkspace.preview` gives 10 edits with line ranges, no codes and no counts, and is one pass (146 ms). It needs the client to declare change annotations | Yes. `edit.bulkFixes`, in passes (18.5 s) | Yes (17.2 s) |
| Would a file's formatting change | Yes. `textDocument/formatting`, 1 ms, an empty list means no | Yes. `edit.format`, 15 ms, an empty list means no | Yes, 15 ms |

None wrote a project file. One file's list held the analyzer's and the plugin's diagnostics together in all three. Legacy `analysis.getErrors` leaves the plugin's diagnostics out; they come only in the notifications. Legacy `lsp.handle` carried an LSP formatting request.

**Knowing when the server is done.**

- At a start, the legacy protocol's `server.status` said "done" when the plugin's last diagnostic had arrived (the two medians are equal). LSP said "done" about 10 s before.
- After an edit, the server said "done" after the plugin's diagnostic and sent no diagnostics later in 10 of 10 edits, in each of the three arrangements. The measurement couldn't make the plugin slow after an edit, so for LSP this is only what was seen.
- Found in the review: LSP publishes nothing for a file with no diagnostics, so one can't tell whether a file has been through the plugin. The plugin does tell the server when it has finished (`plugin.status`); LSP doesn't pass that on.

**A complete list of pending fixes.** Over the legacy protocol: `edit.bulkFixes`, apply the edits to an overlay (`analysis.updateContent`), ask again, until a pass returns no edits. The app needed 3 passes with edits and one that found none (one pass alone found 6 of the 8). The totals equalled `dart fix --dry-run`: `unused_import` 1 in `lib/data/canary.dart`, `deprecated_member_use` 6 and `unused_import` 1 in `lib/ui/legacy/legacy.dart`. LSP's one preview gave the same text as the legacy protocol's first pass. A cold `dart fix --dry-run` took 29.3 s (one run; 21.0 s in the earlier run). It starts a server of its own, and its processes held at most 0.75 GB, looked at about once a second.

**Memory.** At rest: LSP 1.44 GB, legacy 1.49 GB, legacy behind the compiled guard 1.52 GB, of which the guard is 22 MB. The guard run by `dart` instead held 219 MB, and the start took the same time (19.1 s against 18.6 s). While the pending fixes were asked, the legacy server held at most 1.67 GB, with or without the guard. With LSP, the server and `dart fix --dry-run` together come to about 2.2 GB.

**Stopping** (each kill three times).

| | LSP | Legacy | Legacy behind a guard |
|---|---|---|---|
| Asked to stop | `shutdown`, then `exit`: exit code 0 in 84 ms | `server.shutdown`: exit code 0 in 113 ms | exit code 0 in 131 ms |
| Its stdin is closed | exit code 0 in 81 ms | still running after 15 s (and after 90 s in a second check, with and without the plugin) | the guard ended in 6 ms and the server was gone within 0.3 s more |
| Its parent process is killed | gone within 0.3 s, three times | still running after 30 s with nothing to do; then gone within 0.6 to 0.8 s of the next edit of a project file | the guard and the server gone within 0.6 to 0.7 s |
| Only the guard is killed | | | the server still running after 20 s with nothing to do; then gone within 0.3 s of the next edit of a project file |

The tool kills the parent for real: it starts itself again as a process that holds a ready server, ends that process, and looks for the processes' IDs. A check takes about 0.2 s, so "within" is an upper bound. An LSP server ends because its stdin closes; the review showed it does so without being told its parent's process ID.

**The limit proposed:** 180 s. Starts measured on this machine, over five runs of the tool: 7 to 10 s without the plugin, 18 to 22 s with it, 54 to 66 s for a first start that builds the plugin, and 71 s once for a first start without the plugin, which did not happen again and was not explained. No other machine was measured.

**The owner's decisions, 2026-10-12**, recorded in decision record 0001 and in the slice's spec:

- **The legacy analyzer protocol for everything, behind a guard.** The deciding fact: over LSP verify could say "no problems" while the plugin's rules were still running, and nothing would tell it. The guard is the `appstein` binary in a mode of its own.
- **2.3 GB per session is not accepted as the final cost.** In this slice the server starts when a check first needs it and stops when idle. Slice 1d.7 makes it one per project, shared by every session. Slice 1d.3 takes the plugin out of it.
- **The Dart tools' usage reporting is left as the developer set it.** Appstein does not pass `--suppress-analytics`.
- **The limit is 180 s.**

The product design's §9.1, §15 and §22 were corrected with the owner's approval in the same commit.
