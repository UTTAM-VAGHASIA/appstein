# The unverified files, with `dart.warning` and `dart.lint`

**What to build:** Appstein remembers the unverified files: the files changed since a verify run last found no error in them. A fast run reports the analyzer's warnings and lints only on those files, so an agent isn't shown old lints in files it never touched, and an earlier error can't scroll out of view after the next edit. A full run reports them everywhere. An agent or a person can add files with `--files` or the tool's `files` input.

**Blocked by:** 03.

Status: ready-for-agent

- [ ] An analyzer warning is a `dart.warning` warning and an info-level diagnostic is a `dart.lint` info finding, each with the file, the line, the analyzer's message and its code. Plugin diagnostics are reported the same way, by their level.
- [ ] A fast run reports them only on the unverified files; a full run reports them on every file.
- [ ] A file joins the unverified files when the knowledge refresh sees its content changed. This holds for every Dart file the analysis server covers, test files included.
- [ ] A file leaves them when a verify run, fast or full, reports no error on it. An error hidden by a suppression counts as none. A deleted file leaves after one run.
- [ ] The scenario from the interview holds: break file A and run; fix nothing, edit file B correctly and run again. A is still among the unverified files, and its warnings and lints are still reported.
- [ ] The unverified files survive between runs and between processes, in `.appstein/state.json`. A state file written before this ticket is read as having none, without an error.
- [ ] `appstein verify --fast --files <paths>` adds the named files for that run and after it. Relative paths are taken from the project root; absolute paths inside the project are accepted. A path outside the project, and `--files` with a full run, are usage errors (exit 3) with a clear message. A path that isn't a Dart file or no longer exists is accepted.
- [ ] The `verify` MCP tool has the same `files` input with the same rules, and its input schema says so.
- [ ] On an unverified file, a `dart.deprecated` finding's fix hint says whether `dart fix` can migrate it. Elsewhere the hint stays general.
- [ ] The unverified files are read once per run, before the knowledge lock, and the same set is used by everything in that run: what is gathered and what the checks judge never see two different sets.
- [ ] A diagnostic carries what the server's "can this be fixed" question needs (its position in the file), and that question is asked while gathering, never under the knowledge lock.
- [ ] Both checks can be overridden with `verify.severity` and hidden by a suppression.
- [ ] The guide pages for the checks and for the knowledge store's state are updated; the guide check passes.
