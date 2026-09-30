# Slice 1a.2: Graph Staleness Warning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Warn whenever the graphify knowledge graph doesn't hold the current docs, so "the graph is up to date" becomes a checked state instead of a remembered step.

**Why this slice exists:** after slice 1a.1 merged, the graph's document layer was behind. The rule said "a full semantic update at the end of each slice": a moment, not a state. Edits made after that moment (spec and plan changes for the owner's decisions) slipped through, and nothing warned. Three causes were found:
1. The docs rules check the repo's state; the graph rule relied on memory.
2. graphify's hooks rebuild only code structure, yet `GRAPH_REPORT.md` still says "Built from commit X", which reads as fresh.
3. graphify's own changed-file list is noisy after a checkout or pull; the content-hashed cache is the accurate signal.

**Architecture:**
- **`tool/check_graph.py`** is the check. It is Python because it is made of graphify calls, and it runs with graphify's own interpreter (the path graphify records in `graphify-out/.graphify_python`) in about 0.5 s. It lists the docs with graphify's `detect`, hashes each with graphify's `file_hash`, and looks for a valid cached extraction under **any** prompt fingerprint. Each agent's graphify skill ships its own extraction prompt, so tying the check to one prompt would call every doc stale for other agents. It also reads `graph.json` for docs that were extracted but never merged, and for docs that were deleted but are still in the graph.
- **`tool/src/hooks.dart`** gains a graph-check subshell in each of our three hook blocks (post-commit, post-merge, post-rewrite). It runs the script with `--quiet`, so it is silent when the graph is current, and it never fails.
- **CI** can't check the graph (it has none; `graphify-out/` is git-ignored), but CI does **test** the script: the `test` job installs a pinned graphify on all three operating systems.
- The rule moves from "at the end of each slice" to a state: before a slice merges, the graph check must report nothing (owner-approved wording, below).

**Tech Stack:** Dart 3.13.4 via Flutter 3.47.5 (FVM), `test`, `path`; Python 3.11 with graphify (`graphifyy` 0.9.71 on the development machine and pinned in CI); git's own `sh` for hooks.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md` §19.1, §19.4 and §19.6. Task 4 applies the owner-approved wording (approved 2026-09-30) quoted verbatim in that task.

## Global Constraints

- **Tooling:** run every Dart command through FVM (`fvm dart …`). The repo pins Flutter **3.47.5** in `.fvmrc`. The `dart` on your PATH may be an older SDK; never use it.
- **graphify's Python** on the development machine: the path in `graphify-out/.graphify_python` (currently `C:\Users\<you>\AppData\Roaming\uv\tools\graphifyy\Scripts\python.exe`, Python 3.11.14, graphifyy 0.9.71). Use it to run `tool/check_graph.py` and the fixture by hand.
- **Windows is first-class:** paths with spaces and non-ASCII characters must work, in the repo path and in the interpreter path. Git hooks are `sh`, because git runs every hook through the `sh` it ships, on Windows too.
- **Output is UTF-8.** On Windows, Python prints in the console's code page unless told otherwise; the script reconfigures stdout and stderr to UTF-8 (a real failure found while prototyping).
- **The graph check never fails anything.** Hooks only warn; the post-* hooks can't block git anyway, and our subshell always exits 0 so later blocks still run.
- **No API keys, no network** in the check or its tests. graphify's semantic extraction (an LLM) is never run by this slice's code; the tests fake an extraction with graphify's own cache writer.
- **Commits:** only the controller (main session) commits. Subagents never commit. Commit messages end with the `Co-Authored-By` and `Claude-Session` trailers from the session.
- **Guide rules (spec §19.6):** every source file (`tool/**` included, so `tool/check_graph.py` too) is covered by a page's `<!-- covers: -->` comment; a change to a covered file changes a covering page; `fvm dart run tool/gen_docs.dart` then `fvm dart run tool/check_guide.dart --since main` must pass at the end. No ```` ```dart ```` blocks in the guide.
- **Every public Dart member** gets a `///` doc comment (the `public_member_api_docs` lint), and `fvm dart analyze --fatal-infos` and `fvm dart format --output=none --set-exit-if-changed .` stay clean.

## Review Focus

1. **A repo or interpreter path with a space or a non-ASCII character** (for example `C:\Program Files\…` or `tëst`). Expect the check to run and print readable UTF-8. Pinned by Task 1's "no graph" test (the temp repo path contains `tëst`) and Task 2's fake Python named `fake python`.
2. **`graphify-out/.graphify_python` written with CRLF or a trailing newline, missing, or naming a file that no longer exists** (graphify was reinstalled). Expect a working check, or one clear "could not run" line, and never a failed hook. Pinned by Task 2's tests.
3. **A graph updated from a different agent** (another extraction prompt) **or in deep mode.** Expect "current", not a false alarm. Pinned by Task 1's "any prompt" and "deep mode" tests.
4. **A clone where graphify was never run** (no `graphify-out/graph.json`), or a checkout of a branch without `tool/check_graph.py`. Expect complete silence from the hook. Pinned by Task 2's "no graph" test.
5. **A graphify upgrade that changes the functions the check calls.** Expect one "could not run" line and exit 3, not a traceback or a false "current". Pinned by Task 1's "API changed" test (a shadowing fake `graphify` package).

---

### Task 1: `tool/check_graph.py` and its tests

**Files:**
- Create: `tool/check_graph.py`
- Create: `test/support/graphify.dart`
- Create: `test/support/graphify_fixture.py`
- Create: `test/check_graph_test.dart`
- Modify: `docs/guide/docs-tooling.md:1-6` (the covers comment only; the prose comes in Task 4)

**Interfaces:**
- Produces: `tool/check_graph.py [--quiet]`, run from the repo root with graphify's Python. Exit `0` = current (prints `graphify: the graph is current (<n> docs checked).` unless `--quiet`), `1` = behind (prints one line, below), `3` = couldn't run (prints `graphify: the graph check could not run: <reason>`, or a usage line on stderr for an unknown argument).
- The behind line, exactly: `graphify: the graph is behind on <count> doc|docs (<reason>: <names>; <reason>: <names>). Run /graphify . --update before relying on it.` Reasons, in this order: `new or changed`, `missing from the graph`, `deleted or no longer scanned`. At most five names per reason, then ` and <n> more`.
- Produces (Dart, `test/support/graphify.dart`): `final String? graphifyPython` and `Object get skipWithoutGraphify`.

- [ ] **Step 1: Write the test support files**

`test/support/graphify.dart`:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

/// A Python that can import graphify, for the graph check's tests, or null
/// when there is none.
///
/// It is `APPSTEIN_GRAPHIFY_PYTHON` when that is set (CI sets it), or else
/// the interpreter this repo's `graphify-out/.graphify_python` names, which
/// graphify writes on each `/graphify` run.
final String? graphifyPython = _findGraphifyPython();

String? _findGraphifyPython() {
  final recorded = File(p.join('graphify-out', '.graphify_python'));
  final fromEnvironment = Platform.environment['APPSTEIN_GRAPHIFY_PYTHON'];
  final candidates = [
    if (fromEnvironment != null && fromEnvironment.isNotEmpty) fromEnvironment,
    if (recorded.existsSync()) recorded.readAsStringSync().trim(),
  ];
  for (final python in candidates) {
    try {
      if (Process.runSync(python, ['-c', 'import graphify']).exitCode == 0) {
        return python;
      }
    } on ProcessException {
      continue;
    }
  }
  return null;
}

/// The `skip:` value for tests that need graphify: false when a
/// [graphifyPython] exists, or else the reason for skipping.
///
/// With `APPSTEIN_REQUIRE_GRAPHIFY=1` (CI sets it) nothing is skipped, so a
/// missing graphify fails the tests instead of letting them pass unrun.
Object get skipWithoutGraphify {
  if (graphifyPython != null) return false;
  if (Platform.environment['APPSTEIN_REQUIRE_GRAPHIFY'] == '1') return false;
  return 'no Python with graphify (see docs/guide/testing.md)';
}
```

`test/support/graphify_fixture.py`:

```python
"""Test fixture: caches a fake semantic extraction of some docs, the way
`/graphify . --update` would, using graphify's own cache writer.

Run it with graphify's Python, from the fixture repo's root:

    graphify_fixture.py <prompt text> [--partial] [--deep] <doc>...

Each doc gets one node. The prompt text picks the p<fingerprint> cache
folder, as each agent's extraction prompt does. --partial marks the entries
as cut short; --deep writes them in deep mode's cache.
"""

import sys
from pathlib import Path

from graphify.cache import save_semantic_cache


def main(argv):
    prompt, *rest = argv
    docs = [a for a in rest if not a.startswith('--')]
    root = Path.cwd()
    paths = [str(root / d) for d in docs]
    nodes = [{'id': f'doc_{i}', 'label': doc, 'file_type': 'document',
              'source_file': doc} for i, doc in enumerate(docs)]
    save_semantic_cache(
        nodes, [], [], root=root, allowed_source_files=paths,
        mode='deep' if '--deep' in rest else None, prompt=prompt,
        partial_source_files=paths if '--partial' in rest else None)


if __name__ == '__main__':
    main(sys.argv[1:])
```

- [ ] **Step 2: Write the failing tests**

`test/check_graph_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/graphify.dart';
import 'support/temp_repo.dart';

final _script = p.absolute('tool', 'check_graph.py');
final _fixture = p.absolute('test', 'support', 'graphify_fixture.py');

const _update = 'Run /graphify . --update before relying on it.';

void main() {
  late String python;
  late Directory repo;

  /// Runs graphify's Python in [repo], without the caller's `GRAPHIFY_OUT`
  /// or `PYTHONPATH`, which would move the graph or shadow graphify.
  ProcessResult runPython(
    List<String> arguments, {
    Map<String, String> environment = const {},
  }) => Process.runSync(
    python,
    arguments,
    workingDirectory: repo.path,
    environment: {
      for (final entry in Platform.environment.entries)
        if (!const {
          'GRAPHIFY_OUT',
          'PYTHONPATH',
        }.contains(entry.key.toUpperCase()))
          entry.key: entry.value,
      ...environment,
    },
    includeParentEnvironment: false,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
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

  /// Writes a graph.json with one node from each of [sources].
  void graph(List<String> sources) => writeFile(
    repo,
    'graphify-out/graph.json',
    jsonEncode({
      'nodes': [
        for (final (i, source) in sources.indexed)
          {'id': 'n$i', 'source_file': source},
      ],
      'links': <Object>[],
    }),
  );

  ({int code, String output}) check([
    List<String> arguments = const [],
    Map<String, String> environment = const {},
  ]) {
    final result = runPython([
      _script,
      ...arguments,
    ], environment: environment);
    return (
      code: result.exitCode,
      output: '${result.stdout}${result.stderr}'.trim(),
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
      graph([r'docs\a.md', p.join(repo.path, 'docs', 'b.md')]);
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
      final result = check(const [], {
        'PYTHONPATH': p.join(repo.path, 'fake'),
      });
      expect(result.code, 3);
      expect(
        result.output,
        startsWith('graphify: the graph check could not run: '),
      );
    });

    test('rejects an unknown argument', () {
      expect(check(['--nope']), (
        code: 3,
        output: 'usage: check_graph.py [--quiet] (unknown: --nope)',
      ));
    });
  });
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `fvm dart test test/check_graph_test.dart`
Expected: FAIL. The script doesn't exist, so Python reports `can't open file …check_graph.py` and exits 2.

- [ ] **Step 4: Write `tool/check_graph.py`**

```python
"""Says whether the graphify knowledge graph holds the current docs (spec §19.6).

graphify's git hooks rebuild only the code structure. What the docs mean is
extracted by an LLM during `/graphify . --update`, so a doc edited after that
run stays behind in the graph until the next one. This check finds those docs:

- new or changed: no extraction of the doc's current content is cached;
- missing from the graph: an extraction is cached, but graph.json has no node
  from the doc;
- deleted or no longer scanned: graph.json has nodes from a doc that graphify
  no longer scans.

An extraction made with any agent's extraction prompt counts, because each
agent's graphify skill ships its own prompt (docs/guide/docs-tooling.md).

Run it with graphify's Python, from the repo root:

    "$(cat graphify-out/.graphify_python)" tool/check_graph.py [--quiet]

Exit codes: 0 the graph is current, 1 docs are behind, 3 the check couldn't
run. With --quiet, nothing is printed when the graph is current.
"""

import json
import sys
from pathlib import Path

_DOC_KINDS = ('document', 'paper', 'image')
_MAX_NAMES = 5


def _entry_is_valid(entry: Path) -> bool:
    """graphify's own rule: a partial or empty cache entry is a miss."""
    try:
        data = json.loads(entry.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return False
    return (isinstance(data, dict) and not data.get('partial')
            and bool(data.get('nodes') or data.get('hyperedges')))


def _is_extracted(doc: Path, root: Path, cache: Path, file_hash) -> bool:
    """Whether some prompt's cache, in any mode, holds this exact content."""
    try:
        name = file_hash(doc, root) + '.json'
    except OSError:
        return False
    for kind in sorted(cache.glob('semantic*')):
        if not kind.is_dir():
            continue
        folders = [kind] + sorted(d for d in kind.iterdir() if d.is_dir())
        if any(_entry_is_valid(f / name) for f in folders if (f / name).is_file()):
            return True
    return False


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


def find_behind(root: Path) -> dict:
    """The number of docs, and the docs the graph is behind on, by reason.

    Raises on anything that stops the check, such as a missing graph or a
    graphify that lacks the functions used here.
    """
    from graphify.cache import file_hash
    from graphify.detect import CODE_EXTENSIONS, FileType, classify_file, detect
    from graphify.paths import GRAPHIFY_OUT

    out = Path(GRAPHIFY_OUT)
    out = out if out.is_absolute() else root / out
    graph_file = out / 'graph.json'
    if not graph_file.is_file():
        raise FileNotFoundError(
            f'there is no graph yet ({graph_file} is missing); run /graphify .')
    graph = json.loads(graph_file.read_text(encoding='utf-8'))

    detected = detect(root)
    docs = sorted({
        Path(f).resolve().relative_to(root).as_posix()
        for kind in _DOC_KINDS for f in detected['files'].get(kind, [])
    })
    in_graph = {
        _relative(str(node['source_file']), root)
        for node in graph.get('nodes', []) if node.get('source_file')
    }
    changed, missing = [], []
    for doc in docs:
        if not _is_extracted(root / doc, root, out / 'cache', file_hash):
            changed.append(doc)
        elif doc not in in_graph:
            missing.append(doc)
    doc_set = set(docs)
    removed = sorted(
        source for source in in_graph
        if source not in doc_set and source != 'None'
        and Path(source).suffix.lower() not in CODE_EXTENSIONS
        and classify_file(Path(source)) not in (FileType.CODE, None)
    )
    return {'docs': len(docs), 'new or changed': changed,
            'missing from the graph': missing,
            'deleted or no longer scanned': removed}


def main(argv: list) -> int:
    # On Windows, Python prints in the console's code page. Paths may hold any
    # character, and git's sh and the tests read UTF-8.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', errors='replace')
    quiet = '--quiet' in argv
    unknown = [a for a in argv if a != '--quiet']
    if unknown:
        print(f'usage: check_graph.py [--quiet] (unknown: {" ".join(unknown)})',
              file=sys.stderr)
        return 3
    try:
        result = find_behind(Path.cwd().resolve())
    except Exception as error:  # noqa: BLE001 - any failure means "couldn't check"
        print(f'graphify: the graph check could not run: {error}')
        return 3
    reasons = [(k, v) for k, v in result.items() if k != 'docs' and v]
    if not reasons:
        if not quiet:
            print(f'graphify: the graph is current ({result["docs"]} docs checked).')
        return 0
    count = sum(len(v) for _, v in reasons)
    detail = '; '.join(f'{k}: {_names(v)}' for k, v in reasons)
    noun = 'doc' if count == 1 else 'docs'
    print(f'graphify: the graph is behind on {count} {noun} ({detail}). '
          'Run /graphify . --update before relying on it.')
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `fvm dart test test/check_graph_test.dart`
Expected: 12 tests pass (on the development machine graphify is installed, so none skip).

- [ ] **Step 6: Run the check on the real repo**

Run (Git Bash): `"$(cat graphify-out/.graphify_python)" tool/check_graph.py`
Expected: exit 1 naming the docs this task changed that are in graphify's scan, such as `docs/guide/docs-tooling.md`. `.py` and `.dart` files are code to graphify, not docs. That's correct: the graph is behind until Task 5's update. Record the output in the report.

- [ ] **Step 7: Cover the script in the guide**

In `docs/guide/docs-tooling.md`, add `tool/check_graph.py` to the covers comment, after `tool/check_guide.dart`:

```text
<!-- covers:
tool/check_guide.dart
tool/check_graph.py
tool/gen_docs.dart
tool/install_hooks.dart
tool/src/**
-->
```

Then run: `fvm dart run tool/check_guide.dart`
Expected: `The guide check passed.` (no `--since` here; Task 4 writes the prose).

- [ ] **Step 8: Format and analyze**

Run: `fvm dart format test/check_graph_test.dart test/support/graphify.dart` then `fvm dart analyze --fatal-infos`
Expected: no changes needed after formatting, and `No issues found!`

- [ ] **Step 9: Hand back to the controller to commit**

Suggested message: `feat(tool): check_graph.py warns when the graph lacks the current docs`

---

### Task 2: the graph check in our git hook blocks

**Files:**
- Modify: `tool/src/hooks.dart:11-69` (the block definitions)
- Modify: `test/support/temp_repo.dart:38-66` (split `runGit` so tests can read hook output)
- Modify: `test/hooks_test.dart` (a new group)

**Interfaces:**
- Consumes: `tool/check_graph.py [--quiet]` from Task 1: exit 0/1/3, silent with `--quiet` when current.
- Produces: `hookBlocks` stays a `Map<String, String>` with the same keys (`post-commit`, `post-merge`, `post-rewrite`), each value still starting with `# appstein-hook-start\n` and ending with `# appstein-hook-end`. It changes from `const` to `final`.
- Produces: `ProcessResult gitResult(Directory repo, List<String> arguments, {Map<String, String> environment})` in `test/support/temp_repo.dart`; `runGit` keeps its signature and behaviour.
- The hook's own message, exactly: `graphify: the graph check could not run: graphify-out/.graphify_python doesn't name graphify's Python. Run /graphify . --update to set it.`

- [ ] **Step 1: Split `runGit` in `test/support/temp_repo.dart`**

Replace the `runGit` function with:

```dart
/// Runs git in [repo] with a fixed identity, no signing and no line-ending
/// conversion, and returns the whole result without checking it. Hooks print
/// to stderr, so this is how a test reads what a hook said.
ProcessResult gitResult(
  Directory repo,
  List<String> arguments, {
  Map<String, String> environment = const {},
}) => Process.runSync(
  'git',
  [
    '-c',
    'user.name=Appstein Test',
    '-c',
    'user.email=test@example.com',
    '-c',
    'commit.gpgsign=false',
    '-c',
    'core.autocrlf=false',
    ...arguments,
  ],
  workingDirectory: repo.path,
  environment: gitEnvironment(environment),
  includeParentEnvironment: false,
);

/// Runs git in [repo] like [gitResult], and returns what it printed to
/// stdout. Throws when git fails.
String runGit(
  Directory repo,
  List<String> arguments, {
  Map<String, String> environment = const {},
}) {
  final result = gitResult(repo, arguments, environment: environment);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout as String;
}
```

Run: `fvm dart test test`
Expected: every existing test still passes.

- [ ] **Step 2: Write the failing tests**

Add this group at the end of `main()` in `test/hooks_test.dart`:

```dart
  group('the graph check, run by git', () {
    late Directory repo;
    late File log;
    late File fakePython;
    const env = {'APPSTEIN_SKIP_DOCS_HOOK': '1'};

    List<String> logged() =>
        log.existsSync() ? log.readAsLinesSync() : const [];

    /// Commits [file] and returns everything git and its hooks printed.
    String commit(String file, {Map<String, String> extra = const {}}) {
      writeFile(repo, file, file);
      runGit(repo, ['add', '.'], environment: {...env, ...extra});
      final result = gitResult(repo, [
        'commit',
        '-q',
        '-m',
        file,
      ], environment: {...env, ...extra});
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
      writeFile(repo, 'tool/check_graph.py', '# stand-in\n');
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
      final skipped = commit(
        'a.txt',
        extra: {'APPSTEIN_SKIP_GRAPH_HOOK': '1'},
      );
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
      File(
        p.join(repo.path, 'graphify-out', '.graphify_python'),
      ).deleteSync();
      expect(commit('b.txt'), contains(message));
      expect(logged(), isEmpty);
    });

    test('runs once after a merge, not during a rebase, once after it, and '
        'not again for an amend', () {
      commit('a.txt');
      runGit(repo, ['switch', '-q', '-c', 'feature'], environment: env);
      commit('b.txt');
      runGit(repo, ['switch', '-q', 'main'], environment: env);
      commit('c.txt');
      expect(logged(), hasLength(3));
      runGit(repo, [
        'merge',
        '-q',
        '--no-edit',
        'feature',
      ], environment: env);
      expect(logged(), hasLength(4), reason: 'post-merge');
      runGit(repo, ['switch', '-q', '-c', 'topic', 'feature'], environment: env);
      commit('d.txt');
      commit('e.txt');
      expect(logged(), hasLength(6));
      runGit(repo, ['rebase', '-q', 'main'], environment: env);
      expect(
        logged(),
        hasLength(7),
        reason: 'post-rewrite once; post-commit skipped while rebasing',
      );
      runGit(repo, [
        'commit',
        '-q',
        '--amend',
        '-m',
        'e amended',
      ], environment: env);
      expect(logged(), hasLength(8), reason: 'post-commit only');
    });
  });
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `fvm dart test test/hooks_test.dart`
Expected: the new group's tests FAIL (the log stays empty; the message is never printed). The existing tests pass.

- [ ] **Step 4: Rewrite the block definitions in `tool/src/hooks.dart`**

Replace everything from the `/// The blocks Appstein keeps…` doc comment through the end of `_postRewrite` (currently lines 11–69) with:

```dart
/// The blocks Appstein keeps in the repo's git hooks, by hook name
/// (spec §19.6).
///
/// Git runs hooks with its own `sh`, on Windows too. Each part of a block
/// runs in a subshell, so its `exit` never stops the next part, or another
/// block in the same file, such as graphify's.
final hookBlocks = {
  'post-commit': _block([_docsCheck, _graphCheck(_notWhileRebasing)]),
  'post-merge': _block([_mergeRebuild, _graphCheck('')]),
  'post-rewrite': _block([_rebaseRebuild, _graphCheck(_onlyAfterRebase)]),
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
# hooks miss. It reuses graphify's post-checkout rebuild, as if HEAD had
# switched branches.
(
  hook="$(git rev-parse --git-path hooks)/post-checkout"
  [ -x "$hook" ] || exit 0
  old=$(git rev-parse -q --verify ORIG_HEAD) || exit 0
  "$hook" "$old" "$(git rev-parse HEAD)" 1
)''';

const _rebaseRebuild = r'''
# Rebuilds the graphify graph after a rebase; graphify's post-commit hook
# already covers an amend. It reuses graphify's post-checkout rebuild.
(
  [ "$1" = "rebase" ] || exit 0
  hook="$(git rev-parse --git-path hooks)/post-checkout"
  [ -x "$hook" ] || exit 0
  old=$(git rev-parse -q --verify ORIG_HEAD) || exit 0
  "$hook" "$old" "$(git rev-parse HEAD)" 1
)''';

/// Warns when the knowledge graph doesn't hold the current docs
/// (spec §19.6), by running `tool/check_graph.py` with graphify's Python.
/// [guard] is `sh` lines that end the check early when this hook shouldn't
/// run it.
String _graphCheck(String guard) =>
    r'''
# Warns when the knowledge graph doesn't hold the current docs (spec §19.6).
# It only warns. Skip it with APPSTEIN_SKIP_GRAPH_HOOK=1.
(
  [ "${APPSTEIN_SKIP_GRAPH_HOOK:-0}" = "1" ] && exit 0
''' +
    guard +
    r'''
  [ -f tool/check_graph.py ] && [ -f graphify-out/graph.json ] || exit 0
  py=""
  [ -f graphify-out/.graphify_python ] &&
    py=$(tr -d '\r\n' < graphify-out/.graphify_python)
  if [ -z "$py" ] || [ ! -x "$py" ]; then
    echo "graphify: the graph check could not run: graphify-out/.graphify_python doesn't name graphify's Python. Run /graphify . --update to set it."
    exit 0
  fi
  "$py" tool/check_graph.py --quiet
  exit 0
)''';
```

Note the joins: `_notWhileRebasing` and the guards start with two spaces and end with a newline, and the pieces they are joined to end and start with a newline, so every line keeps its indentation. After writing it, print one block (`fvm dart run` a throwaway snippet, or read it in a test failure) and check it reads as plain `sh` with no blank-line gaps or merged lines. The existing test `every block is valid sh` runs `sh -n` on all three.

- [ ] **Step 5: Run the tests to see them pass**

Run: `fvm dart test test/hooks_test.dart`
Expected: every test passes, the old ones included (`every block is marked and runs in a subshell`, `every block is valid sh`, the upsert/remove tests, and the merge and rebase replays).

If `the graph check, run by git` fails only on Windows because git's `sh` can't start `…\fake python` by its Windows path, don't change the path format the test writes: the real `.graphify_python` holds a Windows path, so the block must handle it. Report the exact error instead.

- [ ] **Step 6: Run every root test, format and analyze**

Run: `fvm dart test test`, then `fvm dart format --output=none --set-exit-if-changed .`, then `fvm dart analyze --fatal-infos`
Expected: all pass; no format changes; `No issues found!`

- [ ] **Step 7: Hand back to the controller to commit**

Suggested message: `feat(hooks): warn after commits, merges and rebases when the graph lacks the current docs`

---

### Task 3: CI tests the check against a pinned graphify

**Files:**
- Modify: `.github/workflows/ci.yml` (the top `env:` and the `test` job)
- Modify: `docs/guide/ci.md` (the generated `ci-jobs` section, through `gen_docs`, and the `### test` bullets)

**Interfaces:**
- Consumes: `test/support/graphify.dart` from Task 1 reads `APPSTEIN_GRAPHIFY_PYTHON` and `APPSTEIN_REQUIRE_GRAPHIFY`.

- [ ] **Step 1: Pin the version at the top of `ci.yml`**

In the workflow's top-level `env:` block, after `FLUTTER_MIN`, add:

```yaml
  GRAPHIFY_VERSION: "0.9.71" # tests of tool/check_graph.py (docs/guide/testing.md)
```

- [ ] **Step 2: Install it in the `test` job**

In the `test` job, between the `subosito/flutter-action@v2` step and `dart pub get --enforce-lockfile`, add:

```yaml
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Install graphify for the graph check's tests
        shell: bash
        # Pinned, so a graphify release can't break CI unannounced. With
        # APPSTEIN_REQUIRE_GRAPHIFY=1 the tests fail instead of skipping
        # when graphify is missing.
        run: |
          python -m pip install --disable-pip-version-check "graphifyy==$GRAPHIFY_VERSION"
          echo "APPSTEIN_GRAPHIFY_PYTHON=$(python -c 'import sys; print(sys.executable)')" >> "$GITHUB_ENV"
          echo "APPSTEIN_REQUIRE_GRAPHIFY=1" >> "$GITHUB_ENV"
```

- [ ] **Step 3: Regenerate the CI page and describe the step**

Run: `fvm dart run tool/gen_docs.dart`
Expected: `Updated docs/guide/ci.md`. The `test` job's list gains `actions/setup-python@v5` and `Install graphify for the graph check's tests`.

In `docs/guide/ci.md`, under `### test`, add this bullet after the first one (the "runs on Linux, Windows and macOS" bullet):

```markdown
- **graphify for the graph check's tests:** it installs graphify, at the version pinned in `GRAPHIFY_VERSION` at the top of `ci.yml`, so the tests of [`tool/check_graph.py`](../../tool/check_graph.py) run on all three systems. It also sets `APPSTEIN_REQUIRE_GRAPHIFY=1`, which makes those tests fail instead of skip if graphify is missing. CI never builds a graph; see [docs-tooling](docs-tooling.md#is-the-graph-current) for why the graph itself isn't checked here.
```

(The `#is-the-graph-current` anchor is created in Task 4; the link checker ignores the part after `#`.)

- [ ] **Step 4: Check**

Run: `fvm dart run tool/gen_docs.dart --check`, then `fvm dart run tool/check_guide.dart`
Expected: up to date; `The guide check passed.`

- [ ] **Step 5: Hand back to the controller to commit**

Suggested message: `ci: test tool/check_graph.py against a pinned graphify on every OS`

The controller then pushes the branch and opens a **draft** PR only with the owner's OK, because CI runs on pull requests. Otherwise the CI change is verified when the slice's PR is opened.

---

### Task 4: the rule, as owner-approved wording, and the guide

**Files:**
- Modify: `docs/superpowers/specs/2026-09-29-appstein-design.md` (§19.1 line 879, §19.4 line 904, §19.6 line 945)
- Modify: `AGENTS.md` (the Knowledge graph bullet, the Per slice rule, the Git hooks gotcha)
- Modify: `docs/guide/docs-tooling.md`, `docs/guide/debugging.md`, `docs/guide/testing.md`, `docs/guide/README.md`
- Check only: `docs/superpowers/specs/2026-09-29-appstein-design.html`. Its one graphify sentence (line 814) makes no claim about when the graph is updated, so it doesn't change. Confirm that, and change nothing.

**Interfaces:**
- Consumes: the exact messages and exit codes from Tasks 1 and 2, and the CI step from Task 3.

- [ ] **Step 1: Spec §19.1.** Replace the whole `- **graphify from the first commit.** …` bullet with, verbatim:

```markdown
- **graphify from the first commit.** The graph covers code, this spec, the research report and docs. Git hooks rebuild its code structure on each commit, checkout, merge and rebase. What the docs mean (the semantic layer) needs an LLM, so `/graphify . --update` refreshes it, and a hook warns whenever a doc's current content isn't in the graph (§19.6). Agent sessions start from the graph instead of rediscovering the repo, and update it first when it is behind.
```

- [ ] **Step 2: Spec §19.4.** Replace the `- **Per slice:** …` bullet with, verbatim:

```markdown
- **Per slice:** spec → implementation plan → TDD implementation → verify → docs (API doc comments, the guide pages for what the slice built, `gen_docs` and the guide check (§19.6), then `/graphify . --update` until the graph warning is silent) → owner review → commit. The warning must still be silent when a slice merges, because edits made after the update put the graph behind again.
```

- [ ] **Step 3: Spec §19.6.** Replace the `- **CI is the gate; a local hook warns early.** …` bullet with, verbatim:

```markdown
- **CI is the gate; local hooks warn early.** `tool/install_hooks.dart` installs the repo's git hooks: graphify's code rebuild (on commit, checkout, merge and rebase), a post-commit warning when a page is stale or a generated section is out of date, and a graph warning after each commit, merge and rebase naming every doc whose current content isn't in the graph (new, changed or deleted). CI can't check the graph because it doesn't have one, so the per-slice rule (§19.4) keeps that warning silent before a merge.
```

- [ ] **Step 4: AGENTS.md.** Three edits:

1. The `- **Knowledge graph:** …` bullet becomes:

```markdown
- **Knowledge graph:** when `graphify-out/GRAPH_REPORT.md` exists, read it before searching the repo. If a hook warned that the graph is behind, or you're starting a session after others changed the repo, run `tool/check_graph.py` with graphify's Python (see `docs/guide/docs-tooling.md`) and run `/graphify . --update` when it names docs.
```

2. In the `- **Per slice:** …` rule, replace `then a full \`/graphify . --update\`, because the git hooks refresh only code structure.` with:

```markdown
then `/graphify . --update` until `tool/check_graph.py` reports nothing, because the git hooks refresh only code structure; it must still report nothing when the slice merges.
```

3. In the `- **Git hooks:** …` gotcha, replace `and a post-commit docs warning.` with `a post-commit docs warning, and a warning when the graph lacks the current docs.`

- [ ] **Step 5: `docs/guide/docs-tooling.md`.** Five edits.

(a) In `## The rules`, replace the `- **CI is the gate; a local hook warns early.** …` bullet with:

```markdown
- **CI is the gate; local hooks warn early.** The check runs in CI's `docs` job, and a git hook runs it after each commit as a warning. Another hook warns when the knowledge graph doesn't hold the current docs (see [Is the graph current?](#is-the-graph-current)).
```

(b) Insert this section immediately before `## Git hooks`:

````markdown
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
| `3` | The check couldn't run: there is no graph yet, graphify can't be imported, or a graphify release changed the functions the check calls. It prints `graphify: the graph check could not run: <reason>` |

**Why it isn't in CI.** CI has no graph: `graphify-out/` is git-ignored and built on each developer's machine. CI does test the script against a pinned graphify (see [ci](ci.md)). The rule lives in the per-slice process instead: before a slice merges, this check must report nothing ([spec §19.4](../superpowers/specs/2026-09-29-appstein-design.md#194-git-and-process)).
````

(c) In `## Git hooks`, replace the table and the `**Why tiny \`sh\` blocks.**` paragraph with:

```markdown
| Hook | What our block does |
|---|---|
| `post-commit` | Runs `check_guide.dart --since HEAD~1 --warn-only` through `fvm dart`, or `dart` if there's no `fvm`. It skips during a rebase, on the first commit, when `tool/check_guide.dart` doesn't exist, or when `APPSTEIN_SKIP_DOCS_HOOK=1`. It only warns, and always exits 0. Then it runs the graph check (below). |
| `post-merge` | graphify's hooks miss merges and pulls. This block runs graphify's `post-checkout` hook as if HEAD had switched from `ORIG_HEAD`, so the graph is rebuilt. Then it runs the graph check. |
| `post-rewrite` | The same, but only after a rebase. graphify's `post-commit` already covers an amend. |

**The graph check in each block** runs [`check_graph.py`](../../tool/check_graph.py) `--quiet` with the Python named in `graphify-out/.graphify_python`, a file graphify writes on each `/graphify` run. It prints nothing when the graph is current, and one line when it isn't:

- It is skipped when there's no `tool/check_graph.py` or no `graphify-out/graph.json` (a clone where graphify was never run), during a rebase (`post-rewrite` checks once at the end), or when `APPSTEIN_SKIP_GRAPH_HOOK=1`.
- If `.graphify_python` is missing or names a file that isn't there, it prints `graphify: the graph check could not run: …` instead.
- It never stops the hook: the other parts of the block, and graphify's block, still run.

**Why tiny `sh` blocks.** Git runs every hook with its own `sh`, on Windows too, so a hook must be a shell script. Each part of a block is a few lines that call a tested Dart tool, graphify's own hook, or (for the graph) a tested Python script made of graphify calls, so the logic stays in tested code. Each part runs in a `( … )` subshell, so its `exit` can't stop another part or another block in the same file. (The `AGENTS.md` rule "no bash scripts" is about the hooks Appstein will install for agents, not these.)
```

In **Switches**, add after the `APPSTEIN_SKIP_DOCS_HOOK` bullet (and its PowerShell example):

```markdown
- `APPSTEIN_SKIP_GRAPH_HOOK=1` skips the graph warning, the same way.
```

Replace the **The cost.** paragraph with:

```markdown
**The cost.** graphify rebuilds in the background, so it doesn't slow a commit. The docs check does: it takes a few seconds (about 2.7 s on the development machine) after each commit. That cost is why doc comments are read as text, not with the analyzer. The graph check adds about half a second after a commit, merge or rebase.
```

(d) Replace the whole `## At the end of each slice` section (heading, list and the sentence after it) with:

```markdown
## The docs step of each slice

1. `fvm dart run tool/gen_docs.dart`
2. `fvm dart run tool/check_guide.dart --since main`
3. `/graphify . --update`, then the [graph check](#is-the-graph-current), until it reports nothing. The hooks rebuild only the code structure, not what the docs mean.

Any edit after step 3, such as a review fix, puts the graph behind again, and the hook says so. The check must still report nothing when the slice merges. This is the docs step of the per-slice process in [`AGENTS.md`](../../AGENTS.md).
```

(e) In `## Limits`, append:

```markdown
- **The graph check sees content, not history.** If extractions of both an old and a new version of a doc are cached, for example after switching between branches that differ in it, the check can't tell which version the graph holds. A full `/graphify .` settles it; it reuses cached extractions, so it costs little.
- **The graph hook looks only in `graphify-out/`.** With graphify's `GRAPHIFY_OUT` pointing at another folder, the hook finds no graph and stays silent. Run the check by hand with the same variable set.
```

- [ ] **Step 6: `docs/guide/debugging.md`.** Two edits.

(a) In `## The knowledge graph isn't updating`, replace the closing paragraph (`Two more things to know: …`) with:

```markdown
Two more things to know: graphify's hooks do nothing in a linked git worktree, and they rebuild only the code structure. What the docs mean needs `/graphify . --update`; the graph hook below tells you when.
```

(b) Insert this section right after that one:

````markdown
## The graph hook says the graph is behind

After a commit, merge or rebase you may see:

```text
graphify: the graph is behind on 2 docs (new or changed: docs/guide/cli.md, docs/guide/doctor.md). Run /graphify . --update before relying on it.
```

It means the graph's picture of those docs is older than the files (see [docs-tooling](docs-tooling.md#is-the-graph-current)). It is a warning, not a failure:

- **Run `/graphify . --update`** in your agent, then run the check by hand to confirm it reports nothing.
- **A doc still listed as `missing from the graph` after an update** was extracted, but graphify's change detection saw no change, so the update didn't merge it again. Run a full `/graphify .`: it reuses cached extractions, so it costs little.
- **After switching branches**, it names the docs that differ from the branch the graph was last updated on. That's true: the graph describes the other branch's version of them.
- **graphify's own change list is noisier than this check.** After a checkout or pull, `/graphify . --update` may say dozens of docs changed, because graphify's code-only rebuilds reset its record of the docs. Only the docs whose content really changed are sent to the LLM, because graphify checks its content-hashed cache first; this hook reads the same cache.
- **`graphify: the graph check could not run: …`** means the check itself failed. If it names `.graphify_python`, the file is missing or names a Python that no longer exists (for example after reinstalling graphify); any `/graphify` run rewrites it. If it names a missing function or module, a graphify upgrade changed what the check calls; fix [`check_graph.py`](../../tool/check_graph.py), whose tests in CI pin a graphify version.

With no graph at all (graphify never run in this clone), the hook says nothing.
````

- [ ] **Step 7: `docs/guide/testing.md`.** Two edits.

(a) In the `**The hook tests run real git hooks.**` paragraph, replace `The docs block is switched off there with \`APPSTEIN_SKIP_DOCS_HOOK=1\`.` with:

```markdown
The docs block is switched off there with `APPSTEIN_SKIP_DOCS_HOOK=1`. The graph block runs against a fake Python, named with a space, that logs its arguments; the tests check that it runs after a commit, a merge and a rebase (once, not for every replayed commit), stays silent without a graph, and prints one line when `.graphify_python` is missing. `gitResult()` returns what git and its hooks printed, since hooks print to stderr.
```

(b) Add this paragraph right after that one:

```markdown
**The graph check runs against real graphify.** `check_graph_test.dart` builds a temp repo with docs, fakes an update with [`graphify_fixture.py`](../../test/support/graphify_fixture.py), which writes real cache entries through graphify's own code, and writes a small `graph.json`. It then runs `tool/check_graph.py` and checks what it prints. It needs a Python that can import graphify. [`graphify.dart`](../../test/support/graphify.dart) uses `APPSTEIN_GRAPHIFY_PYTHON` when it is set, or else the interpreter this repo's `graphify-out/.graphify_python` names. Without one, those tests are skipped, except when `APPSTEIN_REQUIRE_GRAPHIFY=1`: CI sets it after installing a pinned graphify (see [ci](ci.md)), so there a missing graphify fails the tests instead.
```

Also in the `- **\`runGit()\`**: …` bullet of the helper list, append: ` \`gitResult()\` is the same, but returns the whole result without checking it.`

- [ ] **Step 8: `docs/guide/README.md` step 4** becomes:

```markdown
4. Install the git hooks: `fvm dart run tool/install_hooks.dart`. It installs graphify's graph rebuilds, a post-commit warning when this guide may have fallen behind the code, and a warning when the knowledge graph lacks the current docs. See [docs-tooling](docs-tooling.md).
```

- [ ] **Step 9: Check the guide**

Run: `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`
Expected: nothing to update; `The guide check passed.` Every source file this slice changed (`tool/check_graph.py`, `tool/src/hooks.dart`, `.github/workflows/ci.yml`) has a covering page changed in the range, so the stale check passes without trailers.

- [ ] **Step 10: Re-read every changed claim against the code**

For each sentence Steps 5–8 added, check it against `tool/check_graph.py`, `tool/src/hooks.dart`, `test/support/graphify.dart` and `.github/workflows/ci.yml` as they are now: messages, exit codes, skip conditions, env variable names and the file names. Fix any page text that disagrees (never the code, unless the code is wrong; report either way).

- [ ] **Step 11: Hand back to the controller to commit**

Suggested message: `docs: make the graph's freshness a checked state (spec §19.1, §19.4, §19.6)`

---

### Task 5 (controller): install, update the graph, verify, record

This task runs graphify's LLM extraction and edits memory, so the controller does it, not a subagent.

- [ ] **Step 1: Reinstall the hooks on the development machine**

Run: `fvm dart run tool/install_hooks.dart`
Expected: `post-commit: updated`, `post-merge: updated`, `post-rewrite: updated`. Then read `.git/hooks/post-commit` and confirm graphify's block is still there next to ours.

- [ ] **Step 2: Full verification**

Run: `fvm dart test test`, each package's `fvm dart test`, `fvm dart format --output=none --set-exit-if-changed .`, `fvm dart analyze --fatal-infos`, `fvm dart run tool/gen_docs.dart --check`, `fvm dart run tool/check_guide.dart --since main`.
Expected: all green.

- [ ] **Step 3: Record the plan's notes**

Add a `## Notes from execution` section at the end of this plan, with the rulings and anything that differed from the plan. Update `AGENTS.md`'s **Current phase** to say slices 1a, 1a.1 and 1a.2 are complete (1a.2: the graph-staleness warning, plan `docs/superpowers/plans/2026-09-30-slice-1a2-graph-staleness.md`), and that next is planning slice 1b. Commit (with the owner's approval for the slice as a whole).

- [ ] **Step 4: Update the graph, and prove the new rule on itself**

Run `/graphify . --update` (the graphify skill, incremental: only uncached docs go to extraction subagents), relabel the communities, then run `"$(cat graphify-out/.graphify_python)" tool/check_graph.py`.
Expected: `graphify: the graph is current (<n> docs checked).` Then make one more commit (for example the notes above, if not yet committed) and confirm the post-commit hook prints no `graphify:` line.

- [ ] **Step 5: Memory**

Mark `project_slice_1a2_graph_staleness.md` as done (with the merge commit once merged), fix the stale description line in `project_slice_1a1_docs_rules.md` (it still says "not yet pushed or merged"), and point the index at slice 1b as next.

- [ ] **Step 6: Finish the branch**

Use superpowers:finishing-a-development-branch. Push and open a PR only with the owner's OK; before merging, re-run the graph check, because the rule is that it reports nothing when the slice merges.
