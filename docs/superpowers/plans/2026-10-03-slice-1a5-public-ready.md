# Slice 1a.5: Public-Ready Repo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the now-public repo ready for outside readers and contributors: the Apache-2.0 license, contributing and security guides, issue and PR templates, and a progress page whose old pull-request links no longer point at the wrong pull requests.

**Architecture:** One tooling change: `progress.yaml` gains an optional `merge` field (a commit ID) for slices whose pull requests were in the deleted private repo. The parser checks it, the visual page links it to `<repository>/commit/<id>`, and the guide check confirms the commit exists. Everything else is new or edited Markdown and YAML files, plus two GitHub settings.

**Tech Stack:** Dart 3.13 via FVM (`fvm dart …`), `package:yaml`, `package:test`, git, the `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md`: §1.1 (license, trademark wording), §19.5 (License), §19.6 (progress is data), §22 rows 10–11, as edited in `a5a8a58`. The design was approved in chat on 2026-10-03 (owner choices below).

**Owner decisions (2026-10-03):**

1. **Old pull requests:** a slice merged in the old private repo records its merge commit (`merge:`), and the page links that commit. 1b.7's real pull request in the new repo is #1.
2. **Community files:** LICENSE, README, CONTRIBUTING.md, SECURITY.md, plus a bug-report issue template and a PR template. No Code of Conduct yet.
3. **Trademark check:** before the first *published* release (pub.dev or GitHub Releases); the public repo alone is not a release (now in the spec).
4. **Security reports:** GitHub private vulnerability reporting first, then the email `the.uttam.vaghasia@gmail.com` (already public in every commit).
5. **The slice id** is 1a.5, a tooling slice (delegated to Claude: "Your call").

## Global Constraints

- Run every Dart command through FVM: `fvm dart …`. The `dart` on PATH is an older SDK.
- Tooling tests live in `test/` at the repo root: `fvm dart test test/<file>`. Package suites run per package.
- Use the Read, Edit and Write tools for files. Never use shell redirection, `sed -i` or heredocs to write files.
- Commit gate: `LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' packages tool test` must print nothing.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01G16ScNBdLf8NHDkSgGiVrW`. A commit that changes a covered source file without changing its guide page carries `Docs-Checked: <page>.md - <reason>`.
- The license is the Apache License 2.0. Contributions are accepted under the same license (Apache-2.0 §5), with no CLA (spec §19.5).
- Never touch agent credentials; never encode Play Store or App Store policies (spec §2.3, §4).
- Never use Albert Einstein's name, image or signature (spec §1.1).
- `rtk` is not on the Git Bash PATH: use plain commands in Bash.

## Review Focus

1. **A `merge` ID YAML reads as a number** (all digits, such as `1234567`, or `1e12345`): the parser must say to quote it, never crash or link a number. Test in Task 1.
2. **A mistyped, ambiguous or missing `merge` commit:** the guide check names the slice and says that a shallow clone lacks old commits. Tests in Task 2, both a unit test and an end-to-end test against a real git repo.
3. **A full 40-digit ID, and uppercase hex:** 40 digits are accepted; uppercase is refused, so the page never mixes forms. Test in Task 1.
4. **Both `pr` and `merge`, or `merge` on a slice that isn't done:** refused. Tests in Task 1.
5. **A done slice with neither `pr` nor `merge`:** still refused, with the message naming both. Test in Task 1 (an updated existing test).

---

### Task 1: Parse the `merge` field

**Files:**
- Modify: `tool/src/progress.dart`
- Test: `test/progress_test.dart`

**Interfaces:**
- Produces: `Slice.merge` (`String?`), the merge commit ID as written (7 to 40 lowercase hex digits). A done slice has exactly one of `Slice.pr` and `Slice.merge`.

- [ ] **Step 1: Write the failing tests.** In `test/progress_test.dart`, change the existing "done slice needs" expectation, and add the tests below it in `main()`. Line numbers refer to `_valid`: 1b.1's `pr: 4` is line 32, and 1b.2's `status: next` is line 37.

Change:

```dart
    expect(problemsOf(text), [
      'docs/superpowers/progress.yaml:7: Slice 1a is done, so it needs plan, '
          'pr and finished.',
    ]);
```

to:

```dart
    expect(problemsOf(text), [
      'docs/superpowers/progress.yaml:7: Slice 1a is done, so it needs plan, '
          'pr (or merge) and finished.',
    ]);
```

Add:

```dart
  group('merge', () {
    test('a done slice may give its merge commit instead of a pr', () {
      final read = parseProgress(_valid.replaceFirst('pr: 4', 'merge: a52fc1a'));
      expect(read.problems, isEmpty);
      final slice = read.progress!.allSlices.singleWhere((s) => s.id == '1b.1');
      expect(slice.merge, 'a52fc1a');
      expect(slice.pr, isNull);
    });

    test('a full 40-digit commit id is accepted', () {
      const id = '0123456789abcdef0123456789abcdef01234567';
      expect(problemsOf(_valid.replaceFirst('pr: 4', 'merge: $id')), isEmpty);
    });

    test('pr and merge together are a problem', () {
      expect(
        problemsOf(
          _valid.replaceFirst('pr: 4\n', 'pr: 4\n            merge: a52fc1a\n'),
        ),
        [
          'docs/superpowers/progress.yaml:33: Slice 1b.1 has both pr and '
              'merge. Use merge only for a pull request that no longer exists.',
        ],
      );
    });

    test('uppercase hex is a problem', () {
      expect(problemsOf(_valid.replaceFirst('pr: 4', 'merge: A52FC1A')), [
        'docs/superpowers/progress.yaml:32: Slice 1b.1: merge must be a '
            'commit id of 7 to 40 lowercase hex digits, not A52FC1A.',
      ]);
    });

    test('a commit id shorter than 7 digits is a problem', () {
      expect(problemsOf(_valid.replaceFirst('pr: 4', 'merge: a52fc1')), [
        'docs/superpowers/progress.yaml:32: Slice 1b.1: merge must be a '
            'commit id of 7 to 40 lowercase hex digits, not a52fc1.',
      ]);
    });

    test('a commit id YAML reads as a number must be quoted', () {
      const message =
          'docs/superpowers/progress.yaml:32: Slice 1b.1: merge must be '
          "text. Quote a commit id that YAML reads as a number, such as "
          "'1234567'.";
      expect(problemsOf(_valid.replaceFirst('pr: 4', 'merge: 1234567')), [
        message,
      ]);
      expect(problemsOf(_valid.replaceFirst('pr: 4', 'merge: 1e12345')), [
        message,
      ]);
      expect(
        problemsOf(_valid.replaceFirst('pr: 4', "merge: '1234567'")),
        isEmpty,
      );
    });

    test('merge is only for a done slice', () {
      expect(
        problemsOf(
          _valid.replaceFirst(
            '            status: next\n',
            '            status: next\n            merge: a52fc1a\n',
          ),
        ),
        [
          'docs/superpowers/progress.yaml:38: Slice 1b.2: merge is only for '
              'a done slice.',
        ],
      );
    });
  });
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `fvm dart test test/progress_test.dart`
Expected: FAIL. The getter `merge` isn't defined for `Slice`, so the file doesn't compile.

- [ ] **Step 3: Implement.** In `tool/src/progress.dart`:

Add `this.merge,` to the `Slice` constructor after `this.pr,`, and the field after `pr`:

```dart
  /// The number of the pull request that merged it.
  final int? pr;

  /// The commit that merged it, as 7 to 40 lowercase hex digits, for a slice
  /// whose pull request was in the old private repo, which no longer exists.
  /// A done slice has [pr] or [merge], not both.
  final String? merge;
```

Change the `Progress.repository` doc comment to:

```dart
  /// The repository's web address, without a trailing slash. A pull request
  /// links to `<repository>/pull/<number>`, and a merge commit to
  /// `<repository>/commit/<id>`.
```

Add the pattern next to `_day`:

```dart
final _commit = RegExp(r'^[0-9a-f]{7,40}$');
```

Add `'merge',` to `_sliceKeys` after `'pr',`.

In `_slice`, after `final pr = _positiveInt(map, 'pr', what);`:

```dart
    final merge = _commitId(map, 'merge', what);
```

Replace the done/not-done block with:

```dart
    if (status == SliceStatus.done) {
      final missing = [
        if (map.nodes['plan'] == null) 'plan',
        if (map.nodes['pr'] == null && map.nodes['merge'] == null)
          'pr (or merge)',
        if (map.nodes['finished'] == null) 'finished',
      ];
      if (missing.isNotEmpty) {
        _problem(map, '$what is done, so it needs ${_and(missing)}.');
      }
      final mergeNode = map.nodes['merge'];
      if (map.nodes['pr'] != null && mergeNode != null) {
        _problem(
          mergeNode,
          '$what has both pr and merge. Use merge only for a pull request '
          'that no longer exists.',
        );
      }
    } else if (status != null) {
      for (final key in const ['pr', 'merge', 'finished']) {
        final value = map.nodes[key];
        if (value != null) {
          _problem(value, '$what: $key is only for a done slice.');
        }
      }
    }
```

Pass `merge: merge,` to the `Slice(...)` constructor after `pr: pr,`.

Add the reader after `_positiveInt`:

```dart
  String? _commitId(YamlMap map, String key, String what) {
    final node = map.nodes[key];
    if (node == null) return null;
    final value = node.value;
    if (value is! String) {
      _problem(
        node,
        "$what: $key must be text. Quote a commit id that YAML reads as a "
        "number, such as '1234567'.",
      );
      return null;
    }
    if (_commit.hasMatch(value)) return value;
    _problem(
      node,
      '$what: $key must be a commit id of 7 to 40 lowercase hex digits, not '
      '$value.',
    );
    return null;
  }
```

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `fvm dart test test/progress_test.dart`
Expected: PASS, all tests.

- [ ] **Step 5: Format and analyze.** Run `fvm dart format tool test` and `fvm dart analyze --fatal-infos`. Expected: no changes, no issues.

- [ ] **Step 6: Commit** (after the BOM gate). Staged: `tool/src/progress.dart`, `test/progress_test.dart`. Message: `tool: progress.yaml slices may give a merge commit instead of a pr`, with the trailer `Docs-Checked: docs-tooling.md - the merge field is documented in Task 2, with its link and check`.

---

### Task 2: Link and check merge commits

**Files:**
- Modify: `tool/src/progress_html.dart` (the meta line, about lines 91–102, and the `renderProgress` doc comment)
- Modify: `tool/src/progress_check.dart` (add `checkMerges`)
- Modify: `tool/src/guide_check.dart` (call it, and add a bullet to the doc comment)
- Modify: `docs/guide/docs-tooling.md` (the Progress section)
- Test: `test/progress_html_test.dart`, `test/progress_check_test.dart`, `test/guide_check_test.dart`

**Interfaces:**
- Consumes: `Slice.merge` (Task 1); `GitRepo.hasCommit(String rev) → bool` (exists in `tool/src/git_repo.dart`).
- Produces: `List<GuideProblem> checkMerges(Progress progress, bool Function(String rev) hasCommit)` in `progress_check.dart`.

- [ ] **Step 1: Write the failing tests.**

In `test/progress_html_test.dart`, add inside the group that holds 'shows a done slice with its date, PR and plan' (it has `html` in scope; this test builds its own record):

```dart
    test('links a merge commit in place of a PR', () {
      const record = Progress(
        repository: 'https://github.com/owner/repo',
        milestones: [
          Milestone(
            id: 'M1',
            title: 'Foundation',
            summary: 'S',
            line: 1,
            slices: [
              Slice(
                id: '1a',
                title: 'Workspace',
                summary: 'S',
                line: 1,
                status: SliceStatus.done,
                plan: '2026-09-29-slice-1a.md',
                merge: '758c535',
                finished: '2026-09-30',
              ),
            ],
          ),
        ],
      );
      expect(
        renderProgress(record),
        contains(
          '<p class="pg-meta"><time datetime="2026-09-30">30 Sep 2026</time>'
          ' · <a href="https://github.com/owner/repo/commit/758c535">merged in'
          ' <code>758c535</code></a>'
          ' · <a href="../plans/2026-09-29-slice-1a.md">Plan</a></p>',
        ),
      );
    });
```

In `test/progress_check_test.dart`, add at the end of `main()` (in `_progress`, slice 1a's entry starts on line 7). `progressOf` calls `expect`, so the record is built in `setUp`, not in the group body:

```dart
  group('checkMerges', () {
    late Progress record;

    setUp(() {
      record = progressOf(_progress.replaceFirst('pr: 1', 'merge: 758c535'));
    });

    test('a merge commit in the repo is fine', () {
      expect(checkMerges(record, (rev) => rev == '758c535'), isEmpty);
    });

    test('a merge commit not in the repo is a problem', () {
      expect(checkMerges(record, (rev) => false).map((p) => '$p'), [
        'docs/superpowers/progress.yaml:7: Slice 1a: merge 758c535 is not a '
            'commit in this repo. A shallow clone lacks old commits; run git '
            'fetch --unshallow.',
      ]);
    });

    test('slices with a pr are not looked up', () {
      final looked = <String>[];
      checkMerges(progressOf(_progress), (rev) {
        looked.add(rev);
        return false;
      });
      expect(looked, isEmpty);
    });
  });
```

In `test/guide_check_test.dart`, add after 'reports progress problems':

```dart
  group('merge commits in progress.yaml', () {
    String progressWith(String merge) =>
        '''
repository: https://github.com/owner/repo
milestones:
  - id: M1
    title: F
    summary: S
    slices:
      - id: 1a
        title: W
        summary: S
        status: done
        plan: p.md
        merge: '$merge'
        finished: 2026-09-30
''';

    late Directory repo;

    setUp(() {
      repo = tempRepo();
      writeFile(repo, 'docs/guide/README.md', '<!-- covers: none -->\n# G\n');
      runGit(repo, ['add', '.']);
      runGit(repo, ['commit', '-q', '-m', 'first']);
    });

    test('a merge commit that is not in the repo is reported', () async {
      writeFile(repo, 'docs/superpowers/progress.yaml', progressWith('abcdef0'));
      final problems = await checkGuide(repo.path);
      expect(
        problems.map((problem) => '$problem'),
        contains(
          'docs/superpowers/progress.yaml:7: Slice 1a: merge abcdef0 is not a '
          'commit in this repo. A shallow clone lacks old commits; run git '
          'fetch --unshallow.',
        ),
      );
    });

    test('a merge commit in the repo is not reported', () async {
      final head = runGit(repo, ['rev-parse', '--short=7', 'HEAD']).trim();
      writeFile(repo, 'docs/superpowers/progress.yaml', progressWith(head));
      final problems = await checkGuide(repo.path);
      expect(
        problems.map((problem) => '$problem'),
        isNot(contains(contains('merge'))),
      );
    });
  });
```

(The quotes around `$merge` matter: a short ID can be all digits, which YAML would read as a number.)

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `fvm dart test test/progress_html_test.dart test/progress_check_test.dart test/guide_check_test.dart`
Expected: FAIL. `checkMerges` isn't defined, the HTML lacks the commit link, and the end-to-end test finds no merge problem.

- [ ] **Step 3: Implement.**

In `tool/src/progress_html.dart`, in `_item`, read `final merge = slice.merge;` after `final pr = slice.pr;`, and add to `meta` after the PR entry:

```dart
    if (merge != null)
      '<a href="${_escape(progress.repository)}/commit/$merge">merged in '
          '<code>$merge</code></a>',
```

Change the last sentence of the `renderProgress` doc comment to: `Pull requests and merge commits link to the repository; plans link relative to docs/superpowers/specs/.` (Keep the backticks the comment already uses around the path.)

In `tool/src/progress_check.dart`, add after `checkProgress`:

```dart
/// Checks that every `merge` commit in [progress] is in the repo, using
/// [hasCommit] (spec §19.6). A mistyped ID would link the visual page to a
/// commit that doesn't exist. Slices with a `pr` aren't looked up.
List<GuideProblem> checkMerges(
  Progress progress,
  bool Function(String rev) hasCommit,
) => [
  for (final slice in progress.allSlices)
    if (slice.merge case final merge? when !hasCommit(merge))
      GuideProblem(
        progressFile,
        slice.line,
        'Slice ${slice.id}: merge $merge is not a commit in this repo. A '
        'shallow clone lacks old commits; run git fetch --unshallow.',
      ),
];
```

In `tool/src/guide_check.dart`, after `problems.addAll(checkProgress(repoRoot, record));`:

```dart
    problems.addAll(checkMerges(record, git.hasCommit));
```

and change the doc comment's bullet `- docs/superpowers/progress.yaml valid, and consistent with the plans and spec §18;` to `- docs/superpowers/progress.yaml valid, consistent with the plans and spec §18, and naming only merge commits that are in the repo;` (keep its existing backticks and line wrapping style).

- [ ] **Step 4: Run the tests to verify they pass.**

Run: `fvm dart test test/progress_html_test.dart test/progress_check_test.dart test/guide_check_test.dart`
Expected: PASS.

- [ ] **Step 5: Update `docs/guide/docs-tooling.md`, section "Progress".**

Replace the example's 1b.1 entry (lines 287–293) with the 1b.7 entry, which shows the usual `pr`:

```text
          - id: 1b.7
            title: Incremental sync
            summary: …
            status: done
            plan: 2026-10-03-slice-1b7-incremental-sync.md
            pr: 1
            finished: 2026-10-03
```

Replace the `pr`, `finished` table row with:

```markdown
| `pr`, `merge`, `finished` | The pull request number, and the day the slice was marked done (`YYYY-MM-DD`). A slice merged in the old private repo, whose pull requests no longer exist, gives its merge commit as `merge` instead: 7 to 40 lowercase hex digits, in quotes when they are all digits. A done slice needs `plan`, `finished`, and `pr` or `merge` but not both; only a done slice may have `pr`, `merge` or `finished` |
```

In "What the page shows", change "with their dates, pull requests and plans" to "with their dates, pull requests (or merge commits) and plans".

In "What the guide check refuses", change the `progress.dart` bullet to:

```markdown
- anything `progress.dart` refuses: an unknown key, a bad status, id, date or commit ID, a done slice without its plan, pull request (or merge commit) and date, a slice with both `pr` and `merge`, more than one slice `next`;
- a `merge` commit that isn't in the repo (from `checkMerges`). A shallow clone lacks old commits, so the check needs the full history, as CI's docs job has;
```

- [ ] **Step 6: Verify.** Run `fvm dart format tool test`, `fvm dart analyze --fatal-infos`, `fvm dart test test`, `fvm dart run tool/gen_docs.dart` and `fvm dart run tool/check_guide.dart --since main`. Expected: everything clean. (`progress.yaml` still uses `pr` everywhere, so the visual page doesn't change yet.)

- [ ] **Step 7: Commit** (after the BOM gate). Staged: the three tool files, the three test files, `docs/guide/docs-tooling.md`. Message: `tool: link merge commits on the progress page and check they exist`.

---

### Task 3: Switch the old slices to their merge commits

**Files:**
- Modify: `docs/superpowers/progress.yaml`
- Regenerated: `docs/superpowers/specs/2026-09-29-appstein-design.html` (by `gen_docs`)

**Interfaces:**
- Consumes: the `merge` field (Tasks 1–2).

- [ ] **Step 1: Confirm each merge commit.** Run `git log --merges --first-parent main --format='%h %s'`. Each old pull request's merge commit must match the table below (the subject ends with the old PR number).

| Slice | Old PR | `merge` |
|---|---|---|
| 1a | #1 | `758c535` |
| 1a.1 | #2 | `1c05b4c` |
| 1a.2 | #3 | `fc5e52b` |
| 1a.3 | #5 | `93d6a28` |
| 1a.4 | #6 | `14d2e06` |
| 1b.1 | #4 | `a52fc1a` |
| 1b.2 | #7 | `2cf55dd` |
| 1b.3 | #8 | `31fd665` |
| 1b.5 | #9 | `de9e977` |
| 1b.4 | #10 | `8bc5725` |
| 1b.6 | #11 | `02d5ebe` |

None of these IDs is all digits, so none needs quotes.

- [ ] **Step 2: Edit `progress.yaml`.** In each slice in the table, replace `pr: <old>` with `merge: <id>`. Change 1b.7's `pr: 12` to `pr: 1`, its pull request in the new repo. Add to the header comment, after its last line:

```yaml
#
# Slices finished before 2026-10-03 give their merge commit (`merge`): their
# pull requests were in the old private repo, which no longer exists.
```

- [ ] **Step 3: Regenerate and read back.** Run `fvm dart run tool/gen_docs.dart`, then `fvm dart run tool/check_guide.dart --since main`. Expected: the page is updated and the check passes. Grep the visual page: `grep -c '/commit/' docs/superpowers/specs/2026-09-29-appstein-design.html` prints `11`; `grep -o 'pull/[0-9]*' …html` prints only `pull/1`. Read the 1a and 1b.7 timeline entries in the page.

- [ ] **Step 4: Commit.** Staged: `progress.yaml`, the visual page. Message: `docs: old slices link their merge commits; 1b.7 is PR #1`.

---

### Task 4: License, NOTICE, README and PRODUCT.md

**Files:**
- Create: `LICENSE`, `NOTICE`
- Modify: `README.md`, `PRODUCT.md`

- [ ] **Step 1: Fetch the license text.** Run `curl -sSfL -o LICENSE https://www.apache.org/licenses/LICENSE-2.0.txt`. This is a download, not a hand-written file, so the official text arrives byte for byte.

- [ ] **Step 2: Verify it.** Run `gh api licenses/apache-2.0 --jq .body > "$SCRATCH/gh-apache.txt"`, where `$SCRATCH` is the session scratchpad, then `diff -w "$SCRATCH/gh-apache.txt" LICENSE`. Expected: no output, so GitHub's own template agrees with the text apart from whitespace and GitHub will detect the license. Also check that `head -3 LICENSE` shows "Apache License" and "Version 2.0, January 2004", and that the file has no BOM. If the texts differ beyond whitespace, stop and report.

- [ ] **Step 3: Create `NOTICE`** (Apache-2.0 §4(d): forks that redistribute must keep it):

```text
Appstein
Copyright 2026 UTTAM-VAGHASIA

This product is licensed under the Apache License, Version 2.0.
See the LICENSE file.
```

- [ ] **Step 4: Edit `README.md`.** Replace the status paragraph's first sentence `> **Status:** pre-alpha, milestone 1.` with `> **Status:** pre-alpha, milestone 1, not published yet (no pub.dev package or binary).`, keeping the rest of the paragraph. Replace the License section with:

```markdown
## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. To report a security problem, see [SECURITY.md](SECURITY.md), and please don't open a public issue.

## License

Appstein is licensed under the [Apache License 2.0](LICENSE). A paid Pro tier may come later, as separate code; the core stays Apache-2.0 (§22 of the spec).
```

- [ ] **Step 5: Edit `PRODUCT.md`.** Replace `- Open source. A paid Pro tier may come later, in separate code. The license is chosen before the first public release.` with `- Open source under the Apache License 2.0. A paid Pro tier may come later, in separate, closed code; the core stays Apache-2.0.`

- [ ] **Step 6: Commit.** Staged: `LICENSE`, `NOTICE`, `README.md`, `PRODUCT.md`. Message: `docs: Apache-2.0 LICENSE and NOTICE; README and PRODUCT say so`.

---

### Task 5: CONTRIBUTING, SECURITY and the GitHub templates

**Files:**
- Create: `CONTRIBUTING.md`, `SECURITY.md`, `.github/ISSUE_TEMPLATE/bug_report.yml`, `.github/pull_request_template.md`
- Modify: `docs/guide/README.md` (one line)

These files are not under the guide's source globs (`packages/*/lib/**`, `packages/*/bin/**`, `tool/**`, `.github/workflows/**`), so they need no covering page.

- [ ] **Step 1: Create `CONTRIBUTING.md`:**

````markdown
# Contributing to Appstein

Thanks for your interest. Appstein is pre-alpha: the design is settled in the [spec](docs/superpowers/specs/2026-09-29-appstein-design.md), and the code is built one slice at a time ([progress](docs/superpowers/progress.yaml)). Small fixes are welcome any time. For anything bigger, open an issue first, so we agree on the approach before you write code.

## Ground rules

- **The spec is the source of truth.** If the code and the spec disagree, say so in an issue. Don't change the spec in a pull request without talking about it first.
- **Appstein never touches agent credentials, and never encodes Play Store or App Store policies** (spec §2.3, §4). Pull requests that do are declined.
- **Windows is first-class:** paths with spaces, drive letters, PowerShell. CI runs on Linux, macOS and Windows.

## Set up

Follow [Set up](docs/guide/README.md#set-up) in the developer guide: FVM, `fvm dart pub get`, and the git hooks. Run every command through FVM (`fvm dart …`, `fvm flutter …`); the `dart` on your PATH may be a different SDK.

graphify (`uv tool install graphifyy`) is optional. It keeps the repo's knowledge graph current for coding agents; without it, `install_hooks` skips the graph hooks and says so.

## Check your change

```powershell
fvm dart format .
fvm dart analyze --fatal-infos
fvm dart test test                                  # the repo tooling
cd packages/appstein_engine; fvm dart test; cd ../..  # and each package you changed
fvm dart run tool/gen_docs.dart
fvm dart run tool/check_guide.dart --since main
```

## Docs travel with the code

Every source file is explained by a page in [`docs/guide/`](docs/guide/README.md); the `<!-- covers: -->` comment at the top of a page lists its files. When you change a file, update its page in the same pull request. If the page is still right, say so with a trailer in your commit message:

```text
Docs-Checked: cli.md - the new flag is hidden and internal
```

Every public API has a `///` doc comment. See [docs-tooling](docs/guide/docs-tooling.md) for the checks.

## Pull requests

- One topic per pull request, with tests. Write the test first when you can.
- Say what changed and why. The pull request template lists the checks.
- Coding agents working on this repo follow [`AGENTS.md`](AGENTS.md).

## License of contributions

Appstein is licensed under the [Apache License 2.0](LICENSE). Unless you say otherwise, a contribution you submit is under the same license (section 5 of the license). There is no CLA.
````

- [ ] **Step 2: Create `SECURITY.md`:**

```markdown
# Security policy

## Supported versions

Appstein is pre-alpha and not released yet. Only the `main` branch gets fixes.

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately:

- **Preferred:** GitHub's private reporting. Open the repository's **Security** tab and choose **Report a vulnerability**.
- **Or email** the.uttam.vaghasia@gmail.com.

Say what you found, how to reproduce it, and what an attacker could do with it. Appstein is a one-person project, so a reply may take a few days. You'll hear back before anything about the problem is made public.

## Scope

Appstein runs locally, inside your own agent sessions: the `appstein` CLI, its git and agent hooks, and the files it writes into your project. In scope, for example: a command or hook that runs code it shouldn't, writes outside the project, or sends data anywhere. Appstein never handles agent credentials, so any way it could read or expose them is in scope too.
```

- [ ] **Step 3: Create `.github/ISSUE_TEMPLATE/bug_report.yml`:**

```yaml
name: Bug report
description: Something in Appstein doesn't work as described.
labels: [bug]
body:
  - type: markdown
    attributes:
      value: Thanks for the report. For a security problem, don't use this form; see SECURITY.md.
  - type: textarea
    id: what
    attributes:
      label: What happened, and what did you expect?
    validations:
      required: true
  - type: textarea
    id: steps
    attributes:
      label: Steps to reproduce
      placeholder: |
        1. appstein sync
        2. …
    validations:
      required: true
  - type: dropdown
    id: os
    attributes:
      label: Operating system
      options:
        - Windows
        - macOS
        - Linux
    validations:
      required: true
  - type: input
    id: flutter
    attributes:
      label: Flutter version
      placeholder: "3.47.5"
  - type: textarea
    id: doctor
    attributes:
      label: Output of appstein doctor
      render: text
```

- [ ] **Step 4: Create `.github/pull_request_template.md`:**

```markdown
## What and why

<!-- What does this change, and why? Link the issue if there is one. -->

## Checks

- [ ] Tests added or updated, and passing (`fvm dart test test`, and `fvm dart test` in each changed package)
- [ ] `fvm dart format .` and `fvm dart analyze --fatal-infos` are clean
- [ ] The `docs/guide/` pages covering the changed files are updated, or a commit has a `Docs-Checked: <page>.md - <reason>` trailer
- [ ] `fvm dart run tool/check_guide.dart --since main` passes
```

- [ ] **Step 5: Link CONTRIBUTING from the guide.** In `docs/guide/README.md`, after the first paragraph (the one ending "…links to the spec instead of repeating it."), add:

```markdown
Contributing from outside? Read [CONTRIBUTING.md](../../CONTRIBUTING.md) first.
```

- [ ] **Step 6: Verify.** Parse the issue template with graphify's Python, which has PyYAML: `"$(cat graphify-out/.graphify_python)" -c "import yaml,sys; yaml.safe_load(open(sys.argv[1], encoding='utf-8'))" .github/ISSUE_TEMPLATE/bug_report.yml`. Expected: no error. Run `fvm dart run tool/check_guide.dart --since main`: it passes, and its link check resolves the new relative link.

- [ ] **Step 7: Commit.** Staged: the four new files, `docs/guide/README.md`. Message: `docs: CONTRIBUTING, SECURITY, bug-report and PR templates`.

---

### Task 6: Old commit IDs and old PR numbers in the plans

The history rewrite changed every commit ID, but only commit messages were rewritten. The plans still cite 24 pre-rewrite IDs, and some name pull requests of the old repo. One rules file fixes both. The same file then moves the graph cache entries of these plans (Task 8), so no LLM is needed for them.

**Files:**
- Modify: the 8 plans that cite old IDs (1a.1, 1a.3, 1a.4, 1b.3, 1b.4, 1b.5, 1b.6, 1b.7), plus 1a and 1b.2 for PR prose only: 10 files in all.
- Scratch (not committed): `<scratchpad>/1a5-rules.txt`, `<scratchpad>/apply_rules.py`.

- [ ] **Step 1: Write the rules file** `<scratchpad>/1a5-rules.txt`, one `old==>new` literal rule per line (the format `rekey_cache.py` reads):

```text
b7fa659==>071d63e
bf2c821==>2e20b29
5dd1d42==>a52fc1a
3edf141==>d54ba6f
cf9d208==>1ef2508
3e123a5==>81ce50e
e43726c==>b511c72
5353e1c==>778fa6f
33dac2b==>2042334
de2e4bb==>877d51b
6bd7a05==>b386f8c
00e1069==>8ed222e
f942d06==>7d0395f
e1fab90==>9351601
b059596==>2bef7c5
0787ad0==>f579e3a
e7a96a6==>8851500
7f5483c==>0a20ad2
e470228==>e98afed
c6a3e51==>cd23d0b
fd5756f==>7c6a1de
da2c5f2==>48f9285
so CI ran through draft PR #1 (==>so CI ran through draft PR #1 in the old private repo (
merging PR #4 with==>merging PR #4 (in the old private repo) with
the same way as PR #4 (==>the same way as PR #4 in the old private repo (
on 2026-10-01, with PR #7.==>on 2026-10-01, with PR #7 in the old private repo.
on 2026-10-01, with PR #8.==>on 2026-10-01, with PR #8 in the old private repo.
scoped re-review. PR #9.==>scoped re-review. PR #9 in the old private repo.
ruled round (below). PR #10.==>ruled round (below). PR #10 in the old private repo.
BOM byte gate. PR #11.==>BOM byte gate. PR #11 in the old private repo.
```

- [ ] **Step 2: Re-derive the ID rules.** Run `python <scratchpad>/find_old_ids.py .` (it reads `.git/filter-repo/commit-map`). It must list exactly the 22 distinct IDs above (24 citations), with the same new IDs and none marked AMBIGUOUS. If it differs, fix the rules file first.

- [ ] **Step 3: Write `<scratchpad>/apply_rules.py`:**

```python
"""Applies literal old==>new rules to files, in rule order, and reports
each rule that matched nothing. Usage: apply_rules.py <rules> <file>..."""
import sys
from pathlib import Path

rules = [
    line.split("==>", 1)
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line
]
used = set()
for name in sys.argv[2:]:
    path = Path(name)
    text = path.read_text(encoding="utf-8")
    new = text
    for old, replacement in rules:
        if old in new:
            used.add(old)
            new = new.replace(old, replacement)
    if new != text:
        path.write_bytes(new.encode("utf-8"))
        print(f"changed {name}")
for old, _ in rules:
    if old not in used:
        print(f"UNUSED rule: {old}")
```

- [ ] **Step 4: Apply it** to every plan except 1a.5's: `python <scratchpad>/apply_rules.py <scratchpad>/1a5-rules.txt $(ls docs/superpowers/plans/*.md | grep -v slice-1a5)`. Expected: 10 files changed and no UNUSED rule.

- [ ] **Step 5: Check.** `python <scratchpad>/find_old_ids.py .` reports only this plan, whose rules list in Step 1 cites the old IDs on purpose. `git diff --stat` shows only the 10 plans. `git diff` shows only the intended replacements (read it all). Run `fvm dart run tool/check_guide.dart --since main`. Expected: passes.

- [ ] **Step 6: Commit.** Staged: the 10 plans. Message: `docs(plans): cite the rewritten commit IDs; mark old-repo PR numbers`.

---

### Task 7: GitHub settings (needs the owner's go-ahead at this step)

Both change the public GitHub repo, so ask the owner first, quoting the commands.

- [ ] **Step 1: Turn on private vulnerability reporting,** so SECURITY.md's preferred route works: `gh api -X PUT repos/UTTAM-VAGHASIA/appstein/private-vulnerability-reporting`. Verify: `gh api repos/UTTAM-VAGHASIA/appstein/private-vulnerability-reporting` prints `{"enabled":true}`.

- [ ] **Step 2: Add topics:** `gh repo edit UTTAM-VAGHASIA/appstein --add-topic flutter --add-topic dart --add-topic ai-agents --add-topic mcp --add-topic claude-code --add-topic codex --add-topic cli`. Verify with `gh repo view UTTAM-VAGHASIA/appstein --json repositoryTopics`.

- [ ] **Step 3: After the merge (Task 8),** check that GitHub detects the license: `gh api repos/UTTAM-VAGHASIA/appstein --jq .license.spdx_id` prints `Apache-2.0`.

---

### Task 8: Verify, graph, pull request, finish

- [ ] **Step 1: Full verification.** Run the BOM gate, `fvm dart format --output=none --set-exit-if-changed .`, `fvm dart analyze --fatal-infos`, `fvm dart test test`, then `fvm dart test` in each of `packages/appstein_protocol`, `appstein_lints`, `appstein_cli` and `appstein_engine`. Then run `fvm dart run tool/gen_docs.dart` and `fvm dart run tool/check_guide.dart --since main`. Record each count. Everything must pass.

- [ ] **Step 2: Graph update.** Follow the memory runbook (graph update runbook):
  - Move the 10 rule-changed plans' cache entries with `rekey_cache.py <repo> .git main <scratchpad>/1a5-rules.txt <extraction spec> <plans…>`. The old content is the plans at `main`. Expect "moved" for each.
  - Then `/graphify . --update` extracts only the docs whose meaning changed (spec md and html, progress.yaml, README, PRODUCT, CONTRIBUTING, SECURITY, NOTICE if detected, docs-tooling.md, guide README, this plan), with at most 3 subagents.
  - Run prep before the subagents write chunks.
  - Repeat until `tool/check_graph.py` prints nothing.

- [ ] **Step 3: Push and open the pull request** (owner's go-ahead): `git push -u origin slice-1a5`, then `gh pr create` with a body summarizing the slice and ending with the Claude Code attribution and session link.

- [ ] **Step 4: Record the result** (one commit after the PR opens):
  - this plan's `## Notes from execution`;
  - `progress.yaml`: 1a.5 `done` with `pr` and `finished`, and 1b.8 `next`;
  - `gen_docs`, then read the page back;
  - the guide check, then the graph again until silent. Push.

- [ ] **Step 5: Merge** once every CI job has really run and passed (the PR merge flow): `gh pr merge <n> --merge --delete-branch`, `git fetch --prune`, `git switch -C main origin/main`. Then Task 7 Step 3.

- [ ] **Step 6: Memory.** Update the memory notes that cite old commit IDs or old PR numbers, using `.git/filter-repo/commit-map`, and record 1a.5 as done.

## Notes from execution

Built inline (the owner chose native execution) on 2026-10-03, on branch `slice-1a5`, with one final whole-branch review on Opus. PR #2.

| Commit | What |
|---|---|
| `a5a8a58` | Spec: Apache-2.0, the published-release wording (§1.1, §19.5, §20, §22); 1a.5 is next |
| `7a660fc` | This plan |
| `a15b2d6` | Task 1: the `merge` field is parsed |
| `cc02ac1` | Task 2: the page links merge commits; `checkMerges`; docs-tooling |
| `13359e5` | Task 3: the old slices give their merge commits; 1b.7 is PR #1 |
| `4fa8ffd` | Task 4: LICENSE, NOTICE, README, PRODUCT.md |
| `d707b48` | Task 5: CONTRIBUTING, SECURITY, the bug-report and PR templates |
| `1aa5cab` | Task 6: the old commit IDs and old PR numbers in 10 plans |
| `37060ca` | Final-review fixes |
| `1d617c6` | Spec §19.6: merge commits (owner-approved after the review) |

**Rulings during execution:**
- **LICENSE** was downloaded to the scratchpad and checked before it was copied in. It is apache.org's text. GitHub's template differs only by one blank line (leading instead of trailing).
- **The issue template** was parsed with `package:yaml`, through `fvm dart --packages=.dart_tool/package_config.json`, since graphify's Python has no PyYAML.
- **`checkMerges`** is called in a cascade with `checkProgress`.

**The final review** found no critical issues and two important ones. Both are fixed:
- **Spec §19.6 didn't mention merge commits.** The plan wrongly said `a5a8a58` had covered it. The owner approved the wording.
- **Four Flutter SDK files (BSD-3-Clause), copied as test fixtures, shipped without Flutter's license.** It now sits in `packages/appstein_engine/test/fixtures/flutter_sdk/LICENSE`, and NOTICE names it.

Four of its minor findings were fixed too, because they were wrong or missing statements in files this slice created:
- what `install_hooks` skips without graphify;
- two CI steps missing from CONTRIBUTING's checks;
- the bug template assumed a released binary;
- when to quote a commit ID.

**Deferred:**
- **An ambiguous short `merge` ID** gets "is not a commit in this repo". Better: "not a single commit (mistyped, ambiguous or missing from a shallow clone)", with a test for the ambiguous case.
- **A slice without a status can still carry `pr`, `merge` or `finished`.** This predates the slice for `pr`. Refuse those keys when there is no status.

**GitHub settings** (owner's yes): private vulnerability reporting is enabled, and the topics are `flutter`, `dart`, `ai-agents`, `mcp`, `claude-code`, `codex` and `cli`.

**The graph:** no LLM was needed for 14 of the 22 changed docs.
- The 10 rule-changed plans' cache entries were moved with the same rules file (`rekey_cache.py`).
- The spec, the visual page, docs-tooling and the guide's start page had small edits. Their old entries were carried over, stale labels were patched (such as "PR #8" becoming "merged in 31fd665"), and a few hand-written nodes were added for the new facts.
- Only the 8 new or rewritten docs were extracted.

**Verification (1aa5cab, then again after the fixes):**
- **Checks:** the BOM scan, format and `analyze --fatal-infos` are clean; dependency_validator and `dart doc --dry-run` are clean.
- **Tests:** tooling 225, protocol 57, lints 19, CLI 44, engine 736 (6 skipped).
- **Docs:** `gen_docs` is up to date, and the guide check passes.
