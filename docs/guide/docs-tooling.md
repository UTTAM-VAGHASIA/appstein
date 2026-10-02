<!-- covers:
tool/check_guide.dart
tool/check_graph.py
tool/gen_docs.dart
tool/install_hooks.dart
tool/src/**
-->

# How this guide stays correct

A guide that drifts from the code is worse than none, because readers trust it. This page explains the tools that stop that from happening quietly, and how to work with them.

## The rules

The rules come from [spec §19.6](../superpowers/specs/2026-09-29-appstein-design.md#196-documentation-for-humans-working-on-appstein):

- **Every source file has a page.** Each page lists the files it explains, and the check fails if a source file is on no page's list.
- **Code changes come with their page.** A change to a covered file must also change a page that covers it, or say in a commit trailer why the page is still right.
- **Facts the code already knows are generated, not typed.** The CLI's help, the exit codes, the doctor checks, the CI jobs and the package graph are written by a tool.
- **Progress is data, not prose.** Where each milestone and slice stands is written once, in `docs/superpowers/progress.yaml`, and drawn on the spec's visual page (see [Progress](#progress)).
- **CI is the gate; local hooks warn early.** The check runs in CI's `docs` job, and a git hook runs it after each commit as a warning. Another hook warns when the knowledge graph doesn't hold the current docs (see [Is the graph current?](#is-the-graph-current)).

## Covers comments

The first line of every page says which files it explains:

```text
<!-- covers:
packages/appstein_cli/lib/**
packages/appstein_cli/bin/**
-->
```

A page that explains no particular file, such as this guide's start page, says so:

```text
<!-- covers: none -->
```

The details, from [`coverage.dart`](../../tool/src/coverage.dart):

- **Source** means every file matched by `packages/*/lib/**`, `packages/*/bin/**`, `tool/**` or `.github/workflows/**`. Each must be covered by at least one page.
- A page may also cover other files, such as test helpers. Those count for the stale-page check below, but nothing requires them to be covered.
- Entries are globs, relative to the repo root, with forward slashes. Spaces, commas or line breaks separate them, so a brace glob such as `{a,b}` is split in two and isn't supported. List each path instead.
- **A glob that matches no file is an error.** That catches a folder that moved while its page kept the old path.
- **Overlapping covers are fine.** A file may be on several pages' lists, such as a barrel file and the area pages behind it. Changing any one of those pages is enough for the stale-page check.
- The comment must be the first non-blank line, and a page has only one. A comment inside a code fence, like the examples above, is ignored.

## Stale pages and `Docs-Checked`

With `--since <rev>`, the check also looks for pages that fell behind. From [`git_repo.dart`](../../tool/src/git_repo.dart) and [`stale_check.dart`](../../tool/src/stale_check.dart):

- **What counts as changed:** every file that differs between the merge base of `<rev>` and HEAD, and the working tree. That includes committed, staged, unstaged and untracked (but not ignored) changes. A rename counts as both its old and its new path, so moving a file trips the pages of both places.
- **A guide page must change in its own words.** A page counts as changed only when its text differs from the merge base's copy with every generated section body left out and line endings ignored. So a page that only `gen_docs` rewrote doesn't clear the check for the files it covers: a regenerated fact isn't a sign that someone read the hand-written text around it. A page that is new since the merge base, deleted, unreadable, or has broken markers counts as changed. `stripGeneratedBodies` in [`generated_sections.dart`](../../tool/src/generated_sections.dart) removes the bodies, and `GitRepo.fileAt` reads the merge base's copy.
- **The rule:** each changed file that a page covers needs one of its covering pages in the change too, or a `Docs-Checked` trailer naming one of them.
- **Trailers** are read from the commit messages between the merge base and HEAD, so a trailer counts once it is committed.

A commit message with a trailer:

```text
refactor(cli): rename a private helper in the doctor printer

The printed report is unchanged.

Docs-Checked: cli.md - only a private name changed
```

- **Use it** when the page is still right: a private rename, a refactor, a fix that doesn't change what the page says.
- **Don't use it** to skip writing docs for a change in behaviour. The trailer is a claim that someone checked; it stays in the history.
- The page may be named relative to `docs/guide/` (`cli.md`) or to the repo (`docs/guide/cli.md`). The key is matched in any case.
- A trailer with no page or no reason, or one naming a file that isn't a guide page, is itself a problem.

## Generated sections

A generated section is a pair of markers on their own lines. `gen_docs` replaces everything between them:

```text
<!-- generated:cli-help -->
<!-- /generated:cli-help -->
```

Never edit between the markers by hand: the next run overwrites it, and the check fails until it matches. The sections, from [`generators.dart`](../../tool/src/generators.dart):

| Section | Page | Source of truth |
|---|---|---|
| `cli-help` | [cli](cli.md) | The CLI's own `--help`, and `help <command>` for each command, run in-process through `runAppstein` |
| `exit-codes` | [cli](cli.md) | The `ExitCodes` constants and the first paragraph of each one's `///` comment |
| `doctor-checks` | [doctor](doctor.md) | `defaultDoctorChecks()`: each check's order, ID and title, and the first paragraph of its `///` comment |
| `ci-jobs` | [ci](ci.md) | `.github/workflows/ci.yml`: the triggers, and each job's runners and step names |
| `package-graph` | [architecture](architecture.md) | The root `pubspec.yaml`'s workspace list and each package's dependencies, without dev dependencies |
| `progress-status` | the spec's [visual page](../superpowers/specs/2026-09-29-appstein-design.html) | `docs/superpowers/progress.yaml`: the milestone being built and the slice that is next |
| `progress` | the spec's [visual page](../superpowers/specs/2026-09-29-appstein-design.html) | `docs/superpowers/progress.yaml`: the milestone rail, each milestone's slice bar and its timeline |

Rules, from [`generated_sections.dart`](../../tool/src/generated_sections.dart) and [`generated_docs.dart`](../../tool/src/generated_docs.dart):

- **Guide sections go only in pages directly in `docs/guide/`.** Generated links are written relative to that folder, so they would break in a subfolder such as `how-to/`. The two progress sections are the exception: they live in the spec's visual page, and [`progress_html.dart`](../../tool/src/progress_html.dart) writes their links relative to its folder.
- **A section that no page shows is an error**, so no generated fact goes unshown. An unknown section name is an error too.
- Markers inside a code fence are examples and are left alone. A page's line endings (LF or CRLF) are kept.
- If a generator can't run, for example because a check has no doc comment or `ci.yml` is malformed, that is reported as a problem naming the file, not a crash.

**Why doc comments are read as text.** [`doc_comments.dart`](../../tool/src/doc_comments.dart) reads `///` lines straight from the source instead of parsing it with `package:analyzer`. When this was measured on the development machine, importing the analyzer made a `dart run` of such a tool take about 8.8 s instead of about 2.2 s, and the hook runs the check on every commit. `dart format` keeps doc comments in a layout that simple reading handles.

## Commands

Run both from the repo root.

| Command | What it does |
|---|---|
| `fvm dart run tool/gen_docs.dart` | Rewrites every out-of-date generated section, in the guide and on the spec's visual page, and prints `Updated <page>` for each |
| `fvm dart run tool/gen_docs.dart --check` | Writes nothing; exits 1 if any section is out of date |
| `fvm dart run tool/check_guide.dart` | Every check except the stale-page check |
| `fvm dart run tool/check_guide.dart --since main` | Every check, plus the stale-page check against `main` |
| `fvm dart run tool/check_guide.dart --warn-only` | Prints problems as warnings and exits 0, even when the check can't run; bad usage still exits 3 (used by the hook) |

`check_guide` runs these checks, all from [`guide_check.dart`](../../tool/src/guide_check.dart):

1. **Links and paths** ([`guide_checker.dart`](../../tool/src/guide_checker.dart)), in every guide page and package README:
   - relative links must point at a file that exists (the part after `#` isn't checked);
   - a path in backticks that starts with `packages/`, `docs/`, `tool/`, `test/` or `.github/` must exist;
   - ```` ```dart ```` code blocks are refused until slice 1f can analyze them. Link to real code instead.
2. **Every page is linked**, through a chain of links from [README](README.md).
3. **Covers comments and coverage.**
4. **Stale pages**, only with `--since`.
5. **Generated sections are up to date.**
6. **Progress** ([`progress.dart`](../../tool/src/progress.dart) and [`progress_check.dart`](../../tool/src/progress_check.dart)): `progress.yaml` is valid and agrees with the plans and spec §18, and the visual page's progress sections are up to date. See [Progress](#progress).

Every check reads Markdown through [`markdown.dart`](../../tool/src/markdown.dart), which tracks code fences and picks out links to files. Anything inside a fence (a link, a path, a covers comment, a marker) is an example and is skipped.

Exit codes, for both tools:

| Code | Meaning |
|---|---|
| `0` | Passed |
| `1` | Problems found. For `gen_docs`: a section is out of date (with `--check`), or a marker, section name or generator has a problem |
| `3` | The tool couldn't run: bad usage, or (for `check_guide`) a git command failed, for example outside a git repo |

`--since` with a revision that isn't a commit is reported as a problem (exit 1). With `--warn-only`, `check_guide` exits 0 whatever it finds, and when it can't run at all it prints one line, `warning: the guide check could not run: <error>`. Only bad usage still exits 3.

**The curated notes are generated too, in a different way.** [`tool/gen_notes.dart`](../../tool/gen_notes.dart) compiles the YAML files in `notes/` into a Dart file the `appstein` binary carries, using [`notes_bundle.dart`](../../tool/src/notes_bundle.dart). It is not a guide section. Instead, `test/notes_bundle_test.dart` fails while the compiled file is stale. See [knowledge-store](knowledge-store.md#the-curated-notes).

## Is the graph current?

graphify's knowledge graph (`graphify-out/`) has two layers. The git hooks rebuild the code structure after every commit, checkout, merge and rebase (see [Git hooks](#git-hooks)). What the docs mean is extracted by an LLM, and that only happens when someone runs `/graphify . --update`. So after a doc changes, the graph describes the old version until the command runs again, and the hooks don't say so: `GRAPH_REPORT.md` still says "Built from commit …", which reads as fresh.

[`check_graph.py`](../../tool/check_graph.py) closes that gap. It runs with graphify's own Python, because it is made of graphify calls, and takes about half a second. It lists the files graphify treats as docs with graphify's own `detect`, so `.graphifyignore` and `.gitignore` apply, and reports three kinds of problem:

| Reason | Meaning |
|---|---|
| `new or changed` | No extraction of the doc's current content is cached. graphify keys its cache by a hash of the content and the path, so any edit to the content counts. For Markdown, graphify hashes only the text below the front matter, so an edit to the front matter alone doesn't. |
| `missing from the graph` | An extraction is cached, but `graph.json` has none of the nodes it adds. graphify's code rebuild gives a Markdown doc heading nodes of its own, one with the id the extraction gives the doc itself, so those don't count. It happens when a code rebuild ran while the doc wasn't on disk, for example on a branch without it, or when an update stopped before merging the doc. The hooks put such docs back by themselves; see [Repairing the graph](#repairing-the-graph). |
| `deleted or no longer scanned` | `graph.json` still has nodes from a doc that graphify no longer scans, because the file was deleted or is now ignored. graphify's background rebuild after a commit prunes such docs, and code files too (which the check leaves out), so this mostly shows once, right after the commit that deleted or renamed a doc, and clears by itself. |

**Any agent's extraction counts.** Each agent's graphify skill (Claude Code, Codex and others) ships its own extraction prompt, and graphify files cached extractions under a fingerprint of the prompt that made them. The check accepts an extraction made with any prompt, in normal or deep mode, so a graph updated from a different agent doesn't look stale. A partial extraction (graphify marks one that was cut short) or an empty one doesn't count, as in graphify itself.

Run it from the repo root. In PowerShell:

```powershell
& (Get-Content graphify-out/.graphify_python) tool/check_graph.py
```

In Git Bash, macOS or Linux:

```text
"$(cat graphify-out/.graphify_python)" tool/check_graph.py
```

When docs are behind, it prints one line, with at most five names per reason and then `and N more`:

```text
graphify: the graph is behind on 1 doc (new or changed: docs/guide/cli.md). Run /graphify . --update before relying on it.
```

| Code | Meaning |
|---|---|
| `0` | The graph is current. It prints how many docs it checked, or nothing with `--quiet` (the hooks use it). With `--skip-repairable` (the merge and rebase hooks), docs missing from the graph don't count: it prints `graphify: repairing N docs from the cache in the background (…)` instead |
| `1` | Docs are behind |
| `3` | The check couldn't run: there is no graph yet, graphify can't be imported, or a graphify release changed the functions the check calls. It prints `graphify: the graph check could not run: <reason>`. An unknown option, or a mode together with another option, also exits 3, with a usage line on stderr |

**Why it isn't in CI.** CI has no graph: `graphify-out/` is git-ignored and built on each developer's machine. CI does test the script against a pinned graphify (see [ci](ci.md)). The rule lives in the per-slice process instead: before a slice merges, this check must report nothing ([spec §19.4](../superpowers/specs/2026-09-29-appstein-design.md#194-git-and-process)).

## Repairing the graph

**Why docs go missing.** graphify's code rebuild keeps the nodes of every doc that is on disk and drops those of a doc that isn't. So a rebuild on a branch that lacks a doc drops what the LLM extracted from it. Switching back, or pulling the doc in, brings the file back, but a code rebuild can't extract its meaning again: that needs the LLM. The extraction is still in graphify's cache, though, keyed by the doc's content. This happened on 2026-10-01: `gh pr merge --delete-branch` switched to the old local `main`, which lacked the slice's plan, and graphify's rebuild there dropped the plan.

**What `--repair` does.** [`check_graph.py`](../../tool/check_graph.py) `--repair` puts every doc that is `missing from the graph` back from the cache, with no LLM:

1. It takes graphify's rebuild lock (`graphify-out/.rebuild.lock`), waiting while a rebuild holds it, so it never runs alongside one.
2. It reads the newest cached extraction of each missing doc's current content, made with any agent's prompt, in either mode.
3. It runs graphify's own full code rebuild, with those extractions added to what the rebuild keeps from the existing graph. graphify then finishes the graph as it always does: it clusters, keeps each community's number where it can, keeps a saved community name when that community's members didn't change, names the others after their best-connected node, and writes `GRAPH_REPORT.md` and `graph.html`.
4. It checks the graph again, and says what it did.

It leaves the other reasons alone: a `new or changed` doc needs the LLM, and graphify's rebuild itself drops a deleted doc. Those still need `/graphify . --update`. graphify's hooks cluster with `PYTHONHASHSEED=0`, so the communities come out the same each time; `--repair` restarts itself with that seed when it isn't set.

In PowerShell:

```powershell
& (Get-Content graphify-out/.graphify_python) tool/check_graph.py --repair
```

In Git Bash, macOS or Linux:

```text
"$(cat graphify-out/.graphify_python)" tool/check_graph.py --repair
```

It prints one line for what it did, then the usual warning if anything else is behind:

```text
graphify: repaired 1 doc from the cache (docs/superpowers/plans/2026-09-30-slice-1b1-sdk-gaps.md).
```

| Line | Code |
|---|---|
| `graphify: repaired N docs from the cache (…)` | `0`, or `1` when other docs are still behind |
| `graphify: nothing to repair.` | `0`, or `1` when other docs are behind |
| `graphify: could not repair the graph: <reason>` | `3`: graphify can't be imported, a graphify release changed what the repair calls, or graphify's rebuild failed (it quotes graphify's last line) or didn't put the docs back |

**In the background, after git.** You rarely need `--repair` by hand: the hooks start the repair after each branch switch, merge and rebase (see [Git hooks](#git-hooks)). Two more modes are there for them:

- `--detach` starts `--after-rebuild` in a separate background process, the way graphify's hooks start their rebuild, and returns at once. It prints nothing, and the process gets none of the hook's handles, so git doesn't wait for it.
- `--after-rebuild` first waits for the rebuild graphify's hook just started. That rebuild starts in the background too, and Python can take seconds to start on Windows, so it waits up to 20 seconds for graphify's lock file to appear, then until the file goes, up to 11 minutes (graphify stops a rebuild after 10). Then it runs the repair. It runs graphify's code rebuild even when no doc is missing, because graphify's hook skips its rebuild during a merge or a rebase (after a real merge commit, `MERGE_HEAD` still exists in `post-merge`, and in `post-rewrite` the rebase's own folder does), and whenever another rebuild still holds the lock.
- It doesn't wait for a lock file nobody holds: each 0.2 s it tries the lock without blocking, so the file a killed rebuild left behind costs nothing. If a merge, cherry-pick or rebase is still in progress when the lock wait ends (`MERGE_HEAD`, `CHERRY_PICK_HEAD`, `rebase-merge` or `rebase-apply` in the git folder), it waits for the operation to end, checking twice a second, and then repairs. The repair takes graphify's lock itself, so the order stays safe. Only when `APPSTEIN_REPAIR_MAX_WAIT` runs out (by default the job's limit, below) does it log one line, `graphify: a merge or rebase was still in progress after waiting for it; the graph was not repaired.`, and leave. Its whole run is limited like graphify's own rebuild: `GRAPHIFY_REBUILD_TIMEOUT` is read as graphify reads it (whole seconds, default 600, anything unparsable means 600), and the job's limit is that plus a minute, the wait for the lock included. When the value is zero or less, graphify sets no limit and neither does the job. On reaching the limit it logs `graphify: could not repair the graph: it took too long.`, kills any worker processes, and exits with `3`.
- It writes only to graphify's rebuild log, `~/.cache/graphify-rebuild.log` (or `GRAPHIFY_REBUILD_LOG`). It opens the log itself and adds to it, so graphify's lines stay. Each of its lines starts with `[appstein]` and the time:

```text
[appstein] 2026-10-01 01:32:32 graphify: repaired 1 doc from the cache (docs/superpowers/plans/2026-09-30-slice-1a2-graph-staleness.md).
```

`APPSTEIN_REPAIR_START_WAIT` and `APPSTEIN_REPAIR_MAX_WAIT` (seconds) change the waits, and `APPSTEIN_REPAIR_TIMEOUT` (seconds) sets the job's whole limit directly; the tests use them to stay short. The repair rebuilds the folder `graphify-out/.graphify_root` names, as graphify's hook does (when it is a folder inside the repo), else the repo root.

## Git hooks

`fvm dart run tool/install_hooks.dart` sets up the repo's hooks. Run it once per clone. It:

1. runs `graphify hook install` when `graphify` is on your PATH. That installs graphify's `post-commit` and `post-checkout` graph rebuilds. Without graphify it prints how to install it (`uv tool install graphifyy`) and skips this step;
2. adds our own block to `post-checkout`, `post-commit`, `post-merge` and `post-rewrite`, from [`hooks.dart`](../../tool/src/hooks.dart). The block sits between `# appstein-hook-start` and `# appstein-hook-end`. An older block is replaced in place; everything else in the file, such as graphify's block, is kept.

What each block does:

| Hook | What our block does |
|---|---|
| `post-checkout` | After a branch switch, starts the [background repair](#repairing-the-graph) with `check_graph.py --detach`, and prints nothing. It sits after graphify's block, which has just started graphify's rebuild. It does nothing for a file checkout, for a new branch at the same commit, during a rebase (the rebase's own checkouts), without `tool/check_graph.py` (or with one from before the repair), without a graph or a usable `graphify-out/.graphify_python`, or with `APPSTEIN_SKIP_GRAPH_HOOK=1` or `GRAPHIFY_SKIP_HOOK=1`. |
| `post-commit` | Runs `check_guide.dart --since HEAD~1 --warn-only` through `fvm dart`, or `dart` if there's no `fvm`. It skips during a rebase, on the first commit, when `tool/check_guide.dart` doesn't exist, or when `APPSTEIN_SKIP_DOCS_HOOK=1`. It only warns, and always exits 0. Then it runs the graph check (below). |
| `post-merge` | graphify's hooks miss merges and pulls. This block replays the `post-checkout` hook as if HEAD had switched from `ORIG_HEAD`, with `APPSTEIN_HOOK_REPLAY=1`. graphify's block rebuilds after a fast-forward, but skips while `MERGE_HEAD` exists, which it still does after a real merge commit. Our block starts the repair, whose own rebuild covers that case. Then it runs the graph check. |
| `post-rewrite` | The same, but only after a rebase. git still has the rebase's folder then, so graphify's block skips; `APPSTEIN_HOOK_REPLAY=1` lets ours run. graphify's `post-commit` already covers an amend. |

**The graph check in each block** runs [`check_graph.py`](../../tool/check_graph.py) `--quiet` with the Python named in `graphify-out/.graphify_python`, a file graphify writes on each `/graphify` run. It prints nothing when the graph is current, and one line when it isn't:

- It is skipped when there's no `tool/check_graph.py` or no `graphify-out/graph.json` (a clone where graphify was never run), during a rebase (`post-rewrite` checks once at the end), or when `APPSTEIN_SKIP_GRAPH_HOOK=1`.
- If `.graphify_python` is missing or names a file that isn't there or isn't executable, it prints `graphify: the graph check could not run: …` instead.
- It never stops the hook: the other parts of the block, and graphify's block, still run.

**After a merge or rebase, docs being repaired get one calm line.** There the check runs with `--skip-repairable`, because the replay has just started the repair. Docs `missing from the graph` are reported as `graphify: repairing N docs from the cache in the background (…)`, not as a request to run `/graphify . --update`. That line says the hook is changing the graph in the background, and where to look if that fails (the log). Silence would hide it, and the request would send you to an LLM run that isn't needed. With `GRAPHIFY_SKIP_HOOK=1` there is no repair, so the check asks for the update as before, and so it does on a branch whose `check_graph.py` is from before `--skip-repairable` (the hook looks for the option in the script, as the `post-checkout` block does for `--detach`). The `post-commit` check is unchanged: a commit doesn't drop docs.

**Why tiny `sh` blocks.** Git runs every hook with its own `sh`, on Windows too, so a hook must be a shell script. Each part of a block is a few lines that call a tested Dart tool, graphify's own hook, or (for the graph) a tested Python script made of graphify calls, so the logic stays in tested code. Each part runs in a `( … )` subshell, so its `exit` can't stop another part or another block in the same file. (The `AGENTS.md` rule "no bash scripts" is about the hooks Appstein will install for agents, not these.)

**Switches:**

- `APPSTEIN_SKIP_DOCS_HOOK=1` skips the docs warning. In PowerShell, for one commit:
  ```powershell
  $env:APPSTEIN_SKIP_DOCS_HOOK = '1'; git commit -m "wip"; Remove-Item Env:APPSTEIN_SKIP_DOCS_HOOK
  ```
- `APPSTEIN_SKIP_GRAPH_HOOK=1` skips the graph warning and the background repair, the same way.
- `GRAPHIFY_SKIP_HOOK=1` is graphify's own switch. It skips graphify's rebuilds, our merge and rebase replays of them, and the background repair, which rebuilds too.
- `fvm dart run tool/install_hooks.dart --remove` takes our blocks out and leaves graphify's. `graphify hook uninstall` removes graphify's.
- Re-run the installer whenever `tool/src/hooks.dart` or `.graphifyrc` changes. It is safe to run again: unchanged hooks are reported as `up to date`.

**The graph page's node limit.** graphify draws each node in `graphify-out/graph.html` only up to 5,000 nodes. Above that it draws one circle per community instead. This repo's graph passed 5,000 nodes in slice 1b.4, so [`.graphifyrc`](../../.graphifyrc) at the repo root raises the limit with `viz_node_limit=10000`. `graphify hook install` bakes that value into graphify's hooks as `GRAPHIFY_VIZ_NODE_LIMIT`. Our merge and rebase blocks replay `post-checkout`, so they use it too. To redraw the page by hand, run `graphify export html --node-limit 10000`.

**The cost.** graphify rebuilds in the background, so it doesn't slow a commit. The docs check does: it takes a few seconds (about 2.7 s on the development machine) after each commit. That cost is why doc comments are read as text, not with the analyzer. The graph check adds about half a second after a commit, merge or rebase. A branch switch, merge or rebase also starts the background repair, which takes about 0.2 s in the foreground. It then runs one more code rebuild after graphify's, about 3 seconds on the development machine, in the background.

## Progress

`docs/superpowers/progress.yaml` records where every milestone and slice stands. It is the only place progress is written; the spec's visual page draws it, and `AGENTS.md` points to it instead of retelling it.

```text
repository: https://github.com/UTTAM-VAGHASIA/appstein
milestones:
  - id: M1
    title: Knowledge + verification foundation
    summary: …
    slices:
      - id: 1b
        title: Knowledge layers 1–2
        summary: …
        slices:
          - id: 1b.1
            title: doctor agrees with flutter doctor -v
            summary: …
            status: done
            plan: 2026-09-30-slice-1b1-sdk-gaps.md
            pr: 4
            finished: 2026-10-01
```

**Fields**, read by [`progress.dart`](../../tool/src/progress.dart):

| Field | Meaning |
|---|---|
| `id` | `M1`, `M2` … for a milestone; `1a`, `1b` … for a slice; a sub-slice adds `.1`, `.2` … to its parent's id. Unique across the file |
| `title`, `summary` | A short name, and a sentence on what it delivers. Text in backticks is shown as code |
| `status` | `done` (finished: its pull request is open or merged), `next` (being built, or the one to build next) or `planned`. At most one slice is `next`. A slice without a status must have sub-slices, and its stage comes from them |
| `plan` | The plan's file name in `docs/superpowers/plans/` |
| `pr`, `finished` | The pull request number and the day it was marked done (`YYYY-MM-DD`). A done slice needs `plan`, `pr` and `finished`; only a done slice may have `pr` or `finished` |
| `tooling` | `true` for a slice that builds tooling for this repo rather than the product. The page tags it, and a slice's progress bar leaves it out, so tooling doesn't make the product look further along |
| `slices` | Sub-slices, in order |

**What the page shows**, from [`progress_html.dart`](../../tool/src/progress_html.dart): a pill at the top ("Building M1 · next: 1b.2 …") linking to the Progress section; a rail of milestones (done, in progress or planned); for each milestone with slices, a bar with one segment per slice, filled by the share of its product parts that are done; and a timeline of slices and sub-slices with their dates, pull requests and plans. The markup is generated; the page's own CSS styles the `pg-*` classes.

**What the guide check refuses**, from [`progress_check.dart`](../../tool/src/progress_check.dart):

- a plan in `docs/superpowers/plans/` (a `.md` file directly in the folder) that no slice names, a plan named by two slices, or a slice naming a plan that isn't there;
- a plan with a `## Notes from execution` heading whose slice isn't done. The notes are written when a slice finishes, so they are the signal;
- a milestone in spec §18 missing from the file, or one the file has that §18 doesn't; the same for the slices of each milestone §18 has a table for (today only M1). Sub-slices aren't in the spec, so they aren't compared;
- anything `progress.dart` refuses: an unknown key, a bad status, id or date, a done slice without its plan, pull request or date, more than one slice `next`;
- the visual page's progress sections not matching the file.

**Through a slice:**

1. The slice to build is already `next` (the previous slice set it).
2. The commit that adds the slice's plan also sets the slice's `plan`. Without it, the check reports the plan as belonging to no slice.
3. Once the pull request is open, one more commit records the result: the plan's notes from execution, the slice `done` with `pr` and `finished`, and the following slice `next`. Then `fvm dart run tool/gen_docs.dart`. It comes after the PR opens because GitHub gives the number only then; before that commit, the slice is still `next` and its plan has no notes, so every check passes on the pull request's runs before and after that commit.

## The docs step of each slice

1. `fvm dart run tool/gen_docs.dart`
2. `fvm dart run tool/check_guide.dart --since main`
3. `/graphify . --update`, then the [graph check](#is-the-graph-current), until it reports nothing. The hooks rebuild only the code structure, not what the docs mean.
4. Once the pull request is open, mark the slice done in `progress.yaml` (see [Progress](#progress)), run steps 1–3 again, and push.

Any edit after step 3, such as a review fix, puts the graph behind again, and the hook says so. The check must still report nothing when the slice merges. This is the docs step of the per-slice process in [`AGENTS.md`](../../AGENTS.md).

## Limits

- The check proves that a page was touched or confirmed, not that it is good. A one-word edit satisfies it. Review still matters.
- It can't tell whether hand-written text is true. Only the generated sections are right by construction, which is why facts the code knows are generated.
- Links are checked to the file, not to the heading after `#`.
- **The check looks at the whole range at once.** One page edit or one `Docs-Checked` trailer anywhere in a pull request clears every matching change in it, in any commit. Only the local hook checks commit by commit, because it runs with `--since HEAD~1`.
- **Trailers are read from every line of every commit message in the range**, not only from the trailer block at the end. A squash merge writes one new message, so it must keep the `Docs-Checked` lines, or the check on the push to `main` fails.
- **A bad trailer can't be fixed with a new commit.** A `Docs-Checked` line that names no guide page or has no reason fails CI. The bad line stays in the range, so once the commit is pushed the only fix is to reword that commit, which rewrites the branch's history.
- **The hook may not find FVM.** It looks for FVM with `command -v fvm` in Git's `sh`. On Windows, FVM installed with `dart pub global activate fvm` is an `fvm.bat` file, which that lookup doesn't find, so the hook falls back to plain `dart`, whichever SDK that is on your PATH (or skips the check when `sh` finds no `dart` either).
- **The graph check sees content, not history.** If extractions of both an old and a new version of a doc are cached, for example after switching between branches that differ in it, the check can't tell which version the graph holds. A full `/graphify .` settles it; it reuses cached extractions, so it costs little.
- **The graph hook looks only in `graphify-out/`.** With graphify's `GRAPHIFY_OUT` pointing at another folder, the hook finds no graph and stays silent. Run the check by hand with the same variable set.
- **The repair trusts the cache.** It puts back the newest cached extraction of the doc's current content. When several agents extracted the same content, the newest one wins.
- **A doc whose extraction is only a node for the doc itself** can't be told from a doc graphify only scanned for headings: graphify's heading node has the same id and wins. The check counts such a doc as in the graph, since there is nothing to put back.
- **A full `/graphify . --update` can look like a missing doc.** It merges near-duplicate entities and may rewrite ids. A doc whose every added id was merged into another doc's node can then be reported `missing from the graph`, and the repair would add the duplicates back. Not seen in this repo.
- **The repair uses graphify's private functions** (`_rebuild_lock`, `_rebuild_code`, `_reconcile_existing_graph`, `_drain_pending`, and the cache readers `_semantic_entry_matches_path` and `_absolutize_ids_in`) and copies graphify's rule for telling its heading nodes apart. CI's tests pin the graphify version (`GRAPHIFY_VERSION`). A graphify release that changes the functions makes the repair say `could not repair the graph`, never report a repair it didn't make. If graphify changed its tier rule, the check could miss docs; CI's pinned tests catch that.
- **A commit during a repair waits for the next rebuild.** The repair holds graphify's lock for a few seconds. graphify skips a rebuild that starts meanwhile, as it does whenever two overlap. A commit's rebuild queues its changes, and the next rebuild picks them up, usually the next commit's. A branch switch meanwhile starts a repair of its own, which rebuilds after it.
- **The extra rebuild can overlap an agent's `/graphify . --update`.** The background repair's rebuild (about 20 s after a merge) can interleave with an agent's `/graphify . --update`, which doesn't take graphify's lock. graphify's own hooks share this risk.
- **The background repair reports only to the log.** If it fails, the terminal doesn't show it. The next commit's warning names any doc still missing, and the `[appstein]` lines in `~/.cache/graphify-rebuild.log` say why.
- **A branch from before the repair** (slice 1a.3) has a `check_graph.py` without `--detach`. The `post-checkout` hook skips the repair there, and the next pull or checkout of a newer branch runs it.
- **Progress is only as true as its last edit.** The check proves the page matches the file and the file agrees with the plans and §18. It can't tell that a slice marked `next` is really being built, or that a summary is accurate.
