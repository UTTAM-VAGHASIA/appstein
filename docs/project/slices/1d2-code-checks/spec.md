# Slice 1d.2: code checks

Status: ready-for-agent (approved by the owner, 2026-10-12)

Implements parts of the product design (`docs/project/specs/2026-09-29-appstein-design.md`): §5.3, §7, §8, §9, §9.1, §9.2, §9.3, §9.5, §9.7 and §15. Decision record: `docs/adr/0001-analysis-server-beside-the-map-analyzer.md`. Words in **bold** on first use are defined in `GLOSSARY.md`.

Agreed with the owner in the design interview of 2026-10-12 (19 questions, all answered).

## Problem Statement

`appstein verify` can check a project's knowledge, decisions and docs (slice 1d.1), but it says nothing about the code itself. An agent that writes Dart which doesn't compile, uses a deprecated Flutter API, leaves a file unformatted or breaks a test hears nothing from Appstein. Success criterion 1 of the design ("zero deprecated-API findings in final code") can't be checked at all.

The Dart tools that could answer are too slow to ask after every change. A cold `dart analyze` on one file took 13.2 s on the 200-file app, against a limit of 5 s for a **fast run**.

## Solution

`appstein verify` gains the code checks: analyzer errors, deprecated use, analyzer warnings and lints, formatting, pending fixes and the project's tests.

`appstein mcp` keeps a Dart analysis server running, so the `verify` tool answers from **warm analysis**: about 0.1 s after an edit in the measurement. A fast run reports errors and deprecated use anywhere in the project, and the smaller findings only on the **unverified files**. A **full run** covers everything and runs the tests.

`verify` still never changes a project file unless it is asked to: a new `--apply` flag makes a full run fix and format the project first. A person can hide a finding in Dart code with a visible comment that needs a reason.

The hook that runs a fast run by itself after each edit is not part of this slice. It is slice 1d.7, built straight after this one.

## User Stories

**Analyzer findings**

1. As an agent, I want an analyzer error reported with its file, line and the analyzer's message, so that I can fix code that doesn't compile before I build on it.
2. As an agent, I want an error in a file I didn't touch reported too, so that I learn when my change to one file broke another.
3. As an agent, I want every use of a deprecated API reported as an error, so that I never leave one in finished code.
4. As an agent, I want a deprecated-use finding to say whether `dart fix` can migrate it, so that I know whether to rewrite the call myself.
5. As a developer, I want analyzer warnings and lints reported at the analyzer's own level, so that verify agrees with my IDE and with `dart analyze`.
6. As an agent, I want warnings and lints in a fast run limited to the unverified files, so that I'm not shown old lints in files I never touched.
7. As a developer, I want the analyzer's own code (such as `unused_import`) in each message, so that I can look it up or switch it off in `analysis_options.yaml`.
8. As a developer, I want `verify.severity` in `appstein.yaml` to raise or lower any of the new findings, so that my team can make warnings block.
9. As a project owner, I want an `// ignore:` comment that hides deprecated use reported as an error, so that an agent can't reach "no deprecated APIs" by hiding them.

**Formatting and fixes**

10. As an agent, I want an unformatted file reported as a warning, so that I know it will be reformatted when I finish.
11. As a developer, I want the format check to agree with `dart format` from my project's own SDK, so that verify never asks for a format my tools would undo.
12. As a developer, I want generated files left out of the format check, so that code a generator owns is never reported or rewritten.
13. As a developer, I want a full run to list the fixes `dart fix` would apply, per file and code with a count, so that I see what a migration would touch before applying it.

**Applying**

14. As a developer, I want `verify` to leave my files alone unless I pass `--apply`, so that a check in CI can never rewrite the code it checks.
15. As an agent finishing a task, I want `--apply` to fix and format the whole project before the checks run, so that fixable findings are gone and not reported.
16. As an agent, I want the list of files `--apply` rewrote, so that I read them again before editing them.
17. As a developer, I want `--apply` refused with a fast run, so that files are never rewritten in the middle of an agent's work.

**Tests**

18. As an agent, I want each failing test reported as its own error with the test's name, file, line and the failure's first lines, so that I can go straight to it.
19. As an agent, I want a test file that can't be loaded reported on that file, so that a broken test file isn't mistaken for no tests.
20. As a developer, I want the tests skipped and named as not run when the code has analyzer errors, so that I don't wait minutes for a suite that can't compile.
21. As a developer, I want a time limit on the test suite that I can change in `appstein.yaml`, so that a hanging test can't hang verify.
22. As a developer, I want a project without a `test/` folder to give no test finding, so that one problem isn't reported twice (`verify.test_required` covers it).

**Fast runs and the unverified files**

23. As an agent, I want a file to stay among the unverified files until a verify run finds no error in it, so that an earlier error can't scroll out of view after my next edit.
24. As an agent, I want to pass files with `--files` or the tool's `files` input, so that a file I know I changed is checked even when the hash scan hasn't seen it yet.
25. As a developer, I want a path outside the project refused with a clear message, so that a typo isn't a silent no-op.
26. As a developer, I want a deleted file accepted in `--files`, so that removing a file counts as a change.

**Warm analysis**

27. As an agent, I want the `verify` tool to answer a fast run within 5 s after I edit one file, so that checking after every change is cheap enough to do.
28. As a developer, I want a terminal `appstein verify` to give exactly the findings the tool gives, so that CI and the agent never disagree.
29. As a developer, I want the analysis server stopped when `appstein mcp` or a terminal run ends, so that no process is left behind on my machine.
30. As a developer, I want a clear message and exit code 3 when the analysis server can't answer, so that a broken environment is never read as "no errors".
31. As an agent, I want the Dart checks to run even when the knowledge is stale because the code doesn't resolve, so that I'm shown the syntax error that caused it.

**Suppression comments**

32. As a developer, I want to hide one finding with `// appstein:ignore <check-id> — <reason>` at the end of the line or on the line above, so that an exception sits next to the code it excuses.
33. As a developer, I want to hide a check for a whole file with `// appstein:ignore-file <check-id> — <reason>`, so that a legacy file doesn't need a comment on every line.
34. As a developer, I want to type the separator as `--` or ` - ` as well as `—`, so that I don't need a character my keyboard lacks.
35. As a project owner, I want a comment without a reason, with an unknown check ID, or that hides nothing reported as a finding on its line, so that suppressions stay honest.
36. As a project owner, I want findings hidden by comments counted in the summary with those hidden by `appstein.yaml`, so that nothing disappears silently.

**Carried from 1d.1**

37. As a developer, I want a decision's path with an escaped glob character (`a\[1\].dart`) to match the file of that name, so that `paths.exist` works for such names.
38. As a developer, I want a suppression path like `C:foo` refused when `appstein.yaml` is loaded, so that an entry that can never match isn't accepted.

## Implementation Decisions

**Where the code goes**

- The code checks are engine checks, not pack checks: they hold for every Dart project whatever its stack or platforms.
- A new engine component, `analysis/`, owns the analysis server: starting it, asking it, stopping it. The checks see it through one small interface, the **code analysis**, which answers four questions: what are the project's diagnostics now, can this diagnostic be fixed automatically, which fixes are pending, and would this file's formatting change. A fifth operation applies fixes and formatting.
- The context every check receives gains the code analysis and the unverified files. Neither needs the project map, so these checks run when the knowledge is stale.

**The analysis server (decision record 0001)**

- It is the analysis server of the project's own SDK, found the way Appstein already finds the SDK, so verify agrees with the developer's `dart analyze` and IDE.
- It is started from the SDK's real executable. On Windows the `dart.bat` wrapper adds about 1.1 s and FVM's wrapper another 1.2 s per start.
- `appstein mcp` starts it when a `verify` call first needs it, not when the MCP server starts, so a session that never verifies holds no analysis server. It keeps one per project, stops it when it has not been asked anything for 10 minutes, and stops it when the MCP server stops. The `verify` tool waits for it when it isn't ready yet; a call after an idle stop starts it again.
- One `appstein mcp` with the plugin holds about 2.3 GB for the 200-file app, which the owner does not accept as the final cost (decision record 0001, "Memory"). Starting on demand and stopping when idle is this slice's part. One server per project shared by every session is slice 1d.7's, and taking the plugin out of this server is slice 1d.3's.
- A terminal `appstein verify` starts its own, waits for the first analysis, runs, and stops it.
- **The protocol is the legacy analyzer protocol, for every question** (owner's decision, 2026-10-12; decision record 0001, "The protocol"). Ticket 02 measured both protocols. They take the same time and memory to start (about 18 s and 1.5 GB with the plugin; the interview's lighter LSP number was taken before the plugin had finished). Over LSP nothing says when the plugin has finished, so verify could report "no problems" too early, and the server can't list the pending fixes per code. The legacy protocol does both.
- **The server runs behind a guard.** A legacy server keeps running when its parent is killed, until the next edit of a project file. So Appstein starts it through a guard: the `appstein` binary in a mode of its own, which starts the server, passes its input and output through, and ends it when its own input closes. A killed `appstein mcp` took the guard and the server with it within 0.7 s in the measurement, and the guard cost 22 MB and no measurable time.
- **"Ready"** is the server's own word that its analysis is done, which over this protocol includes the plugin's. The plugin's diagnostics are taken from the notifications the server sends, since the request for one file's errors leaves them out.
- **Pending fixes** come from the running server, in passes: ask for the fixes, apply them to an overlay in the server's memory and never to disk, and ask again until a pass finds none. The totals equalled `dart fix --dry-run` in the measurement (17 to 19 s).
- **The Dart tools' own usage reporting is left as the developer set it.** Appstein does not pass the server's flag that switches it off (owner's decision, 2026-10-12).
- A server that doesn't start, dies or doesn't become ready within 180 s is Appstein failing: exit 3 in the terminal and an error reply from the tool, with the reason and "run `appstein doctor`" (§9.5, §15). The starts measured on the Windows development machine: 7 to 10 s without the plugin, 18 to 22 s with it, 54 to 66 s for a first start that builds the plugin, and 71 s once for a first start without the plugin, which was not explained. No other machine was measured.

**The checks**

| ID | What it reports | Severity | Fast run | Full run |
|---|---|---|---|---|
| `dart.error` | An analyzer error | error | whole project | whole project |
| `dart.deprecated` | A `deprecated_member_use*` diagnostic, and an `// ignore:` or `// ignore_for_file:` comment that names one | error | whole project | whole project |
| `dart.warning` | An analyzer warning | warning | unverified files | whole project |
| `dart.lint` | An info-level diagnostic | info | unverified files | whole project |
| `dart.unformatted` | A file whose formatting would change | warning | unverified files | whole project |
| `dart.fix_pending` | The fixes `dart fix` would apply, one finding per file and code with the count, on the file with no line | warning | not run | whole project |
| `test.failed` | A failing test; a test file that can't load; the suite passing its time limit | error | not run | whole project |
| `dart.plugin_failed` | An analyzer plugin the analysis server could not load, so its rules did not run; on the project, with the server's message (added by the owner on 2026-10-14, after the review of ticket 03) | error | whole project | whole project |

- Each analyzer finding carries the analyzer's code and message. "Whole project" is what the analysis server covers: every Dart file under the project root that `analysis_options.yaml` doesn't exclude.
- Diagnostics from the `appstein_lints` plugin arrive the same way and are reported under these IDs by their level until slice 1d.3 gives the rules their own IDs.
- **Deprecated use and fixes in a fast run:** for each `dart.deprecated` finding on an unverified file, the fix hint says whether `dart fix` can migrate it. Findings elsewhere get a general hint.
- **Hidden deprecated use:** the comments are found by reading the Dart files' comments, so text inside a string never counts. The finding is on the comment's line and says what it hides.
- **Formatting** is asked of the analysis server, which uses the project's SDK. Generated files are left out: those `analysis_options.yaml` excludes, and those that start with a `GENERATED CODE - DO NOT MODIFY` header.
- **Tests:** one `flutter test` run on the whole project with machine-readable output, started with the project's Flutter. A failure is reported on the test's file and line. The check doesn't run when the same run has a `dart.error`, and is then named among the checks not run with that reason. It doesn't run when the project has no `test/` folder.
- **Test time limit:** `verify.test_timeout_seconds` in `appstein.yaml`, default 600. On reaching it the run is stopped and one `test.failed` is reported on the project.

**The unverified files**

- They are kept in `.appstein/state.json`. A state file written before this slice reads as having none.
- A file joins them when the knowledge refresh sees its content changed, or when it is named in `--files` or the tool's `files` input.
- A file leaves them when a verify run, fast or full, reports no error on it. A hidden (suppressed) error counts as none. A deleted file leaves after one run.
- The refresh must see a change in every Dart file the analysis server covers, including tests. Where the map's inputs cover less, the hash scan is widened for this purpose.

**`--apply`**

- Allowed with a full run only; with `--fast` it is a usage error.
- Order: apply `dart fix` to the whole project, format the whole project (generated files left out), refresh the knowledge, then run every check.
- The result names each file it rewrote: an `applied` list in the JSON output, a list in the text output before the findings.
- Without `--apply` nothing changes: every check keeps the 1d.1 promise never to write a project file.

**The command line and the tool**

- `appstein verify` gains `--apply` and `--files <paths>`. `--files` takes paths relative to the project root or absolute paths inside it. A path outside the project, `--files` with a full run and `--apply` with a fast run are usage errors (exit 3). A path that isn't a Dart file or no longer exists is accepted.
- The `verify` MCP tool gains the optional inputs `files` (fast scope) and `apply` (full scope), with the same rules, and its result gains `applied`.

**Suppression comments in Dart code**

- `// appstein:ignore <check-id> — <reason>` hides that check's findings on its own line when it ends a line of code, or on the next line of code when it stands alone.
- `// appstein:ignore-file <check-id> — <reason>` counts anywhere before the file's first declaration and hides that check's findings in the file.
- The separator is `—`, `--` or ` - `. Several IDs separated by commas are not supported: one comment, one check.
- They hide any finding whose file is that Dart file, whichever check reported it, except the four findings nothing can hide (§9.7).
- The three `suppression.*` findings apply as for `appstein.yaml`: no reason (error, hides nothing), unknown check ID (error), hides nothing (warning, full run only, and not when its check didn't run). Each is on the comment's line.
- Hidden findings and the comments that hid them are counted in the summary together with the `appstein.yaml` suppressions.

**Fixes carried from 1d.1**

- `paths.exist` keeps a backslash that escapes a glob character instead of turning it into `/`.
- The configuration loader refuses a drive-relative suppression path (`C:foo`) with the other absolute forms.
- The CLI's in-process tests get the real Dart SDK path the engine's tests use, and gain a run of `verify` on a healthy project.

**Measuring**

- The 5 s limit of §15 is measured on the `verify` tool of a running `appstein mcp`, after one file of the 200-file app is edited, in CI on Linux, macOS and Windows.
- The terminal fast run and full run are timed and recorded with no limit.
- The analysis server's start-up time and memory are recorded with them.

## Testing Decisions

A good test here states what a person or an agent sees: given this project, these findings, this exit code, these files rewritten or untouched. It doesn't state how the analysis server was asked. Each check is first written with an empty body so its tests fail on behaviour, not at compile time (a lesson from 1d.1).

**Seams, highest first**

1. **`verify` run on a fixture app with the real analysis server.** This is the existing seam of the engine's fixture tests, with a real Dart SDK. Every check gets a passing and a failing fixture here (§18's exit criterion): an error, an error in a dependent file, deprecated use with and without a data-driven fix, a hiding `// ignore:`, a warning, a lint, an unformatted file, a generated file, pending fixes, `--apply`, and the suppression comments. One server is started per test file and shared, since a start costs 6 s or more.
2. **The code analysis interface, with a scripted stand-in.** This is the one new seam. It is for what a real server can't produce on demand or would make slow: the unverified files across several runs, the mapping of levels to severities, a server that dies or never becomes ready, and many diagnostics at once. Prior art: the scripted checks of the 1d.1 verify tests.
3. **The process runner, with scripted output**, for the test check: the event stream of a passing run, a failing test, a thrown error, a file that can't load, and a run that never ends. Prior art: the scripted process runner the sync and doctor tests use. One run of the real `flutter test` on a fixture app is made where a real Flutter SDK is present, as the doctor's real-environment tests do.
4. **The CLI, in process**, with the real Dart SDK path: flags, usage errors, text and JSON output, exit codes 0, 1 and 3, and the healthy-project run carried from 1d.1.
5. **The MCP server**, as its tool tests do today: the `files` and `apply` inputs, one analysis server reused across calls, an error reply when it can't answer, and the server stopped with the process.
6. **The compiled binary on the 200-file app**, in the existing measurement tool: the warm limit, the recorded terminal times, and every line of real output read once by hand before the slice is called done.

**Also tested**

- No analysis server process is left running after a test, a terminal run or a stopped `appstein mcp`, on Windows too.
- Paths with spaces and letter case on Windows, for `--files` and for the files findings name.
- The three carried fixes, each test first.

## Out of Scope

- **Slice 1d.7, built next:** `--hook claude`, exit code 2, the hook's route to the running `appstein mcp` over a local socket, the loop guard, what a hook does when no `appstein mcp` is running, the `fast_timeout_seconds` cap, the 5 s measurement on the hook's route, and the order of the Stop hook's steps in §5.4.
- **Slice 1d.7 also:** one analysis server per project, shared by every session that works on it (decision record 0001, "Memory").
- **Slice 1d.3 also:** running Appstein's lint rules on the analyzer the map already has, so the plugin leaves the analysis server verify uses.
- **Slice 1d.3:** the lint rules and their own check IDs; a `verify.severity` key that names no check (moved there by the owner, since the design's own example key names a 1d.3 check).
- **Slice 1d.4:** the package gate, including what a fast run does when dependencies changed.
- **Slice 1e:** `--hook codex`; whether the `create` template's accessibility guideline tests exist.
- Running a single test or only the tests of changed files.
- Projects with several packages (pub workspaces).
- Reducing memory by sharing one analyzer between the map and verify (ruled out in decision record 0001).

## Further Notes

**The measurement behind this design** (Windows development machine, 2026-10-12, 200-file app, `appstein_lints` plugin on, median of three):

| | Time |
|---|---|
| Cold `dart analyze`, one file / whole project | 13.2 s / 23.5 s |
| Cold `dart fix --dry-run` | 12.8 s (21.0 s and 29.3 s in ticket 02, one run each) |
| Analysis server until ready, LSP / legacy protocol / legacy behind a guard (ticket 02) | 18.3 s, 1.44 GB / 18.8 s, 1.49 GB / 18.6 s, 1.52 GB |
| The same without the plugin, LSP / legacy (ticket 02) | 7.5 s, 0.63 GB / 7.2 s, 0.63 GB |
| The first start with the plugin, which builds it (ticket 02, one run) | 54.5 s |
| Warm: edit until the file's and its importer's diagnostics arrive, LSP / legacy / legacy behind a guard (ticket 02) | 0.10 s and 0.47 s in two runs / 0.08 s / 0.05 s |
| Warm: format one file | under 0.02 s |
| Warm: complete fix dry-run (legacy protocol, 3 passes and one that finds none; ticket 02) | 18.5 s, and 17.2 s behind a guard (7.5 s in the interview) |
| In-process analyzer after an edit | about 0.03 s, but no `flutter_lints` lints, no plugin rules, no fixes |
| `flutter test`, 7 tests in 3 files | 5.8 s |

The rows marked "ticket 02" were measured again with `tool/measure_analysis_server.dart`, which waits for the plugin's diagnostics before it calls a server ready. The interview's 7.6 s and 0.56 GB for LSP were taken when the server said it was done, about 10 s before the plugin had finished.

Not measured: Linux, macOS, CI machines, a 1,000-file app, a fix for a removed API, a test file that fails to compile. In the measurement every pending `fix_data` migration also showed as `deprecated_member_use` on the same line, and `dart fix --dry-run` printed no line numbers.

**Two things assumed, not asked.** Compile errors can be hidden like any other finding, so the list of findings nothing can hide stays at four. The Dart checks cover what `dart analyze` covers in the project.

**Edits this slice makes to the product design.** The owner approved them with this spec, and they are in the same commit, with the visual summary and `progress.yaml`. Risk 21 in §22 was updated to match.

- **§5.2:** a row for `analysis/`: "Start, ask and stop the Dart analysis server that verify's code checks use (§9.1)".
- **§5.3:** the `verify` row becomes `appstein verify [--fast|--full] [--apply] [--format json|text] [--hook claude|codex] [--files <…>]`, with: "`--apply` (full runs only) first applies `dart fix` and `dart format` to the project; without it `verify` writes no project file. `--files` (fast runs only) adds files to the unverified files."
- **§7:** a key under `verify:`, `test_timeout_seconds: 600`, "a full run stops the test suite after this".
- **§8:** the `verify` tool's input becomes "`scope`: `fast` or `full`; optional `files` (fast) and `apply` (full)", and its result gains the files `apply` rewrote.
- **§9, "Built in slices":** 1d.2 adds the analyze, fix, format and test checks, warm analysis, `--files`, `--apply` and the Dart suppression comments; 1d.7 adds `--hook`, the hook's route to the running process and the 5 s proof on it.
- **§9.1:** the title drops "changed files only". The list becomes: analyzer errors and deprecated use anywhere in the project; warnings, lints and formatting on the unverified files; an `// ignore:` naming deprecated use is itself reported; pending fixes move to the full checks, and a deprecated-use finding says whether `dart fix` can migrate it. "Unverified files" is defined there. The warm-analysis paragraph records the measurement above and names the analysis server (decision record 0001); "still to prove" becomes the hook's route, in 1d.7.
- **§9.2:** "first apply `dart fix --apply` and `dart format`" becomes "with `--apply`, first apply…"; `dart.fix_pending` and `test.failed` are named, with the rule that tests don't run while the code has errors, and the time limit.
- **§9.3:** the JSON output gains `applied`, and the text output lists the rewritten files.
- **§9.7:** the Dart comment may stand at the end of the line or alone on the line above, with `—`, `--` or ` - `; an `// ignore:` doesn't hide deprecated use from verify.
- **§15:** "Fast verify < 5 s on the fixture app" gains "measured on a running `appstein mcp` after one file is edited; a terminal run starts its own analysis server and is timed without a limit".
- **§18:** 1d is "built as seven slices, 1d.1–1d.7": the verify frame, code checks, then hook mode and fast verify in 5 s (1d.7, built after 1d.2), lint rules, the package gate, Android, iOS.
