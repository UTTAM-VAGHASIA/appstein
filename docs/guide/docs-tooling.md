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

Rules, from [`generated_sections.dart`](../../tool/src/generated_sections.dart) and [`generated_docs.dart`](../../tool/src/generated_docs.dart):

- **Sections go only in pages directly in `docs/guide/`.** Generated links are written relative to that folder, so they would break in a subfolder such as `how-to/`.
- **A section that no page shows is an error**, so no generated fact goes unshown. An unknown section name is an error too.
- Markers inside a code fence are examples and are left alone. A page's line endings (LF or CRLF) are kept.
- If a generator can't run, for example because a check has no doc comment or `ci.yml` is malformed, that is reported as a problem naming the file, not a crash.

**Why doc comments are read as text.** [`doc_comments.dart`](../../tool/src/doc_comments.dart) reads `///` lines straight from the source instead of parsing it with `package:analyzer`. When this was measured on the development machine, importing the analyzer made a `dart run` of such a tool take about 8.8 s instead of about 2.2 s, and the hook runs the check on every commit. `dart format` keeps doc comments in a layout that simple reading handles.

## Commands

Run both from the repo root.

| Command | What it does |
|---|---|
| `fvm dart run tool/gen_docs.dart` | Rewrites every out-of-date generated section and prints `Updated <page>` for each |
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

Every check reads Markdown through [`markdown.dart`](../../tool/src/markdown.dart), which tracks code fences and picks out links to files. Anything inside a fence (a link, a path, a covers comment, a marker) is an example and is skipped.

Exit codes, for both tools:

| Code | Meaning |
|---|---|
| `0` | Passed |
| `1` | Problems found. For `gen_docs`: a section is out of date (with `--check`), or a marker, section name or generator has a problem |
| `3` | The tool couldn't run: bad usage, or (for `check_guide`) a git command failed, for example outside a git repo |

`--since` with a revision that isn't a commit is reported as a problem (exit 1). With `--warn-only`, `check_guide` exits 0 whatever it finds, and when it can't run at all it prints one line, `warning: the guide check could not run: <error>`. Only bad usage still exits 3.

## Is the graph current?

graphify's knowledge graph (`graphify-out/`) has two layers. graphify's own hooks rebuild the code structure after every commit, checkout, merge and rebase. What the docs mean is extracted by an LLM, and that only happens when someone runs `/graphify . --update`. So after a doc changes, the graph describes the old version until the command runs again, and the hooks don't say so: `GRAPH_REPORT.md` still reports the latest commit.

[`check_graph.py`](../../tool/check_graph.py) closes that gap. It runs with graphify's own Python, because it is made of graphify calls, and takes about half a second. It lists the files graphify treats as docs with graphify's own `detect`, so `.graphifyignore` and `.gitignore` apply, and reports three kinds of problem:

| Reason | Meaning |
|---|---|
| `new or changed` | No extraction of the doc's current content is cached. graphify keys its cache by a hash of the content and the path, so any edit counts. |
| `missing from the graph` | An extraction is cached, but `graph.json` has no node from the doc: an update stopped before merging it. |
| `deleted or no longer scanned` | `graph.json` still has nodes from a doc that graphify no longer scans, because the file was deleted or is now ignored. Code files are left out, because graphify's hooks prune them. |

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
| `0` | The graph is current. It prints how many docs it checked, or nothing with `--quiet` (the hooks use it) |
| `1` | Docs are behind |
| `3` | The check couldn't run: there is no graph yet, graphify can't be imported, or a graphify release changed the functions the check calls. It prints `graphify: the graph check could not run: <reason>`. An option other than `--quiet` also exits 3, with a usage line on stderr |

**Why it isn't in CI.** CI has no graph: `graphify-out/` is git-ignored and built on each developer's machine. CI does test the script against a pinned graphify (see [ci](ci.md)). The rule lives in the per-slice process instead: before a slice merges, this check must report nothing ([spec §19.4](../superpowers/specs/2026-09-29-appstein-design.md#194-git-and-process)).

## Git hooks

`fvm dart run tool/install_hooks.dart` sets up the repo's hooks. Run it once per clone. It:

1. runs `graphify hook install` when `graphify` is on your PATH. That installs graphify's `post-commit` and `post-checkout` graph rebuilds. Without graphify it prints how to install it (`uv tool install graphifyy`) and skips this step;
2. adds our own block to `post-commit`, `post-merge` and `post-rewrite`, from [`hooks.dart`](../../tool/src/hooks.dart). The block sits between `# appstein-hook-start` and `# appstein-hook-end`. An older block is replaced in place; everything else in the file, such as graphify's block, is kept.

What each block does:

| Hook | What our block does |
|---|---|
| `post-commit` | Runs `check_guide.dart --since HEAD~1 --warn-only` through `fvm dart`, or `dart` if there's no `fvm`. It skips during a rebase, on the first commit, when `tool/check_guide.dart` doesn't exist, or when `APPSTEIN_SKIP_DOCS_HOOK=1`. It only warns, and always exits 0. Then it runs the graph check (below). |
| `post-merge` | graphify's hooks miss merges and pulls. This block runs graphify's `post-checkout` hook as if HEAD had switched from `ORIG_HEAD`, so the graph is rebuilt. Then it runs the graph check. |
| `post-rewrite` | The same, but only after a rebase. graphify's `post-commit` already covers an amend. |

**The graph check in each block** runs [`check_graph.py`](../../tool/check_graph.py) `--quiet` with the Python named in `graphify-out/.graphify_python`, a file graphify writes on each `/graphify` run. It prints nothing when the graph is current, and one line when it isn't:

- It is skipped when there's no `tool/check_graph.py` or no `graphify-out/graph.json` (a clone where graphify was never run), during a rebase (`post-rewrite` checks once at the end), or when `APPSTEIN_SKIP_GRAPH_HOOK=1`.
- If `.graphify_python` is missing or names a file that isn't there or isn't executable, it prints `graphify: the graph check could not run: …` instead.
- It never stops the hook: the other parts of the block, and graphify's block, still run.

**Why tiny `sh` blocks.** Git runs every hook with its own `sh`, on Windows too, so a hook must be a shell script. Each part of a block is a few lines that call a tested Dart tool, graphify's own hook, or (for the graph) a tested Python script made of graphify calls, so the logic stays in tested code. Each part runs in a `( … )` subshell, so its `exit` can't stop another part or another block in the same file. (The `AGENTS.md` rule "no bash scripts" is about the hooks Appstein will install for agents, not these.)

**Switches:**

- `APPSTEIN_SKIP_DOCS_HOOK=1` skips the docs warning. In PowerShell, for one commit:
  ```powershell
  $env:APPSTEIN_SKIP_DOCS_HOOK = '1'; git commit -m "wip"; Remove-Item Env:APPSTEIN_SKIP_DOCS_HOOK
  ```
- `APPSTEIN_SKIP_GRAPH_HOOK=1` skips the graph warning, the same way.
- `GRAPHIFY_SKIP_HOOK=1` is graphify's own switch. It skips graphify's rebuilds, and so our merge and rebase replays, which go through graphify's `post-checkout` hook.
- `fvm dart run tool/install_hooks.dart --remove` takes our blocks out and leaves graphify's. `graphify hook uninstall` removes graphify's.
- Re-run the installer whenever `tool/src/hooks.dart` changes. It is safe to run again: unchanged hooks are reported as `up to date`.

**The cost.** graphify rebuilds in the background, so it doesn't slow a commit. The docs check does: it takes a few seconds (about 2.7 s on the development machine) after each commit. That cost is why doc comments are read as text, not with the analyzer. The graph check adds about half a second after a commit, merge or rebase.

## The docs step of each slice

1. `fvm dart run tool/gen_docs.dart`
2. `fvm dart run tool/check_guide.dart --since main`
3. `/graphify . --update`, then the [graph check](#is-the-graph-current), until it reports nothing. The hooks rebuild only the code structure, not what the docs mean.

Any edit after step 3, such as a review fix, puts the graph behind again, and the hook says so. The check must still report nothing when the slice merges. This is the docs step of the per-slice process in [`AGENTS.md`](../../AGENTS.md).

## Limits

- The check proves that a page was touched or confirmed, not that it is good. A one-word edit satisfies it. Review still matters.
- It can't tell whether hand-written text is true. Only the generated sections are right by construction, which is why facts the code knows are generated.
- Links are checked to the file, not to the heading after `#`.
- **A regenerated section counts as the page changing.** When a change alters a fact that `gen_docs` writes, the page's diff clears the stale check for every file that page covers. Read the page's hand-written text too.
- **The check looks at the whole range at once.** One page edit or one `Docs-Checked` trailer anywhere in a pull request clears every matching change in it, in any commit. Only the local hook checks commit by commit, because it runs with `--since HEAD~1`.
- **Trailers are read from every line of every commit message in the range**, not only from the trailer block at the end. A squash merge writes one new message, so it must keep the `Docs-Checked` lines, or the check on the push to `main` fails.
- **A bad trailer can't be fixed with a new commit.** A `Docs-Checked` line that names no guide page or has no reason fails CI. The bad line stays in the range, so once the commit is pushed the only fix is to reword that commit, which rewrites the branch's history.
- **The hook may not find FVM.** It looks for FVM with `command -v fvm` in Git's `sh`. On Windows, FVM installed with `dart pub global activate fvm` is an `fvm.bat` file, which that lookup doesn't find, so the hook falls back to plain `dart`, whichever SDK that is on your PATH (or skips the check when `sh` finds no `dart` either).
- **The graph check sees content, not history.** If extractions of both an old and a new version of a doc are cached, for example after switching between branches that differ in it, the check can't tell which version the graph holds. A full `/graphify .` settles it; it reuses cached extractions, so it costs little.
- **The graph hook looks only in `graphify-out/`.** With graphify's `GRAPHIFY_OUT` pointing at another folder, the hook finds no graph and stays silent. Run the check by hand with the same variable set.
