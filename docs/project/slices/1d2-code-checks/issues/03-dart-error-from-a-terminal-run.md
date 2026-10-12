# 03: `dart.error` from a terminal run

**What to build:** `appstein verify`, run in a terminal, reports the project's analyzer errors. It starts the analysis server of the project's own SDK, waits for the first analysis, reports each error as a `dart.error` finding, and stops the server. This is the first complete path through every layer: the server, the code analysis interface, a check, the output and the exit codes. Later tickets add checks on top of it.

**Blocked by:** 01, 02.

**Status:** ready-for-agent

- [ ] On a fixture app with a compile error, `appstein verify` (fast and full) reports a `dart.error` error with the file, the line, the analyzer's message and the analyzer's code, and exits 1. On the same app without the error it reports nothing for this check and exits 0.
- [ ] An error in a file that depends on the edited one is reported too: breaking a class another file uses gives a `dart.error` in that other file.
- [ ] Diagnostics that aren't errors are not reported by this ticket.
- [ ] The check runs when the knowledge is stale: on a project whose code doesn't resolve, `dart.error` findings appear beside `knowledge.stale`.
- [ ] The analysis server is the one of the project's SDK, started from the SDK's real executable, not a wrapper script.
- [ ] After the run ends, normally or with an error, no analysis server process is left running. Checked on Windows.
- [ ] A server that doesn't start, dies during the run, or isn't ready within the fixed limit makes the run exit 3 with the reason and "run `appstein doctor`". It is never reported as "no errors", and never as a finding.
- [ ] The checks reach the server only through the code analysis interface, and a scripted stand-in for it exists for tests. The stand-in's tests cover the level-to-severity mapping and the server that fails.
- [ ] `dart.error` is a known check ID: a suppression in `appstein.yaml` and a `verify.severity` override both work on it.
- [ ] Paths with spaces work, and the file a finding names is relative to the project root with `/` separators on every system.
- [ ] `///` comments on every new public API; the guide pages for the new component and the changed files are written or updated; the guide check passes.
