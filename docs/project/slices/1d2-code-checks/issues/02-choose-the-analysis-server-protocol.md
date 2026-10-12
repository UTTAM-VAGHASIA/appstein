# 02: Choose the analysis server's protocol

**What to build:** a measured choice of the protocol Appstein uses to talk to the Dart analysis server, made before any product code depends on it. The interview's measurement favoured LSP (7.6 s and 0.56 GB to become ready with the `appstein_lints` plugin on) over the legacy analyzer protocol (20.5 s and 1.35 GB), but only the legacy protocol gave pending fixes per file and code with a count. Nobody knows yet why the legacy start was so heavy, or whether one protocol can answer everything.

This ticket writes no product code. Its results are a measurement script kept in the repo, numbers, and a recorded choice.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] A measurement script in the repo's tooling starts the analysis server of the pinned SDK on the 200-file app, in each protocol, with and without the plugin, and prints the time to become ready and the memory used. It can be run again by anyone with one command, which the developer guide names.
- [ ] The cause of the legacy protocol's heavy start with the plugin is found, or the ticket states plainly that it wasn't and what was tried.
- [ ] For each protocol it is established, by running it, whether it can answer the four questions of the code analysis: the project's diagnostics after an edit (plugin rules included), whether one diagnostic can be fixed automatically, the pending fixes per file and code with their counts, and whether a file's formatting would change. Where a protocol can't, the ticket says what is missing.
- [ ] How a complete list of pending fixes is obtained is established: how many passes it needs, and that its totals equal what `dart fix --dry-run` prints for the same project.
- [ ] How the server is told to stop, and that no process is left behind when its parent is killed, is checked on Windows.
- [ ] The choice (one protocol, or a named split) is recorded in decision record 0001 with the numbers behind it, and the measurement table in the slice's spec is corrected where the new numbers differ.
- [ ] A fixed limit for "the server did not become ready" is proposed from the measured start-up times and written into the spec.
- [ ] If the result contradicts the spec (for example, no protocol can answer a question the spec relies on), work stops and the owner is asked.
