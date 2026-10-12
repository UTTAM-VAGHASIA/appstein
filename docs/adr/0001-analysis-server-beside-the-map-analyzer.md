---
status: accepted
---

# Verify asks a Dart analysis server, kept beside the map's analyzer

The code checks of `appstein verify` (errors, deprecated use, lints, pending fixes, formatting) get their answers from a Dart analysis server that `appstein mcp` starts as a child process and keeps running, although the engine already holds an in-process analyzer for the project map. A cold `dart analyze` on one file took 13.2 s on the 200-file app, against the 5 s limit for a fast run (design §9.1, §15); the running server answered about 0.1 s after an edit. A plain `appstein verify` starts its own server, uses it and stops it, so both routes run the same code.

Decided by the owner on 2026-10-12, during the design interview for slice 1d.2.

## Considered options

- **The in-process analyzer for verify too.** It answered in about 0.03 s and can name the files an edit affects, but it reported no `flutter_lints` lints, no `appstein_lints` plugin rules and no fixes, so verify would disagree with `dart analyze` and with the developer's IDE.
- **The analysis server for the map too.** The map needs the resolved code of every file, which the server's protocols don't hand out.
- **Cold `dart analyze`, `dart fix` and `dart format` on every run.** 8 to 23 s each on the 200-file app.

## Consequences

- Two analyzers hold the same project in memory: about 0.8 GB in process for the map and 0.56 GB for the server on the 200-file app (Windows development machine, 2026-10-12). Worth measuring again on a larger app.
- The server takes 6 to 20 s to become ready, so the first verify after `appstein mcp` starts waits for it.
- The server re-reports the whole project after an edit and can't say which files it analyzed again. A fast run therefore reports errors wherever they are, not "the changed files and their dependents".
- A complete fix dry-run took 7.5 s on the running server, so the pending-fix check belongs to the full run.
