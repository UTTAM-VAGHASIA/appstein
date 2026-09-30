# Slice 1a.3: Graph Self-Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Whenever a git operation makes graphify's code rebuild drop a doc's semantic nodes, put them back from graphify's cache by themselves, with no LLM and no manual step, whoever runs git.

**Why this slice exists (the incident, 2026-10-01):** merging PR #4 with `gh pr merge --delete-branch` switched the checkout from `slice-1b1` to the *old* local `main`, which lacked files that were new on the branch, then pulled. graphify's `post-checkout` hook started a background code rebuild on the old `main`. graphify's `_reconcile_existing_graph` drops the nodes of any non-code source that isn't on disk, so the 1b.1 plan's semantic nodes (and the new code files' nodes) were pruned. The pull brought the files back, and our `post-merge` block replayed graphify's rebuild, which restored the code. But a hook can't rebuild semantic doc nodes (that needs an LLM), so the plan stayed "missing from the graph", although its extraction was still in graphify's cache. `tool/check_graph.py` (slice 1a.2) caught it, and the controller repaired it by hand by re-merging the cached extraction. The owner wants this never to need manual action again.

**Architecture:**
- **`tool/check_graph.py --repair`** puts every doc that is `missing from the graph` back. Under graphify's own rebuild lock, it runs **graphify's own full code rebuild** (`graphify.watch._rebuild_code`) with the docs' newest cached extractions added to what the rebuild keeps from the existing graph. It adds them by wrapping `graphify.watch._reconcile_existing_graph` for the duration of the call. graphify then finishes the graph exactly as its hook rebuild does: it clusters, remaps communities to the previous numbers, keeps saved labels whose membership signature still matches, names the rest by hub, and writes the report, `graph.html`, the manifest and `built_at_commit`. No LLM runs.
- **`--detach` / `--after-rebuild`**: the hooks start the repair in a detached background process. That process waits for graphify's rebuild from the same git operation to finish, then runs the repair plus one more code rebuild (decision D1), and writes only to graphify's rebuild log with an `[appstein]` prefix.
- **Hooks** (`tool/src/hooks.dart`): a new `post-checkout` block starts the background repair on branch switches. Our `post-merge` and `post-rewrite` blocks already replay `post-checkout`, so they start it too. They now set `APPSTEIN_HOOK_REPLAY=1` so the repair also runs after a rebase. The foreground warning after a merge or rebase runs with `--skip-repairable`: docs the job will repair get one calm line instead of "Run /graphify . --update".
- **The check's definition of `missing from the graph` is fixed** (finding F1 below). A doc counts as in the graph only when `graph.json` holds a node its cached extraction adds, not merely any node whose `source_file` is the doc.

**Tech Stack:** Dart 3.13.4 via Flutter 3.47.5 (FVM), `test`, `path`; Python 3.11 with graphify (`graphifyy` 0.9.71 on the development machine and pinned in CI); git's own `sh` for hooks.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md` §19.1 and §19.6. Task 3 changes the §19.6 bullet, but only to wording the owner approved (proposal D2 below). §19.1's wording stays.

## Proof: the scratch experiment (2026-10-01)

Everything below was run before this plan was written: against graphify 0.9.71 (Python 3.11.14, Windows 11), in a `git clone` of this repo at `5dd1d42` with a copy of the real `graphify-out/`, in a folder named `rëpo x`. The real `graphify-out/` was not touched. The code in Tasks 1 and 2 is the code that passed there.

1. **Baseline.** graphify's hook rebuild (`_rebuild_code(Path('.'))`, `PYTHONHASHSEED=0`) took 3.1 s and gave 2162 nodes, 2750 links, 21 hyperedges and 173 communities.
2. **The incident, replayed.** A rebuild with `docs/superpowers/plans/2026-09-30-slice-1a2-graph-staleness.md` and `docs/superpowers/specs/2026-09-29-appstein-design.html` moved away dropped both docs' nodes. Putting them back and rebuilding gave the plan **10 AST heading nodes and none of its 20 semantic nodes**, and the `.html` nothing.
3. **Finding F1 (a 1a.2 false negative).** The 1a.2 check then named only the `.html`. The heading nodes carry the plan's `source_file`, so it called the plan "in the graph". One heading node even has the same id as the extraction's node for the doc itself, so a naive "any cached id is in the graph" rule misses it too. The rule that works: ignore the ids of AST-tier nodes, then ask whether any id the extraction adds is in the graph. On the real repo this rule reports `the graph is current (54 docs checked)`, with no false alarms (docs such as `CLAUDE.md`, whose extraction is only the doc node, count as present).
4. **`--repair`**, 4.2 s including its restart with the hash seed, printed `graphify: repaired 2 docs from the cache (…)`. Compared with the baseline: the same 2162 node ids, identical hyperedges, and the same links (26 are written with their endpoints the other way round, as the graph is undirected). Every node has a community. 137 of the 155 saved labels were kept and the rest were named by hub (graphify's own rule). A second `--repair` printed `nothing to repair.` graphify's next hook rebuild printed `No code-graph topology changes detected; outputs left untouched.`
5. **Why not merge into graph.json first, then rebuild.** The obvious route writes a merged `graph.json` with `build_merge`, then calls `_rebuild_code`. It hits graphify's unchanged-topology fast path (`watch.py` L2069-2103): the topology compare ignores `community`, so the new nodes would keep no community and the report would not be rewritten. `changed_paths=[]` doesn't work either: it returns before reconcile (`No tracked code files in change set`). Injecting at reconcile makes graphify see a changed topology and run its whole tail. The shrink guard passes because the graph grows.
6. **Background.** `--detach` returned in 0.17 to 0.19 s and printed nothing. The job waited for graphify's rebuild (which ran from 21.3 to 24.7 s), then repaired.
7. **Finding F2 (log clobbering).** Passing the log to the child as its stdout handle made the child write at the offset the handle had when `--detach` opened it. That overwrote graphify's rebuild lines written in between. Now `--after-rebuild` opens the log itself in append mode, and the detached process gets `DEVNULL` handles. A test pins this.
8. **End to end with real hooks** (graphify's real `post-checkout` plus our blocks, through `core.hooksPath` in the clone, `HOME` in scratch):
   - `git switch` to a branch that lacks the plan: dropped.
   - `git merge --ff-only` back: the terminal printed `graphify: repairing 1 doc from the cache in the background (docs/superpowers/plans/2026-09-30-slice-1a2-graph-staleness.md).` Within about 10 s the plan had its 10 heading and 20 semantic nodes again, and the log held graphify's lines and ours.
   - `git rebase` onto the branch with the plan: graphify's replayed rebuild **did not run** (F3). The job's own rebuild, after its 20 s wait, restored the plan.
9. **Finding F3 (1a.2's replays skip).** In a scratch repo: during `post-rewrite`, `.git/rebase-merge` (or `rebase-apply` with `--apply`) still exists. During `post-merge` after a real merge commit, `MERGE_HEAD` still exists. graphify's `post-checkout` block exits early on both, so 1a.2's replays rebuild only after a fast-forward merge. Our `post-checkout` block would skip on the rebase folder too, hence `APPSTEIN_HOOK_REPLAY=1`. Decision D1 covers graphify's side.
10. **Tests.** Tasks 1 and 2's tests (25 in `check_graph_test.dart`, 18 in `hooks_test.dart`) and all 134 root tests pass in the clone against real graphify. `analyze` and `format` are clean. `check_graph_test.dart` takes about 55 s.
11. **Cost.** Importing `graphify.build` (for `_is_ast_tier`) added 0.19 s to every check. The script copies graphify's tier rule instead, and the check stays at about 0.48 s on the real repo, as in 1a.2.

## Decisions (settled 2026-10-01)

The owner delegated this mini-slice ("Don't wait for my approval, just complete this mini slice by yourself", 2026-10-01), so the controller decided these under that delegation: **D1 accepted; D2's wording (with D1) approved verbatim; F1's stricter rule accepted; the choices below accepted.**

- **D1 (accepted): the background job always runs graphify's code rebuild, even when no doc is missing.**
  - **Why:** graphify's hook skips its rebuild during a merge commit and a rebase (F3), and whenever another rebuild still holds the lock. For example, `gh pr merge` switches branches and then pulls a moment later. Without D1, the code graph stays at the pre-merge or pre-rebase state until the next commit, and spec §19.1's existing sentence "Git hooks rebuild its code structure on each commit, checkout, merge and rebase" stays untrue for those cases. D1 makes it true.
  - **Cost:** one more background rebuild per branch switch, merge or rebase: about 3 s, or about 2.3 s when nothing changed.
  - **If rejected:** in Task 1, change `rebuild=True` to `rebuild=False` in `_after_rebuild`, delete the test `--after-rebuild rebuilds the code when graphify's hook did not`, drop the sentences marked **[D1]** in Task 1 Step 7, and use D2's shorter variant.
- **D2: spec §19.6 wording.** Replace the `- **CI is the gate; local hooks warn early.** …` bullet with, verbatim (with D1):

  ```markdown
  - **CI is the gate; local hooks warn early.** `tool/install_hooks.dart` installs the repo's git hooks: graphify's code rebuild (on commit, checkout, merge and rebase), a post-commit warning when a page is stale or a generated section is out of date, and a graph warning after each commit, merge and rebase naming the docs whose current content isn't in the graph (new, changed or deleted). After each checkout, merge and rebase, a background job waits for graphify's rebuild, rebuilds the code structure once more, and puts back, from graphify's cache and without an LLM, any doc a rebuild dropped from the graph although its extraction is cached; the warning reports those as being repaired and names only what needs `/graphify . --update`. CI can't check the graph because it doesn't have one, so the per-slice rule (§19.4) keeps that warning silent before a merge.
  ```

  Without D1, drop `, rebuilds the code structure once more,` (the sentence then reads "…waits for graphify's rebuild and puts back, from…"). §19.1 is unchanged either way. `2026-09-29-appstein-design.html` makes no claim about the hooks (its one graphify line, 814, is about who the graph serves), so it doesn't change.
- **Choices made here (tell the owner; no approval needed):**
  - The merge and rebase warning prints one calm line, `graphify: repairing N docs from the cache in the background (…)`, instead of leaving those docs out silently. Silence would hide a background write to the graph and leave nothing to look for if it failed. Asking for `/graphify . --update` would send the owner to an LLM run that isn't needed.
  - `GRAPHIFY_SKIP_HOOK=1` also turns the repair off. The repair rebuilds the graph, and that switch means "hooks, leave the graph alone". The merge and rebase check then asks for the update as before.
  - A branch from before 1a.3 has a `check_graph.py` without `--detach`. The `post-checkout` block skips it (a `grep` guard) instead of printing a usage error on checkout.

## Global Constraints

- **Tooling:** run every Dart command through FVM (`fvm dart …`). The repo pins Flutter **3.47.5** in `.fvmrc`. The `dart` on your PATH may be an older SDK; never use it.
- **graphify's Python** on the development machine: the path in `graphify-out/.graphify_python` (currently `C:\Users\<you>\AppData\Roaming\uv\tools\graphifyy\Scripts\python.exe`, Python 3.11.14, graphifyy 0.9.71).
- **Never run `--repair`, `--after-rebuild` or a graphify rebuild against a copy of the real graph you care about by accident.** In the real repo, `--repair` with a current graph only reads it (`nothing to repair.`). The tests work in temp repos.
- **Windows is first-class:** paths with spaces and non-ASCII characters must work, in the repo path, the interpreter path and the log path. Git hooks are `sh`, because git runs every hook through the `sh` it ships, on Windows too.
- **Output is UTF-8.** The script reconfigures stdout and stderr to UTF-8. On Windows, Python writes `\r\n` between lines; tests normalize it.
- **Never fail git.** Every hook part runs in a `( … )` subshell and exits 0. The background job never prints to the terminal and never holds git's pipes.
- **graphify's private APIs** (`graphify.watch._rebuild_lock`, `_rebuild_code`, `_reconcile_existing_graph`, `_drain_pending`, `graphify.cache.file_hash`, `graphify.detect.*`, `graphify.paths.GRAPHIFY_OUT`, the cache layout, and the tier rule copied from `graphify.build._is_ast_tier`) are pinned by CI's `GRAPHIFY_VERSION` (`0.9.71`). Any drift must surface as `graphify: the graph check could not run: …` or `graphify: could not repair the graph: …` with exit 3, never a traceback or a silent success.
- **No API keys, no network, no LLM** in the script or its tests.
- **Commits:** only the controller (main session) commits. Subagents never commit. Commit messages end with the session's `Co-Authored-By` and `Claude-Session` trailers.
- **Guide rules (spec §19.6):** a change to a covered file changes a covering page **in the same task** (`tool/check_graph.py` and `tool/src/hooks.dart` are covered by `docs/guide/docs-tooling.md`; `test/support/**` by `docs/guide/testing.md`). `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`, must pass at the end. No ```` ```dart ```` blocks in the guide.
- **Every public Dart member** gets a `///` doc comment. `fvm dart analyze --fatal-infos` and `fvm dart format --output=none --set-exit-if-changed .` stay clean. No new Dart dependencies.

## Review Focus

1. **A git operation run by anyone** (the owner, GitHub's merge button then `git pull`, `gh pr merge`, an agent's rebase) **that drops a doc and brings it back.** The doc should be back with no action. Pinned by Task 2's replay and rebase hook tests, Task 1's `--detach`/`--after-rebuild` tests, and Task 4's live proof on this slice's own merge.
2. **Paths with spaces or non-ASCII characters** in the repo, the interpreter or the log (for example `C:\Users\Jöhn Doe\.cache`). Expect it to work and print UTF-8. Pinned by the temp repos (`tëst`), the fake Python named `fake python`, and the log file `rebuild log.txt` in a `tëst` folder.
3. **A rebuild already running** (graphify's hook, or anything holding `.rebuild.lock`). The repair waits and never runs alongside it. Pinned by Task 1's lock-holder test and lock-file test.
4. **A graphify upgrade that changes what the repair calls.** Expect one `could not repair the graph` line and exit 3, and never "repaired" when nothing was. Pinned by Task 1's shadowing-package test and the `sitecustomize.py` test.
5. **The background job and the terminal or the log.** It prints nothing, doesn't hold git's pipes, and appends to graphify's log without overwriting it. Pinned by Task 1's `--detach` test (the "rebuilt meanwhile" line must survive) and Task 2's "silently" hook test.

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `tool/check_graph.py` | Rewrite | The check (with the F1 rule), `--repair`, `--skip-repairable`, `--detach`, `--after-rebuild` |
| `test/support/graphify_fixture.py` | Rewrite | Fake extractions (ids as real ones), `--only-heading`, `--build` (graphify's own code rebuild) |
| `test/check_graph_test.dart` | Rewrite | Check tests (updated), repair tests against real graphify builds |
| `tool/src/hooks.dart` | Modify | `post-checkout` repair block, replay variable, `--skip-repairable` after merge and rebase |
| `test/hooks_test.dart` | Rewrite | The new block, the replay variable, skip rules |
| `docs/guide/docs-tooling.md` | Modify | Tasks 1 and 2: the check, "Repairing the graph", hooks, switches, cost, limits |
| `docs/guide/testing.md` | Modify | Tasks 1 and 2: how the new tests work |
| `docs/guide/debugging.md`, `docs/guide/README.md`, `docs/guide/ci.md`, `AGENTS.md`, the spec | Modify | Task 3 |

---

### Task 1: `check_graph.py` repairs the graph

**Files:**
- Rewrite: `test/support/graphify_fixture.py`
- Rewrite: `test/check_graph_test.dart`
- Rewrite: `tool/check_graph.py`
- Modify: `docs/guide/docs-tooling.md` (the `## Is the graph current?` section, a new `## Repairing the graph` section, `## Limits`)
- Modify: `docs/guide/testing.md` (the `**The graph check runs against real graphify.**` paragraph)

**Interfaces:**
- Produces: `tool/check_graph.py [--quiet] [--skip-repairable] | --repair | --detach | --after-rebuild`, run from the repo root with graphify's Python.
- Check lines (unchanged from 1a.2): `graphify: the graph is current (<n> doc|docs checked).`, `graphify: the graph is behind on <n> doc|docs (<reason>: <names>; …). Run /graphify . --update before relying on it.`, `graphify: the graph check could not run: <reason>`.
- New lines, exactly:
  - `graphify: repairing <n> doc|docs from the cache in the background (<names>).` (`--skip-repairable`)
  - `graphify: repaired <n> doc|docs from the cache (<names>).`
  - `graphify: nothing to repair.`
  - `graphify: could not repair the graph: <reason>`, where `<reason>` includes `graphify's rebuild failed.[ It said: <graphify's last line>]` and `graphify's rebuild didn't put back <names>.[ It said: …]`
  - `graphify: the background graph repair could not start: <reason>` (`--detach` only)
  - usage (stderr): `usage: check_graph.py [--quiet] [--skip-repairable] | --repair | --detach | --after-rebuild (not understood: <args>)`
- Exit codes: `0` current (with `--skip-repairable`, apart from docs being repaired; for `--repair`, nothing else behind); `1` docs behind; `3` couldn't run, couldn't repair, or bad usage. `--detach` exits 0 once started.
- `--after-rebuild` writes only to the log: `GRAPHIFY_REBUILD_LOG`, else `$HOME/.cache/graphify-rebuild.log` (else `~`). Each line is `[appstein] YYYY-MM-DD HH:MM:SS <line>`. Waits: `APPSTEIN_REPAIR_START_WAIT` (seconds, default 20) and `APPSTEIN_REPAIR_MAX_WAIT` (default 660).
- Task 2 consumes `--detach` and `--quiet --skip-repairable`.

- [ ] **Step 1: Rewrite the fixture**

`test/support/graphify_fixture.py`:

```python
"""Test fixture: fakes what graphify does, with graphify's own code.

Run it with graphify's Python, from the fixture repo's root:

    graphify_fixture.py <prompt text> [--partial] [--deep] [--only-heading] <doc>...
    graphify_fixture.py --build

The first form caches a fake semantic extraction of the docs, the way
`/graphify . --update` would, with graphify's cache writer. Each doc gets a
node for the doc itself, whose id is the one graphify's code rebuild gives the
doc's own heading node (as in real extractions), and a concept node,
`<id>_concept`, unless --only-heading. The prompt text picks the
p<fingerprint> cache folder, as each agent's extraction prompt does.
--partial marks the entries as cut short; --deep writes them in deep mode's
cache.

--build runs graphify's code rebuild, as its git hooks do. It keeps what
graph.json holds from docs that are still on disk, and drops the rest.
"""

import re
import sys
from pathlib import Path


def doc_id(doc: str) -> str:
    """The id graphify gives a doc's own heading node: the path without its
    extension, lowercased, with every run of other characters as one '_'."""
    stem = doc.rsplit('.', 1)[0]
    return re.sub(r'[^0-9a-z]+', '_', stem.lower()).strip('_')


def extract(argv):
    from graphify.cache import save_semantic_cache

    prompt, *rest = argv
    docs = [a for a in rest if not a.startswith('--')]
    root = Path.cwd()
    paths = [str(root / d) for d in docs]
    nodes, edges = [], []
    for doc in docs:
        nodes.append({'id': doc_id(doc), 'label': doc, 'file_type': 'document',
                      'source_file': doc})
        if '--only-heading' in rest:
            continue
        concept = doc_id(doc) + '_concept'
        nodes.append({'id': concept, 'label': f'Concept of {doc}',
                      'file_type': 'concept', 'source_file': doc})
        edges.append({'source': doc_id(doc), 'target': concept,
                      'relation': 'mentions', 'confidence': 'EXTRACTED',
                      'source_file': doc, 'weight': 1.0})
    save_semantic_cache(
        nodes, edges, [], root=root, allowed_source_files=paths,
        mode='deep' if '--deep' in rest else None, prompt=prompt,
        partial_source_files=paths if '--partial' in rest else None)


def build():
    from graphify.watch import _rebuild_code

    if not _rebuild_code(Path('.'), block_on_lock=True):
        sys.exit('graphify_fixture.py: the rebuild failed')


if __name__ == '__main__':
    if sys.argv[1:] == ['--build']:
        build()
    else:
        extract(sys.argv[1:])
```

- [ ] **Step 2: Write the failing tests**

`test/check_graph_test.dart` (the whole file):

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/graphify.dart';
import 'support/temp_repo.dart';

final _script = p.absolute('tool', 'check_graph.py');
final _fixture = p.absolute('test', 'support', 'graphify_fixture.py');

const _update = 'Run /graphify . --update before relying on it.';
const _usage =
    'usage: check_graph.py [--quiet] [--skip-repairable] | --repair | '
    '--detach | --after-rebuild';

/// Holds graphify's rebuild lock for `argv[1]` seconds, as a running
/// rebuild does, and says when it has it and when it let go.
const _holdLock = '''
import sys, time
from pathlib import Path
from graphify.watch import _rebuild_lock
with _rebuild_lock(Path('graphify-out'), blocking=True):
    print('held', flush=True)
    time.sleep(float(sys.argv[1]))
print('released', flush=True)
''';

/// The id graphify gives [doc]'s own heading node, as graphify_fixture.py
/// computes it.
String _docId(String doc) => doc
    .replaceFirst(RegExp(r'\.[^./]*$'), '')
    .toLowerCase()
    .replaceAll(RegExp('[^0-9a-z]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

void main() {
  late String python;
  late Directory repo;

  /// The environment for graphify's Python: without the caller's
  /// `GRAPHIFY_OUT`, `PYTHONPATH`, `PYTHONHASHSEED` or
  /// `GRAPHIFY_REBUILD_LOG`, which would move the graph, shadow graphify,
  /// skip the script's own seeding or write to the caller's log.
  Map<String, String> environment(Map<String, String> extra) => {
    for (final entry in Platform.environment.entries)
      if (!const {
        'GRAPHIFY_OUT',
        'PYTHONPATH',
        'PYTHONHASHSEED',
        'GRAPHIFY_REBUILD_LOG',
      }.contains(entry.key.toUpperCase()))
        entry.key: entry.value,
    ...extra,
  };

  /// Runs graphify's Python in [repo].
  ProcessResult runPython(
    List<String> arguments, {
    Map<String, String> extra = const {},
  }) => Process.runSync(
    python,
    arguments,
    workingDirectory: repo.path,
    environment: environment(extra),
    includeParentEnvironment: false,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );

  /// Starts graphify's Python in [repo], for a test that runs it alongside
  /// something else.
  Future<Process> startPython(
    List<String> arguments, {
    Map<String, String> extra = const {},
  }) => Process.start(
    python,
    arguments,
    workingDirectory: repo.path,
    environment: environment(extra),
    includeParentEnvironment: false,
  );

  /// Fakes `/graphify . --update` extracting [docs] with [prompt].
  void extract(
    String prompt,
    List<String> docs, {
    List<String> flags = const [],
  }) {
    final result = runPython([_fixture, prompt, ...flags, ...docs]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  /// Writes a graph.json with the concept node the fixture extracts from
  /// each of [docs] (its source written as in [sources], if given), and
  /// [more] nodes.
  void graph(
    List<String> docs, {
    Map<String, String> sources = const {},
    List<Map<String, String>> more = const [],
  }) => writeFile(
    repo,
    'graphify-out/graph.json',
    jsonEncode({
      'nodes': [
        for (final doc in docs)
          {'id': '${_docId(doc)}_concept', 'source_file': sources[doc] ?? doc},
        ...more,
      ],
      'links': <Object>[],
    }),
  );

  /// Runs the script with [arguments] and returns its exit code and what it
  /// printed, with Windows line endings as `\n`.
  ({int code, String output}) check([
    List<String> arguments = const [],
    Map<String, String> extra = const {},
  ]) {
    final result = runPython([_script, ...arguments], extra: extra);
    return (
      code: result.exitCode,
      output: '${result.stdout}${result.stderr}'
          .replaceAll('\r\n', '\n')
          .trim(),
    );
  }

  setUp(() {
    python =
        graphifyPython ??
        fail(
          'APPSTEIN_REQUIRE_GRAPHIFY=1, but no Python with graphify was found',
        );
    repo = tempRepo();
    writeFile(repo, '.gitignore', 'graphify-out/\n');
    writeFile(repo, 'docs/a.md', '# A\n\nalpha\n');
    writeFile(repo, 'docs/b.md', '# B\n\nbeta\n');
    writeFile(repo, 'lib/c.dart', 'void main() {}\n');
  });

  group('with graphify', skip: skipWithoutGraphify, () {
    void upToDate() {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(['docs/a.md', 'docs/b.md', 'lib/c.dart']);
    }

    test('says the graph is current, or nothing with --quiet', () {
      upToDate();
      expect(check(), (
        code: 0,
        output: 'graphify: the graph is current (2 docs checked).',
      ));
      expect(check(['--quiet']), (code: 0, output: ''));
    });

    test('names a changed doc and a new doc', () {
      upToDate();
      writeFile(repo, 'docs/b.md', '# B\n\nbeta, changed\n');
      writeFile(repo, 'docs/n.md', '# N\n\nnew\n');
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 2 docs (new or changed: '
            'docs/b.md, docs/n.md). $_update',
      ));
    });

    test('counts an extraction made with any prompt', () {
      upToDate();
      writeFile(repo, 'docs/b.md', '# B\n\nbeta, changed\n');
      extract('another agent prompt', ['docs/b.md']);
      expect(check().code, 0);
    });

    test('counts a deep-mode extraction', () {
      extract('prompt one', ['docs/a.md']);
      extract('prompt one', ['docs/b.md'], flags: ['--deep']);
      graph(['docs/a.md', 'docs/b.md']);
      expect(check().code, 0);
    });

    test('treats a partial extraction as missing', () {
      extract('prompt one', ['docs/a.md']);
      extract('prompt one', ['docs/b.md'], flags: ['--partial']);
      graph(['docs/a.md', 'docs/b.md']);
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (new or changed: '
            'docs/b.md). $_update',
      ));
    });

    test('names a doc that is extracted but missing from the graph', () {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(['docs/a.md']);
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (missing from the graph: '
            'docs/b.md). $_update',
      ));
    });

    test("doesn't count graphify's heading node as the doc's extraction", () {
      // A code rebuild adds heading nodes for a Markdown doc, one with the
      // id the extraction gives the doc itself.
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(
        ['docs/a.md'],
        more: [
          {'id': 'docs_b', 'source_file': 'docs/b.md', '_origin': 'ast'},
        ],
      );
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (missing from the graph: '
            'docs/b.md). $_update',
      ));
    });

    test('counts a doc whose extraction is only its heading node as in the '
        'graph', () {
      // Nothing could be put back: the heading node wins.
      extract('prompt one', ['docs/a.md'], flags: ['--only-heading']);
      extract('prompt one', ['docs/b.md']);
      graph(
        ['docs/b.md'],
        more: [
          {'id': 'docs_a', 'source_file': 'docs/a.md', '_origin': 'ast'},
        ],
      );
      expect(check().code, 0);
    });

    test('names a deleted doc still in the graph, but not a deleted code '
        'file', () {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(['docs/a.md', 'docs/b.md', 'docs/old.md', 'lib/gone.dart']);
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (deleted or no longer '
            'scanned: docs/old.md). $_update',
      ));
    });

    test('matches graph paths written with backslashes or as absolute '
        'paths', () {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(
        ['docs/a.md', 'docs/b.md'],
        sources: {
          'docs/a.md': r'docs\a.md',
          'docs/b.md': p.join(repo.path, 'docs', 'b.md'),
        },
      );
      expect(check().code, 0);
    });

    test('lists at most five names per reason', () {
      upToDate();
      for (var i = 0; i < 7; i++) {
        writeFile(repo, 'docs/m$i.md', '# M$i\n');
      }
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 7 docs (new or changed: '
            'docs/m0.md, docs/m1.md, docs/m2.md, docs/m3.md, docs/m4.md and '
            '2 more). $_update',
      ));
    });

    test('with --skip-repairable, says docs missing from the graph are '
        'being repaired, and warns only about the rest', () {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(['docs/a.md']);
      const repairing =
          'graphify: repairing 1 doc from the cache in the background '
          '(docs/b.md).';
      expect(check(['--quiet', '--skip-repairable']), (
        code: 0,
        output: repairing,
      ));
      writeFile(repo, 'docs/n.md', '# N\n\nnew\n');
      expect(check(['--quiet', '--skip-repairable']), (
        code: 1,
        output:
            '$repairing\ngraphify: the graph is behind on 1 doc (new or '
            'changed: docs/n.md). $_update',
      ));
    });

    test('cannot run without a graph, and says so in UTF-8', () {
      final result = check();
      expect(result.code, 3);
      expect(
        result.output,
        startsWith(
          'graphify: the graph check could not run: there is no graph yet',
        ),
      );
      // The temp repo's path contains "tëst"; on Windows this fails unless
      // the script prints UTF-8.
      expect(result.output, contains('tëst'));
    });

    test("cannot run when graphify doesn't have what it calls", () {
      upToDate();
      // A fake, empty graphify package that shadows the real one, as a
      // graphify release that moved its functions would.
      writeFile(repo, 'fake/graphify/__init__.py', '');
      final fake = {'PYTHONPATH': p.join(repo.path, 'fake')};
      final checked = check(const [], fake);
      expect(checked.code, 3);
      expect(
        checked.output,
        startsWith('graphify: the graph check could not run: '),
      );
      final repaired = check(['--repair'], fake);
      expect(repaired.code, 3);
      expect(
        repaired.output,
        startsWith('graphify: could not repair the graph: '),
      );
    });

    test('rejects an unknown argument, or two modes at once', () {
      expect(check(['--nope']), (
        code: 3,
        output: '$_usage (not understood: --nope)',
      ));
      expect(check(['--repair', '--quiet']), (
        code: 3,
        output: '$_usage (not understood: --repair --quiet)',
      ));
    });
  });

  group('repair, with graphify', skip: skipWithoutGraphify, () {
    /// Runs graphify's own code rebuild, as its git hooks do.
    void build() {
      final result = runPython([_fixture, '--build']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    }

    Map<String, Object?> loadGraph() =>
        jsonDecode(
              File(
                p.join(repo.path, 'graphify-out', 'graph.json'),
              ).readAsStringSync(),
            )
            as Map<String, Object?>;

    List<Map<String, Object?>> nodes() => [
      for (final node in loadGraph()['nodes']! as List)
        node as Map<String, Object?>,
    ];

    Set<String> nodeIds() => {
      for (final node in nodes()) node['id']! as String,
    };

    /// Rebuilds the graph while docs/b.md is gone, as on a branch without
    /// it, then puts the same file back and rebuilds again, as a pull does.
    void dropB() {
      final b = File(p.join(repo.path, 'docs', 'b.md'));
      final text = b.readAsStringSync();
      b.deleteSync();
      build();
      b.writeAsStringSync(text);
      build();
    }

    /// Repairs, and expects both docs to be put back.
    void repairAll() => expect(check(['--repair']), (
      code: 0,
      output:
          'graphify: repaired 2 docs from the cache (docs/a.md, docs/b.md).',
    ));

    /// graphify's rebuild log, for the background repair, outside the repo.
    late File log;

    String logged() => log.existsSync() ? log.readAsStringSync() : '';

    setUp(() {
      log = File(p.join(tempFolder().path, 'rebuild log.txt'));
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      build();
    });

    test('puts cached docs into a graph built from code alone', () {
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 2 docs (missing from the graph: '
            'docs/a.md, docs/b.md). $_update',
      ));
      repairAll();
      expect(check().code, 0);
      expect(
        nodeIds(),
        containsAll([
          'docs_a_concept',
          'docs_b_concept',
          'lib_c',
          'lib_c_main',
        ]),
      );
    });

    test('puts back a doc a rebuild dropped, and keeps the other docs and '
        'the code', () {
      repairAll();
      dropB();
      expect(nodeIds(), contains('docs_b'), reason: 'the heading node');
      expect(nodeIds(), isNot(contains('docs_b_concept')));
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (missing from the graph: '
            'docs/b.md). $_update',
      ));
      expect(check(['--repair']), (
        code: 0,
        output: 'graphify: repaired 1 doc from the cache (docs/b.md).',
      ));
      expect(check(), (
        code: 0,
        output: 'graphify: the graph is current (2 docs checked).',
      ));
      expect(
        nodeIds(),
        containsAll([
          'docs_a_concept',
          'docs_b_concept',
          'lib_c',
          'lib_c_main',
        ]),
      );
      expect(nodes().where((node) => node['community'] == null), isEmpty);
    });

    test('keeps a saved label of a community the repair left alone', () {
      repairAll();
      dropB();
      final code = nodes().firstWhere((node) => node['id'] == 'lib_c');
      final labels = File(
        p.join(repo.path, 'graphify-out', '.graphify_labels.json'),
      );
      final saved = jsonDecode(labels.readAsStringSync()) as Map;
      labels.writeAsStringSync(
        jsonEncode({...saved, '${code['community']}': 'Hand label'}),
      );
      expect(check(['--repair']).code, 0);
      final after = jsonDecode(labels.readAsStringSync()) as Map;
      final community = nodes().firstWhere(
        (node) => node['id'] == 'lib_c',
      )['community'];
      expect(after['$community'], 'Hand label');
    });

    test('leaves new, changed and deleted docs to /graphify . --update', () {
      writeFile(repo, 'docs/old.md', '# Old\n\ngone soon\n');
      extract('prompt one', ['docs/old.md']);
      expect(check(['--repair']).code, 0);
      dropB();
      File(p.join(repo.path, 'docs', 'old.md')).deleteSync();
      writeFile(repo, 'docs/a.md', '# A\n\nalpha, changed\n');
      writeFile(repo, 'docs/n.md', '# N\n\nnew\n');
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 4 docs (new or changed: '
            'docs/a.md, docs/n.md; missing from the graph: docs/b.md; '
            'deleted or no longer scanned: docs/old.md). $_update',
      ));
      // graphify's own rebuild, which the repair runs, drops the deleted doc.
      expect(check(['--repair']), (
        code: 1,
        output:
            'graphify: repaired 1 doc from the cache (docs/b.md).\n'
            'graphify: the graph is behind on 2 docs (new or changed: '
            'docs/a.md, docs/n.md). $_update',
      ));
    });

    test('says when there is nothing to repair', () {
      repairAll();
      expect(check(['--repair']), (
        code: 0,
        output: 'graphify: nothing to repair.',
      ));
    });

    test('waits for a rebuild that holds graphify\'s lock', () async {
      repairAll();
      dropB();
      final holder = await startPython(['-c', _holdLock, '6']);
      unawaited(holder.stderr.drain<void>());
      final said = holder.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      await said.firstWhere((line) => line == 'held');
      final repairing = await startPython([_script, '--repair']);
      final output = repairing.stdout.transform(utf8.decoder).join();
      unawaited(repairing.stderr.drain<void>());
      var finished = false;
      unawaited(repairing.exitCode.then((_) => finished = true));
      await said.firstWhere((line) => line == 'released');
      expect(finished, isFalse, reason: 'it repaired while the lock was held');
      expect(await repairing.exitCode, 0);
      expect(
        (await output).trim(),
        'graphify: repaired 1 doc from the cache (docs/b.md).',
      );
      await holder.exitCode;
    });

    test('--after-rebuild waits for graphify\'s rebuild to end, then repairs, '
        'and writes only to the log, each line prefixed', () async {
      repairAll();
      dropB();
      // Stands in for a rebuild in progress: graphify's lock file.
      final lock = File(p.join(repo.path, 'graphify-out', '.rebuild.lock'))
        ..writeAsStringSync('12345\n');
      final job = await startPython(
        [_script, '--after-rebuild'],
        extra: {
          'GRAPHIFY_REBUILD_LOG': log.path,
          'APPSTEIN_REPAIR_START_WAIT': '5',
          'APPSTEIN_REPAIR_MAX_WAIT': '120',
        },
      );
      final output = job.stdout.transform(utf8.decoder).join();
      final errors = job.stderr.transform(utf8.decoder).join();
      var finished = false;
      unawaited(job.exitCode.then((_) => finished = true));
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(finished, isFalse, reason: 'it ran before the rebuild ended');
      lock.deleteSync();
      expect(await job.exitCode, 0);
      expect('${await output}${await errors}', isEmpty);
      final lines = log.readAsLinesSync();
      expect(
        lines,
        everyElement(matches(RegExp(r'^\[appstein\] \d{4}-\d\d-\d\d '))),
      );
      expect(
        lines.last,
        endsWith(' graphify: repaired 1 doc from the cache (docs/b.md).'),
      );
    });

    test('--after-rebuild rebuilds the code when graphify\'s hook did not', () {
      repairAll();
      writeFile(repo, 'lib/d.dart', 'void d() {}\n');
      final result = runPython(
        [_script, '--after-rebuild'],
        extra: {
          'GRAPHIFY_REBUILD_LOG': log.path,
          'APPSTEIN_REPAIR_START_WAIT': '0.5',
        },
      );
      expect(result.exitCode, 0, reason: logged());
      expect(logged().trim(), endsWith(' graphify: nothing to repair.'));
      expect(nodeIds(), contains('lib_d'));
    });

    test('--detach returns at once, prints nothing, and repairs in the '
        'background, appending to graphify\'s log', () async {
      repairAll();
      dropB();
      final started = runPython(
        [_script, '--detach'],
        extra: {
          'GRAPHIFY_REBUILD_LOG': log.path,
          'APPSTEIN_REPAIR_START_WAIT': '3',
        },
      );
      expect(started.exitCode, 0);
      expect('${started.stdout}${started.stderr}', isEmpty);
      // runPython returns once the pipes close, so the job must not hold
      // them, as it would hold git's.
      expect(logged(), isNot(contains('graphify: repaired')));
      // graphify's rebuild writes to the same log meanwhile; the job must
      // add to it, not write over it.
      log.writeAsStringSync(
        '[graphify] rebuilt meanwhile\n',
        mode: FileMode.append,
      );
      const repaired = 'graphify: repaired 1 doc from the cache (docs/b.md).';
      for (var i = 0; i < 120 && !logged().contains(repaired); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      expect(logged(), startsWith('[graphify] rebuilt meanwhile\n'));
      expect(logged(), contains(repaired));
      expect(check().code, 0);
    });

    test("cannot repair when graphify's rebuild no longer takes the "
        'extraction', () {
      repairAll();
      dropB();
      // As a graphify release that rebuilt without the function the repair
      // hooks into would.
      writeFile(
        repo,
        'shim/sitecustomize.py',
        'import graphify.watch\n'
            'graphify.watch._rebuild_code = lambda *a, **k: True\n',
      );
      expect(check(['--repair'], {'PYTHONPATH': p.join(repo.path, 'shim')}), (
        code: 3,
        output:
            "graphify: could not repair the graph: graphify's rebuild didn't "
            'put back docs/b.md.',
      ));
    });
  });
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `fvm dart test test/check_graph_test.dart`
Expected: FAIL. The 1a.2 script rejects `--repair`, `--skip-repairable`, `--detach` and `--after-rebuild` (`usage: check_graph.py [--quiet] (unknown: …)`). The heading-node test fails because the old rule counts any node with the doc's `source_file`. The usage test fails on the new usage line.

- [ ] **Step 4: Rewrite `tool/check_graph.py`**

```python
"""Says whether the graphify knowledge graph holds the current docs, and puts
back docs whose extraction is cached but missing from it (spec §19.6).

graphify's git hooks rebuild only the code structure. What the docs mean is
extracted by an LLM during `/graphify . --update`, so a doc edited after that
run stays behind in the graph until the next one. This check finds those docs:

- new or changed: no extraction of the doc's current content is cached;
- missing from the graph: an extraction is cached, but graph.json has none of
  the nodes it adds (graphify's own heading nodes for the doc don't count);
- deleted or no longer scanned: graph.json has nodes from a doc that graphify
  no longer scans.

An extraction made with any agent's extraction prompt counts, because each
agent's graphify skill ships its own prompt (docs/guide/docs-tooling.md).

A doc goes missing from the graph when graphify rebuilds the code while the
doc isn't on disk, for example on a branch that lacks it: the rebuild drops
the doc's nodes, and no code rebuild can extract them again. --repair puts
them back from the cache, with no LLM, and lets graphify finish the graph the
way its own rebuild does: communities, labels, report and graph.html.

Run it with graphify's Python, from the repo root:

    "$(cat graphify-out/.graphify_python)" tool/check_graph.py [--quiet]
    "$(cat graphify-out/.graphify_python)" tool/check_graph.py --repair

  (no mode)        Check. --quiet prints nothing when the graph is current.
                   --skip-repairable (the hooks use it, right after starting
                   a background repair) reports docs missing from the graph
                   as being repaired, instead of asking for an update.
  --repair         Repair now, then report what is still behind.
  --detach         Start --after-rebuild in a background process and return.
  --after-rebuild  Wait for graphify's rebuild to finish, then rebuild once
                   more with the missing docs put back. It writes only to
                   graphify's rebuild log.

Exit codes: 0 the graph is current (apart from docs being repaired), 1 docs
are behind, 3 the check or the repair couldn't run, or bad usage.
"""

import contextlib
import io
import json
import os
import subprocess
import sys
import time
from pathlib import Path

_DOC_KINDS = ('document', 'paper', 'image')
_REASONS = ('new or changed', 'missing from the graph',
            'deleted or no longer scanned')
_MISSING = 'missing from the graph'
_MAX_NAMES = 5
_MODES = ('--repair', '--detach', '--after-rebuild')
_USAGE = ('usage: check_graph.py [--quiet] [--skip-repairable] | --repair | '
          '--detach | --after-rebuild')


def _valid_extraction(entry: Path):
    """The extraction in a cache entry, or None when graphify would treat the
    entry as a miss: unreadable, partial, or with no nodes and no hyperedges."""
    try:
        data = json.loads(entry.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None
    if (isinstance(data, dict) and not data.get('partial')
            and (data.get('nodes') or data.get('hyperedges'))):
        return data
    return None


def _extractions(doc: Path, root: Path, cache: Path, file_hash) -> list:
    """Every valid cached extraction of this exact content, from any prompt's
    cache and in any mode, newest first."""
    try:
        name = file_hash(doc, root) + '.json'
    except OSError:
        return []
    entries = []
    for kind in sorted(cache.glob('semantic*')):
        if not kind.is_dir():
            continue
        for folder in [kind] + sorted(d for d in kind.iterdir() if d.is_dir()):
            if (folder / name).is_file():
                entries.append(folder / name)
    found = []
    for entry in sorted(entries, key=lambda e: e.stat().st_mtime, reverse=True):
        data = _valid_extraction(entry)
        if data is not None:
            found.append(data)
    return found


def _is_ast(item: dict) -> bool:
    """Whether graphify's code rebuild made a node or edge, by graphify's own
    rule (graphify.build._is_ast_tier): its _origin marker, or for items from
    before the marker, a source_location such as 'L12'. It is copied, not
    imported, because importing graphify.build costs 0.2 s on every commit;
    the repair tests, which run graphify's real rebuild, catch a change."""
    origin = item.get('_origin')
    if origin is not None:
        return origin == 'ast'
    location = item.get('source_location')
    return (isinstance(location, str) and location[:1] == 'L'
            and location[1:2].isdigit())


def _ids(data: dict) -> set:
    """The ids of the nodes and hyperedges in a graph or an extraction."""
    return {
        item.get('id')
        for bucket in ('nodes', 'hyperedges')
        for item in data.get(bucket, [])
        if isinstance(item, dict) and isinstance(item.get('id'), str)
    }


def _relative(path: str, root: Path) -> str:
    """A graph.json source_file as a forward-slash path relative to root."""
    text = path.replace('\\', '/')
    candidate = Path(text)
    if candidate.is_absolute():
        try:
            return candidate.resolve().relative_to(root).as_posix()
        except ValueError:
            return candidate.as_posix()
    return text


def _names(paths: list) -> str:
    shown = ', '.join(paths[:_MAX_NAMES])
    more = len(paths) - _MAX_NAMES
    return f'{shown} and {more} more' if more > 0 else shown


def _docs(count: int) -> str:
    return f'{count} {"doc" if count == 1 else "docs"}'


def _out_dir(root: Path) -> Path:
    from graphify.paths import GRAPHIFY_OUT
    out = Path(GRAPHIFY_OUT)
    return out if out.is_absolute() else root / out


def find_behind(root: Path) -> dict:
    """The number of docs, the docs the graph is behind on by reason, and
    under 'cached' the cached extractions of each doc missing from the graph.

    Raises on anything that stops the check, such as a missing graph or a
    graphify that lacks the functions used here.
    """
    from graphify.cache import file_hash
    from graphify.detect import CODE_EXTENSIONS, FileType, classify_file, detect

    out = _out_dir(root)
    graph_file = out / 'graph.json'
    if not graph_file.is_file():
        raise FileNotFoundError(
            f'there is no graph yet ({graph_file} is missing); run /graphify .')
    graph = json.loads(graph_file.read_text(encoding='utf-8'))
    graph_ids = _ids(graph)

    detected = detect(root)
    docs = sorted({
        _relative(str(f), root)
        for kind in _DOC_KINDS for f in detected['files'].get(kind, [])
    })
    in_graph = {
        _relative(str(node['source_file']), root)
        for node in graph.get('nodes', []) if node.get('source_file')
    }
    # graphify's code rebuild adds heading nodes of its own for a Markdown
    # doc, and one can have the same id as the extraction's node for the doc
    # itself (the heading node wins). Only the nodes an extraction adds count.
    heading_ids = {n.get('id') for n in graph.get('nodes', []) if _is_ast(n)}
    changed, missing, cached = [], [], {}
    for doc in docs:
        extractions = _extractions(root / doc, root, out / 'cache', file_hash)
        if not extractions:
            changed.append(doc)
            continue
        adds = [_ids(e) - heading_ids for e in extractions]
        if any(adds) and not any(a & graph_ids for a in adds):
            missing.append(doc)
            cached[doc] = extractions
    doc_set = set(docs)
    removed = sorted(
        source for source in in_graph
        if source not in doc_set and source != 'None'
        and Path(source).suffix.lower() not in CODE_EXTENSIONS
        and classify_file(Path(source)) not in (FileType.CODE, None)
    )
    return {'docs': len(docs), 'new or changed': changed,
            _MISSING: missing, 'deleted or no longer scanned': removed,
            'cached': cached}


def repair(root: Path, echo=None, rebuild: bool = False) -> tuple:
    """Puts the docs missing from the graph back from graphify's cache, and
    returns (the docs repaired, find_behind's result afterwards).

    It holds graphify's rebuild lock, waiting for a running rebuild first,
    and runs graphify's own full code rebuild with the cached extractions
    added to what it keeps from the existing graph, so graphify clusters,
    names communities and writes the report as usual. No LLM runs. With
    [rebuild], the code rebuild runs even when no doc is missing. [echo]
    receives what graphify printed. Raises when the repair can't run or
    graphify's rebuild doesn't put the docs back.
    """
    import graphify.watch as watch

    out = _out_dir(root)
    with watch._rebuild_lock(out, blocking=True):
        before = find_behind(root)
        docs = before[_MISSING]
        if not docs and not rebuild:
            return [], before
        added = {'nodes': [], 'edges': [], 'hyperedges': []}
        for doc in docs:
            newest = before['cached'][doc][0]
            for bucket, items in added.items():
                items.extend(i for i in newest.get(bucket, []) if isinstance(i, dict))
        # Stamped as graphify stamps what it keeps from an existing graph.
        for item in added['nodes'] + added['edges']:
            item.setdefault('_origin', 'ast' if _is_ast(item) else 'semantic')

        keep = watch._reconcile_existing_graph

        def keep_and_add(*args, **kwargs):
            result, existing = keep(*args, **kwargs)
            have = {n.get('id') for n in result['nodes']}
            result['nodes'] = result['nodes'] + [
                n for n in added['nodes'] if n.get('id') not in have]
            result['edges'] = result['edges'] + added['edges']
            result['hyperedges'] = (
                result.get('hyperedges', []) + added['hyperedges'])
            return result, existing

        printed = io.StringIO()
        watch._reconcile_existing_graph = keep_and_add
        try:
            with contextlib.redirect_stdout(printed), \
                    contextlib.redirect_stderr(printed):
                # As in graphify's own full rebuild: it covers any change a
                # hook queued while the lock was held.
                watch._drain_pending(out)
                rebuilt = watch._rebuild_code(Path('.'), acquire_lock=False)
        finally:
            watch._reconcile_existing_graph = keep
        if echo is not None:
            echo(printed.getvalue())
        after = find_behind(root)
    lines = [line.strip() for line in printed.getvalue().splitlines()
             if line.strip()]
    said = f' It said: {lines[-1]}' if lines else ''
    if not rebuilt:
        raise RuntimeError(f"graphify's rebuild failed.{said}")
    still = [d for d in docs if d in after[_MISSING]]
    if still:
        raise RuntimeError(
            f"graphify's rebuild didn't put back {_names(still)}.{said}")
    return docs, after


def _behind_line(result: dict, reasons=_REASONS):
    """The one-line warning for [reasons], or None when none has docs."""
    found = [(k, result[k]) for k in reasons if result[k]]
    if not found:
        return None
    count = sum(len(v) for _, v in found)
    detail = '; '.join(f'{k}: {_names(v)}' for k, v in found)
    return (f'graphify: the graph is behind on {_docs(count)} ({detail}). '
            'Run /graphify . --update before relying on it.')


def _check(root: Path, quiet: bool, skip_repairable: bool) -> int:
    try:
        result = find_behind(root)
    except Exception as error:  # noqa: BLE001 - any failure means "couldn't check"
        print(f'graphify: the graph check could not run: {error}')
        return 3
    reasons = _REASONS
    if skip_repairable and result[_MISSING]:
        docs = result[_MISSING]
        print(f'graphify: repairing {_docs(len(docs))} from the cache in the '
              f'background ({_names(docs)}).')
        reasons = tuple(r for r in _REASONS if r != _MISSING)
    line = _behind_line(result, reasons)
    if line is None:
        if not quiet and not (skip_repairable and result[_MISSING]):
            print(f'graphify: the graph is current ({_docs(result["docs"])} '
                  'checked).')
        return 0
    print(line)
    return 1


def _repair(root: Path, say, echo=None, rebuild: bool = False) -> int:
    try:
        docs, after = repair(root, echo, rebuild)
    except Exception as error:  # noqa: BLE001 - any failure means "couldn't repair"
        say(f'graphify: could not repair the graph: {error}')
        return 3
    if docs:
        say(f'graphify: repaired {_docs(len(docs))} from the cache '
            f'({_names(docs)}).')
    else:
        say('graphify: nothing to repair.')
    line = _behind_line(after)
    if line is None:
        return 0
    say(line)
    return 1


def _log_path() -> Path:
    """graphify's rebuild log, where its hooks send background output:
    GRAPHIFY_REBUILD_LOG, or .cache/graphify-rebuild.log in $HOME, which
    graphify's hooks use (on Windows, git's sh sets HOME)."""
    configured = os.environ.get('GRAPHIFY_REBUILD_LOG')
    if configured:
        return Path(configured)
    home = os.environ.get('HOME') or os.path.expanduser('~')
    return Path(home) / '.cache' / 'graphify-rebuild.log'


def _rebuild_env() -> dict:
    """The environment graphify's hooks give a rebuild: a fixed hash seed, so
    clustering is reproducible, and one worker on Windows."""
    env = dict(os.environ, PYTHONHASHSEED='0')
    if os.name == 'nt':
        env.setdefault('GRAPHIFY_MAX_WORKERS', '1')
    return env


def _detach(root: Path) -> int:
    """Starts --after-rebuild in a process of its own, as graphify's hooks
    start their rebuild, and returns at once.

    The process gets none of the hook's handles, so git doesn't wait for
    it. It opens the log itself: a handle passed down would write at the
    offset it had when opened, over what graphify wrote since.
    """
    try:
        options = dict(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       stdin=subprocess.DEVNULL, cwd=str(root),
                       close_fds=True, env=_rebuild_env())
        command = [sys.executable, str(Path(__file__).resolve()),
                   '--after-rebuild']
        if os.name == 'nt':
            flags = 0x08000000 | 0x00000200  # NO_WINDOW | NEW_PROCESS_GROUP
            try:
                # Also leave the hook's job object, if the system allows.
                subprocess.Popen(command, creationflags=flags | 0x01000000,
                                 **options)
            except OSError:
                subprocess.Popen(command, creationflags=flags, **options)
        else:
            subprocess.Popen(command, start_new_session=True, **options)
    except Exception as error:  # noqa: BLE001 - any failure means "couldn't start"
        print(f'graphify: the background graph repair could not start: {error}')
        return 3
    return 0


def _seconds(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


def _after_rebuild(root: Path) -> int:
    """Waits for the rebuild graphify's hook just started, then repairs, and
    writes what happened to graphify's rebuild log.

    graphify's hook starts its rebuild in the background too, and Python can
    take seconds to start on Windows, so it first waits for graphify's lock
    file to appear, then for it to go. With no rebuild (graphify's hook
    skipped it) the file never appears, and it goes on after the first wait.
    It then runs graphify's code rebuild once more, with any missing docs
    put back: graphify's hook skips its rebuild during a merge or a rebase,
    and when another rebuild still holds the lock.
    """
    try:
        log_file = _log_path()
        log_file.parent.mkdir(parents=True, exist_ok=True)
        log = open(log_file, 'a', encoding='utf-8', errors='replace')
    except OSError:
        return 3
    with log:
        def say(text: str) -> None:
            stamp = time.strftime('%Y-%m-%d %H:%M:%S')
            for line in text.splitlines():
                if line.strip():
                    log.write(f'[appstein] {stamp} {line}\n')
            log.flush()

        try:
            lock = _out_dir(root) / '.rebuild.lock'
        except Exception as error:  # noqa: BLE001 - any failure means "couldn't repair"
            say(f'graphify: could not repair the graph: {error}')
            return 3
        until = time.monotonic() + _seconds('APPSTEIN_REPAIR_START_WAIT', 20)
        while not lock.exists() and time.monotonic() < until:
            time.sleep(0.1)
        until = time.monotonic() + _seconds('APPSTEIN_REPAIR_MAX_WAIT', 660)
        while lock.exists() and time.monotonic() < until:
            time.sleep(0.2)
        return _repair(root, say, echo=say, rebuild=True)


def main(argv: list) -> int:
    # On Windows, Python prints in the console's code page. Paths may hold any
    # character, and git's sh, the log and the tests read UTF-8.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', errors='replace')
    known = {'--quiet', '--skip-repairable', *_MODES}
    unknown = [a for a in argv if a not in known]
    modes = [a for a in argv if a in _MODES]
    if unknown or len(modes) > 1 or (modes and len(argv) > 1):
        extra = ' '.join(unknown) if unknown else ' '.join(argv)
        print(f'{_USAGE} (not understood: {extra})', file=sys.stderr)
        return 3
    root = Path.cwd().resolve()
    mode = modes[0] if modes else None
    if mode in ('--repair', '--after-rebuild') and \
            os.environ.get('PYTHONHASHSEED') != '0':
        # graphify's hooks cluster with a fixed hash seed; without it the
        # communities would shuffle. The seed is read at start-up, so run
        # again with it.
        return subprocess.run([sys.executable, str(Path(__file__).resolve()),
                               *argv], env=_rebuild_env()).returncode
    if mode == '--repair':
        return _repair(root, print)
    if mode == '--detach':
        return _detach(root)
    if mode == '--after-rebuild':
        return _after_rebuild(root)
    return _check(root, '--quiet' in argv, '--skip-repairable' in argv)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `fvm dart test test/check_graph_test.dart`
Expected: 25 tests pass, in about a minute. graphify is installed on the development machine, so none skip.

- [ ] **Step 6: Run it on the real repo (read-only)**

In Git Bash: `"$(cat graphify-out/.graphify_python)" tool/check_graph.py`, then `"$(cat graphify-out/.graphify_python)" tool/check_graph.py --repair`.
Expected:
- **The check:** about half a second. It exits 1, naming as `new or changed` the docs this slice changed so far (this plan, `docs/guide/docs-tooling.md`, `docs/guide/testing.md`); `.py` and `.dart` files are code to graphify. There is no `missing from the graph` reason.
- **`--repair`:** prints `graphify: nothing to repair.` then the same line. It exits 1 and doesn't rebuild.

Record both outputs in the report. If the check names a doc as `missing from the graph`, stop and report it: F1's rule found a doc the 1a.2 check didn't, which needs a look before anything writes to the real graph.

- [ ] **Step 7: The guide (`docs/guide/docs-tooling.md` and `docs/guide/testing.md`)**

(a) In `docs-tooling.md`'s `## Is the graph current?` table, replace the `missing from the graph` row with:

```markdown
| `missing from the graph` | An extraction is cached, but `graph.json` has none of the nodes it adds. graphify's code rebuild gives a Markdown doc heading nodes of its own, one with the id the extraction gives the doc itself, so those don't count. It happens when a code rebuild ran while the doc wasn't on disk, for example on a branch without it, or when an update stopped before merging the doc. The hooks put such docs back by themselves; see [Repairing the graph](#repairing-the-graph). |
```

(b) In the exit-code table under it, replace the `0` and `3` rows with:

```markdown
| `0` | The graph is current. It prints how many docs it checked, or nothing with `--quiet` (the hooks use it). With `--skip-repairable` (the merge and rebase hooks), docs missing from the graph don't count: it prints `graphify: repairing N docs from the cache in the background (…)` instead |
| `3` | The check couldn't run: there is no graph yet, graphify can't be imported, or a graphify release changed the functions the check calls. It prints `graphify: the graph check could not run: <reason>`. An unknown option, or a mode together with another option, also exits 3, with a usage line on stderr |
```

(c) Insert this section immediately before `## Git hooks`:

````markdown
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
- `--after-rebuild` first waits for the rebuild graphify's hook just started. That rebuild starts in the background too, and Python can take seconds to start on Windows, so it waits up to 20 seconds for graphify's lock file to appear, then until the file goes, up to 11 minutes (graphify stops a rebuild after 10). Then it runs the repair. **[D1]** It runs graphify's code rebuild even when no doc is missing, because graphify's hook skips its rebuild during a merge or a rebase (after a real merge commit, `MERGE_HEAD` still exists in `post-merge`, and in `post-rewrite` the rebase's own folder does), and whenever another rebuild still holds the lock.
- It writes only to graphify's rebuild log, `~/.cache/graphify-rebuild.log` (or `GRAPHIFY_REBUILD_LOG`). It opens the log itself and adds to it, so graphify's lines stay. Each of its lines starts with `[appstein]` and the time:

```text
[appstein] 2026-10-01 01:32:32 graphify: repaired 1 doc from the cache (docs/superpowers/plans/2026-09-30-slice-1a2-graph-staleness.md).
```

`APPSTEIN_REPAIR_START_WAIT` and `APPSTEIN_REPAIR_MAX_WAIT` (seconds) change the two waits; the tests use them to stay short.
````

If the owner rejected D1, write the `--after-rebuild` bullet without the sentence marked **[D1]**, and drop the marker.

(d) In `## Limits`, append:

```markdown
- **The repair trusts the cache.** It puts back the newest cached extraction of the doc's current content. When several agents extracted the same content, the newest one wins.
- **A doc whose extraction is only a node for the doc itself** can't be told from a doc graphify only scanned for headings: graphify's heading node has the same id and wins. The check counts such a doc as in the graph, since there is nothing to put back.
- **The repair uses graphify's private functions** (`_rebuild_lock`, `_rebuild_code`, `_reconcile_existing_graph`, `_drain_pending`) and copies graphify's rule for telling its heading nodes apart. CI's tests pin the graphify version (`GRAPHIFY_VERSION`). A graphify release that changes them makes the repair say `could not repair the graph`, never report a repair it didn't make.
```

(e) In `testing.md`, replace the whole `**The graph check runs against real graphify.**` paragraph with:

```markdown
**The graph check runs against real graphify.** `check_graph_test.dart` builds a temp repo with two docs and a Dart file, and fakes an update with [`graphify_fixture.py`](../../test/support/graphify_fixture.py), which writes real cache entries through graphify's own code. Like a real extraction, each fake one has a node for the doc itself, with the id graphify's heading node for the doc gets, and a concept node (`--only-heading` leaves the concept out). The check tests then write a small `graph.json` by hand. The repair tests build it with graphify's own code rebuild instead (`graphify_fixture.py --build`). They drop a doc the way a branch switch does (rebuild without the file, put it back, rebuild) and check that `--repair` puts it back and keeps everything else, a saved community name included. They also cover waiting: a Python process that holds graphify's lock, and a lock file that `--after-rebuild` waits out. `APPSTEIN_REPAIR_START_WAIT` and `APPSTEIN_REPAIR_MAX_WAIT` keep the waits short, and `GRAPHIFY_REBUILD_LOG` sends the background log to a temp folder. A `sitecustomize.py` on `PYTHONPATH` stands in for a graphify release whose rebuild no longer takes the extraction. The file takes about a minute. It needs a Python that can import graphify. [`graphify.dart`](../../test/support/graphify.dart) tries `APPSTEIN_GRAPHIFY_PYTHON`, then the interpreter this repo's `graphify-out/.graphify_python` names, and takes the first that can import graphify. Without one, those tests are skipped, except when `APPSTEIN_REQUIRE_GRAPHIFY=1`: CI sets it after installing a pinned graphify (see [ci](ci.md)), so there a missing graphify fails the tests instead.
```

- [ ] **Step 8: Check, format and analyze**

Run: `fvm dart run tool/check_guide.dart`, `fvm dart format test/check_graph_test.dart`, `fvm dart analyze --fatal-infos`.
Expected: `The guide check passed.`, no formatting changes, `No issues found!`.

- [ ] **Step 9: Hand back to the controller to commit**

Suggested message: `feat(tool): check_graph.py puts docs a rebuild dropped back from graphify's cache`

---

### Task 2: the hooks start the repair

**Files:**
- Modify: `tool/src/hooks.dart:11-102` (the block definitions, through the end of `_graphCheck`)
- Rewrite: `test/hooks_test.dart`
- Modify: `docs/guide/docs-tooling.md` (`## Git hooks`, `## Limits`)
- Modify: `docs/guide/testing.md` (the `**The hook tests run real git hooks.**` paragraph)

**Interfaces:**
- Consumes: `tool/check_graph.py --detach` (silent, starts the background job) and `--quiet --skip-repairable`, from Task 1.
- Produces: `hookBlocks` keys become `post-checkout`, `post-commit`, `post-merge`, `post-rewrite`, in that order. The replays set `APPSTEIN_HOOK_REPLAY=1`.

- [ ] **Step 1: Write the failing tests**

`test/hooks_test.dart` (the whole file):

```dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/hooks.dart';
import 'support/temp_repo.dart';

const graphify =
    '#!/bin/sh\n# graphify-hook-start\n(\n  echo graph\n)\n'
    '# graphify-hook-end\n';

bool _hasSh() {
  try {
    return Process.runSync('sh', ['-c', 'exit 0']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  final block = hookBlocks['post-merge']!;

  test('every block is marked and runs in a subshell', () {
    expect(hookBlocks.keys, [
      'post-checkout',
      'post-commit',
      'post-merge',
      'post-rewrite',
    ]);
    for (final text in hookBlocks.values) {
      expect(text, startsWith('$hookBlockStart\n'));
      expect(text, endsWith(hookBlockEnd));
      expect(text, contains('\n(\n'));
      expect(text, contains('\n)\n'));
    }
  });

  test('every block is valid sh', () {
    final folder = tempFolder();
    for (final MapEntry(key: name, value: text) in hookBlocks.entries) {
      File(
        p.join(folder.path, name),
      ).writeAsStringSync(upsertHookBlock(null, text));
      final result = Process.runSync('sh', [
        '-n',
        name,
      ], workingDirectory: folder.path);
      expect(result.exitCode, 0, reason: '$name: ${result.stderr}');
    }
  }, skip: _hasSh() ? false : 'sh is not on PATH');

  test('upsert creates a file with a shebang', () {
    expect(upsertHookBlock(null, block), '#!/bin/sh\n$block\n');
  });

  test("upsert appends after other content, such as graphify's block", () {
    expect(upsertHookBlock(graphify, block), '$graphify\n$block\n');
  });

  test('upsert replaces an older Appstein block in place, and is '
      'idempotent', () {
    const old =
        '#!/bin/sh\n$hookBlockStart\necho old\n$hookBlockEnd\n'
        '# graphify-hook-start\n# graphify-hook-end\n';
    final updated = upsertHookBlock(old, block);
    expect(
      updated,
      '#!/bin/sh\n$block\n# graphify-hook-start\n# graphify-hook-end\n',
    );
    expect(upsertHookBlock(updated, block), updated);
  });

  test('upsert refuses a start marker without an end marker', () {
    expect(
      () => upsertHookBlock('#!/bin/sh\n$hookBlockStart\n', block),
      throwsFormatException,
    );
  });

  test('remove keeps other content, and is null when only the shebang is '
      'left', () {
    expect(removeHookBlock(upsertHookBlock(graphify, block)), graphify);
    expect(removeHookBlock(upsertHookBlock(null, block)), isNull);
    expect(removeHookBlock(graphify), graphify);
  });

  test('installHookBlocks installs, reports up to date, and removes', () {
    final hooks = p.join(tempFolder().path, 'hooks');
    expect(installHookBlocks(hooks), [
      'post-checkout: installed',
      'post-commit: installed',
      'post-merge: installed',
      'post-rewrite: installed',
    ]);
    expect(installHookBlocks(hooks), [
      'post-checkout: up to date',
      'post-commit: up to date',
      'post-merge: up to date',
      'post-rewrite: up to date',
    ]);
    expect(installHookBlocks(hooks, remove: true), [
      'post-checkout: removed (file deleted)',
      'post-commit: removed (file deleted)',
      'post-merge: removed (file deleted)',
      'post-rewrite: removed (file deleted)',
    ]);
    expect(Directory(hooks).listSync(), isEmpty);
  });

  group('in a real repo, run by git', () {
    late Directory repo;
    late File log;
    const env = {'APPSTEIN_SKIP_DOCS_HOOK': '1'};

    String head() => runGit(repo, ['rev-parse', 'HEAD']).trim();
    void commit(String file) {
      writeFile(repo, file, file);
      runGit(repo, ['add', '.'], environment: env);
      runGit(repo, ['commit', '-q', '-m', file], environment: env);
    }

    List<String> logged() =>
        log.existsSync() ? log.readAsLinesSync() : const [];

    setUp(() {
      repo = tempRepo();
      final hooks = p.join(repo.path, '.git', 'hooks');
      log = File(p.join(repo.path, '.git', 'checkout.log'));
      // Stands in for graphify's post-checkout rebuild: it logs its
      // arguments, and whether one of our blocks replayed it.
      final fake = File(p.join(hooks, 'post-checkout'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          '#!/bin/sh\necho "\$1 \$2 \$3 replay=\${APPSTEIN_HOOK_REPLAY:-0}" '
          '>> "\$(git rev-parse --git-dir)/checkout.log"\n',
        );
      if (!Platform.isWindows) Process.runSync('chmod', ['+x', fake.path]);
      installHookBlocks(hooks);
      commit('a.txt');
    });

    test('post-merge replays a fast-forward as a checkout', () {
      final a = head();
      runGit(repo, ['switch', '-q', '-c', 'feature'], environment: env);
      commit('b.txt');
      final b = head();
      runGit(repo, ['switch', '-q', 'main'], environment: env);
      runGit(repo, ['merge', '-q', '--ff-only', 'feature'], environment: env);
      expect(logged().last, '$a $b 1 replay=1');
    });

    test('post-rewrite replays a rebase, but not an amend', () {
      runGit(repo, ['switch', '-q', '-c', 'feature'], environment: env);
      commit('c.txt');
      runGit(repo, ['switch', '-q', 'main'], environment: env);
      commit('d.txt');
      runGit(repo, ['switch', '-q', 'feature'], environment: env);
      final before = logged().length;
      runGit(repo, [
        'commit',
        '-q',
        '--amend',
        '-m',
        'c amended',
      ], environment: env);
      expect(logged(), hasLength(before));
      final oldTip = head();
      runGit(repo, ['rebase', '-q', 'main'], environment: env);
      expect(logged().last, '$oldTip ${head()} 1 replay=1');
    });
  });

  group('the graph check, run by git', () {
    late Directory repo;
    late File log;
    late File fakePython;
    const env = {'APPSTEIN_SKIP_DOCS_HOOK': '1'};
    const repair = 'tool/check_graph.py --detach';

    List<String> logged() =>
        log.existsSync() ? log.readAsLinesSync() : const [];

    /// The checks the hooks ran, without the repairs they started.
    List<String> checks() => [
      for (final line in logged())
        if (line != repair) line,
    ];

    /// How many background repairs the hooks started.
    int repairs() => logged().where((line) => line == repair).length;

    /// Commits [file] and returns everything git and its hooks printed.
    String commit(String file, {Map<String, String> extra = const {}}) {
      writeFile(repo, file, file);
      runGit(repo, ['add', '.'], environment: {...env, ...extra});
      final result = gitResult(
        repo,
        ['commit', '-q', '-m', file],
        environment: {...env, ...extra},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return '${result.stdout}${result.stderr}';
    }

    /// Runs `git` [arguments] and returns everything git and its hooks
    /// printed.
    String git(List<String> arguments, {Map<String, String> extra = const {}}) {
      final result = gitResult(
        repo,
        arguments,
        environment: {...env, ...extra},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return '${result.stdout}${result.stderr}';
    }

    setUp(() {
      repo = tempRepo();
      log = File(p.join(repo.path, '.git', 'python.log'));
      // Stands in for graphify's Python. It logs its arguments and exits 1,
      // as the real check does when the graph is behind. Its name has a
      // space, like "C:\Program Files\…".
      fakePython = File(p.join(repo.path, '.git', 'fake python'))
        ..writeAsStringSync(
          '#!/bin/sh\necho "\$*" >> "\$(git rev-parse --git-dir)/'
          'python.log"\nexit 1\n',
        );
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['+x', fakePython.path]);
      }
      writeFile(repo, '.gitignore', 'graphify-out/\n');
      writeFile(repo, 'tool/check_graph.py', '# stand-in with --detach\n');
      writeFile(repo, 'graphify-out/graph.json', '{}');
      writeFile(repo, 'graphify-out/.graphify_python', fakePython.path);
      installHookBlocks(p.join(repo.path, '.git', 'hooks'));
    });

    test('after a commit, runs the check quietly with graphify\'s Python, '
        'and prints nothing of its own', () {
      final output = commit('a.txt');
      expect(logged(), ['tool/check_graph.py --quiet']);
      expect(output, isNot(contains('graphify:')));
    });

    test('reads an interpreter path written with CRLF', () {
      writeFile(
        repo,
        'graphify-out/.graphify_python',
        '${fakePython.path}\r\n',
      );
      commit('a.txt');
      expect(logged(), hasLength(1));
    });

    test('is silent with APPSTEIN_SKIP_GRAPH_HOOK=1, without a graph, and '
        'without the script', () {
      final skipped = commit('a.txt', extra: {'APPSTEIN_SKIP_GRAPH_HOOK': '1'});
      File(p.join(repo.path, 'graphify-out', 'graph.json')).deleteSync();
      final noGraph = commit('b.txt');
      writeFile(repo, 'graphify-out/graph.json', '{}');
      File(p.join(repo.path, 'tool', 'check_graph.py')).deleteSync();
      final noScript = commit('c.txt');
      expect(logged(), isEmpty);
      for (final output in [skipped, noGraph, noScript]) {
        expect(output, isNot(contains('graphify:')));
      }
    });

    test('says so when graphify\'s Python is missing, and the commit still '
        'succeeds', () {
      const message =
          "graphify: the graph check could not run: "
          "graphify-out/.graphify_python doesn't name graphify's Python. "
          'Run /graphify . --update to set it.';
      writeFile(
        repo,
        'graphify-out/.graphify_python',
        p.join(repo.path, 'no such python'),
      );
      expect(commit('a.txt'), contains(message));
      File(p.join(repo.path, 'graphify-out', '.graphify_python')).deleteSync();
      expect(commit('b.txt'), contains(message));
      expect(logged(), isEmpty);
    });

    test('runs once after a merge, not during a rebase, once after it, and '
        'not again for an amend', () {
      commit('a.txt');
      git(['switch', '-q', '-c', 'feature']);
      commit('b.txt');
      git(['switch', '-q', 'main']);
      commit('c.txt');
      expect(checks(), hasLength(3));
      git(['merge', '-q', '--no-edit', 'feature']);
      expect(checks(), hasLength(4), reason: 'post-merge');
      expect(checks().last, 'tool/check_graph.py --quiet --skip-repairable');
      git(['switch', '-q', '-c', 'topic', 'feature']);
      commit('d.txt');
      commit('e.txt');
      expect(checks(), hasLength(6));
      git(['rebase', '-q', 'main']);
      expect(
        checks(),
        hasLength(7),
        reason: 'post-rewrite once; post-commit skipped while rebasing',
      );
      expect(checks().last, 'tool/check_graph.py --quiet --skip-repairable');
      git(['commit', '-q', '--amend', '-m', 'e amended']);
      expect(checks(), hasLength(8), reason: 'post-commit only');
    });

    test('starts the background repair, silently, on a branch switch and '
        'after a merge or rebase, but not while rebasing', () {
      commit('a.txt');
      expect(git(['switch', '-q', '-c', 'feature']), isEmpty);
      expect(repairs(), 0, reason: 'a new branch at the same commit');
      commit('b.txt');
      expect(git(['switch', '-q', 'main']), isNot(contains('graphify:')));
      expect(repairs(), 1, reason: 'a branch switch');
      commit('c.txt');
      git(['merge', '-q', '--no-edit', 'feature']);
      expect(repairs(), 2, reason: 'a merge commit, through the replay');
      git(['switch', '-q', '-c', 'topic', 'feature']);
      expect(repairs(), 3);
      commit('d.txt');
      git(['rebase', '-q', 'main']);
      expect(
        repairs(),
        4,
        reason: "once, after the rebase; not for the rebase's own checkout",
      );
    });

    test('starts no repair for a file checkout, with a skip variable, or '
        'with a script from before the repair, or none', () {
      commit('a.txt');
      git(['switch', '-q', '-c', 'feature']);
      commit('b.txt');
      writeFile(repo, 'a.txt', 'edited');
      git(['checkout', '--', 'a.txt']);
      git(['switch', '-q', 'main'], extra: {'APPSTEIN_SKIP_GRAPH_HOOK': '1'});
      git(['switch', '-q', 'feature'], extra: {'GRAPHIFY_SKIP_HOOK': '1'});
      writeFile(repo, 'tool/check_graph.py', '# stand-in, before 1a.3\n');
      expect(git(['switch', '-q', 'main']), isEmpty);
      File(p.join(repo.path, 'tool', 'check_graph.py')).deleteSync();
      git(['switch', '-q', 'feature']);
      expect(repairs(), 0);
    });

    test('after a merge with GRAPHIFY_SKIP_HOOK=1, which keeps the repair '
        'off, the check asks for an update as before', () {
      commit('a.txt');
      git(['switch', '-q', '-c', 'feature']);
      commit('b.txt');
      git(['switch', '-q', 'main']);
      commit('c.txt');
      git(
        ['merge', '-q', '--no-edit', 'feature'],
        extra: {'GRAPHIFY_SKIP_HOOK': '1'},
      );
      expect(checks().last, 'tool/check_graph.py --quiet');
      expect(repairs(), 1, reason: 'only the switch to main');
    });
  });
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `fvm dart test test/hooks_test.dart`
Expected: FAIL. The key list has no `post-checkout`, the replay logs `replay=0`, no `--detach` is ever logged, and the merge check has no `--skip-repairable`. The upsert and remove tests still pass.

- [ ] **Step 3: Rewrite the block definitions in `tool/src/hooks.dart`**

Replace everything from the `/// The blocks Appstein keeps…` doc comment through the end of `_graphCheck` (currently lines 11-102) with:

```dart
/// The blocks Appstein keeps in the repo's git hooks, by hook name
/// (spec §19.6).
///
/// Git runs hooks with its own `sh`, on Windows too. Each part of a block
/// runs in a subshell, so its `exit` never stops the next part, or another
/// block in the same file, such as graphify's.
final hookBlocks = {
  'post-checkout': _block([_graphRepair]),
  'post-commit': _block([_docsCheck, _graphCheck(_notWhileRebasing)]),
  'post-merge': _block([_mergeRebuild, _graphCheck('', repairing: true)]),
  'post-rewrite': _block([
    _rebaseRebuild,
    _graphCheck(_onlyAfterRebase, repairing: true),
  ]),
};

String _block(List<String> parts) =>
    '$hookBlockStart\n${parts.join('\n')}\n'
    '# Installed by: fvm dart run tool/install_hooks.dart\n$hookBlockEnd';

const _notWhileRebasing = r'''
  GIT_DIR=${GIT_DIR:-$(git rev-parse --git-dir 2>/dev/null)}
  [ -d "$GIT_DIR/rebase-merge" ] && exit 0
  [ -d "$GIT_DIR/rebase-apply" ] && exit 0
''';

const _onlyAfterRebase = r'''
  [ "$1" = "rebase" ] || exit 0
''';

const _docsCheck =
    r'''
# Warns when the developer guide may have fallen behind this commit
# (spec §19.6). CI is the gate; this only warns. Skip it once with
# APPSTEIN_SKIP_DOCS_HOOK=1.
(
  [ "${APPSTEIN_SKIP_DOCS_HOOK:-0}" = "1" ] && exit 0
''' +
    _notWhileRebasing +
    r'''
  [ -f tool/check_guide.dart ] || exit 0
  git rev-parse -q --verify HEAD~1 >/dev/null || exit 0
  if command -v fvm >/dev/null 2>&1; then
    fvm dart run tool/check_guide.dart --since HEAD~1 --warn-only
  elif command -v dart >/dev/null 2>&1; then
    dart run tool/check_guide.dart --since HEAD~1 --warn-only
  fi
  exit 0
)''';

const _mergeRebuild = r'''
# Rebuilds the graphify graph after a merge or pull, which graphify's own
# hooks miss. It replays the post-checkout hook (graphify's rebuild and the
# graph repair), as if HEAD had switched branches.
(
  hook="$(git rev-parse --git-path hooks)/post-checkout"
  [ -x "$hook" ] || exit 0
  old=$(git rev-parse -q --verify ORIG_HEAD) || exit 0
  APPSTEIN_HOOK_REPLAY=1 "$hook" "$old" "$(git rev-parse HEAD)" 1
)''';

const _rebaseRebuild = r'''
# Rebuilds the graphify graph after a rebase; graphify's post-commit hook
# already covers an amend. It replays the post-checkout hook.
(
  [ "$1" = "rebase" ] || exit 0
  hook="$(git rev-parse --git-path hooks)/post-checkout"
  [ -x "$hook" ] || exit 0
  old=$(git rev-parse -q --verify ORIG_HEAD) || exit 0
  APPSTEIN_HOOK_REPLAY=1 "$hook" "$old" "$(git rev-parse HEAD)" 1
)''';

/// Finds graphify's Python for a graph part of a block: sets `py`, or runs
/// [otherwise] (`sh` lines that end with `exit 0`) when
/// `graphify-out/.graphify_python` is missing or names no executable.
String _graphifyPython(String otherwise) =>
    r'''
  [ -f tool/check_graph.py ] && [ -f graphify-out/graph.json ] || exit 0
  py=""
  [ -f graphify-out/.graphify_python ] &&
    py=$(tr -d '\r\n' < graphify-out/.graphify_python)
  if [ -z "$py" ] || [ ! -x "$py" ]; then
''' +
    otherwise +
    r'''
  fi
''';

/// Starts the graph repair in the background after a branch switch, and
/// when a merge or rebase replays this hook (spec §19.6). It waits for
/// graphify's own rebuild, then puts back the docs that rebuild dropped.
final _graphRepair =
    r'''
# Puts back, from graphify's cache, the docs a code rebuild dropped from the
# knowledge graph (spec §19.6). It runs in the background, after graphify's
# rebuild, and writes to graphify's log. Skip it with
# APPSTEIN_SKIP_GRAPH_HOOK=1; it also stays off with GRAPHIFY_SKIP_HOOK=1.
(
  [ "${APPSTEIN_SKIP_GRAPH_HOOK:-0}" = "1" ] && exit 0
  [ "${GRAPHIFY_SKIP_HOOK:-0}" = "1" ] && exit 0
  [ "$3" = "1" ] && [ "$1" != "$2" ] || exit 0
  if [ "${APPSTEIN_HOOK_REPLAY:-0}" != "1" ]; then
    # A rebase checks out commits on its way; post-rewrite replays this
    # hook once it is done.
    GIT_DIR=${GIT_DIR:-$(git rev-parse --git-dir 2>/dev/null)}
    [ -d "$GIT_DIR/rebase-merge" ] && exit 0
    [ -d "$GIT_DIR/rebase-apply" ] && exit 0
  fi
''' +
    _graphifyPython('    exit 0\n') +
    r'''
  # A branch from before the repair has a check_graph.py without it.
  grep -q -e --detach tool/check_graph.py || exit 0
  "$py" tool/check_graph.py --detach
  exit 0
)''';

/// Warns when the knowledge graph doesn't hold the current docs
/// (spec §19.6), by running `tool/check_graph.py` with graphify's Python.
/// [guard] is `sh` lines that end the check early when this hook shouldn't
/// run it. With [repairing], the hook has just replayed post-checkout, which
/// started the graph repair, so docs missing from the graph are reported as
/// being repaired, unless `GRAPHIFY_SKIP_HOOK=1` kept the repair off.
String _graphCheck(String guard, {bool repairing = false}) =>
    r'''
# Warns when the knowledge graph doesn't hold the current docs (spec §19.6).
# It only warns. Skip it with APPSTEIN_SKIP_GRAPH_HOOK=1.
(
  [ "${APPSTEIN_SKIP_GRAPH_HOOK:-0}" = "1" ] && exit 0
''' +
    guard +
    _graphifyPython(r'''
    echo "graphify: the graph check could not run: graphify-out/.graphify_python doesn't name graphify's Python. Run /graphify . --update to set it."
    exit 0
''') +
    (repairing
        ? r'''
  if [ "${GRAPHIFY_SKIP_HOOK:-0}" = "1" ]; then
    "$py" tool/check_graph.py --quiet
  else
    "$py" tool/check_graph.py --quiet --skip-repairable
  fi
  exit 0
)'''
        : r'''
  "$py" tool/check_graph.py --quiet
  exit 0
)''');
```

About the joins: a Dart multi-line string whose first line is empty drops that line, so each piece starts at its first real line. `_notWhileRebasing`, the guards and `_graphifyPython` start with two spaces and end with a newline. After writing the code, print one block (for example with a throwaway `fvm dart run` script that prints `hookBlocks['post-merge']`) and check that it reads as plain `sh` with no merged lines. `every block is valid sh` runs `sh -n` on all four.

- [ ] **Step 4: Run the tests to see them pass**

Run: `fvm dart test test/hooks_test.dart`
Expected: 18 tests pass.

- [ ] **Step 5: The guide (`docs/guide/docs-tooling.md` and `docs/guide/testing.md`)**

(a) In `## Git hooks`, installer step 2 becomes:

```markdown
2. adds our own block to `post-checkout`, `post-commit`, `post-merge` and `post-rewrite`, from [`hooks.dart`](../../tool/src/hooks.dart). The block sits between `# appstein-hook-start` and `# appstein-hook-end`. An older block is replaced in place; everything else in the file, such as graphify's block, is kept.
```

(b) Replace the hook table with:

```markdown
| Hook | What our block does |
|---|---|
| `post-checkout` | After a branch switch, starts the [background repair](#repairing-the-graph) with `check_graph.py --detach`, and prints nothing. It sits after graphify's block, which has just started graphify's rebuild. It does nothing for a file checkout, for a new branch at the same commit, during a rebase (the rebase's own checkouts), without `tool/check_graph.py` (or with one from before the repair), without a graph or a usable `graphify-out/.graphify_python`, or with `APPSTEIN_SKIP_GRAPH_HOOK=1` or `GRAPHIFY_SKIP_HOOK=1`. |
| `post-commit` | Runs `check_guide.dart --since HEAD~1 --warn-only` through `fvm dart`, or `dart` if there's no `fvm`. It skips during a rebase, on the first commit, when `tool/check_guide.dart` doesn't exist, or when `APPSTEIN_SKIP_DOCS_HOOK=1`. It only warns, and always exits 0. Then it runs the graph check (below). |
| `post-merge` | graphify's hooks miss merges and pulls. This block replays the `post-checkout` hook as if HEAD had switched from `ORIG_HEAD`, with `APPSTEIN_HOOK_REPLAY=1`. graphify's block rebuilds after a fast-forward, but skips while `MERGE_HEAD` exists, which it still does after a real merge commit. Our block starts the repair, whose own rebuild covers that case. Then it runs the graph check. |
| `post-rewrite` | The same, but only after a rebase. git still has the rebase's folder then, so graphify's block skips; `APPSTEIN_HOOK_REPLAY=1` lets ours run. graphify's `post-commit` already covers an amend. |
```

(c) After the `**The graph check in each block**` bullet list, add:

```markdown
**After a merge or rebase, docs being repaired get one calm line.** There the check runs with `--skip-repairable`, because the replay has just started the repair. Docs `missing from the graph` are reported as `graphify: repairing N docs from the cache in the background (…)`, not as a request to run `/graphify . --update`. That line says the hook is changing the graph in the background, and where to look if that fails (the log). Silence would hide it, and the request would send you to an LLM run that isn't needed. With `GRAPHIFY_SKIP_HOOK=1` there is no repair, so the check asks for the update as before. The `post-commit` check is unchanged: a commit doesn't drop docs.
```

(d) In **Switches**, replace the `APPSTEIN_SKIP_GRAPH_HOOK` and `GRAPHIFY_SKIP_HOOK` bullets with:

```markdown
- `APPSTEIN_SKIP_GRAPH_HOOK=1` skips the graph warning and the background repair, the same way.
- `GRAPHIFY_SKIP_HOOK=1` is graphify's own switch. It skips graphify's rebuilds, our merge and rebase replays of them, and the background repair, which rebuilds too.
```

(e) Replace the last sentence of **The cost.** (`The graph check adds about half a second after a commit, merge or rebase.`) with:

```markdown
The graph check adds about half a second after a commit, merge or rebase. A branch switch, merge or rebase also starts the background repair, which takes about 0.2 s in the foreground. It then runs one more code rebuild after graphify's, about 3 seconds on the development machine, in the background.
```

(f) In `## Limits`, append:

```markdown
- **A commit during a repair waits for the next rebuild.** The repair holds graphify's lock for a few seconds. graphify skips a rebuild that starts meanwhile, as it does whenever two overlap. A commit's rebuild queues its changes, and the next rebuild picks them up, usually the next commit's. A branch switch meanwhile starts a repair of its own, which rebuilds after it.
- **The background repair reports only to the log.** If it fails, the terminal doesn't show it. The next commit's warning names any doc still missing, and the `[appstein]` lines in `~/.cache/graphify-rebuild.log` say why.
- **A branch from before the repair** (slice 1a.3) has a `check_graph.py` without `--detach`. The `post-checkout` hook skips the repair there, and the next pull or checkout of a newer branch runs it.
```

(g) In `testing.md`'s `**The hook tests run real git hooks.**` paragraph, replace the sentence starting `The graph block runs against a fake Python,` (through `…prints one line when \`.graphify_python\` is missing.`) with:

```markdown
The graph blocks run against a fake Python, named with a space, that logs its arguments. The tests check that the graph check runs after a commit, a merge and a rebase (once, not for every replayed commit), with `--skip-repairable` after a merge or rebase, stays silent without a graph, and prints one line when `.graphify_python` is missing. They also check that the background repair (`--detach`) starts, silently, on a branch switch and once after a merge or rebase. It must not start for a rebase's own checkouts, a file checkout, a new branch at the same commit, a skip variable, or a `check_graph.py` from before the repair. The fake `post-checkout` hook also logs `APPSTEIN_HOOK_REPLAY`, so the replay tests see that our blocks set it.
```

- [ ] **Step 6: Run every root test, check, format and analyze**

Run: `fvm dart test test`, `fvm dart run tool/check_guide.dart`, `fvm dart format --output=none --set-exit-if-changed .`, `fvm dart analyze --fatal-infos`.
Expected: all pass; `The guide check passed.`; no format changes; `No issues found!`.

- [ ] **Step 7: Hand back to the controller to commit**

Suggested message: `feat(hooks): start the graph repair after checkouts, merges and rebases`

---

### Task 3: the rule, the agent guide and the remaining pages

**Files:**
- Modify: `docs/superpowers/specs/2026-09-29-appstein-design.md` (§19.6, the `CI is the gate; local hooks warn early` bullet, line 945)
- Modify: `AGENTS.md` (the Knowledge graph bullet, the Git hooks gotcha)
- Modify: `docs/guide/debugging.md`, `docs/guide/README.md`, `docs/guide/ci.md`
- Check only: `docs/superpowers/specs/2026-09-29-appstein-design.html` (no change expected; see D2)

**Interfaces:**
- Consumes: the exact lines and flags from Tasks 1 and 2.

- [ ] **Step 1: Spec §19.6.** Replace the `- **CI is the gate; local hooks warn early.** …` bullet with the wording the owner approved in D2, verbatim. If the owner changed it, the controller puts the approved text here before dispatching this task. Change nothing else in the spec; §19.1 stays as it is.

- [ ] **Step 2: `AGENTS.md`.** Two edits.

1. The `- **Knowledge graph:** …` bullet becomes:

```markdown
- **Knowledge graph:** when `graphify-out/GRAPH_REPORT.md` exists, read it before searching the repo. If a hook warned that the graph is behind, or you're starting a session after others changed the repo, run `tool/check_graph.py` with graphify's Python (see `docs/guide/docs-tooling.md`). Run `/graphify . --update` when it names new, changed or deleted docs; docs `missing from the graph` are put back from the cache by the hooks, or at once with `tool/check_graph.py --repair` (no LLM).
```

2. In the `- **Git hooks:** …` gotcha, replace `a post-commit docs warning, and a warning when the graph lacks the current docs.` with `a post-commit docs warning, a warning when the graph lacks the current docs, and a background repair of docs a rebuild dropped from the graph.`

- [ ] **Step 3: `docs/guide/debugging.md`.** Four edits.

(a) In `## The knowledge graph isn't updating`, step 2 becomes:

```markdown
2. Read the rebuild log at `~/.cache/graphify-rebuild.log`. A background rebuild prints its errors there, not in your terminal. Lines starting with `[appstein]` come from our background repair.
```

(b) Step 3 becomes:

```markdown
3. Check that `GRAPHIFY_SKIP_HOOK` isn't set to `1` in your environment. It turns off every graph rebuild, including ours after a merge or rebase, and the background repair.
```

(c) In `## The graph hook says the graph is behind`, replace the bullet that starts `- **A doc still listed as \`missing from the graph\` after an update**` with:

```markdown
- **`missing from the graph` is repaired by itself.** After a branch switch, merge or rebase, a background job puts such docs back from graphify's cache, with no LLM (see [docs-tooling](docs-tooling.md#repairing-the-graph)). After a merge or rebase the hook says `graphify: repairing 1 doc from the cache in the background (…)` instead of warning. If a later warning still names one, run `check_graph.py --repair` by hand, and read the `[appstein]` lines in `~/.cache/graphify-rebuild.log`.
```

(d) After the `**\`graphify: the graph check could not run: …\`**` bullet, add:

```markdown
- **`graphify: could not repair the graph: …`** means the repair failed. With `graphify's rebuild failed`, it quotes graphify's last line: fix what that names, then run `--repair` again. With `didn't put back …`, or a missing function or module, a graphify upgrade changed what the repair calls; fix [`check_graph.py`](../../tool/check_graph.py). Until then, a full `/graphify .` puts the docs back; it reuses cached extractions, so it costs little.
```

- [ ] **Step 4: `docs/guide/README.md` step 4** becomes:

```markdown
4. Install the git hooks: `fvm dart run tool/install_hooks.dart`. It installs graphify's graph rebuilds, a post-commit warning when this guide may have fallen behind the code, a warning when the knowledge graph lacks the current docs, and a background repair of docs a rebuild dropped from it. See [docs-tooling](docs-tooling.md).
```

- [ ] **Step 5: `docs/guide/ci.md`.** In the `- **graphify for the graph check's tests:** …` bullet, replace `CI never builds a graph;` with `CI never builds this repo's graph (the repair tests build tiny ones in temp repos);`.

- [ ] **Step 6: Check the guide and re-read every changed claim**

Run: `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`.
Expected: nothing to update; `The guide check passed.`

Then check each sentence Tasks 1-3 added to the pages against `tool/check_graph.py`, `tool/src/hooks.dart` and the tests as they are now: messages, exit codes, flags, environment variable names, waits, skip conditions. Fix any page text that disagrees (never the code, unless the code is wrong; report either way). Confirm `2026-09-29-appstein-design.html` needs no change.

- [ ] **Step 7: Hand back to the controller to commit**

Suggested message: `docs: the graph repairs docs a rebuild dropped (spec §19.6)`

---

### Task 4 (controller): install, verify, update the graph, merge, prove it live

The controller does this task: it runs graphify's LLM extraction, edits `AGENTS.md` and memory, commits, and merges.

- [ ] **Step 1: Reinstall the hooks on the development machine**

Run: `fvm dart run tool/install_hooks.dart`
Expected: graphify's install output, then `post-checkout: updated`, `post-commit: up to date`, `post-merge: updated`, `post-rewrite: updated`. Read `.git/hooks/post-checkout` and confirm graphify's block comes first and ours after it.

- [ ] **Step 2: Full verification**

Run: `fvm dart test test`; `fvm dart test` in each of `packages/appstein_protocol`, `packages/appstein_engine`, `packages/appstein_cli`, `packages/appstein_lints`; `fvm dart format --output=none --set-exit-if-changed .`; `fvm dart analyze --fatal-infos`; `fvm dart run tool/gen_docs.dart --check`; `fvm dart run tool/check_guide.dart --since main`.
Expected: all green.

- [ ] **Step 3: Record the plan's notes and the phase**

Add a `## Notes from execution` section at the end of this plan: the rulings, D1 and D2 as decided, and anything that differed from the plan. In `AGENTS.md`'s **Current phase**:
- change `M1 slices 1a, 1a.1, 1a.2 and 1b.1 are complete.` to `M1 slices 1a, 1a.1, 1a.2, 1a.3 and 1b.1 are complete.`;
- before `Slice 1b is split`, add `1a.3 made the graph repair itself: docs a code rebuild dropped are put back from graphify's cache in the background after each checkout, merge and rebase, or by hand with \`tool/check_graph.py --repair\` (plan: docs/superpowers/plans/2026-10-01-slice-1a3-graph-self-repair.md).`

Commit with the owner's approval.

- [ ] **Step 4: Update the graph until the check is silent**

Run `/graphify . --update`, relabel the communities, then run the check (PowerShell: `& (Get-Content graphify-out/.graphify_python) tool/check_graph.py`).
Expected: `graphify: the graph is current (<n> docs checked).` Repeat after any later edit.

- [ ] **Step 5: Memory**

Record slice 1a.3 as done (with the merge commit once merged), including findings F1-F3. Mark `project_slice_1a2_graph_staleness.md`'s follow-up as closed. Point the index at slice 1b.2 as next.

- [ ] **Step 6: Finish the branch, per the owner's merge rule**

Use superpowers:finishing-a-development-branch. Push and open a PR only with the owner's explicit OK. CI runs the new tests on Windows, macOS and Linux against graphify `0.9.71`; read the `check_graph_test.dart` and `hooks_test.dart` results on each OS. Re-run the graph check just before merging; it must report nothing. Merge only with the owner's approval, the same way as PR #4 (`gh pr merge <n> --merge --delete-branch`).

- [ ] **Step 7: Prove it live on this merge**

This merge replays the incident. `gh pr merge --delete-branch` switches to the old local `main`, which lacks this plan and has a `check_graph.py` without `--detach`, so our `post-checkout` block skips there and graphify's rebuild drops this plan's nodes. The pull then fast-forwards, and `post-merge` replays `post-checkout` with the new script.
Expected:
1. The terminal shows `graphify: repairing 1 doc from the cache in the background (docs/superpowers/plans/2026-10-01-slice-1a3-graph-self-repair.md).`, possibly with other docs this slice changed.
2. About 30 s later, `& (Get-Content graphify-out/.graphify_python) tool/check_graph.py` prints `graphify: the graph is current (<n> docs checked).`
3. `~/.cache/graphify-rebuild.log` ends with graphify's rebuild lines, then `[appstein] … graphify: repaired … from the cache (…).`

Record the three outputs in memory. If any differs, don't repair by hand first: read the `[appstein]` lines, report, then run `--repair`.
