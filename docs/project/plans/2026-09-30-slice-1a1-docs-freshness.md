# Slice 1a.1: Developer Guide Freshness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the developer guide (`docs/guide/`) explain the whole current system, and make it impossible for it to fall behind the code unnoticed. Four mechanisms enforce this:
- a coverage map;
- a stale-page check with a `Docs-Checked` escape hatch;
- generated sections for facts the code already knows;
- repo-installable git hooks (graphify's graph rebuilds and a docs warning).

**Architecture:** Everything lives in the root workspace package's `tool/` folder, and the checks never touch the four product packages.

Repo files:
- `tool/check_guide.dart` is the single gate. It checks links and paths, that every page is linked, the coverage map, the stale-page check (with `--since`) and that generated sections are up to date.
- `tool/gen_docs.dart` rewrites generated sections.
- `tool/install_hooks.dart` installs graphify's hooks, then keeps one marked block of our own in `post-commit`, `post-merge` and `post-rewrite`.

The logic sits in small, tested files under `tool/src/`:
- **`git_repo.dart`** runs the read-only git queries.
- **`coverage.dart`** holds the covers comments and the coverage check.
- **`stale_check.dart`** holds the stale-page check and the trailers.
- **`guide_checker.dart`** already exists; it gains the "linked from the start page" check.
- **`generated_sections.dart`** handles the section markers.
- **`doc_comments.dart`** reads `///` comments from source text.
- **`generators.dart`** renders the five sections.
- **`generated_docs.dart`** regenerates the whole guide.
- **`guide_check.dart`** runs every check.
- **`hooks.dart`** holds the hook blocks and the install logic.

Two content tasks then rewrite and extend the guide until the check passes on the real repo.

**Tech Stack:**
- Dart 3.13.4, via Flutter 3.47.5 pinned with FVM.
- Libraries: `args`, `glob`, `path`, `yaml`, plus the workspace's own `appstein_cli` and `appstein_engine` as root dev dependencies.
- Testing: `test`.
- `git` is called as a real process in tests, and git hooks run through git's own `sh`.
- **No `package:analyzer`.** A measurement on the development machine (2026-09-30) found that importing it makes `dart run` take 8.8 s warm, against 2.2 s without it. The post-commit hook runs the check on every commit, so doc comments are read as text instead. `dart format` keeps their layout stable.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md` §19.6 "Keeping the guide correct" (amended and approved 2026-09-30), plus §19.1 (graphify hooks), §19.3 (`docs` job) and §19.4 (the per-slice docs step).

## Global Constraints

- **Tooling:** run every Dart command through FVM (`fvm dart …`). The repo pins Flutter **3.47.5** in `.fvmrc`. The `dart` on your PATH may be an older SDK; never use it.
- **SDK:** the root `pubspec.yaml` keeps `environment: sdk: ^3.12.0`. Every new dependency must already resolve on Flutter 3.44 (CI's `min-sdk` job). `args`, `glob`, `path` and `yaml` are already in `pubspec.lock` at versions that do.
- **Windows is first-class:** repo paths with spaces and non-ASCII characters must work. Git hooks are `sh` files, because git runs every hook through the `sh` it ships, on Windows too. They stay tiny and call Dart tools, so the logic is in tested Dart. (AGENTS.md's "no bash scripts" rule is about hooks Appstein installs *for agents*; it doesn't apply here.)
- **Spec §19.6 rules, verbatim in behaviour:**
  - Every guide page starts with a hidden `<!-- covers: … -->` comment.
  - Source means `packages/*/lib/`, `packages/*/bin/`, `tool/` and `.github/workflows/`.
  - The check fails if any source file is covered by no page.
  - The check fails if a change edits a covered file but none of its pages, unless a commit trailer `Docs-Checked: <page> - <reason>` names one of them.
  - Generated sections sit between `<!-- generated:<name> -->` markers, and CI fails if regenerating would change a page.
  - CI is the gate; the local hook only warns.
- **Guide content rules (spec §19.6):**
  - The guide explains the *current* system and links to the spec for the "what and why". It never restates the spec.
  - No pages or sections about code that doesn't exist yet.
  - No ```` ```dart ```` code blocks until slice 1f; the checker refuses them. ```` ```text ````, ```` ```powershell ```` and ```` ```mermaid ```` blocks are fine.
  - Every claim is checked against the code it describes.
- **Documentation:** every public member in `tool/` gets a `///` doc comment. Doc comments say what a thing is for, not how it is implemented.
- **Exit codes for the tools:**
  - `0`: passed.
  - `1`: problems found.
  - `3`: the tool itself couldn't run, such as bad usage or not being in a git repo. This mirrors spec §9.5.
- **Git:**
  - Work on the branch `slice-1a1`.
  - The controller (main session) commits each task; subagents never commit.
  - Never push without the owner's explicit OK.
  - Commit messages end with the `Co-Authored-By` and `Claude-Session` trailers given in the session.

## Review Focus

These are inputs the spec implies but no feature test would naturally hit. Each has a pinned test in the task that owns the code.

1. **A repo path with spaces and non-ASCII characters** (`C:\Users\Jöhn Doe\appstein`). The git queries, glob matching and real hook scripts must all work. Pinned by the `tempRepo()` helper (Task 1), which every git and hook test uses, and by the hook shell tests (Task 7).
2. **Files that move:**
   - A renamed or deleted source file must trip the stale-page check under both its old and new path.
   - A tracked file deleted from disk isn't "uncovered".
   - A covers glob left pointing at a moved folder is reported.
   - Pinned in Task 1 (`changedSince` rename, `files()` deletion, a glob that matches nothing) and Task 2 (a deleted path).
3. **CRLF text:** a page saved with CRLF by a Windows editor, and a commit message with CRLF. Pinned in Task 1 (`parseCovers`), Task 2 (trailers) and Task 4 (`regenerate` keeps CRLF).
4. **Marker syntax shown as an example inside a code fence.** The docs-tooling page and the how-to page show both kinds of marker. They must not count as a real covers comment or a real section. Pinned in Task 1 and Task 4.
5. **No usable base commit, or a hook's `GIT_DIR`:**
   - Cases: a manual CI run, a first push (`before` is all zeros), a force push (`before` unreachable), and a check started from a git hook, where git sets `GIT_DIR`.
   - The stale-page part is skipped visibly or reported, and the check never crashes or looks at the wrong repo.
   - Pinned by the CI guard and the `--since nope` test (Task 6), and the `GIT_DIR` test (Task 1).

## Evidence Gathered Before Planning (2026-09-30, on the development machine)

- **Guide check timing:**
  - The current `fvm dart run tool/check_guide.dart` takes 1.9 s.
  - A probe importing `appstein_cli` and `appstein_engine` took 2.2 s warm.
  - The same probe plus `package:analyzer` took 15.7 s cold and 8.8 s warm.
- **CLI help is capturable:** `runAppstein(['--help'], out: buffer)` and `runAppstein(['help', 'doctor'], out: buffer)` print the usage with no line wrapping, because `package:args` never reads the terminal width. The output is identical on every OS.
- **graphify's hooks:**
  - `graphify hook install` writes `post-commit` and `post-checkout`, each wrapped in `( … )` between `# graphify-hook-start`/`# graphify-hook-end` markers (`# graphify-checkout-hook-start`/`-end` in `post-checkout`).
  - It also registers the `graph.json` merge driver.
  - Re-running it reports "already installed".
  - When the hook file already exists, it appends its block and keeps the existing content (tested in a scratch repo).
  - Its `post-checkout` block skips when the old and new HEAD are the same, and during a rebase, merge or cherry-pick.
- **The development machine:**
  - `fvm` is a Chocolatey `.exe` shim, so `command -v fvm` finds it from git's `sh`.
  - `graphify` is at `~/.local/bin/graphify`.
  - `core.autocrlf` is `true`, but `.gitattributes` sets `* text=auto eol=lf`, so working-tree text files are LF.
- **Hand-made local hooks:** `.git/hooks/post-merge` and `.git/hooks/post-rewrite` were written by hand on 2026-09-30, without markers. Task 7 replaces them with the installer's blocks.

## File Structure

| File | Responsibility |
|---|---|
| `pubspec.yaml` (modify) | Root dev dependencies: `appstein_cli`, `appstein_engine`, `args`, `glob`, `yaml` |
| `tool/src/git_repo.dart` (create) | Read-only git queries: files, changes since a base, commit messages |
| `tool/src/coverage.dart` (create) | Covers comments, the cover map, the coverage check |
| `tool/src/stale_check.dart` (create) | `Docs-Checked` trailers and the stale-page check |
| `tool/src/guide_checker.dart` (modify) | `GuideProblem.line` becomes nullable; `guidePages`, `toPosix`, `checkLinked` |
| `tool/src/generated_sections.dart` (create) | Parse and replace `<!-- generated:… -->` sections |
| `tool/src/doc_comments.dart` (create) | Read `///` comments from source text |
| `tool/src/generators.dart` (create) | Render `cli-help`, `exit-codes`, `doctor-checks`, `ci-jobs`, `package-graph` |
| `tool/src/generated_docs.dart` (create) | Regenerate every page; report stale and unused sections |
| `tool/src/guide_check.dart` (create) | Run every guide check |
| `tool/src/hooks.dart` (create) | The hook blocks; insert, remove and install them |
| `tool/gen_docs.dart` (create) | CLI: rewrite generated sections, or `--check` |
| `tool/check_guide.dart` (modify) | CLI: all checks, `--since`, `--warn-only` |
| `tool/install_hooks.dart` (create) | CLI: graphify's hooks plus our blocks, or `--remove` |
| `test/support/temp_repo.dart` (create) | Temp folders and git repos for tool tests |
| `test/*_test.dart` (create or modify) | One test file per `tool/src` file |
| `.github/workflows/ci.yml` (modify) | `docs` job: full history, and the guide check with `--since` |
| `AGENTS.md` (modify) | Per-slice docs step, the hooks installer, graphify |
| `docs/guide/*.md`, `docs/guide/how-to/*.md` (create or rewrite) | The guide content (Tasks 8–9) |
| `packages/*/README.md` (modify) | Accuracy check, and links to their guide pages (Task 9) |

**Final guide pages and their covers.** Tasks 8 and 9 create exactly these. Every source file in the repo then has a page.

| Page | `covers:` | Generated sections |
|---|---|---|
| `README.md` | `none` | — |
| `architecture.md` | `packages/appstein_engine/lib/appstein_engine.dart`, `packages/appstein_protocol/lib/**` | `package-graph` |
| `cli.md` | `packages/appstein_cli/lib/**`, `packages/appstein_cli/bin/**` | `cli-help`, `exit-codes` |
| `doctor.md` | `packages/appstein_engine/lib/src/doctor/**`, `packages/appstein_engine/lib/src/project/**` | `doctor-checks` |
| `sdk-lookups.md` | `packages/appstein_engine/lib/src/sdk/**`, `packages/appstein_engine/lib/src/android/**`, `packages/appstein_protocol/lib/src/sdk_info.dart` | — |
| `running-tools.md` | `packages/appstein_engine/lib/src/host/**` | — |
| `config.md` | `packages/appstein_engine/lib/src/config/**`, `packages/appstein_engine/lib/src/text/**`, `packages/appstein_protocol/lib/src/config/**` | — |
| `lints.md` | `packages/appstein_lints/lib/**`, `packages/appstein_protocol/lib/src/layer_rules.dart`, `analysis_options.yaml` | — |
| `testing.md` | `packages/appstein_engine/test/support/**`, `packages/appstein_cli/test/support/**`, `packages/appstein_engine/dart_test.yaml`, `test/support/**` | — |
| `ci.md` | `.github/workflows/**`, `tool/startup_check.dart`, `tool/measure_analyze.dart` | `ci-jobs` |
| `docs-tooling.md` | `tool/check_guide.dart`, `tool/gen_docs.dart`, `tool/install_hooks.dart`, `tool/src/**` | — |
| `debugging.md` | `none` | — |
| `how-to/add-a-doctor-check.md` | `packages/appstein_engine/lib/src/doctor/doctor_check.dart` | — |
| `how-to/add-a-lint-rule.md` | `packages/appstein_lints/lib/src/appstein_lints_plugin.dart` | — |
| `how-to/add-a-guide-page.md` | `none` | — |

---

### Task 0: Commit the approved spec change and this plan

The owner approved the §19.1, §19.3, §19.4 and §19.6 wording and the visual-page line on 2026-09-30. They are already edited in the working tree.

- [ ] **Step 1: Check the diff is only the approved text**

Run: `git diff --stat`
Expected: only `docs/superpowers/specs/2026-09-29-appstein-design.md` and `.html` changed. The plan file is new.

- [ ] **Step 2: Commit (controller)**

```bash
git add docs/superpowers/specs/2026-09-29-appstein-design.md docs/superpowers/specs/2026-09-29-appstein-design.html docs/superpowers/plans/2026-09-30-slice-1a1-docs-freshness.md
git commit -m "docs(spec): rules that keep the developer guide current, and the slice 1a.1 plan"
```

---

### Task 1: Git queries, test helpers and the coverage map

**Files:**
- Modify: `pubspec.yaml` (root)
- Create: `test/support/temp_repo.dart`, `tool/src/git_repo.dart`, `tool/src/coverage.dart`
- Modify: `tool/src/guide_checker.dart` (`GuideProblem.line` nullable, `toPosix`)
- Test: `test/git_repo_test.dart`, `test/coverage_test.dart`

**Interfaces:**
- Produces:
  - `GuideProblem(String file, int? line, String message)`, whose `toString()` is `file:line: message`, or `file: message` when `line` is null.
  - `String toPosix(String path)`.
  - `GitRepo(String root, {Map<String, String>? environment})` with:
    - `List<String> files()`;
    - `bool hasCommit(String rev)`;
    - `List<String> changedSince(String rev)`;
    - `List<String> messagesSince(String rev)`.
  - `GitException`.
  - `const sourceGlobs`.
  - `CoversComment(List<String> globs, int line)`, `CoversException(int line, String message)` and `CoversComment? parseCovers(String markdown)`.
  - `CoverMap(Map<String, CoversComment> pages)` with `pagesCovering(String file)`.
  - `({CoverMap map, List<GuideProblem> problems}) readCoverMap(String repoRoot, List<String> pages)`.
  - `List<GuideProblem> checkCoverage(CoverMap map, List<String> files)`.
  - The test helpers `tempFolder()`, `tempRepo()`, `runGit(...)`, `writeFile(...)`.

- [ ] **Step 1: Add the root dev dependencies**

In the root `pubspec.yaml`, replace the `dev_dependencies:` block with:

```yaml
dev_dependencies:
  appstein_cli: ^0.1.0-dev
  appstein_engine: ^0.1.0-dev
  args: ^2.7.0
  dependency_validator: ^5.0.0
  glob: ^2.2.0
  lints: ^6.1.0
  path: ^1.9.1
  test: ^1.32.0
  yaml: ^3.1.4
```

Run: `fvm dart pub get`
Expected: resolves with no version changes to existing packages. `pubspec.lock` only changes the dependency kind of these packages ("from transitive dependency to direct dev dependency"). `appstein_cli` and `appstein_engine` resolve to the workspace packages.

- [ ] **Step 2: Write the test helpers**

Create `test/support/temp_repo.dart`:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The real environment without git's own `GIT_*` variables, plus [extra].
///
/// A git hook sets `GIT_DIR`. Without this, a test started from a hook would
/// run its git commands against the Appstein repo instead of the temp repo.
Map<String, String> gitEnvironment([Map<String, String> extra = const {}]) => {
  for (final entry in Platform.environment.entries)
    if (!entry.key.toUpperCase().startsWith('GIT_')) entry.key: entry.value,
  ...extra,
};

/// Creates a temporary folder whose path contains a space and a non-ASCII
/// character, and deletes it after the test.
Directory tempFolder() {
  final dir = Directory.systemTemp.createTempSync('appstein guide tëst ');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Git marks object files read-only on Windows, which can block the
      // delete. A leftover temp folder is harmless.
    }
  });
  return dir;
}

/// Creates an empty git repo, on branch `main`, in a [tempFolder].
Directory tempRepo() {
  final dir = tempFolder();
  runGit(dir, ['init', '-q', '-b', 'main']);
  return dir;
}

/// Runs git in [repo] with a fixed identity, no signing and no line-ending
/// conversion, and returns what it printed. Throws when git fails.
String runGit(
  Directory repo,
  List<String> arguments, {
  Map<String, String> environment = const {},
}) {
  final result = Process.runSync(
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
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout as String;
}

/// Writes [text] to [path] (with forward slashes) under [root], creating the
/// folders it needs.
void writeFile(Directory root, String path, String text) {
  File(p.joinAll([root.path, ...path.split('/')]))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
}
```

- [ ] **Step 3: Make `GuideProblem.line` nullable and add `toPosix`**

In `tool/src/guide_checker.dart`:
- Change the constructor doc to `/// Creates a problem at [line] of [file]; [line] is null when the problem is about the whole file.`
- Change the field to `final int? line;` with the doc `/// The 1-based line, or null for the whole file.`
- Change `toString` to:

```dart
  @override
  String toString() =>
      line == null ? '$file: $message' : '$file:$line: $message';
```

Add at the end of the file:

```dart
/// [path] with forward slashes, the form every guide tool compares.
String toPosix(String path) => p.split(path).join('/');
```

Add this test to `test/guide_checker_test.dart`, inside `main()`:

```dart
  test('a problem about a whole file has no line number', () {
    expect('${const GuideProblem('a.md', null, 'x')}', 'a.md: x');
    expect('${const GuideProblem('a.md', 3, 'x')}', 'a.md:3: x');
  });
```

- [ ] **Step 4: Write the failing git tests**

Create `test/git_repo_test.dart`:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/git_repo.dart';
import 'support/temp_repo.dart';

void main() {
  late Directory repo;
  late GitRepo git;

  setUp(() {
    repo = tempRepo();
    git = GitRepo(repo.path);
    writeFile(repo, '.gitignore', 'build/\n');
    writeFile(repo, 'packages/a/lib/a.dart', 'a');
    writeFile(repo, 'docs/guide/README.md', '# Guide\n');
    runGit(repo, ['add', '.']);
    runGit(repo, ['commit', '-q', '-m', 'first']);
  });

  test('files() lists tracked and untracked files, not ignored or deleted '
      'ones', () {
    writeFile(repo, 'tool/new tool.dart', 'x');
    writeFile(repo, 'build/out.txt', 'x');
    File(p.join(repo.path, 'docs', 'guide', 'README.md')).deleteSync();
    expect(git.files(), [
      '.gitignore',
      'packages/a/lib/a.dart',
      'tool/new tool.dart',
    ]);
  });

  test('changedSince() compares the merge base with the working tree', () {
    runGit(repo, ['switch', '-q', '-c', 'feature']);
    runGit(repo, ['mv', 'packages/a/lib/a.dart', 'packages/a/lib/b.dart']);
    runGit(repo, ['commit', '-q', '-m', 'rename']);
    runGit(repo, ['switch', '-q', 'main']);
    writeFile(repo, 'main-only.txt', 'x');
    runGit(repo, ['add', '.']);
    runGit(repo, ['commit', '-q', '-m', 'main moves on']);
    runGit(repo, ['switch', '-q', 'feature']);
    writeFile(repo, 'docs/guide/README.md', '# Changed\n');
    writeFile(repo, 'tool/untracked.dart', 'x');
    expect(git.changedSince('main'), [
      'docs/guide/README.md',
      'packages/a/lib/a.dart',
      'packages/a/lib/b.dart',
      'tool/untracked.dart',
    ]);
  });

  test('messagesSince() returns the messages after the merge base', () {
    runGit(repo, ['switch', '-q', '-c', 'feature']);
    writeFile(repo, 'x.txt', 'x');
    runGit(repo, ['add', '.']);
    runGit(repo, [
      'commit',
      '-q',
      '-m',
      'Change x\n\nDocs-Checked: doctor.md - only a rename',
    ]);
    final messages = git.messagesSince('main');
    expect(messages, hasLength(1));
    expect(messages.single, contains('Docs-Checked: doctor.md - only a rename'));
  });

  test('hasCommit() is false for unknown and all-zero revisions', () {
    expect(git.hasCommit('main'), isTrue);
    expect(git.hasCommit('nope'), isFalse);
    expect(git.hasCommit('0' * 40), isFalse);
  });

  test('a failing git command throws GitException', () {
    expect(() => git.changedSince('nope'), throwsA(isA<GitException>()));
  });

  test('ignores GIT_DIR, which a git hook sets', () {
    final other = tempRepo();
    writeFile(other, 'other.txt', 'x');
    final fromHook = GitRepo(
      repo.path,
      environment: {
        ...gitEnvironment(),
        'GIT_DIR': p.join(other.path, '.git'),
      },
    );
    expect(fromHook.files(), contains('packages/a/lib/a.dart'));
    expect(fromHook.files(), isNot(contains('other.txt')));
  });
}
```

Run: `fvm dart test test/git_repo_test.dart`
Expected: FAIL, because `tool/src/git_repo.dart` doesn't exist.

- [ ] **Step 5: Implement `GitRepo`**

Create `tool/src/git_repo.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Thrown when a git command fails.
final class GitException implements Exception {
  /// Creates the exception.
  const GitException(this.message);

  /// What failed, with git's own error.
  final String message;

  @override
  String toString() => message;
}

/// The read-only git queries the guide check needs, run in the repo at
/// [root].
///
/// Git's own `GIT_*` variables are dropped from the environment. A git hook
/// sets `GIT_DIR`, and a check started from a hook must still look at
/// [root].
final class GitRepo {
  /// Creates a view of the repo at [root]. [environment] defaults to this
  /// process's environment.
  GitRepo(this.root, {Map<String, String>? environment})
    : _environment = {
        for (final entry in (environment ?? Platform.environment).entries)
          if (!entry.key.toUpperCase().startsWith('GIT_'))
            entry.key: entry.value,
      };

  /// The repo's top folder.
  final String root;

  final Map<String, String> _environment;

  /// Every file in the working tree that git tracks or would track, as
  /// repo-relative paths with forward slashes, sorted. Untracked files
  /// count; ignored files, and tracked files deleted from disk, don't.
  List<String> files() => [
    for (final path in _paths([
      'ls-files',
      '-z',
      '--cached',
      '--others',
      '--exclude-standard',
    ]))
      if (File(p.join(root, path)).existsSync()) path,
  ];

  /// Whether [rev] names a commit.
  bool hasCommit(String rev) =>
      _run(['rev-parse', '-q', '--verify', '$rev^{commit}']).exitCode == 0;

  /// The files that differ between the merge base of [rev] and HEAD, and the
  /// working tree: committed, staged, unstaged and untracked changes, sorted.
  /// A rename appears as both its old and its new path.
  List<String> changedSince(String rev) {
    final base = _mergeBase(rev);
    return {
      ..._paths(['diff', '--name-only', '-z', '--no-renames', base]),
      ..._paths(['ls-files', '-z', '--others', '--exclude-standard']),
    }.toList()..sort();
  }

  /// The full messages of the commits between the merge base of [rev] and
  /// HEAD.
  List<String> messagesSince(String rev) => [
    for (final message in _git([
      'log',
      '-z',
      '--format=%B',
      '${_mergeBase(rev)}..HEAD',
    ]).split('\x00'))
      if (message.trim().isNotEmpty) message,
  ];

  String _mergeBase(String rev) => _git(['merge-base', rev, 'HEAD']).trim();

  List<String> _paths(List<String> arguments) {
    final paths = {
      for (final path in _git(arguments).split('\x00'))
        if (path.isNotEmpty) path,
    };
    return paths.toList()..sort();
  }

  String _git(List<String> arguments) {
    final result = _run(arguments);
    if (result.exitCode != 0) {
      throw GitException(
        'git ${arguments.join(' ')} failed: '
        '${(result.stderr as String).trim()}',
      );
    }
    return result.stdout as String;
  }

  ProcessResult _run(List<String> arguments) => Process.runSync(
    'git',
    arguments,
    workingDirectory: root,
    environment: _environment,
    includeParentEnvironment: false,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
}
```

Run: `fvm dart test test/git_repo_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 6: Write the failing coverage tests**

Create `test/coverage_test.dart`:

```dart
import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/coverage.dart';
import 'support/temp_repo.dart';

const uncovered =
    'No guide page covers this file. Add it to the covers comment of the '
    'page that explains it.';

void main() {
  group('parseCovers', () {
    test('reads globs split by spaces, commas and lines', () {
      final covers = parseCovers(
        '<!-- covers:\npackages/a/lib/**, tool/x.dart\n'
        '  .github/workflows/**\n-->\n# Title\n',
      )!;
      expect(covers.globs, [
        'packages/a/lib/**',
        'tool/x.dart',
        '.github/workflows/**',
      ]);
      expect(covers.line, 1);
    });

    test('reads a one-line comment after blank lines, and `none`', () {
      final covers = parseCovers('\n\n<!-- covers: none -->\n# Title\n')!;
      expect(covers.globs, isEmpty);
      expect(covers.line, 3);
    });

    test('accepts CRLF line endings', () {
      expect(
        parseCovers('<!-- covers:\r\ntool/**\r\n-->\r\n# T\r\n')!.globs,
        ['tool/**'],
      );
    });

    test('returns null without a comment, ignoring examples in code '
        'fences', () {
      expect(
        parseCovers('# Title\n```text\n<!-- covers: tool/** -->\n```\n'),
        isNull,
      );
    });

    for (final (name, markdown, message) in [
      (
        'not first',
        '# Title\n<!-- covers: tool/** -->\n',
        'must be the first line',
      ),
      (
        'repeated',
        '<!-- covers: tool/** -->\n<!-- covers: none -->\n',
        'only one covers comment',
      ),
      ('never closed', '<!-- covers: tool/**\n# Title\n', 'never closed'),
      ('empty', '<!-- covers: -->\n', 'or write `none`'),
      ('none with paths', '<!-- covers: none tool/** -->\n', "can't be"),
      ('using backslashes', '<!-- covers: tool\\x.dart -->\n', 'forward'),
      ('absolute', '<!-- covers: /tool/** -->\n', 'forward slashes'),
      ('on a drive', '<!-- covers: C:/tool/** -->\n', 'forward slashes'),
      ('above the repo', '<!-- covers: ../tool/** -->\n', 'forward slashes'),
      (
        'followed by text',
        '<!-- covers: tool/** --> # Title\n',
        'Nothing may follow',
      ),
    ]) {
      test('rejects a comment that is $name', () {
        expect(
          () => parseCovers(markdown),
          throwsA(
            isA<CoversException>().having(
              (e) => e.message,
              'message',
              contains(message),
            ),
          ),
        );
      });
    }
  });

  group('the cover map', () {
    test('pagesCovering lists every page whose globs match, sorted', () {
      final map = CoverMap({
        'docs/guide/z.md': const CoversComment(['packages/*/lib/**'], 1),
        'docs/guide/a.md': const CoversComment([
          'packages/engine/lib/src/sdk/**',
        ], 1),
      });
      expect(map.pagesCovering('packages/engine/lib/src/sdk/fvm.dart'), [
        'docs/guide/a.md',
        'docs/guide/z.md',
      ]);
      expect(map.pagesCovering('tool/x.dart'), isEmpty);
    });

    test('readCoverMap reports pages without a comment or with a bad '
        'one', () {
      final Directory dir = tempFolder();
      writeFile(dir, 'docs/guide/a.md', '<!-- covers: tool/** -->\n# A\n');
      writeFile(dir, 'docs/guide/b.md', '# B\n');
      writeFile(dir, 'docs/guide/c.md', '# C\n<!-- covers: tool/** -->\n');
      final result = readCoverMap(dir.path, [
        'docs/guide/a.md',
        'docs/guide/b.md',
        'docs/guide/c.md',
      ]);
      expect(result.map.pages.keys, ['docs/guide/a.md']);
      expect(result.problems.map((problem) => '$problem'), [
        'docs/guide/b.md:1: Start the page with a covers comment: '
            '<!-- covers: <paths> --> or <!-- covers: none -->.',
        'docs/guide/c.md:2: The covers comment must be the first line of '
            'the page.',
      ]);
    });

    test('checkCoverage reports uncovered source files and globs that '
        'match nothing', () {
      final map = CoverMap({
        'docs/guide/a.md': const CoversComment([
          'packages/*/lib/src/sdk/**',
          'tool/gone.dart',
        ], 1),
        'docs/guide/b.md': const CoversComment([], 1),
      });
      final problems = checkCoverage(map, [
        '.github/workflows/ci.yml',
        'README.md',
        'packages/engine/lib/src/sdk/fvm.dart',
        'packages/engine/lib/src/host/runner.dart',
        'packages/engine/test/sdk_test.dart',
        'packages/cli/bin/cli.dart',
      ]);
      expect(problems.map((problem) => '$problem'), [
        'docs/guide/a.md:1: Covers tool/gone.dart, which matches no file.',
        '.github/workflows/ci.yml: $uncovered',
        'packages/engine/lib/src/host/runner.dart: $uncovered',
        'packages/cli/bin/cli.dart: $uncovered',
      ]);
    });
  });
}
```

Run: `fvm dart test test/coverage_test.dart`
Expected: FAIL, because `tool/src/coverage.dart` doesn't exist.

- [ ] **Step 7: Implement the coverage map**

Create `tool/src/coverage.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'guide_checker.dart';

/// The files spec §19.6 calls source. Each must be covered by a guide page.
const sourceGlobs = [
  'packages/*/lib/**',
  'packages/*/bin/**',
  'tool/**',
  '.github/workflows/**',
];

/// A guide page's `<!-- covers: … -->` comment: the files the page explains.
final class CoversComment {
  /// Creates a comment that starts on [line] and lists [globs].
  const CoversComment(this.globs, this.line);

  /// Repo-relative globs with forward slashes. Empty for `covers: none`.
  final List<String> globs;

  /// The 1-based line the comment starts on.
  final int line;
}

/// Thrown when a covers comment is malformed.
final class CoversException implements Exception {
  /// Creates the exception for [line].
  const CoversException(this.line, this.message);

  /// The 1-based line.
  final int line;

  /// What is wrong.
  final String message;

  @override
  String toString() => 'line $line: $message';
}

final _coversStart = RegExp(r'^<!--\s*covers:');

/// Reads the covers comment of a guide page (spec §19.6).
///
/// The comment must be the first non-blank line of the page, and it may run
/// over several lines until `-->`. Entries are separated by spaces, commas
/// or line breaks, and `none` marks a page that explains no particular file.
/// Comments inside code fences are examples and are ignored. Returns null
/// when the page has no comment. Throws [CoversException] when the comment
/// is malformed.
CoversComment? parseCovers(String markdown) {
  final lines = const LineSplitter().convert(markdown);
  final starts = <int>[];
  var inFence = false;
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trim();
    if (trimmed.startsWith('```')) {
      inFence = !inFence;
      continue;
    }
    if (!inFence && _coversStart.hasMatch(trimmed)) starts.add(i);
  }
  if (starts.isEmpty) return null;
  if (starts.length > 1) {
    throw CoversException(starts[1] + 1, 'A page has only one covers comment.');
  }
  final start = starts.single;
  if (start != lines.indexWhere((line) => line.trim().isNotEmpty)) {
    throw CoversException(
      start + 1,
      'The covers comment must be the first line of the page.',
    );
  }
  final text = StringBuffer();
  var closed = false;
  for (var i = start; i < lines.length && !closed; i++) {
    var line = lines[i].trim();
    if (i == start) {
      line = line.substring(line.indexOf('covers:') + 'covers:'.length);
    }
    final close = line.indexOf('-->');
    if (close >= 0) {
      if (line.substring(close + 3).trim().isNotEmpty) {
        throw CoversException(
          i + 1,
          'Nothing may follow --> on the line that closes the covers comment.',
        );
      }
      line = line.substring(0, close);
      closed = true;
    }
    text.write(' $line');
  }
  if (!closed) {
    throw CoversException(
      start + 1,
      'The covers comment is never closed with -->.',
    );
  }
  final entries = text
      .toString()
      .split(RegExp(r'[\s,]+'))
      .where((entry) => entry.isNotEmpty)
      .toList();
  if (entries.isEmpty) {
    throw CoversException(
      start + 1,
      'List the paths this page explains, or write `none`.',
    );
  }
  if (entries.contains('none')) {
    if (entries.length > 1) {
      throw CoversException(start + 1, "`none` can't be combined with paths.");
    }
    return CoversComment(const [], start + 1);
  }
  for (final entry in entries) {
    if (entry.contains(r'\') ||
        entry.startsWith('/') ||
        entry.startsWith('./') ||
        entry.contains(':') ||
        entry.split('/').contains('..')) {
      throw CoversException(
        start + 1,
        'Covers entries are repo-relative paths with forward slashes: $entry',
      );
    }
  }
  return CoversComment(entries, start + 1);
}

/// The covers comment of every guide page.
final class CoverMap {
  /// Creates a map from each page to its comment.
  CoverMap(this.pages)
    : _globs = {
        for (final entry in pages.entries)
          entry.key: [
            for (final glob in entry.value.globs) Glob(glob, context: p.posix),
          ],
      };

  /// Each guide page (repo-relative, forward slashes) and its comment.
  final Map<String, CoversComment> pages;

  final Map<String, List<Glob>> _globs;

  /// The pages whose covers match [file] (repo-relative, forward slashes),
  /// sorted.
  List<String> pagesCovering(String file) => [
    for (final entry in _globs.entries)
      if (entry.value.any((glob) => glob.matches(file))) entry.key,
  ]..sort();
}

/// Reads the covers comment of each of [pages] (repo-relative, forward
/// slashes). A page without a comment, or with a malformed one, becomes a
/// problem and is left out of the map.
({CoverMap map, List<GuideProblem> problems}) readCoverMap(
  String repoRoot,
  List<String> pages,
) {
  final comments = <String, CoversComment>{};
  final problems = <GuideProblem>[];
  for (final page in pages) {
    try {
      final comment = parseCovers(
        File(p.join(repoRoot, page)).readAsStringSync(),
      );
      if (comment == null) {
        problems.add(
          GuideProblem(
            page,
            1,
            'Start the page with a covers comment: '
            '<!-- covers: <paths> --> or <!-- covers: none -->.',
          ),
        );
      } else {
        comments[page] = comment;
      }
    } on CoversException catch (error) {
      problems.add(GuideProblem(page, error.line, error.message));
    }
  }
  return (map: CoverMap(comments), problems: problems);
}

/// Checks the coverage map against [files], which is every file in the
/// working tree (repo-relative, forward slashes). Each covers entry must
/// match a file, and each source file ([sourceGlobs]) must be covered by a
/// page.
List<GuideProblem> checkCoverage(CoverMap map, List<String> files) {
  final problems = <GuideProblem>[];
  for (final entry in map.pages.entries) {
    for (final pattern in entry.value.globs) {
      final glob = Glob(pattern, context: p.posix);
      if (!files.any(glob.matches)) {
        problems.add(
          GuideProblem(
            entry.key,
            entry.value.line,
            'Covers $pattern, which matches no file.',
          ),
        );
      }
    }
  }
  final source = [for (final glob in sourceGlobs) Glob(glob, context: p.posix)];
  for (final file in files) {
    if (source.any((glob) => glob.matches(file)) &&
        map.pagesCovering(file).isEmpty) {
      problems.add(
        GuideProblem(
          file,
          null,
          'No guide page covers this file. Add it to the covers comment of '
          'the page that explains it.',
        ),
      );
    }
  }
  return problems;
}
```

- [ ] **Step 8: Run the tests, format and analyze**

Run: `fvm dart test test` then `fvm dart format .` then `fvm dart analyze --fatal-infos`
Expected: all tests pass, no format changes left and no analyzer issues. If `Glob.matches` rejects a relative path, fix the call, not the test. The glob package matches relative paths against relative patterns in the same context, and the lints package already relies on that (`layer_matcher.dart`).

- [ ] **Step 9: Commit (controller)**

```bash
git add pubspec.yaml pubspec.lock test/support/temp_repo.dart test/git_repo_test.dart test/coverage_test.dart test/guide_checker_test.dart tool/src/git_repo.dart tool/src/coverage.dart tool/src/guide_checker.dart
git commit -m "feat(tool): git queries and the guide coverage map"
```

---

### Task 2: The stale-page check and `Docs-Checked` trailers

**Files:**
- Create: `tool/src/stale_check.dart`
- Test: `test/stale_check_test.dart`

**Interfaces:**
- Consumes: `CoverMap`, `CoversComment` and `GuideProblem` (Task 1).
- Produces:
  - `DocsChecked(String page, String reason)`;
  - `({List<DocsChecked> checked, List<GuideProblem> problems}) parseDocsChecked(List<String> messages)`;
  - `List<GuideProblem> checkStale({required CoverMap map, required List<String> changed, required List<String> messages})`.

- [ ] **Step 1: Write the failing tests**

Create `test/stale_check_test.dart`:

```dart
import 'package:test/test.dart';

import '../tool/src/coverage.dart';
import '../tool/src/stale_check.dart';

final map = CoverMap({
  'docs/guide/doctor.md': const CoversComment([
    'packages/engine/lib/src/doctor/**',
  ], 1),
  'docs/guide/sdk-lookups.md': const CoversComment([
    'packages/engine/lib/src/sdk/**',
  ], 1),
  'docs/guide/how-to/add-a-check.md': const CoversComment([
    'packages/engine/lib/src/doctor/doctor_check.dart',
  ], 1),
});

List<String> stale(List<String> changed, [List<String> messages = const []]) =>
    [
      for (final problem in checkStale(
        map: map,
        changed: changed,
        messages: messages,
      ))
        '$problem',
    ];

void main() {
  test('passes when the covering page changed too', () {
    expect(
      stale(['packages/engine/lib/src/doctor/a.dart', 'docs/guide/doctor.md']),
      isEmpty,
    );
  });

  test('passes when any one of several covering pages changed', () {
    expect(
      stale([
        'packages/engine/lib/src/doctor/doctor_check.dart',
        'docs/guide/how-to/add-a-check.md',
      ]),
      isEmpty,
    );
  });

  test('ignores files no page covers', () {
    expect(stale(['README.md', 'packages/engine/test/x_test.dart']), isEmpty);
  });

  test('reports a changed file whose page did not change, with the '
      'trailer to use', () {
    expect(stale(['packages/engine/lib/src/sdk/fvm.dart']), [
      'packages/engine/lib/src/sdk/fvm.dart: Changed, but the page that '
          'explains it did not: docs/guide/sdk-lookups.md. Update the page, '
          'or if it is still right, add a commit trailer: '
          'Docs-Checked: sdk-lookups.md - <why it is still right>',
    ]);
  });

  test('a deleted or renamed file counts like an edit', () {
    expect(stale(['packages/engine/lib/src/doctor/old.dart']), [
      startsWith('packages/engine/lib/src/doctor/old.dart: Changed'),
    ]);
  });

  for (final message in [
    'Refactor\n\nDocs-Checked: sdk-lookups.md - only renamed a private helper',
    'Tidy\r\n\r\ndocs-checked: docs/guide/sdk-lookups.md - no behaviour '
        'change\r\n',
  ]) {
    test('a Docs-Checked trailer clears it: ${message.split('\n').first}', () {
      expect(stale(['packages/engine/lib/src/sdk/fvm.dart'], [message]), isEmpty);
    });
  }

  test('a trailer for a different page does not clear it', () {
    expect(
      stale(
        ['packages/engine/lib/src/sdk/fvm.dart'],
        ['x\n\nDocs-Checked: doctor.md - unrelated'],
      ),
      hasLength(1),
    );
  });

  test('rejects trailers without a reason or naming no guide page', () {
    expect(
      stale(
        [],
        ['a\n\nDocs-Checked: doctor.md', 'b\n\nDocs-Checked: nope.md - why'],
      ),
      [
        'commit message: Write the trailer as '
            '`Docs-Checked: <page> - <reason>`: Docs-Checked: doctor.md',
        'commit message: Docs-Checked names docs/guide/nope.md, which is not '
            'a guide page.',
      ],
    );
  });
}
```

Run: `fvm dart test test/stale_check_test.dart`
Expected: FAIL, because `tool/src/stale_check.dart` doesn't exist.

- [ ] **Step 2: Implement the check**

Create `tool/src/stale_check.dart`:

```dart
import 'coverage.dart';
import 'guide_checker.dart';

/// A `Docs-Checked:` commit trailer: someone confirmed that a page is still
/// right after a code change (spec §19.6).
final class DocsChecked {
  /// Creates a trailer for [page].
  const DocsChecked(this.page, this.reason);

  /// The page, repo-relative with forward slashes.
  final String page;

  /// Why the page is still right.
  final String reason;
}

final _trailer = RegExp(r'^\s*docs-checked:(.*)$', caseSensitive: false);

/// Reads every `Docs-Checked: <page> - <reason>` line in [messages]. The key
/// is matched in any case. The page may be written relative to `docs/guide/`
/// (`doctor.md`) or to the repo root. A line without a page or a reason is a
/// problem.
({List<DocsChecked> checked, List<GuideProblem> problems}) parseDocsChecked(
  List<String> messages,
) {
  final checked = <DocsChecked>[];
  final problems = <GuideProblem>[];
  for (final message in messages) {
    for (final raw in message.split('\n')) {
      final line = raw.trimRight();
      final match = _trailer.firstMatch(line);
      if (match == null) continue;
      final value = match.group(1)!.trim();
      final dash = value.indexOf(' - ');
      final page = (dash < 0 ? value : value.substring(0, dash)).trim();
      final reason = dash < 0 ? '' : value.substring(dash + 3).trim();
      if (page.isEmpty || reason.isEmpty) {
        problems.add(
          GuideProblem(
            'commit message',
            null,
            'Write the trailer as `Docs-Checked: <page> - <reason>`: '
            '${line.trim()}',
          ),
        );
        continue;
      }
      checked.add(
        DocsChecked(
          page.startsWith('docs/guide/') ? page : 'docs/guide/$page',
          reason,
        ),
      );
    }
  }
  return (checked: checked, problems: problems);
}

/// The stale-page check (spec §19.6). Every file in [changed] that a page
/// covers needs one of its covering pages in [changed] too, or named by a
/// `Docs-Checked` trailer in [messages].
List<GuideProblem> checkStale({
  required CoverMap map,
  required List<String> changed,
  required List<String> messages,
}) {
  final trailers = parseDocsChecked(messages);
  final problems = [...trailers.problems];
  final confirmed = <String>{};
  for (final trailer in trailers.checked) {
    if (map.pages.containsKey(trailer.page)) {
      confirmed.add(trailer.page);
    } else {
      problems.add(
        GuideProblem(
          'commit message',
          null,
          'Docs-Checked names ${trailer.page}, which is not a guide page.',
        ),
      );
    }
  }
  final changedFiles = changed.toSet();
  for (final file in changed) {
    final pages = map.pagesCovering(file);
    if (pages.isEmpty ||
        pages.any(changedFiles.contains) ||
        pages.any(confirmed.contains)) {
      continue;
    }
    final short = pages.first.substring('docs/guide/'.length);
    problems.add(
      GuideProblem(
        file,
        null,
        'Changed, but the page that explains it did not: '
        '${pages.join(', ')}. Update the page, or if it is still right, add '
        'a commit trailer: Docs-Checked: $short - <why it is still right>',
      ),
    );
  }
  return problems;
}
```

- [ ] **Step 3: Run the tests, format and analyze**

Run: `fvm dart test test` then `fvm dart format .` then `fvm dart analyze --fatal-infos`
Expected: all pass, clean.

- [ ] **Step 4: Commit (controller)**

```bash
git add tool/src/stale_check.dart test/stale_check_test.dart
git commit -m "feat(tool): stale-page check with Docs-Checked trailers"
```

---

### Task 3: Every page is linked from the start page

**Files:**
- Modify: `tool/src/guide_checker.dart`
- Test: `test/guide_checker_test.dart`

**Interfaces:**
- Consumes: `GuideProblem` and `toPosix` (Task 1).
- Produces:
  - `List<String> guidePages(String repoRoot)`: every `.md` under `docs/guide/`, repo-relative, forward slashes, sorted;
  - `List<GuideProblem> checkLinked(String repoRoot, List<String> pages)`.

- [ ] **Step 1: Write the failing tests**

Append to `main()` in `test/guide_checker_test.dart`. It already has `repo`, a temp folder with `docs/guide/` and `packages/appstein_cli/README.md`.

```dart
  group('checkLinked', () {
    void page(String path, String text) =>
        File(p.join(repo.path, path))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text);

    test('guidePages lists guide pages with forward slashes', () {
      page('docs/guide/README.md', '# Start\n');
      page('docs/guide/how-to/b.md', '# B\n');
      expect(guidePages(repo.path), [
        'docs/guide/README.md',
        'docs/guide/how-to/b.md',
      ]);
    });

    test('reports pages that no chain of links reaches from the start '
        'page', () {
      page(
        'docs/guide/README.md',
        '[A](a.md#top) and [B](how-to/b.md) and [web](https://dart.dev)\n',
      );
      page('docs/guide/a.md', '# A\n');
      page('docs/guide/how-to/b.md', 'See [C](../c.md).\n');
      page('docs/guide/c.md', '# C\n');
      page('docs/guide/d.md', '# D, linked from nowhere\n');
      page('docs/guide/e.md', '# E\n');
      page('docs/guide/f.md', '```text\n[E](e.md) is only an example\n```\n');
      const notLinked =
          'Not linked from the guide. Link it from docs/guide/README.md or '
          'from a page linked there.';
      expect(checkLinked(repo.path, guidePages(repo.path)).map((x) => '$x'), [
        'docs/guide/d.md: $notLinked',
        'docs/guide/e.md: $notLinked',
        'docs/guide/f.md: $notLinked',
      ]);
    });

    test('reports a missing start page', () {
      page('docs/guide/a.md', '# A\n');
      expect(checkLinked(repo.path, guidePages(repo.path)).map((x) => '$x'), [
        'docs/guide/README.md: The guide has no start page.',
      ]);
    });
  });
```

Run: `fvm dart test test/guide_checker_test.dart`
Expected: FAIL, because `guidePages` and `checkLinked` aren't defined.

- [ ] **Step 2: Implement**

In `tool/src/guide_checker.dart`, add a private helper and use it in `checkMarkdown` in place of the four `startsWith` tests:

```dart
bool _isExternal(String target) =>
    target.startsWith('http://') ||
    target.startsWith('https://') ||
    target.startsWith('mailto:') ||
    target.startsWith('#');
```

Then add:

```dart
/// The developer guide's pages: every Markdown file under `docs/guide/`, as
/// repo-relative paths with forward slashes, sorted.
List<String> guidePages(String repoRoot) => [
  for (final file in guideFiles(repoRoot))
    if (toPosix(file).startsWith('docs/guide/')) toPosix(file),
];

/// Guide pages that no chain of relative links reaches from
/// `docs/guide/README.md` (spec §19.6: nothing is left unlinked). [pages]
/// are repo-relative with forward slashes, as [guidePages] returns them.
/// Links inside code fences are examples and don't count.
List<GuideProblem> checkLinked(String repoRoot, List<String> pages) {
  const start = 'docs/guide/README.md';
  final known = pages.toSet();
  if (!known.contains(start)) {
    return [const GuideProblem(start, null, 'The guide has no start page.')];
  }
  final reached = {start};
  final queue = [start];
  while (queue.isNotEmpty) {
    final page = queue.removeLast();
    final lines = File(p.join(repoRoot, page)).readAsLinesSync();
    for (final target in _relativeLinks(lines)) {
      final linked = p.posix.normalize(
        p.posix.join(p.posix.dirname(page), target),
      );
      if (known.contains(linked) && reached.add(linked)) queue.add(linked);
    }
  }
  return [
    for (final page in pages)
      if (!reached.contains(page))
        GuideProblem(
          page,
          null,
          'Not linked from the guide. Link it from docs/guide/README.md or '
          'from a page linked there.',
        ),
  ];
}

Iterable<String> _relativeLinks(List<String> lines) sync* {
  var inFence = false;
  for (final line in lines) {
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    for (final match in _link.allMatches(line)) {
      final target = match.group(1)!;
      if (_isExternal(target)) continue;
      yield Uri.decodeFull(target.split('#').first);
    }
  }
}
```

- [ ] **Step 3: Run the tests, format and analyze**

Run: `fvm dart test test` then `fvm dart format .` then `fvm dart analyze --fatal-infos`
Expected: all pass, clean.

- [ ] **Step 4: Commit (controller)**

```bash
git add tool/src/guide_checker.dart test/guide_checker_test.dart
git commit -m "feat(tool): every guide page must be linked from the start page"
```

---

### Task 4: Generated-section markers and doc-comment reading

**Files:**
- Create: `tool/src/generated_sections.dart`, `tool/src/doc_comments.dart`
- Test: `test/generated_sections_test.dart`, `test/doc_comments_test.dart`

**Interfaces:**
- Consumes: `GuideProblem` (Task 1).
- Produces:
  - `RegeneratedPage(String text, List<String> sections, List<GuideProblem> problems)`;
  - `RegeneratedPage regenerate(String page, String markdown, Map<String, String> bodies)`;
  - `String? docCommentAbove(List<String> lines, int index)`;
  - `String firstParagraph(String doc)`.

- [ ] **Step 1: Write the failing tests**

Create `test/generated_sections_test.dart`:

```dart
import 'package:test/test.dart';

import '../tool/src/generated_sections.dart';

const bodies = {'alpha': '| a |\n|---|', 'beta': 'B'};
const page = 'docs/guide/x.md';

void main() {
  test('replaces section bodies and keeps the text around them', () {
    final result = regenerate(
      page,
      '# T\n\n<!-- generated:alpha -->\nold\nstuff\n<!-- /generated:alpha -->'
      '\n\nText\n<!-- generated:beta -->\n<!-- /generated:beta -->\n',
      bodies,
    );
    expect(result.problems, isEmpty);
    expect(result.sections, ['alpha', 'beta']);
    expect(
      result.text,
      '# T\n\n<!-- generated:alpha -->\n\n| a |\n|---|\n\n'
      '<!-- /generated:alpha -->\n\nText\n<!-- generated:beta -->\n\nB\n\n'
      '<!-- /generated:beta -->\n',
    );
  });

  test('regenerating twice changes nothing', () {
    final once = regenerate(
      page,
      '<!-- generated:beta -->\n<!-- /generated:beta -->\n',
      bodies,
    ).text;
    expect(regenerate(page, once, bodies).text, once);
  });

  test('keeps CRLF line endings', () {
    final text = regenerate(
      page,
      'Intro\r\n<!-- generated:beta -->\r\n<!-- /generated:beta -->\r\n',
      bodies,
    ).text;
    expect(
      text,
      'Intro\r\n<!-- generated:beta -->\r\n\r\nB\r\n\r\n'
      '<!-- /generated:beta -->\r\n',
    );
  });

  test('leaves markers inside code fences alone', () {
    const markdown = '```text\n<!-- generated:alpha -->\n```\n';
    final result = regenerate(page, markdown, bodies);
    expect(result.text, markdown);
    expect(result.sections, isEmpty);
    expect(result.problems, isEmpty);
  });

  for (final (name, markdown, problem) in [
    (
      'an unknown name',
      '<!-- generated:gamma -->\n<!-- /generated:gamma -->\n',
      '$page:1: Unknown generated section: gamma. Known: alpha, beta.',
    ),
    (
      'a section never closed',
      '<!-- generated:alpha -->\ntext\n',
      '$page:1: Section alpha is never closed with '
          '<!-- /generated:alpha -->.',
    ),
    (
      'an end marker without a start',
      '<!-- /generated:alpha -->\n',
      '$page:1: An end marker without a start marker.',
    ),
    (
      'mismatched markers',
      '<!-- generated:alpha -->\n<!-- /generated:beta -->\n',
      '$page:2: This ends section beta, but alpha is open (line 1).',
    ),
    (
      'nested sections',
      '<!-- generated:alpha -->\n<!-- generated:beta -->\n'
          '<!-- /generated:alpha -->\n',
      "$page:2: Generated sections can't be nested.",
    ),
  ]) {
    test('reports $name and leaves the text unchanged', () {
      final result = regenerate(page, markdown, bodies);
      expect(result.problems.map((x) => '$x'), [problem]);
      expect(result.text, markdown);
    });
  }

  test('refuses sections in pages below docs/guide/', () {
    final result = regenerate(
      'docs/guide/how-to/x.md',
      '<!-- generated:beta -->\n<!-- /generated:beta -->\n',
      bodies,
    );
    expect(result.problems.map((x) => '$x'), [
      'docs/guide/how-to/x.md: Generated sections link relative to '
          'docs/guide/, so they belong in pages directly in that folder.',
    ]);
  });
}
```

Create `test/doc_comments_test.dart`:

```dart
import 'package:test/test.dart';

import '../tool/src/doc_comments.dart';

void main() {
  test('docCommentAbove reads the /// lines above a declaration, skipping '
      'annotations', () {
    final lines = [
      "import 'x.dart';",
      '',
      '/// Checks the JDK.',
      '///',
      '/// More detail.',
      '@immutable',
      'final class A {',
    ];
    expect(docCommentAbove(lines, 6), 'Checks the JDK.\n\nMore detail.');
  });

  test('docCommentAbove is null without a doc comment', () {
    expect(docCommentAbove(['// plain comment', 'class A {}'], 1), isNull);
  });

  test('firstParagraph joins the first paragraph, shows references as code '
      'and escapes pipes', () {
    expect(
      firstParagraph('Finds [JavaLocation] via\n`a|b` and [link](x).\n\nMore.'),
      r'Finds `JavaLocation` via `a\|b` and [link](x).',
    );
  });
}
```

Run: `fvm dart test test/generated_sections_test.dart test/doc_comments_test.dart`
Expected: FAIL, because the files don't exist.

- [ ] **Step 2: Implement the markers**

Create `tool/src/generated_sections.dart`:

```dart
import 'package:path/path.dart' as p;

import 'guide_checker.dart';

final _start = RegExp(r'^<!-- generated:([a-z0-9-]+) -->$');
final _end = RegExp(r'^<!-- /generated:([a-z0-9-]+) -->$');

/// A page after its generated sections were rendered again.
final class RegeneratedPage {
  /// Creates the result.
  const RegeneratedPage(this.text, this.sections, this.problems);

  /// The page with every section's body replaced. It is the unchanged input
  /// when there are [problems].
  final String text;

  /// The names of the sections the page has, in order.
  final List<String> sections;

  /// Malformed markers, unknown names, or sections in a page they can't be
  /// in.
  final List<GuideProblem> problems;
}

/// Replaces the body of each generated section in [markdown], the text of
/// [page], with its entry in [bodies] (spec §19.6).
///
/// A section is a `<!-- generated:<name> -->` line, then anything, then a
/// `<!-- /generated:<name> -->` line. The body is written with a blank line
/// after the start marker and before the end marker. Markers inside code
/// fences are examples and are left alone. The page's line endings (LF or
/// CRLF) are kept. Generated links are relative to `docs/guide/`, so a page
/// in a subfolder may not have sections.
RegeneratedPage regenerate(
  String page,
  String markdown,
  Map<String, String> bodies,
) {
  final crlf = markdown.contains('\r\n');
  final lines = markdown.replaceAll('\r\n', '\n').split('\n');
  final out = <String>[];
  final sections = <String>[];
  final problems = <GuideProblem>[];
  String? open;
  var openLine = 0;
  var inFence = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();
    if (open == null) {
      out.add(line);
      if (trimmed.startsWith('```')) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      final start = _start.firstMatch(trimmed);
      if (start != null) {
        open = start.group(1)!;
        openLine = i + 1;
        sections.add(open);
      } else if (_end.hasMatch(trimmed)) {
        problems.add(
          GuideProblem(page, i + 1, 'An end marker without a start marker.'),
        );
      }
      continue;
    }
    final end = _end.firstMatch(trimmed);
    if (end == null) {
      if (_start.hasMatch(trimmed)) {
        problems.add(
          GuideProblem(page, i + 1, "Generated sections can't be nested."),
        );
      }
      continue;
    }
    if (end.group(1) != open) {
      problems.add(
        GuideProblem(
          page,
          i + 1,
          'This ends section ${end.group(1)}, but $open is open '
          '(line $openLine).',
        ),
      );
    }
    final body = bodies[open];
    if (body == null) {
      final known = bodies.keys.toList()..sort();
      problems.add(
        GuideProblem(
          page,
          openLine,
          'Unknown generated section: $open. Known: ${known.join(', ')}.',
        ),
      );
    }
    out
      ..add('')
      ..add((body ?? '').trimRight())
      ..add('')
      ..add(line);
    open = null;
  }
  if (open != null) {
    problems.add(
      GuideProblem(
        page,
        openLine,
        'Section $open is never closed with <!-- /generated:$open -->.',
      ),
    );
  }
  if (sections.isNotEmpty && p.posix.dirname(page) != 'docs/guide') {
    problems.add(
      GuideProblem(
        page,
        null,
        'Generated sections link relative to docs/guide/, so they belong in '
        'pages directly in that folder.',
      ),
    );
  }
  if (problems.isNotEmpty) return RegeneratedPage(markdown, sections, problems);
  final text = out.join('\n');
  return RegeneratedPage(
    crlf ? text.replaceAll('\n', '\r\n') : text,
    sections,
    const [],
  );
}
```

- [ ] **Step 3: Implement doc-comment reading**

Create `tool/src/doc_comments.dart`:

```dart
/// The `///` doc comment directly above line [index] of [lines], without
/// the slashes, with its lines joined by `\n`. Annotation lines, such as
/// `@override`, between the comment and the declaration are skipped. Null
/// when there is no doc comment.
///
/// This reads source text rather than parsing it: `package:analyzer` would
/// make every guide check several seconds slower, and `dart format` keeps
/// doc comments in this layout.
String? docCommentAbove(List<String> lines, int index) {
  var i = index - 1;
  while (i >= 0 && lines[i].trimLeft().startsWith('@')) {
    i--;
  }
  final doc = <String>[];
  while (i >= 0 && lines[i].trimLeft().startsWith('///')) {
    final text = lines[i].trimLeft().substring(3);
    doc.add(text.startsWith(' ') ? text.substring(1) : text);
    i--;
  }
  return doc.isEmpty ? null : doc.reversed.join('\n');
}

/// The first paragraph of [doc] on one line, with `[Name]` references shown
/// as code and `|` escaped, so it fits in a Markdown table cell.
String firstParagraph(String doc) {
  final paragraph = <String>[];
  for (final line in doc.split('\n')) {
    if (line.trim().isEmpty) {
      if (paragraph.isNotEmpty) break;
      continue;
    }
    paragraph.add(line.trim());
  }
  return paragraph
      .join(' ')
      .replaceAllMapped(
        RegExp(r'\[([^\]]+)\](?!\()'),
        (match) => '`${match[1]}`',
      )
      .replaceAll('|', r'\|');
}
```

- [ ] **Step 4: Run the tests, format and analyze**

Run: `fvm dart test test` then `fvm dart format .` then `fvm dart analyze --fatal-infos`
Expected: all pass, clean.

- [ ] **Step 5: Commit (controller)**

```bash
git add tool/src/generated_sections.dart tool/src/doc_comments.dart test/generated_sections_test.dart test/doc_comments_test.dart
git commit -m "feat(tool): generated-section markers and doc-comment reading"
```

---

### Task 5: The five generators and `gen_docs.dart`

**Files:**
- Create: `tool/src/generators.dart`, `tool/src/generated_docs.dart`, `tool/gen_docs.dart`
- Test: `test/generators_test.dart`, `test/generated_docs_test.dart`

**Interfaces:**
- Consumes:
  - `regenerate`, `docCommentAbove` and `firstParagraph` (Task 4);
  - `GuideProblem` (Task 1);
  - from `package:appstein_engine`: `defaultDoctorChecks()`, each with `id` and `title`;
  - from `package:appstein_cli`: `runAppstein(List<String>, {StringSink? out, StringSink? err})` and `ExitCodes.ok`.
- Produces:
  - `GenerateException(String message)`;
  - `Future<Map<String, String>> renderSections(String repoRoot)`, whose keys are `cli-help`, `exit-codes`, `doctor-checks`, `ci-jobs` and `package-graph`;
  - the renderers `renderDoctorChecks(String)`, `renderExitCodes(String)`, `Future<String> renderCliHelp()`, `renderCiJobs(String)` and `renderPackageGraph(String)`;
  - `GuideRegeneration(List<String> changedPages, List<GuideProblem> problems)`;
  - `Future<GuideRegeneration> regenerateGuide(String repoRoot, List<String> pages, {required bool write, Map<String, String>? bodies})`.

Every link a generator writes is relative to `docs/guide/`, so a link reads `../../<repo path>`.

- [ ] **Step 1: Write the failing generator tests (against the real repo)**

Create `test/generators_test.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/generators.dart';

/// `dart test test` runs from the repo root, and these generators read the
/// real repo: that is the point of them.
final root = Directory.current.path;

void main() {
  test('doctor-checks lists every default check in order, with its doc '
      'comment and a working link', () {
    final rows = renderDoctorChecks(root).split('\n');
    expect(rows.take(2), [
      '| # | ID | Shown as | What it checks | Code |',
      '|---|---|---|---|---|',
    ]);
    final checks = defaultDoctorChecks();
    expect(rows.skip(2), hasLength(checks.length));
    for (var i = 0; i < checks.length; i++) {
      final row = rows[i + 2];
      expect(
        row,
        startsWith('| ${i + 1} | `${checks[i].id}` | ${checks[i].title} | '),
      );
      final link = RegExp(r'\]\(\.\./\.\./([^)]+)\) \|$').firstMatch(row);
      expect(link, isNotNull, reason: row);
      expect(File(p.join(root, link!.group(1))).existsSync(), isTrue);
    }
    expect(
      rows.join('\n'),
      contains('Checks the JDK Flutter actually uses for Android builds'),
    );
  });

  test('exit-codes lists ExitCodes with their doc comments, by code', () {
    expect(
      renderExitCodes(root),
      startsWith(
        '| Code | Name | Meaning |\n|---|---|---|\n'
        '| `0` | `ExitCodes.ok` | No errors. |\n'
        '| `1` | `ExitCodes.errorsFound` | Errors found. Used by the CLI and '
        'CI. |\n'
        '| `3` | `ExitCodes.appsteinFailed` | Appstein itself failed: bad '
        'usage, a bad environment or a crash. |',
      ),
    );
  });

  test('cli-help shows the top-level help and each command', () async {
    final text = await renderCliHelp();
    expect(
      text,
      startsWith(
        '```text\n\$ appstein --help\nA knowledge and verification layer',
      ),
    );
    expect(text, contains('\$ appstein help doctor\nCheck your environment'));
    expect('```'.allMatches(text), hasLength(4));
  });

  test('ci-jobs lists the triggers, each job, where it runs and its '
      'steps', () {
    final text = renderCiJobs(root);
    expect(
      text,
      contains('Triggers: `push` (`main`), `pull_request`, '
          '`workflow_dispatch`.'),
    );
    for (final job in ['analyze', 'test', 'build', 'docs', 'min-sdk']) {
      expect(text, contains('**`$job`** runs on'));
    }
    expect(
      text,
      contains(
        '**`test`** runs on `ubuntu-latest`, `windows-latest`, '
        '`macos-latest`:',
      ),
    );
    expect(text, contains('1. `actions/checkout@v4`'));
    expect(text, contains('. Developer guide check'));
  });

  test('package-graph draws the workspace dependencies', () {
    expect(
      renderPackageGraph(root),
      startsWith(
        '```mermaid\ngraph LR\n'
        '  appstein_cli --> appstein_engine\n'
        '  appstein_cli --> appstein_protocol\n'
        '  appstein_engine --> appstein_protocol\n'
        '  appstein_lints --> appstein_protocol\n```',
      ),
    );
  });

  test('renderSections renders all five sections', () async {
    expect((await renderSections(root)).keys, unorderedEquals([
      'cli-help',
      'exit-codes',
      'doctor-checks',
      'ci-jobs',
      'package-graph',
    ]));
  });
}
```

Create `test/generated_docs_test.dart`:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/generated_docs.dart';
import 'support/temp_repo.dart';

void main() {
  late Directory repo;
  const bodies = {'alpha': 'A', 'beta': 'B'};
  const pages = ['docs/guide/a.md', 'docs/guide/b.md'];

  setUp(() {
    repo = tempFolder();
    writeFile(
      repo,
      'docs/guide/a.md',
      '# A\n<!-- generated:alpha -->\nold\n<!-- /generated:alpha -->\n',
    );
    writeFile(
      repo,
      'docs/guide/b.md',
      '# B\n<!-- generated:beta -->\n\nB\n\n<!-- /generated:beta -->\n',
    );
  });

  String read(String page) => File(p.join(repo.path, page)).readAsStringSync();

  test('without write, reports out-of-date pages and writes nothing', () async {
    final before = read('docs/guide/a.md');
    final result = await regenerateGuide(
      repo.path,
      pages,
      write: false,
      bodies: bodies,
    );
    expect(result.changedPages, ['docs/guide/a.md']);
    expect(result.problems, isEmpty);
    expect(read('docs/guide/a.md'), before);
  });

  test('with write, rewrites them, and a second run finds nothing', () async {
    await regenerateGuide(repo.path, pages, write: true, bodies: bodies);
    expect(read('docs/guide/a.md'), contains('\n\nA\n\n'));
    final again = await regenerateGuide(
      repo.path,
      pages,
      write: false,
      bodies: bodies,
    );
    expect(again.changedPages, isEmpty);
  });

  test('a section no page shows is a problem', () async {
    final result = await regenerateGuide(
      repo.path,
      pages,
      write: false,
      bodies: {...bodies, 'gamma': 'G'},
    );
    expect(result.problems.map((x) => '$x'), [
      'docs/guide: No page shows the generated section gamma. Add '
          '<!-- generated:gamma --> and <!-- /generated:gamma --> to the '
          'page that explains it.',
    ]);
  });

  test('a generator that fails is a problem, not a crash', () async {
    final result = await regenerateGuide(repo.path, pages, write: false);
    expect(result.problems, isNotEmpty);
    expect(result.changedPages, isEmpty);
  });
}
```

Run: `fvm dart test test/generators_test.dart test/generated_docs_test.dart`
Expected: FAIL, because the files don't exist.

- [ ] **Step 2: Implement the generators**

Create `tool/src/generators.dart`:

```dart
import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'doc_comments.dart';

/// Thrown when a generated section can't be rendered, for example because a
/// doctor check has no doc comment.
final class GenerateException implements Exception {
  /// Creates the exception.
  const GenerateException(this.message);

  /// What is missing, and where.
  final String message;

  @override
  String toString() => message;
}

/// Renders the body of every generated section of the guide (spec §19.6),
/// by section name. Links are relative to `docs/guide/`.
Future<Map<String, String>> renderSections(String repoRoot) async => {
  'cli-help': await renderCliHelp(),
  'exit-codes': renderExitCodes(repoRoot),
  'doctor-checks': renderDoctorChecks(repoRoot),
  'ci-jobs': renderCiJobs(repoRoot),
  'package-graph': renderPackageGraph(repoRoot),
};

/// A table of the checks `appstein doctor` runs, in the order it shows
/// them. Each row gives the ID, the title, the first paragraph of the
/// check's doc comment and a link to its file.
String renderDoctorChecks(String repoRoot) {
  const folder = 'packages/appstein_engine/lib/src/doctor/checks';
  final files =
      Directory(p.join(repoRoot, folder))
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final rows = [
    '| # | ID | Shown as | What it checks | Code |',
    '|---|---|---|---|---|',
  ];
  var number = 0;
  for (final check in defaultDoctorChecks()) {
    final idPattern = RegExp(
      r"\bid(\s*=>|:)\s*'" + RegExp.escape(check.id) + "'",
    );
    String? summary;
    String? path;
    for (final file in files) {
      final lines = file.readAsLinesSync();
      final at = lines.indexWhere(idPattern.hasMatch);
      if (at < 0) continue;
      var start = at;
      while (start > 0 && !_isTopLevelDeclaration(lines[start])) {
        start--;
      }
      final doc = docCommentAbove(lines, start);
      if (doc == null) {
        throw GenerateException(
          '${check.id} has no /// doc comment on its declaration in '
          '${p.basename(file.path)}.',
        );
      }
      summary = firstParagraph(doc);
      path = '$folder/${p.basename(file.path)}';
      break;
    }
    if (summary == null || path == null) {
      throw GenerateException('No declaration in $folder has id ${check.id}.');
    }
    number++;
    rows.add(
      '| $number | `${check.id}` | ${check.title.replaceAll('|', r'\|')} | '
      '$summary | [${p.posix.basename(path)}](../../$path) |',
    );
  }
  return rows.join('\n');
}

/// Whether [line] starts a top-level declaration: it isn't indented, and
/// isn't a closing bracket, comment or annotation.
bool _isTopLevelDeclaration(String line) =>
    line.isNotEmpty && !line.startsWith(RegExp(r'[\s})\]/@]'));

/// A table of the exit codes in `ExitCodes`, sorted by code, each with the
/// first paragraph of its doc comment.
String renderExitCodes(String repoRoot) {
  const file = 'packages/appstein_cli/lib/src/exit_codes.dart';
  final lines = File(p.join(repoRoot, file)).readAsLinesSync();
  final constant = RegExp(r'^\s*static const (\w+) = (\d+);');
  final rows = <(int, String)>[];
  for (var i = 0; i < lines.length; i++) {
    final match = constant.firstMatch(lines[i]);
    if (match == null) continue;
    final doc = docCommentAbove(lines, i);
    if (doc == null) {
      throw GenerateException('ExitCodes.${match[1]} has no /// doc comment.');
    }
    rows.add((
      int.parse(match[2]!),
      '| `${match[2]}` | `ExitCodes.${match[1]}` | ${firstParagraph(doc)} |',
    ));
  }
  if (rows.isEmpty) throw GenerateException('No exit codes found in $file.');
  rows.sort((a, b) => a.$1.compareTo(b.$1));
  return [
    '| Code | Name | Meaning |',
    '|---|---|---|',
    for (final row in rows) row.$2,
    '',
    'Defined in [exit_codes.dart](../../$file).',
  ].join('\n');
}

/// The CLI's own `--help` text, and each command's, exactly as `appstein`
/// prints them.
Future<String> renderCliHelp() async {
  Future<String> help(List<String> arguments) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runAppstein(arguments, out: out, err: err);
    if (code != ExitCodes.ok) {
      throw GenerateException(
        'appstein ${arguments.join(' ')} exited $code: $err',
      );
    }
    return out.toString().trimRight();
  }

  final top = await help(['--help']);
  final commands = _commandNames(top);
  if (commands.isEmpty) {
    throw const GenerateException('`appstein --help` lists no commands.');
  }
  final parts = ['```text', r'$ appstein --help', top, '```'];
  for (final command in commands) {
    parts.addAll([
      '',
      '```text',
      '\$ appstein help $command',
      await help(['help', command]),
      '```',
    ]);
  }
  return parts.join('\n');
}

List<String> _commandNames(String usage) {
  final lines = usage.split('\n');
  final start = lines.indexWhere((line) => line.trim() == 'Available commands:');
  if (start < 0) return const [];
  final names = <String>[];
  for (final line in lines.skip(start + 1)) {
    final match = RegExp(r'^  (\S+)\s').firstMatch(line);
    if (match == null) break;
    names.add(match[1]!);
  }
  return names;
}

/// The CI workflow's triggers, and each job with where it runs and its
/// steps, read from `.github/workflows/ci.yml`.
String renderCiJobs(String repoRoot) {
  const file = '.github/workflows/ci.yml';
  final workflow =
      loadYaml(File(p.join(repoRoot, file)).readAsStringSync()) as YamlMap;
  final triggers = workflow['on'];
  final jobs = workflow['jobs'];
  if (triggers is! YamlMap || jobs is! YamlMap) {
    throw const GenerateException('$file needs an `on:` map and a `jobs:` map.');
  }
  final out = [
    'Defined in [ci.yml](../../$file). Triggers: '
        '${[for (final entry in triggers.entries) _trigger('${entry.key}', entry.value)].join(', ')}.',
  ];
  for (final entry in jobs.entries) {
    final job = entry.value as YamlMap;
    final steps = job['steps'];
    if (steps is! YamlList) {
      throw GenerateException('Job ${entry.key} in $file has no steps.');
    }
    out
      ..add('')
      ..add('**`${entry.key}`** runs on ${_runsOn(job)}:')
      ..add('');
    var number = 0;
    for (final step in steps.cast<YamlMap>()) {
      number++;
      out.add('$number. ${_step(step)}');
    }
  }
  return out.join('\n');
}

String _trigger(String name, Object? value) {
  final branches = value is YamlMap ? value['branches'] : null;
  return branches is YamlList
      ? '`$name` (${branches.map((branch) => '`$branch`').join(', ')})'
      : '`$name`';
}

String _runsOn(YamlMap job) {
  final runsOn = '${job['runs-on']}';
  final strategy = job['strategy'];
  final matrix = strategy is YamlMap ? strategy['matrix'] : null;
  final os = matrix is YamlMap ? matrix['os'] : null;
  if (runsOn.contains('matrix.os') && os is YamlList) {
    return os.map((name) => '`$name`').join(', ');
  }
  return '`$runsOn`';
}

String _step(YamlMap step) {
  if (step['name'] != null) return '${step['name']}';
  if (step['uses'] != null) return '`${step['uses']}`';
  return '`${'${step['run'] ?? ''}'.trim().split('\n').first}`';
}

/// A Mermaid diagram of which workspace package depends on which, read from
/// the pubspecs. Dev dependencies are left out.
String renderPackageGraph(String repoRoot) {
  final workspace =
      loadYaml(File(p.join(repoRoot, 'pubspec.yaml')).readAsStringSync())
          as YamlMap;
  final members = workspace['workspace'];
  if (members is! YamlList) {
    throw const GenerateException('The root pubspec.yaml has no workspace.');
  }
  final dependencies = <String, List<String>>{};
  for (final member in members) {
    final pubspec =
        loadYaml(
              File(p.join(repoRoot, '$member', 'pubspec.yaml')).readAsStringSync(),
            )
            as YamlMap;
    final deps = pubspec['dependencies'];
    dependencies['${pubspec['name']}'] = deps is YamlMap
        ? [for (final name in deps.keys) '$name']
        : const [];
  }
  final names = dependencies.keys.toList()..sort();
  final lines = ['```mermaid', 'graph LR'];
  for (final name in names) {
    final internal =
        dependencies[name]!.where(dependencies.containsKey).toList()..sort();
    if (internal.isEmpty) {
      final usedBySome = dependencies.values.any((deps) => deps.contains(name));
      if (!usedBySome) lines.add('  $name');
    }
    for (final dependency in internal) {
      lines.add('  $name --> $dependency');
    }
  }
  lines
    ..add('```')
    ..add('')
    ..add(
      'An arrow means "depends on". Read from each package\'s '
      '`pubspec.yaml`; dev dependencies are left out.',
    );
  return lines.join('\n');
}
```

- [ ] **Step 3: Implement the regeneration run and `gen_docs.dart`**

Create `tool/src/generated_docs.dart`:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

import 'generated_sections.dart';
import 'generators.dart';
import 'guide_checker.dart';

/// What regenerating the guide found.
final class GuideRegeneration {
  /// Creates the result.
  const GuideRegeneration(this.changedPages, this.problems);

  /// Pages whose generated sections were out of date. They were rewritten
  /// when regenerating with `write`.
  final List<String> changedPages;

  /// Problems that stopped a page or a section from being regenerated.
  final List<GuideProblem> problems;
}

/// Renders every generated section of the guide [pages] again (spec §19.6).
///
/// With [write], out-of-date pages are rewritten; without it, nothing is
/// written. [bodies] replaces the real generators, for tests. A section no
/// page shows is a problem, so no generated fact goes unshown. A generator
/// that fails is reported as a problem.
Future<GuideRegeneration> regenerateGuide(
  String repoRoot,
  List<String> pages, {
  required bool write,
  Map<String, String>? bodies,
}) async {
  final Map<String, String> rendered;
  try {
    rendered = bodies ?? await renderSections(repoRoot);
  } on Exception catch (error) {
    return GuideRegeneration(const [], [
      GuideProblem('tool/src/generators.dart', null, '$error'),
    ]);
  }
  final changed = <String>[];
  final problems = <GuideProblem>[];
  final used = <String>{};
  for (final page in pages) {
    final file = File(p.join(repoRoot, page));
    final before = file.readAsStringSync();
    final result = regenerate(page, before, rendered);
    problems.addAll(result.problems);
    used.addAll(result.sections);
    if (result.problems.isEmpty && result.text != before) {
      changed.add(page);
      if (write) file.writeAsStringSync(result.text);
    }
  }
  for (final name in rendered.keys) {
    if (!used.contains(name)) {
      problems.add(
        GuideProblem(
          'docs/guide',
          null,
          'No page shows the generated section $name. Add '
          '<!-- generated:$name --> and <!-- /generated:$name --> to the '
          'page that explains it.',
        ),
      );
    }
  }
  return GuideRegeneration(changed, problems);
}
```

Create `tool/gen_docs.dart`:

```dart
import 'dart:io';

import 'src/generated_docs.dart';
import 'src/guide_checker.dart';

/// Regenerates the generated sections of the developer guide (spec §19.6).
/// Run from the repo root:
///   fvm dart run tool/gen_docs.dart          rewrite out-of-date sections
///   fvm dart run tool/gen_docs.dart --check  write nothing; exit 1 if any
///                                            section is out of date
Future<void> main(List<String> arguments) async {
  final check = arguments.contains('--check');
  if (arguments.any((argument) => argument != '--check')) {
    stderr.writeln('Usage: fvm dart run tool/gen_docs.dart [--check]');
    exitCode = 3;
    return;
  }
  final root = Directory.current.path;
  final result = await regenerateGuide(
    root,
    guidePages(root),
    write: !check,
  );
  for (final problem in result.problems) {
    stderr.writeln(problem);
  }
  for (final page in result.changedPages) {
    stdout.writeln(
      check ? '$page: generated sections are out of date.' : 'Updated $page',
    );
  }
  if (result.problems.isNotEmpty ||
      (check && result.changedPages.isNotEmpty)) {
    exitCode = 1;
  } else if (result.changedPages.isEmpty) {
    stdout.writeln('Generated sections are up to date.');
  }
}
```

- [ ] **Step 4: Run the tests, format, analyze and check dependencies**

Run: `fvm dart test test` then `fvm dart format .` then `fvm dart analyze --fatal-infos` then `fvm dart run dependency_validator`
Expected: all pass and clean.
- If the `ci-jobs` test shows that `package:yaml` reads the `on:` key as `true` (YAML 1.1), not `'on'`, look the key up by checking both, then add a test for it.
- If `dependency_validator` flags one of the new root dev dependencies as unused, check that `tool/` imports it. Fix the import, not the validator config.

Also run: `fvm dart run tool/gen_docs.dart --check`
Expected: exit 1 with `No page shows the generated section …` for all five, because no page has markers yet. Tasks 8 and 9 add them.

- [ ] **Step 5: Commit (controller)**

```bash
git add tool/src/generators.dart tool/src/generated_docs.dart tool/gen_docs.dart test/generators_test.dart test/generated_docs_test.dart
git commit -m "feat(tool): generate guide sections from the code (gen_docs)"
```

---

### Task 6: One guide gate, CI and AGENTS.md

**Files:**
- Create: `tool/src/guide_check.dart`
- Modify: `tool/check_guide.dart`, `.github/workflows/ci.yml` (the `docs` job), `AGENTS.md`
- Test: `test/guide_check_test.dart`

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces:
  - `Future<List<GuideProblem>> checkGuide(String repoRoot, {String? since})`;
  - the CLI `fvm dart run tool/check_guide.dart [--since <rev>] [--warn-only]`, which Task 7's hook calls with `--since HEAD~1 --warn-only`.

- [ ] **Step 1: Write the failing test**

Create `test/guide_check_test.dart`:

```dart
import 'package:test/test.dart';

import '../tool/src/guide_check.dart';
import 'support/temp_repo.dart';

void main() {
  test('reports a --since that is not a commit instead of crashing', () async {
    final repo = tempRepo();
    writeFile(repo, 'docs/guide/README.md', '<!-- covers: none -->\n# G\n');
    runGit(repo, ['add', '.']);
    runGit(repo, ['commit', '-q', '-m', 'first']);
    final problems = await checkGuide(repo.path, since: 'nope');
    expect(
      problems.map((problem) => '$problem'),
      contains('--since: nope is not a commit.'),
    );
  });
}
```

Run: `fvm dart test test/guide_check_test.dart`
Expected: FAIL, because `tool/src/guide_check.dart` doesn't exist. (Once it exists, this temp repo also reports generator problems, since it has no Appstein code. That is expected, so the test only asserts the `--since` problem.)

- [ ] **Step 2: Implement `checkGuide`**

Create `tool/src/guide_check.dart`:

```dart
import 'coverage.dart';
import 'generated_docs.dart';
import 'git_repo.dart';
import 'guide_checker.dart';
import 'stale_check.dart';

/// Runs every developer guide check (spec §19.6) on the repo at [repoRoot]:
/// - links and repo paths in the guide and package READMEs;
/// - every guide page linked from the start page;
/// - the coverage map;
/// - generated sections up to date;
/// - with [since], the stale-page check against the merge base of [since]
///   and HEAD.
///
/// Throws [GitException] when [repoRoot] isn't a git repo.
Future<List<GuideProblem>> checkGuide(String repoRoot, {String? since}) async {
  final git = GitRepo(repoRoot);
  final pages = guidePages(repoRoot);
  final problems = <GuideProblem>[
    for (final file in guideFiles(repoRoot)) ...checkMarkdown(repoRoot, file),
    ...checkLinked(repoRoot, pages),
  ];
  final covers = readCoverMap(repoRoot, pages);
  problems
    ..addAll(covers.problems)
    ..addAll(checkCoverage(covers.map, git.files()));
  if (since != null) {
    if (git.hasCommit(since)) {
      problems.addAll(
        checkStale(
          map: covers.map,
          changed: git.changedSince(since),
          messages: git.messagesSince(since),
        ),
      );
    } else {
      problems.add(GuideProblem('--since', null, '$since is not a commit.'));
    }
  }
  final generated = await regenerateGuide(repoRoot, pages, write: false);
  problems
    ..addAll(generated.problems)
    ..addAll([
      for (final page in generated.changedPages)
        GuideProblem(
          page,
          null,
          'Generated sections are out of date. Run: '
          'fvm dart run tool/gen_docs.dart',
        ),
    ]);
  return problems;
}
```

Replace `tool/check_guide.dart` with:

```dart
import 'dart:io';

import 'package:args/args.dart';

import 'src/git_repo.dart';
import 'src/guide_check.dart';
import 'src/guide_checker.dart';

/// Checks the developer guide and package READMEs (spec §19.6). Run from the
/// repo root:
///   fvm dart run tool/check_guide.dart               every check except the
///                                                    stale-page check
///   fvm dart run tool/check_guide.dart --since main  plus the stale-page
///                                                    check against main
/// The post-commit hook adds --warn-only, which prints problems as warnings
/// and always exits 0. CI is the gate.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'since',
      valueHelp: 'rev',
      help:
          'Also check for stale pages: compare the working tree with the '
          'merge base of <rev> and HEAD.',
    )
    ..addFlag(
      'warn-only',
      negatable: false,
      help: 'Print problems as warnings and exit 0 (for the git hook).',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');
  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln(parser.usage);
    exitCode = 3;
    return;
  }
  if (options.flag('help')) {
    stdout.writeln(parser.usage);
    return;
  }
  if (options.rest.isNotEmpty) {
    stderr
      ..writeln('Unexpected arguments: ${options.rest.join(' ')}')
      ..writeln(parser.usage);
    exitCode = 3;
    return;
  }
  final warnOnly = options.flag('warn-only');
  final List<GuideProblem> problems;
  try {
    problems = await checkGuide(
      Directory.current.path,
      since: options.option('since'),
    );
  } on GitException catch (error) {
    stderr.writeln('Run this from the root of the Appstein repo. $error');
    exitCode = warnOnly ? 0 : 3;
    return;
  }
  for (final problem in problems) {
    stderr.writeln(warnOnly ? 'warning: $problem' : '$problem');
  }
  if (problems.isEmpty) {
    if (!warnOnly) stdout.writeln('Guide check passed.');
    return;
  }
  if (warnOnly) {
    stderr.writeln(
      'The developer guide may need attention (${problems.length} '
      'warning(s)). CI fails on these. See docs/guide/docs-tooling.md.',
    );
  } else {
    stdout.writeln('${problems.length} problem(s) found.');
    exitCode = 1;
  }
}
```

- [ ] **Step 3: Update the CI `docs` job**

In `.github/workflows/ci.yml`, change the `docs` job's first step to:

```yaml
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # the stale-page check compares with the base commit
```

Then replace its `Developer guide check` step with:

```yaml
      - name: Developer guide check
        shell: bash
        # Pull requests compare with their base branch, and pushes with the
        # commit before the push. A manual run, a new branch or a force push
        # has no usable base, so only the stale-page part is skipped
        # (spec §19.6).
        env:
          BASE_REF: ${{ github.base_ref }}
          BEFORE: ${{ github.event.before }}
        run: |
          since=""
          if [ -n "$BASE_REF" ]; then
            since="origin/$BASE_REF"
          elif [ -n "$BEFORE" ] && git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
            since="$BEFORE"
          fi
          if [ -n "$since" ]; then
            dart run tool/check_guide.dart --since "$since"
          else
            echo "No base commit to compare with, so the stale-page check is skipped."
            dart run tool/check_guide.dart
          fi
```

- [ ] **Step 4: Update AGENTS.md**

In `AGENTS.md`:

Replace the **Developer guide** bullet under "Source of truth" with:

```markdown
- **Developer guide:** `docs/guide/` explains how the whole system works now, for humans (spec §19.6). Every source file is covered by a page (the `<!-- covers: -->` comment at its top). When you change code, update the pages that cover it, or add a `Docs-Checked: <page> - <reason>` commit trailer when a page is still right. Run `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`. See `docs/guide/docs-tooling.md`.
```

Replace the **Per slice** rule with:

```markdown
- **Per slice:** spec → implementation plan → TDD implementation → verify → docs → owner review → commit. The docs step means `///` comments on every public API, the `docs/guide/` pages for what the slice built, `gen_docs` and the guide check (spec §19.6), then a full `/graphify . --update`, because the git hooks refresh only code structure. Never write guide pages for code that doesn't exist yet.
```

Replace the **graphify** gotcha with:

```markdown
- **Git hooks:** run `fvm dart run tool/install_hooks.dart` once per clone, and again when `tool/src/hooks.dart` changes. It installs graphify's hooks (dev tooling: `uv tool install graphifyy`), graph rebuilds after merges and rebases, and a post-commit docs warning.
```

- [ ] **Step 5: Run everything, and look at the real-repo result**

Run: `fvm dart test test` then `fvm dart format .` then `fvm dart analyze --fatal-infos`
Expected: all pass, clean.

Run: `fvm dart run tool/check_guide.dart --since main`
Expected: exit 1. The guide isn't written yet. The problems must be only of these kinds:
- `docs/guide/<page>.md:1: Start the page with a covers comment…`, for the three existing pages;
- `<source file>: No guide page covers this file…`;
- the five `No page shows the generated section …`;
- stale-page problems for changed `tool/` files and `ci.yml`.

Any other problem, or a crash, is a bug in this task. Record the problem count in the task report.

- [ ] **Step 6: Commit (controller)**

```bash
git add tool/src/guide_check.dart tool/check_guide.dart test/guide_check_test.dart .github/workflows/ci.yml AGENTS.md
git commit -m "feat(tool): one guide gate with coverage, stale pages and generated sections; wire into CI"
```

---

### Task 7: Hooks installable from the repo

**Files:**
- Create: `tool/src/hooks.dart`, `tool/install_hooks.dart`
- Test: `test/hooks_test.dart`
- Local, not versioned: replace `.git/hooks/post-merge` and `.git/hooks/post-rewrite` (the controller does this)

**Interfaces:**
- Consumes:
  - `findExecutable(String name, HostEnvironment environment)`, `HostEnvironment.current()` and `const SystemProcessRunner()`, whose `.run(executable, args, {timeout})` returns a `RunResult` with `.ok`, `.stdout` and `.stderr` (`package:appstein_engine`);
  - `check_guide.dart --since HEAD~1 --warn-only` (Task 6).
- Produces:
  - `hookBlockStart`, `hookBlockEnd`;
  - `hookBlocks` (`post-commit`, `post-merge`, `post-rewrite`);
  - `String upsertHookBlock(String? existing, String block)`;
  - `String? removeHookBlock(String existing)`;
  - `List<String> installHookBlocks(String hooksDir, {bool remove = false})`.

- [ ] **Step 1: Write the failing tests**

Create `test/hooks_test.dart`:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/hooks.dart';
import 'support/temp_repo.dart';

const graphify =
    '#!/bin/sh\n# graphify-hook-start\n(\n  echo graph\n)\n'
    '# graphify-hook-end\n';

void main() {
  final block = hookBlocks['post-merge']!;

  test('every block is marked and runs in a subshell', () {
    expect(hookBlocks.keys, ['post-commit', 'post-merge', 'post-rewrite']);
    for (final text in hookBlocks.values) {
      expect(text, startsWith('$hookBlockStart\n'));
      expect(text, endsWith(hookBlockEnd));
      expect(text, contains('\n(\n'));
      expect(text, contains('\n)\n'));
    }
  });

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
      'post-commit: installed',
      'post-merge: installed',
      'post-rewrite: installed',
    ]);
    expect(installHookBlocks(hooks), [
      'post-commit: up to date',
      'post-merge: up to date',
      'post-rewrite: up to date',
    ]);
    expect(installHookBlocks(hooks, remove: true), [
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
      // arguments.
      final fake = File(p.join(hooks, 'post-checkout'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          '#!/bin/sh\necho "\$1 \$2 \$3" >> "\$(git rev-parse --git-dir)/'
          'checkout.log"\n',
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
      expect(logged().last, '$a $b 1');
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
      expect(logged().last, '$oldTip ${head()} 1');
    });
  });
}
```

Run: `fvm dart test test/hooks_test.dart`
Expected: FAIL, because `tool/src/hooks.dart` doesn't exist.

- [ ] **Step 2: Implement the hook blocks**

Create `tool/src/hooks.dart`:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

/// Marks the start of the block Appstein keeps in a git hook file.
const hookBlockStart = '# appstein-hook-start';

/// Marks the end of that block.
const hookBlockEnd = '# appstein-hook-end';

/// The blocks Appstein keeps in the repo's git hooks, by hook name
/// (spec §19.6).
///
/// Git runs hooks with its own `sh`, on Windows too. Each block runs in a
/// subshell, so its `exit` never stops the other blocks in the same file,
/// such as graphify's.
const hookBlocks = {
  'post-commit': _postCommit,
  'post-merge': _postMerge,
  'post-rewrite': _postRewrite,
};

const _postCommit = r'''
# appstein-hook-start
# Warns when the developer guide may have fallen behind this commit
# (spec §19.6). CI is the gate; this only warns. Skip it once with
# APPSTEIN_SKIP_DOCS_HOOK=1. Installed by: fvm dart run tool/install_hooks.dart
(
  [ "${APPSTEIN_SKIP_DOCS_HOOK:-0}" = "1" ] && exit 0
  GIT_DIR=${GIT_DIR:-$(git rev-parse --git-dir 2>/dev/null)}
  [ -d "$GIT_DIR/rebase-merge" ] && exit 0
  [ -d "$GIT_DIR/rebase-apply" ] && exit 0
  [ -f tool/check_guide.dart ] || exit 0
  git rev-parse -q --verify HEAD~1 >/dev/null || exit 0
  if command -v fvm >/dev/null 2>&1; then
    fvm dart run tool/check_guide.dart --since HEAD~1 --warn-only
  elif command -v dart >/dev/null 2>&1; then
    dart run tool/check_guide.dart --since HEAD~1 --warn-only
  fi
  exit 0
)
# appstein-hook-end''';

const _postMerge = r'''
# appstein-hook-start
# Rebuilds the graphify graph after a merge or pull, which graphify's own
# hooks miss. It reuses graphify's post-checkout rebuild, as if HEAD had
# switched branches. Installed by: fvm dart run tool/install_hooks.dart
(
  hook="$(git rev-parse --git-path hooks)/post-checkout"
  [ -x "$hook" ] || exit 0
  old=$(git rev-parse -q --verify ORIG_HEAD) || exit 0
  "$hook" "$old" "$(git rev-parse HEAD)" 1
)
# appstein-hook-end''';

const _postRewrite = r'''
# appstein-hook-start
# Rebuilds the graphify graph after a rebase; graphify's post-commit hook
# already covers an amend. It reuses graphify's post-checkout rebuild.
# Installed by: fvm dart run tool/install_hooks.dart
(
  [ "$1" = "rebase" ] || exit 0
  hook="$(git rev-parse --git-path hooks)/post-checkout"
  [ -x "$hook" ] || exit 0
  old=$(git rev-parse -q --verify ORIG_HEAD) || exit 0
  "$hook" "$old" "$(git rev-parse HEAD)" 1
)
# appstein-hook-end''';

/// Where Appstein's block is in [text], or null when it has none. Throws
/// [FormatException] when a start marker has no end marker.
(int, int)? _blockRange(String text) {
  final start = text.indexOf(hookBlockStart);
  if (start < 0) return null;
  final end = text.indexOf(hookBlockEnd, start);
  if (end < 0) {
    throw const FormatException(
      'The hook has "$hookBlockStart" but no "$hookBlockEnd". Fix or delete '
      'the file, then run the installer again.',
    );
  }
  return (start, end + hookBlockEnd.length);
}

/// [existing] (a hook file's text, or null when there is no file) with
/// [block] in it. An older Appstein block is replaced in place; otherwise
/// [block] is appended. Everything else, such as graphify's block, is kept.
String upsertHookBlock(String? existing, String block) {
  if (existing == null || existing.trim().isEmpty) {
    return '#!/bin/sh\n$block\n';
  }
  final text = existing.replaceAll('\r\n', '\n');
  final range = _blockRange(text);
  if (range == null) {
    return '${text.endsWith('\n') ? text : '$text\n'}\n$block\n';
  }
  return text.replaceRange(range.$1, range.$2, block);
}

/// [existing] without Appstein's block, or [existing] unchanged when it has
/// none. Null when nothing but the `#!` line would be left, meaning the file
/// can be deleted.
String? removeHookBlock(String existing) {
  final text = existing.replaceAll('\r\n', '\n');
  final range = _blockRange(text);
  if (range == null) return existing;
  final before = text.substring(0, range.$1).trimRight();
  final after = text.substring(range.$2).trim();
  final rest = [if (before.isNotEmpty) before, if (after.isNotEmpty) after]
      .join('\n\n');
  if (rest.isEmpty || rest == '#!/bin/sh') return null;
  return '$rest\n';
}

/// Writes Appstein's block into each hook in [hooksDir], or with [remove]
/// takes it out. Returns one line per hook saying what changed. A file left
/// with nothing but `#!/bin/sh` is deleted. On macOS and Linux, hooks are
/// made executable.
List<String> installHookBlocks(String hooksDir, {bool remove = false}) {
  Directory(hooksDir).createSync(recursive: true);
  final report = <String>[];
  for (final entry in hookBlocks.entries) {
    final file = File(p.join(hooksDir, entry.key));
    final before = file.existsSync() ? file.readAsStringSync() : null;
    if (remove) {
      final after = before == null ? before : removeHookBlock(before);
      if (before == null || after == before) {
        report.add('${entry.key}: not installed');
      } else if (after == null) {
        file.deleteSync();
        report.add('${entry.key}: removed (file deleted)');
      } else {
        file.writeAsStringSync(after);
        report.add('${entry.key}: removed');
      }
      continue;
    }
    final after = upsertHookBlock(before, entry.value);
    if (after == before) {
      report.add('${entry.key}: up to date');
    } else {
      file.writeAsStringSync(after);
      report.add('${entry.key}: ${before == null ? 'installed' : 'updated'}');
    }
    if (!Platform.isWindows) Process.runSync('chmod', ['+x', file.path]);
  }
  return report;
}
```

Create `tool/install_hooks.dart`:

```dart
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;

import 'src/hooks.dart';

/// Installs the repo's git hooks (spec §19.6). Run it from the repo root
/// once per clone, and again when `tool/src/hooks.dart` changes:
///   fvm dart run tool/install_hooks.dart           install or update
///   fvm dart run tool/install_hooks.dart --remove  remove Appstein's blocks
/// graphify's own hooks are removed with `graphify hook uninstall`.
Future<void> main(List<String> arguments) async {
  final remove = arguments.contains('--remove');
  if (arguments.any((argument) => argument != '--remove')) {
    stderr.writeln('Usage: fvm dart run tool/install_hooks.dart [--remove]');
    exitCode = 3;
    return;
  }
  final root = Directory.current.path;
  final gitPath = Process.runSync('git', [
    'rev-parse',
    '--git-path',
    'hooks',
  ], workingDirectory: root);
  if (gitPath.exitCode != 0) {
    stderr.writeln('Run this from the Appstein repo: ${gitPath.stderr}');
    exitCode = 3;
    return;
  }
  final hooksDir = p.normalize(
    p.join(root, (gitPath.stdout as String).trim()),
  );
  if (!remove) {
    final graphify = findExecutable('graphify', HostEnvironment.current());
    if (graphify == null) {
      stdout.writeln(
        'graphify is not installed, so its graph hooks are skipped. Install '
        'it with `uv tool install graphifyy`, then run this again.',
      );
    } else {
      final result = await const SystemProcessRunner().run(graphify, [
        'hook',
        'install',
      ], timeout: const Duration(minutes: 2));
      stdout.write(result.stdout);
      if (!result.ok) {
        stderr.writeln('graphify hook install failed: ${result.stderr}');
      }
    }
  }
  try {
    for (final line in installHookBlocks(hooksDir, remove: remove)) {
      stdout.writeln(line);
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 3;
  }
}
```

- [ ] **Step 3: Run the tests, format and analyze**

Run: `fvm dart test test` then `fvm dart format .` then `fvm dart analyze --fatal-infos`
Expected: all pass, clean.

The real-repo group runs actual git hooks through git's `sh`. It must pass on Windows here and on all three CI runners. If `[ -x "$hook" ]` is false on Windows for the fake hook, don't weaken the block. Git for Windows' `sh` treats a file starting with `#!` as executable, and the owner's hand-made hooks passed this check end to end on 2026-09-30. Investigate the fake file's content instead.

- [ ] **Step 4: Install on the development machine (controller)**

1. The hand-made hooks from 2026-09-30 have no markers, so the installer would append a second rebuild. Show the owner their content, then delete `.git/hooks/post-merge` and `.git/hooks/post-rewrite`.
2. Run: `fvm dart run tool/install_hooks.dart`
   - Expected: graphify reports its hooks as already installed.
   - Then: `post-commit: updated`, `post-merge: installed`, `post-rewrite: installed`.
3. Run: `graphify hook status`
   - Expected: both of graphify's hooks are "installed".
4. Look at `.git/hooks/post-commit`. Expected: graphify's block, then ours.

- [ ] **Step 5: Commit (controller)**

```bash
git add tool/src/hooks.dart tool/install_hooks.dart test/hooks_test.dart
git commit -m "feat(tool): install graphify's hooks, graph rebuilds on merge and rebase, and a docs warning"
```

The post-commit docs warning now runs on this commit. It warns, because the guide isn't written yet; that is expected until Task 9.

---

### Task 8: Guide content, part 1 (start page, overview, CLI, CI, docs tooling, testing, debugging)

**Files:**
- Rewrite: `docs/guide/README.md`, `docs/guide/architecture.md`, `docs/guide/debugging.md`
- Create: `docs/guide/cli.md`, `docs/guide/ci.md`, `docs/guide/docs-tooling.md`, `docs/guide/testing.md`

**How to write every page (applies to Tasks 8 and 9):**
- **Structure:**
  - Line 1 is the page's covers comment, exactly as in the File Structure table; line 2 is blank; line 3 is the `# Title`.
  - Generated sections are empty marker pairs; `gen_docs` fills them.
- **Accuracy:**
  - Read the code a section describes before writing it. Every claim must be true of the code now.
  - Link to source files with relative links (`../../packages/...`) or name them as backticked repo paths. The checker verifies both.
  - Don't copy source code. No ```` ```dart ```` blocks.
  - Never describe code that doesn't exist yet. To mention later work, link the spec section in one short clause.
- **Style:**
  - Explain *why* as well as *how*: the owner is learning to build large CLI tools.
  - Keep each page short and scannable: short sections, tables and lists over long paragraphs.
  - Link to the spec instead of restating it.
- **Links:** link every page you write from the README's guide map.

**Page contents:**

1. **`README.md`** (`<!-- covers: none -->`). Keep the title, the intro, "Set up", "A tour of the repo", "Build and run the CLI from source" and "Run the tests", with these changes:
   - **Intro:** add one sentence: "The spec is the design: what we decided and why. This guide is the current system: how it works."
   - **Set up:** add step 4, "Install the git hooks: `fvm dart run tool/install_hooks.dart`". Say in one line what it installs, and link [docs-tooling](docs-tooling.md).
   - **Tour:** the `tool/` row becomes "Repo scripts: start-up check, analyze measurement, the guide check, the docs generator and the hooks installer".
   - **New section "Guide map":** a table, Page | Read it to learn, with one row per page in the File Structure table except README itself, each linked.
   - **Run the tests:** add that `fvm dart test test` from the repo root runs the `tool/` tests, and link [testing](testing.md).
   - **New section "Before you commit":**
     - `fvm dart format .`;
     - `fvm dart analyze --fatal-infos`;
     - `fvm dart run tool/gen_docs.dart`;
     - `fvm dart run tool/check_guide.dart --since main`.
     - Link docs-tooling.
   - **CI:** replace the table with one sentence and a link to [ci](ci.md). ci.md generates the job list, so a hand copy here would drift.

2. **`architecture.md`** (covers `packages/appstein_engine/lib/appstein_engine.dart`, `packages/appstein_protocol/lib/**`). Title: "How Appstein works". This is the overview. Sections:
   - **What exists now.** It is a CLI with `--version` and `doctor`, an engine behind it, shared data models and an analyzer plugin. Link spec §18 for what later slices add, in one clause.
   - **The four packages.** An empty `package-graph` section, then the roles of protocol, engine, cli and lints. Reuse the current bullets, checked against the code. The protocol bullet names its models; verify the list against `packages/appstein_protocol/lib/appstein_protocol.dart`.
   - **One command, end to end.** A ```` ```mermaid ```` `flowchart TD` of `appstein doctor`: `bin/appstein.dart` → `runGuarded` → `runAppstein` → the command runner → `DoctorCommand.run` → `resolveProjectRoot` → `Doctor.run` → `SdkDetector.detect` (once) → every `DoctorCheck` in parallel → `DoctorReport` → `formatDoctorReport` → exit code. Below it, a numbered list with one line per step and a link to the area page that explains it (cli, doctor, sdk-lookups, running-tools).
   - **Where each part is explained.** A table: engine folder, what it does, guide page (host → running-tools, config and text → config, sdk and android → sdk-lookups, doctor and project → doctor). Add the lints package → lints and the repo tools → docs-tooling and ci.
   - **What the engine exports.** One paragraph: the barrel `appstein_engine.dart` exports everything the CLI and the tools use, and there's no other public entry point.
   - Move the old "How `layer_imports` finds its rules" section to lints.md (Task 9). Delete it here, and link lints.md instead.

3. **`cli.md`** (covers `packages/appstein_cli/lib/**`, `packages/appstein_cli/bin/**`). Title: "The command line". Sections:
   - **What the CLI does and doesn't.** It is a thin layer: it parses arguments, calls the engine and prints. No logic, so the MCP server and hooks can later share the engine (spec §5.1).
   - **Start-up and crash safety.**
     - `bin/appstein.dart` → `runGuarded`: why it sets `exitCode` instead of calling `exit()` (stdout flushing on Windows consoles), and how an uncaught async error becomes exit 3.
     - `runAppstein` returns a code instead of exiting, so tests run the CLI in-process.
     - `UsageException` → message plus usage, exit 3; `ConfigException` → "Invalid appstein.yaml", exit 3; anything else → `reportCrash`, exit 3.
   - **Global options.**
     - `--version` (`versionText`);
     - `--project`: `resolveProjectRoot`. An explicit path must contain `pubspec.yaml`; otherwise it is the nearest folder upward with one, or none.
   - **Output.** `formatDoctorReport`, and why the labels are plain ASCII (`[ok]`, `[warn]`, …): any Windows console code page shows them.
   - **Help text.** An empty `cli-help` section.
   - **Exit codes.** An empty `exit-codes` section, then one line linking spec §9.5.

4. **`ci.md`** (covers `.github/workflows/**`, `tool/startup_check.dart`, `tool/measure_analyze.dart`). Title: "Continuous integration". Sections:
   - **When CI runs, and how to run it on a branch.** It runs on pull requests, pushes to `main` and manual runs. A feature branch gets CI through a draft PR. `gh run list` and `gh run view --log` read results; job summaries can't be read through `gh`, which is why `measure` also `tee`s its table into the log.
   - **The jobs.** An empty `ci-jobs` section.
   - **Why each job exists.** One short subsection per job, taken from the workflow's comments and the old README table, each checked against `ci.yml`:
     - **analyze:** the FLUTTER_STABLE and `.fvmrc` sync, the raw-BOM guard and why (editing tools that decode `\uFEFF` escapes), `--enforce-lockfile`, `--fatal-infos`, `dependency_validator`.
     - **test:** the three OSes, and the integration-tagged doctor tests against the real runner.
     - **build:** the AOT binary, the 200 ms start-up budget measured by `tool/startup_check.dart`, and why doctor may exit 0 or 1 but never 3 or 255.
     - **docs:** `dart doc --dry-run`, and the guide check with its `--since` choice (PR base, the push's `before`, or skipped); link docs-tooling.md.
     - **min-sdk:** Flutter 3.44.x, and why there's no `--enforce-lockfile`.
     - **measure:** cold analysis with the plugin, by `tool/measure_analyze.dart`, and what the numbers decided (spec §9.1).

5. **`docs-tooling.md`** (covers `tool/check_guide.dart`, `tool/gen_docs.dart`, `tool/install_hooks.dart`, `tool/src/**`). Title: "How this guide stays correct". Sections:
   - **The rules,** in four bullets, linking spec §19.6.
   - **Covers comments:**
     - a ```` ```text ```` example of the multi-line form and of `none`;
     - what "source" means (the four globs);
     - that a glob matching nothing is an error, which catches moved folders;
     - that overlapping covers are fine.
   - **Stale pages and `Docs-Checked`:**
     - what counts as changed (the merge base with `--since`, compared with the working tree including untracked files; renames count as both paths);
     - a ```` ```text ```` example commit message with the trailer;
     - when to use it (the page is still right) and when not (to skip writing docs);
     - that the page may be named relative to `docs/guide/` or to the repo.
   - **Generated sections:**
     - a ```` ```text ```` example of the markers;
     - a table of the five names, each with its page and source of truth (`cli-help` and `exit-codes` → cli.md; `doctor-checks` → doctor.md; `ci-jobs` → ci.md; `package-graph` → architecture.md);
     - that sections only go in pages directly in `docs/guide/`;
     - that a section no page shows is an error.
   - **Commands:** `gen_docs` (and `--check`), and `check_guide` (with `--since` and `--warn-only`), with the exit codes 0, 1 and 3.
   - **Git hooks:**
     - what `install_hooks` does: runs `graphify hook install` when graphify is on PATH, then adds our marked block to `post-commit`, `post-merge` and `post-rewrite`;
     - what each block does;
     - why they are tiny `sh` blocks: git runs hooks with its own `sh`, on Windows too, and the logic stays in tested Dart;
     - `APPSTEIN_SKIP_DOCS_HOOK=1`, `GRAPHIFY_SKIP_HOOK=1`, `--remove`, and re-running after `tool/src/hooks.dart` changes;
     - the cost: the post-commit check takes a few seconds, which is why doc comments are read as text, not with the analyzer.
   - **At the end of each slice:** `gen_docs`, then `check_guide --since main`, then a full `/graphify . --update`, because hooks rebuild only code structure. Link AGENTS.md.
   - **Limits:** the check proves a page was touched or confirmed, not that it is good. Review still matters.

6. **`testing.md`** (covers `packages/appstein_engine/test/support/**`, `packages/appstein_cli/test/support/**`, `packages/appstein_engine/dart_test.yaml`, `test/support/**`). Title: "How the tests work". Read every support file first. Sections:
   - **Where the tests are, and how to run them.** Each package has its own tests, plus the root `test/` for `tool/`. Commands are in README; link it.
   - **Fakes for the machine:** `fakeEnvironment`, the fake process runner, `fake_sdk.dart`, `fake_android.dart` and `doctor_support.dart`. Say what each builds, and that fake executables are made executable on POSIX.
   - **Real temporary folders.** `tempDir()` names folders with a space and a non-ASCII character. Explain why.
   - **Tests against the real machine:**
     - the `integration` tag in `dart_test.yaml`, and `--run-skipped --tags integration`;
     - `doctor_real_environment_test.dart`, including its cross-check of the JDK choice against `flutter doctor -v`;
     - the lesson: unit tests mirror our model of Flutter, so they can't catch a wrong model. Only comparing with Flutter's own answer can.
   - **CLI tests:** `runAppstein` with a `StringBuffer`, and `async_error_harness.dart` for `runGuarded`. Read it to describe how it's used.
   - **Lint tests:** `analyzer_testing` with `test_reflective_loader`.
   - **Tool tests:**
     - `tempRepo()` and `runGit()` in `test/support/temp_repo.dart`;
     - why `GIT_*` variables are stripped;
     - that the hook tests run real git hooks.

7. **`debugging.md`** (`<!-- covers: none -->`). Keep the three sections, checked against the code, and add two:
   - **The knowledge graph isn't updating:**
     - `graphify hook status`;
     - the log at `~/.cache/graphify-rebuild.log`;
     - `GRAPHIFY_SKIP_HOOK`;
     - re-running `tool/install_hooks.dart`.
   - **The docs hook prints warnings after a commit:** what they mean, that they never block a commit, how to fix or confirm (link docs-tooling.md), and `APPSTEIN_SKIP_DOCS_HOOK=1`.

- [ ] **Step 1: Write the seven pages** as specified above.
- [ ] **Step 2: Fill the generated sections.** Run: `fvm dart run tool/gen_docs.dart`. Expected: `Updated docs/guide/architecture.md`, `cli.md` and `ci.md`. Read the generated text in each page; it must read well where it sits.
- [ ] **Step 3: Check.** Run: `fvm dart run tool/check_guide.dart`. Expected:
  - no link, path or covers-comment problems in these seven pages;
  - the only link problems are `Broken link` entries in README's guide map for the Task 9 pages (`doctor.md`, `sdk-lookups.md`, `running-tools.md`, `config.md`, `lints.md` and the three `how-to/` pages), which don't exist yet. Every page that exists is reached from the start page;
  - the remaining uncovered files are only under `doctor/`, `project/`, `sdk/`, `android/`, `host/`, `config/`, `text/` and `packages/appstein_lints/lib/`;
  - `doctor-checks` is the only unused generated section.
- [ ] **Step 4: Commit (controller)**

```bash
git add docs/guide
git commit -m "docs(guide): overview, CLI, CI, docs tooling and testing pages"
```

---

### Task 9: Guide content, part 2 (doctor, lookups, running tools, config, lints, how-tos, package READMEs)

**Files:**
- Create: `docs/guide/doctor.md`, `docs/guide/sdk-lookups.md`, `docs/guide/running-tools.md`, `docs/guide/config.md`, `docs/guide/lints.md`, `docs/guide/how-to/add-a-doctor-check.md`, `docs/guide/how-to/add-a-lint-rule.md`, `docs/guide/how-to/add-a-guide-page.md`
- Modify: `packages/appstein_protocol/README.md`, `packages/appstein_engine/README.md`, `packages/appstein_cli/README.md`, `packages/appstein_lints/README.md`, and `docs/guide/README.md` (only if the guide map needs fixing)

Follow "How to write every page" from Task 8.

**Page contents:**

1. **`doctor.md`** (covers `packages/appstein_engine/lib/src/doctor/**`, `packages/appstein_engine/lib/src/project/**`). Title: "`appstein doctor`". Sections:
   - **What it is for.** Link spec §5.3.
   - **How a run works.** `Doctor.run` detects the SDK once through `SdkDetector`, builds a `DoctorContext`, runs the checks in parallel and keeps results in check order. `DoctorReport.hasErrors` drives exit 1.
   - **Results.** The `CheckStatus` values and what each means; a fix hint appears only on a warning or an error; `details` lines.
   - **The checks.** An empty `doctor-checks` section.
   - **Finding the project:** `findProjectRoot`, and what `ProjectCheck` reports.
   - **Shared helpers:** what `check_helpers.dart` provides. Read it.
   - **A rule the checks follow.** When doctor reports on Flutter's toolchain, it gives Flutter's own answer, not an opinion. Link sdk-lookups.md. Give the slice 1a lesson (a false JDK error, found by comparing with `flutter doctor -v`) in two sentences, and link testing.md.
   - **Adding a check.** Link [how-to/add-a-doctor-check](how-to/add-a-doctor-check.md).

2. **`sdk-lookups.md`** (covers `packages/appstein_engine/lib/src/sdk/**`, `packages/appstein_engine/lib/src/android/**`, `packages/appstein_protocol/lib/src/sdk_info.dart`). Title: "Finding Flutter, the JDK and the Android SDK". Verify every rule against the code and its `///` comments. Sections:
   - **Why the lookups copy Flutter's own.** A different answer from Flutter's is a bug, even when ours looks more sensible.
   - **The Flutter SDK:**
     - the order FVM pin → FLUTTER_ROOT → PATH;
     - FVM pins (`.fvmrc` or `.fvm/fvm_config.json`), looked up in parent folders with the nearest winning;
     - the `.fvm/flutter_sdk` link, then FVM's cache (`FVM_CACHE_PATH` or `~/fvm`);
     - a stale link being skipped;
     - an unmet pin, which falls back to FLUTTER_ROOT or PATH, accepted only when the version equals the pin (`SdkLocation.unmetFvmPin`, `SdkInfo.fvmVersion`);
     - `resolveLinks` for links and junctions (link running-tools.md).
   - **Versions:**
     - `readSdkVersions` reads `bin/cache/flutter.version.json`, because it takes milliseconds where `flutter --version` takes seconds;
     - `SdkNotSetUpException`, which FVM shows as "Need setup";
     - the language version from `pubspec.yaml` and why it matters (spec §3);
     - `supported_versions.dart`.
   - **Flutter's settings file:** where `flutterSettingsPath` looks on each OS.
   - **The JDK:**
     - the order `--jdk-dir` → Android Studio → JAVA_HOME → PATH;
     - how Android Studio is chosen, mirroring `AndroidStudio.latestValid`:
       - `android-studio-dir` only;
       - the install records and default folders;
       - newest first;
       - a bundled `java -version` that runs;
       - the `skipped` list;
       - Toolbox not searched;
     - that a configured `android-studio-dir` that doesn't exist is an error, as in Flutter (in `java_check.dart`; link doctor.md);
     - `parseJavaMajor`.
   - **The Android SDK:**
     - the first *defined* of the config value, ANDROID_HOME, ANDROID_SDK_ROOT and the default folder, or its `sdk` subfolder;
     - that `licenses/` or `platform-tools/` marks an SDK;
     - the `adb` fallback.
   - **Known gaps.** Link the slice 1a plan's "Carried to later slices" section (`docs/superpowers/plans/2026-09-29-slice-1a-workspace-cli-doctor.md`), for example the narrower macOS Android Studio discovery.

3. **`running-tools.md`** (covers `packages/appstein_engine/lib/src/host/**`). Title: "Reading the machine and running tools". Sections:
   - **`HostEnvironment`:**
     - it is the engine's only view of the OS, environment variables and working folder, and why (tests);
     - names are case-insensitive on Windows;
     - home;
     - PATH parsing: quotes and empty entries.
   - **`findExecutable`:** PATHEXT on Windows, the executable bit elsewhere.
   - **`ProcessRunner` and `SystemProcessRunner`:**
     - it never throws;
     - the `RunResult` states;
     - the default 20 s timeout;
     - no `runInShell`, and why (unquoted paths with spaces);
     - `.bat` and `.cmd` files by full path;
     - the Windows tree kill (`taskkill /T /F` by its full SystemRoot path), and why `Process.kill` isn't enough;
     - pipes drained with a bound, so a child that keeps a pipe open can't hang doctor;
     - invalid bytes tolerated.
   - **`resolveLinks`:** symbolic links and Windows junctions.
   - **Testing code that uses these.** Link testing.md.

4. **`config.md`** (covers `packages/appstein_engine/lib/src/config/**`, `packages/appstein_engine/lib/src/text/**`, `packages/appstein_protocol/lib/src/config/**`). Title: "`appstein.yaml`". Sections:
   - **What the file is.** Link spec §7.
   - **Loading:** `loadConfig` (null when the file is absent) and `parseConfig` (every key has a default, so an empty file is valid).
   - **The keys.** A table built from `AppsteinConfig` and the parser: key, type, default, allowed values (`knownStacks`, `knownPlatforms`, `knownAgents`, `supportedConfigFormat`). Build it by reading the code; don't guess.
   - **Errors:**
     - `ConfigException` with file, line and column;
     - unknown keys with "did you mean" hints, from `closestMatch` and `editDistance` in `text/`;
     - how the CLI turns it into exit 3.
   - **Byte order marks.** Windows PowerShell 5.1 writes a BOM, so it is stripped. The code writes the BOM as an escape, never the raw character, and CI enforces that. Link ci.md.
   - **Where config is used today.** Find the callers of `loadConfig` and say which run it.

5. **`lints.md`** (covers `packages/appstein_lints/lib/**`, `packages/appstein_protocol/lib/src/layer_rules.dart`, `analysis_options.yaml`). Title: "The analyzer plugin and `layer_imports`". Sections:
   - **Why a plugin.** Its rules show up in every IDE and agent through the analysis server.
   - **How the plugin is wired:** `main.dart` and `AppsteinLintsPlugin`. Read them.
   - **`layer_imports`:**
     - what it enforces (spec §5.1, §9.6);
     - where the rules live: the top-level `appstein_lints:` key, because keys under a `plugins:` entry trigger `unsupported_option`;
     - how `LayerConfigFinder` walks up (move the text from the old architecture.md, checked against the code);
     - matching: the first matching tag wins, posix globs, and a tag with no `allow` entry is unrestricted;
     - `LayerRules` in protocol;
     - our own boundaries at the bottom of the root `analysis_options.yaml`.
   - **Why `path:` for the protocol dependency:** the analysis server resolves a plugin's dependencies outside the workspace.
   - **Testing rules:** `analyzer_testing`. Link testing.md.
   - **Debugging:** link debugging.md.
   - **Adding a rule:** link the how-to.

6. **`how-to/add-a-doctor-check.md`** (covers `packages/appstein_engine/lib/src/doctor/doctor_check.dart`). Numbered steps, each with the file to touch:
   1. Create the file in `checks/` and implement `DoctorCheck`:
      - the id is `doctor.<name>`;
      - the title is shown to people;
      - `run` returns a `CheckResult` and never throws;
      - use `context.runner` and `context.environment`, with a full path for `.bat` tools.
   2. Write a `///` doc comment on the class. Its first paragraph becomes the check's row in doctor.md.
   3. Add it to `defaultDoctorChecks()` in display order.
   4. Export it from `appstein_engine.dart`.
   5. Test a passing case and a failing case with the fakes.
   6. If it mirrors Flutter, extend the integration cross-check.
   7. Run `gen_docs`, update doctor.md's prose if needed, then run `check_guide`.

7. **`how-to/add-a-lint-rule.md`** (covers `packages/appstein_lints/lib/src/appstein_lints_plugin.dart`). Numbered steps from the real code: the rule class, registration in the plugin, the diagnostic name, enabling it in `analysis_options.yaml`, tests with `analyzer_testing`, restarting the analysis server, and updating lints.md.

8. **`how-to/add-a-guide-page.md`** (`<!-- covers: none -->`). Steps:
   1. Create the page.
   2. Put the covers comment first. A ```` ```text ```` example.
   3. Link it from README's guide map.
   4. Add generated sections if the page shows code facts: top-level pages only; a new generator goes in `tool/src/generators.dart` with a test.
   5. Run `gen_docs` and `check_guide`.

   Link docs-tooling.md.

9. **Package READMEs.** Check each claim in the four `packages/*/README.md` files against the code and fix what's wrong. Add a line "How it works: …" linking the matching guide pages: protocol → architecture; engine → doctor, sdk-lookups, running-tools, config; cli → cli; lints → lints.

- [ ] **Step 1: Write the eight pages and fix the READMEs** as specified above.
- [ ] **Step 2: Fill the generated sections.** Run: `fvm dart run tool/gen_docs.dart`. Expected: `Updated docs/guide/doctor.md`. Read the table in place.
- [ ] **Step 3: The whole gate must pass**

Run:
- `fvm dart run tool/gen_docs.dart --check`. Expected: `Generated sections are up to date.`, exit 0.
- `fvm dart run tool/check_guide.dart --since main`. Expected: `Guide check passed.`, exit 0.
  - Every source file is covered.
  - Every page is linked.
  - The branch's `tool/` and `ci.yml` changes are matched by docs-tooling.md and ci.md, which this branch created.

If a stale-page problem remains for a file whose page really is still right, fix the page. `Docs-Checked` isn't needed on this branch, because it writes every page.

- [ ] **Step 4: Full verification**

Run, from the repo root:
- `fvm dart format --output=none --set-exit-if-changed .`
- `fvm dart analyze --fatal-infos`
- `fvm dart run dependency_validator`
- `fvm dart test test`
- for each package: `cd packages/<pkg>` then `fvm dart test`
- for each package: `fvm dart doc --dry-run`

Expected: all pass.

- [ ] **Step 5: Commit (controller)**

```bash
git add docs/guide packages/appstein_protocol/README.md packages/appstein_engine/README.md packages/appstein_cli/README.md packages/appstein_lints/README.md
git commit -m "docs(guide): doctor, lookups, running tools, config, lints and how-to pages"
```

The post-commit hook runs the docs check on this commit and must print nothing.

---

### Task 10: Finish the slice (controller)

- [ ] **Step 1:** Update AGENTS.md "Current phase": "M1 slice 1a and 1a.1 (developer-guide freshness: coverage map, stale-page check, generated sections, hooks) are complete. Next: plan slice 1b." Run `check_guide --since main` again.
- [ ] **Step 2:** Add a "Notes from execution" section to this plan: what differed from the plan, and the hook timing measured on the development machine (time `fvm dart run tool/check_guide.dart --since HEAD~1 --warn-only`).
- [ ] **Step 3:** Run a full semantic graph update (`/graphify . --update`), as the per-slice rule says.
- [ ] **Step 4:** Commit, after the final whole-branch review and its fix wave. Then offer the owner a push and a PR. Never push without the owner's OK.
- [ ] **Step 5:** Update memory: the slice 1a.1 status, and that the next step is planning slice 1b.

---

## Notes from execution (2026-09-30)

Executed subagent-driven. The controller committed every task; each task had a spec-and-quality review, and the whole branch had a final review plus one fix wave. Commits: 071d63e (spec and plan) through 2e20b29 (final fixes).

**What differed from the plan:**
- **`firstParagraph`** leaves `[x]` inside backtick code alone (Task 4 fix). The plan's regex would have broken a table cell for a doc comment containing `list[0]`.
- **YAML reading in the generators** checks each shape and reports a malformed `ci.yml` or pubspec as a problem naming the file (Task 5 fix). The plan's `as` casts threw `TypeError`, which the regeneration run didn't catch.
- **The git check's doc comment** in `tool_check.dart` now says the planned `create` and `upgrade` commands need git (spec §13), so the generated doctor table no longer describes unbuilt commands (Task 9 fix). The user-facing `why:` strings are unchanged.
- **Final review:**
  - One shared fence helper and one link helper (`tool/src/markdown.dart`) replace four copies.
  - Guide problems print posix paths on every OS, and backticked `test/` paths are checked.
  - `--warn-only` never fails the hook.
  - New tests: an end-to-end stale-page test and `sh -n` on every hook block.
  - `docs-tooling.md` states the stale check's limits.
- **Hand-made hooks:** the owner's hand-made `post-merge` and `post-rewrite` were kept as `.git/hooks/*.handmade-2026-09-30.bak`, not deleted, before the installer replaced them.

**Measured on the development machine:**
- `fvm dart run tool/check_guide.dart --since HEAD~1 --warn-only` takes 2.9–3.0 s warm (three runs).
- A whole commit, including graphify's detached rebuild launch, takes about 4 s.

**Owner decisions (2026-09-30), on the questions raised at the finish:**
- **Exit code for an invalid `appstein.yaml`: the spec was updated to match the code.** §9.5 and §15 now say `doctor` reports a bad environment or an invalid config as failed checks (exit 1), and exits 3 only when it can't run at all. Other commands keep exit 3.
- **A stricter stale rule: yes, in a later slice.** The stale-page check should stop counting a page diff that `gen_docs` wrote as the page changing. Compare pages with generated section bodies stripped (`git show <base>:<page>` against the working copy). Until then, the limit is documented in docs-tooling.md "Limits".
- **Trailer severity: kept strict.** A mistyped `Docs-Checked` trailer still fails CI. It is rare, and the stale file it meant to clear fails anyway. Revisit if it causes trouble.

**Carried to later slices:**
- The stricter stale rule above. It is small and self-contained, so it can go into whichever slice next touches `tool/`.

**Parked (see the final review):**
- A slightly overbroad sentence in docs-tooling.md:121.
- Multi-line git errors under `--warn-only`.
- The empty reason when `merge-base` finds no common ancestor.
