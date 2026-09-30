# Slice 1a.4: Project Progress on the Visual Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record where every milestone and slice stands in `docs/superpowers/progress.yaml`, render it into the spec's visual page as a status pill and a progress section, and make the guide check fail whenever the page, the plans or spec §18 disagree with it.

**Architecture:** Three new tool files: `progress.dart` reads and validates the YAML into a small model; `progress_check.dart` compares it with the plans folder and spec §18; `progress_html.dart` renders two generated sections as static HTML. The existing generated-sections machinery (`regenerate`) writes them into the visual page between `<!-- generated:… -->` markers, `gen_docs` rewrites them, and `check_guide` (CI's `docs` job and the post-commit hook) reports every disagreement. The page's CSS is hand-written once; only the markup is generated.

**Tech Stack:** Dart 3.12+ via FVM (`fvm dart`), `package:yaml`, `package:path`, `package:test`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-29-appstein-design.md` (§18 milestones, §19.3 CI, §19.4 per-slice process, §19.6 documentation). The spec wording below was approved by the owner on 2026-10-01.

## Global Constraints

- Run every Dart command through FVM: `fvm dart …`. The `dart` on your PATH may be an older SDK.
- Windows is first-class: paths with spaces, drive letters, CRLF files in the working tree. Tests use `tempFolder()` (its path has a space and a non-ASCII character).
- The repo stores text with LF (`.gitattributes`: `* text=auto eol=lf`). Generated output must be byte-identical on every OS: no dates from the clock, no map iteration that isn't ordered, sorted file listings.
- Every public declaration in `tool/` has a `///` doc comment (the repo's style; `public_member_api_docs` applies to the packages and we keep the tools to the same standard).
- `dart format` clean, `fvm dart analyze` clean, for every file touched.
- Subagents never commit, never write to the real `graphify-out/` or `.git/hooks`, and never use `python -` stdin heredocs as probes.
- Use the Read/Edit/Write/Grep/Glob tools for files; the shell is for running commands.
- Never write guide text for code that doesn't exist yet: the guide page is updated in Task 5, after the code exists.
- Until Task 5 adds `docs/superpowers/progress.yaml`, `fvm dart run tool/check_guide.dart` on this branch reports it missing, and the post-commit hook warns about it. That is expected in Tasks 1–4.

### Approved spec wording (applied in Task 5, verbatim)

**§19.3**, the `docs` row of the CI table, becomes:

```text
| `docs` | `dart doc` for every package, failing on warnings; developer guide checks (§19.6): snippet analysis, link check, every file path it mentions exists, every source file covered by a page, no stale pages, generated sections up to date, and the progress record consistent with the plans and §18 |
```

**§19.4**, the per-slice bullet, becomes:

```text
- **Per slice:** spec → implementation plan → TDD implementation → verify → docs (API doc comments, the guide pages for what the slice built, the slice's entry in `docs/superpowers/progress.yaml` marked done, with its pull request number once the PR is open, `gen_docs` and the guide check (§19.6), then `/graphify . --update` until the graph warning is silent) → owner review → commit. The warning must still be silent when a slice merges, because edits made after the update put the graph behind again.
```

**§19.6**, a new bullet directly after the bullet that starts "**Facts the code already knows are generated, not typed.**":

```text
- **Progress is data, not prose.** `docs/superpowers/progress.yaml` records every milestone and slice: its status (done, next or planned), its plan, its pull request, the date it finished and what it delivered. `gen_docs` renders it into the spec's visual page as a status line at the top and a progress section with the milestone rail and the slice timeline. The guide check fails when:
  - the page doesn't match the file;
  - a plan in `docs/superpowers/plans/` belongs to no slice;
  - a plan with notes from execution belongs to a slice that isn't done;
  - a done slice has no plan or pull request;
  - a §18 slice is missing;
  - more than one slice is next.
```

## Review Focus

1. **The visual page checked out with CRLF** (a Windows clone without `.gitattributes` applied, or an editor that rewrote it): regenerating must keep CRLF and a second run must report nothing. Test in Task 4 (`regenerateVisualPage keeps CRLF`).
2. **HTML-special characters in `progress.yaml`** (`<`, `>`, `&`, `"` in a title or summary, e.g. "`List<String>`"): the page must show them as text, never as markup. Test in Task 3 (`escapes HTML in titles and summaries`).
3. **`progress.yaml` saved with a UTF-8 byte order mark** by a Windows editor: it must parse the same as without. Test in Task 1 (`a byte order mark is ignored`).
4. **Files in `docs/superpowers/plans/` that aren't plans** (a `.DS_Store`, a folder, a `.txt` note): the plan check must ignore everything that isn't a `.md` file directly in the folder. Test in Task 2 (`ignores files that are not plans`).
5. **The spec checked out with CRLF**: §18 must still be found and parsed. Test in Task 2 (`reads §18 with CRLF line endings`).

---

## File Structure

| File | Responsibility |
|---|---|
| Create `tool/src/progress.dart` | The model (`Progress`, `Milestone`, `Slice`, `SliceStatus`, `Stage`), `readProgress` and `parseProgress` with every structural rule |
| Create `tool/src/progress_check.dart` | `checkProgress`: plans folder and spec §18 against the model; `specMilestones` parses §18 |
| Create `tool/src/progress_html.dart` | `renderProgressSections`: the `progress-status` and `progress` HTML bodies |
| Modify `tool/src/generated_sections.dart` | `regenerate` gains `guideLinks` so a page outside `docs/guide/` may hold sections |
| Modify `tool/src/generated_docs.dart` | `visualPage` and `regenerateVisualPage` |
| Modify `tool/gen_docs.dart` | Also regenerates the visual page |
| Modify `tool/src/guide_check.dart` | Also reads, checks and compares progress |
| Create `test/progress_test.dart`, `test/progress_check_test.dart`, `test/progress_html_test.dart` | Unit tests |
| Modify `test/generated_sections_test.dart`, `test/generated_docs_test.dart`, `test/guide_check_test.dart` | Tests for the wiring |
| Create `docs/superpowers/progress.yaml` | The record |
| Modify `docs/superpowers/specs/2026-09-29-appstein-design.html` | CSS, nav link, hero markers, the Progress section |
| Modify `docs/superpowers/specs/2026-09-29-appstein-design.md` | §19.3, §19.4, §19.6 (approved wording above) |
| Modify `docs/guide/docs-tooling.md`, `AGENTS.md` | Docs |

---

### Task 1: The progress model and parser

**Files:**
- Create: `tool/src/progress.dart`
- Test: `test/progress_test.dart`

**Interfaces:**
- Consumes: `GuideProblem(String file, int? line, String message)` from `tool/src/guide_checker.dart`.
- Produces (used by Tasks 2–4):
  - `const progressFile = 'docs/superpowers/progress.yaml';`
  - `enum SliceStatus { done, next, planned }`
  - `enum Stage { done, underway, planned }`
  - `Stage stageOf(Iterable<Slice> parts)`
  - `final class Slice` with `id`, `title`, `summary`, `line`, `status` (`SliceStatus?`), `plan` (`String?`), `pr` (`int?`), `finished` (`String?`), `tooling` (`bool`), `slices` (`List<Slice>`), and getters `parts`, `productParts`, `stage`.
  - `final class Milestone` with `id`, `title`, `summary`, `line`, `slices`, getter `stage`.
  - `final class Progress` with `repository`, `milestones`, getters `allSlices` and `next`.
  - `final class ProgressRead` with `progress` (`Progress?`) and `problems` (`List<GuideProblem>`).
  - `ProgressRead readProgress(String repoRoot)`
  - `ProgressRead parseProgress(String text)`

- [ ] **Step 1: Write the failing tests**

Create `test/progress_test.dart`:

```dart
import 'package:test/test.dart';

import '../tool/src/progress.dart';
import 'support/temp_repo.dart';

const _valid = '''
repository: https://github.com/owner/repo
milestones:
  - id: M1
    title: Foundation
    summary: The first milestone.
    slices:
      - id: 1a
        title: Workspace
        summary: The workspace.
        status: done
        plan: 2026-09-29-slice-1a.md
        pr: 1
        finished: 2026-09-30
        slices:
          - id: 1a.1
            title: Guide tooling
            summary: Keeps the guide current.
            status: done
            tooling: true
            plan: 2026-09-30-slice-1a1.md
            pr: 2
            finished: 2026-09-30
      - id: 1b
        title: Knowledge
        summary: The knowledge layers.
        slices:
          - id: 1b.1
            title: SDK gaps
            summary: Doctor agrees with Flutter.
            status: done
            plan: 2026-09-30-slice-1b1.md
            pr: 4
            finished: 2026-10-01
          - id: 1b.2
            title: Store
            summary: The `.appstein/` store.
            status: next
          - id: 1b.3
            title: Map
            summary: The project map.
            status: planned
  - id: M2
    title: Pipeline
    summary: The second milestone.
''';

List<String> problemsOf(String text) =>
    [for (final problem in parseProgress(text).problems) '$problem'];

void main() {
  group('a valid file', () {
    late Progress progress;

    setUp(() {
      final read = parseProgress(_valid);
      expect(read.problems, isEmpty);
      progress = read.progress!;
    });

    test('keeps the repository, milestones and slices in file order', () {
      expect(progress.repository, 'https://github.com/owner/repo');
      expect(progress.milestones.map((m) => m.id), ['M1', 'M2']);
      expect(progress.milestones.first.slices.map((s) => s.id), ['1a', '1b']);
      expect(progress.allSlices.map((s) => s.id), [
        '1a',
        '1a.1',
        '1b',
        '1b.1',
        '1b.2',
        '1b.3',
      ]);
    });

    test('reads every field of a done slice', () {
      final slice = progress.allSlices.firstWhere((s) => s.id == '1a.1');
      expect(slice.title, 'Guide tooling');
      expect(slice.summary, 'Keeps the guide current.');
      expect(slice.status, SliceStatus.done);
      expect(slice.plan, '2026-09-30-slice-1a1.md');
      expect(slice.pr, 2);
      expect(slice.finished, '2026-09-30');
      expect(slice.tooling, isTrue);
      expect(slice.line, 15);
    });

    test('finds the next slice', () {
      expect(progress.next?.id, '1b.2');
    });

    test('works out stages from the parts', () {
      final m1 = progress.milestones.first;
      expect(m1.slices[0].stage, Stage.done);
      expect(m1.slices[1].stage, Stage.underway);
      expect(m1.stage, Stage.underway);
      expect(progress.milestones[1].stage, Stage.planned);
    });

    test('leaves tooling out of the product parts', () {
      final m1 = progress.milestones.first;
      expect(m1.slices[0].productParts.map((s) => s.id), ['1a']);
      expect(m1.slices[1].productParts.map((s) => s.id), [
        '1b.1',
        '1b.2',
        '1b.3',
      ]);
    });
  });

  test('a slice made only of tooling counts its tooling parts', () {
    const slice = Slice(
      id: '1z',
      title: 't',
      summary: 's',
      line: 1,
      slices: [
        Slice(
          id: '1z.1',
          title: 't',
          summary: 's',
          line: 2,
          status: SliceStatus.planned,
          tooling: true,
        ),
      ],
    );
    expect(slice.productParts.map((s) => s.id), ['1z.1']);
    expect(slice.stage, Stage.planned);
  });

  // Review Focus 3.
  test('a byte order mark is ignored', () {
    final read = parseProgress('﻿$_valid');
    expect(read.problems, isEmpty);
    expect(read.progress!.milestones, hasLength(2));
  });

  test('invalid YAML is one problem with its line', () {
    expect(problemsOf('repository: x\nmilestones: [\n'), [
      matches(
        RegExp(r'^docs/superpowers/progress\.yaml:\d+: Not valid YAML: '),
      ),
    ]);
  });

  test('an empty file is a problem', () {
    expect(problemsOf(''), [
      'docs/superpowers/progress.yaml:1: The file must be a map.',
    ]);
  });

  test('a repository that is not an https address is a problem', () {
    expect(
      problemsOf(
        _valid.replaceFirst(
          'https://github.com/owner/repo',
          'https://github.com/owner/repo/',
        ),
      ),
      [
        'docs/superpowers/progress.yaml:1: repository must be an https:// '
            'address without a trailing slash, such as '
            'https://github.com/owner/repo.',
      ],
    );
  });

  test('an unknown key is a problem, naming the known ones', () {
    expect(
      problemsOf(
        _valid.replaceFirst(
          '    title: Pipeline',
          '    titel: x\n    title: Pipeline',
        ),
      ),
      [
        'docs/superpowers/progress.yaml:43: Milestone M2 has an unknown key: '
            'titel. Known: id, slices, summary, title.',
      ],
    );
  });

  test('a done slice needs its plan, pr and finished date', () {
    const text = '''
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
''';
    expect(problemsOf(text), [
      'docs/superpowers/progress.yaml:7: Slice 1a is done, so it needs plan, '
          'pr and finished.',
    ]);
  });

  test('pr and finished are only for a done slice', () {
    expect(
      problemsOf(
        _valid.replaceFirst(
          '            status: next\n',
          '            status: next\n            pr: 9\n',
        ),
      ),
      [
        'docs/superpowers/progress.yaml:38: Slice 1b.2: pr is only for a '
            'done slice.',
      ],
    );
  });

  test('a slice needs a status or sub-slices', () {
    expect(
      problemsOf(_valid.replaceFirst('            status: planned\n', '')),
      [
        'docs/superpowers/progress.yaml:38: Slice 1b.3 needs a status (done, '
            'next or planned), or sub-slices.',
      ],
    );
  });

  test('an unknown status is a problem', () {
    expect(
      problemsOf(_valid.replaceFirst('status: planned', 'status: later')),
      [
        'docs/superpowers/progress.yaml:41: Slice 1b.3: status must be done, '
            'next or planned, not later.',
      ],
    );
  });

  test('more than one next slice is a problem', () {
    expect(
      problemsOf(_valid.replaceFirst('status: planned', 'status: next')),
      [
        'docs/superpowers/progress.yaml:38: More than one slice is next '
            '(1b.2, 1b.3). Only one slice can be next.',
      ],
    );
  });

  test('a sub-slice id must start with its parent id', () {
    expect(problemsOf(_valid.replaceFirst('id: 1b.3', 'id: 1c.3')), [
      'docs/superpowers/progress.yaml:38: Slice 1c.3: a sub-slice of 1b '
          'needs an id starting with 1b.',
    ]);
  });

  test('a duplicate id is a problem', () {
    expect(problemsOf(_valid.replaceFirst('id: 1b.3', 'id: 1b.2')), [
      'docs/superpowers/progress.yaml:38: 1b.2 is used twice (first on line '
          '34). IDs must be unique.',
    ]);
  });

  test('a date that does not exist is a problem', () {
    expect(
      problemsOf(
        _valid.replaceFirst('finished: 2026-10-01', 'finished: 2026-02-30'),
      ),
      [
        'docs/superpowers/progress.yaml:33: Slice 1b.1: finished must be a '
            'date like 2026-10-01, not 2026-02-30.',
      ],
    );
  });

  test('a pr that is not a positive whole number is a problem', () {
    expect(problemsOf(_valid.replaceFirst('pr: 4', 'pr: four')), [
      'docs/superpowers/progress.yaml:32: Slice 1b.1: pr must be a whole '
          'number above 0.',
    ]);
  });

  test('a plan must be a file name ending in .md', () {
    expect(
      problemsOf(
        _valid.replaceFirst(
          'plan: 2026-09-30-slice-1b1.md',
          'plan: plans/2026-09-30-slice-1b1.md',
        ),
      ),
      [
        'docs/superpowers/progress.yaml:31: Slice 1b.1: plan must be a file '
            'name in docs/superpowers/plans/, such as '
            '2026-09-29-slice-1a-workspace-cli-doctor.md.',
      ],
    );
  });

  group('readProgress', () {
    test('a missing file is a problem', () {
      final repo = tempFolder();
      expect(readProgress(repo.path).problems.map((x) => '$x'), [
        'docs/superpowers/progress.yaml: Missing. It records where each '
            'milestone and slice stands (spec §19.6).',
      ]);
    });

    test('reads the file in the repo', () {
      final repo = tempFolder();
      writeFile(repo, 'docs/superpowers/progress.yaml', _valid);
      final read = readProgress(repo.path);
      expect(read.problems, isEmpty);
      expect(read.progress!.next?.id, '1b.2');
    });
  });
}
```

Line numbers in the expected messages count from line 1 of `_valid` (the line `repository: …`): `1a.1`'s entry starts on line 15, `1b.1`'s on 27 (its `plan` on 31, `pr` on 32, `finished` on 33), `1b.2`'s on 34 (`status` on 37), `1b.3`'s on 38 (`status` on 41), and `M2`'s `title` on 43. The rule is "the 1-based line of the node the problem is about": the value node for a field problem, the entry's map (its first key) for a whole-entry problem, the `id` value for an id problem, the key itself for an unknown key. If an expectation disagrees with a careful recount, fix the expectation, not the rule.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fvm dart test test/progress_test.dart`
Expected: FAIL, because `tool/src/progress.dart` doesn't exist.

- [ ] **Step 3: Write the implementation**

Create `tool/src/progress.dart`:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'guide_checker.dart';

/// Where Appstein's progress is recorded, relative to the repo root
/// (spec §19.6).
const progressFile = 'docs/superpowers/progress.yaml';

/// Where a slice stands, as `progress.yaml` records it.
enum SliceStatus {
  /// Finished and merged into `main`.
  done,

  /// Being built, or the one to build next. At most one slice is next.
  next,

  /// Not started.
  planned,
}

/// How far a slice or milestone has got, counting its parts.
enum Stage {
  /// Every part is done.
  done,

  /// Some parts are done, and some aren't.
  underway,

  /// No part is done.
  planned,
}

/// The [Stage] of [parts]: done when every part is done, planned when none
/// is (or there are none), else underway.
Stage stageOf(Iterable<Slice> parts) {
  final all = parts.toList();
  final done = all.where((part) => part.status == SliceStatus.done).length;
  if (all.isNotEmpty && done == all.length) return Stage.done;
  return done == 0 ? Stage.planned : Stage.underway;
}

/// A slice of a milestone, or a sub-slice of a slice.
final class Slice {
  /// Creates a slice.
  const Slice({
    required this.id,
    required this.title,
    required this.summary,
    required this.line,
    this.status,
    this.plan,
    this.pr,
    this.finished,
    this.tooling = false,
    this.slices = const [],
  });

  /// The slice's ID, such as `1b` or `1b.2`.
  final String id;

  /// A short name.
  final String title;

  /// What the slice delivered, or will deliver. Text in backticks is shown
  /// as code.
  final String summary;

  /// The 1-based line of the slice's entry in `progress.yaml`.
  final int line;

  /// The slice's own status, or null for a slice that is only the sum of
  /// its [slices].
  final SliceStatus? status;

  /// The file name of the slice's plan in `docs/superpowers/plans/`.
  final String? plan;

  /// The number of the pull request that merged it.
  final int? pr;

  /// The day it was marked done, as `YYYY-MM-DD`.
  final String? finished;

  /// Whether it builds tooling for Appstein's own repo rather than the
  /// product.
  final bool tooling;

  /// Its sub-slices, in order.
  final List<Slice> slices;

  /// This slice, if it has a status of its own, and every such sub-slice
  /// below it, depth first.
  Iterable<Slice> get parts sync* {
    if (status != null) yield this;
    for (final slice in slices) {
      yield* slice.parts;
    }
  }

  /// The [parts] that build the product, or every part when all of them
  /// are tooling. A slice's progress bar counts these, so tooling doesn't
  /// make the product look further along.
  List<Slice> get productParts {
    final all = parts.toList();
    final product = all.where((part) => !part.tooling).toList();
    return product.isEmpty ? all : product;
  }

  /// How far the slice has got, counting every part.
  Stage get stage => stageOf(parts);
}

/// A milestone of the roadmap (spec §18).
final class Milestone {
  /// Creates a milestone.
  const Milestone({
    required this.id,
    required this.title,
    required this.summary,
    required this.line,
    this.slices = const [],
  });

  /// The milestone's ID, such as `M1`.
  final String id;

  /// A short name.
  final String title;

  /// What the milestone delivers, in a sentence.
  final String summary;

  /// The 1-based line of the milestone's entry in `progress.yaml`.
  final int line;

  /// Its slices, in order. Empty until the milestone has its own spec.
  final List<Slice> slices;

  /// How far the milestone has got, counting every part of every slice.
  Stage get stage => stageOf([for (final slice in slices) ...slice.parts]);
}

/// Everything `progress.yaml` records.
final class Progress {
  /// Creates the record.
  const Progress({required this.repository, required this.milestones});

  /// The repository's web address, without a trailing slash. A pull request
  /// links to `<repository>/pull/<number>`.
  final String repository;

  /// The milestones, in order.
  final List<Milestone> milestones;

  /// Every slice and sub-slice, depth first, in file order.
  Iterable<Slice> get allSlices sync* {
    for (final milestone in milestones) {
      for (final slice in milestone.slices) {
        yield* _walk(slice);
      }
    }
  }

  /// The slice marked next, if any.
  Slice? get next => allSlices
      .where((slice) => slice.status == SliceStatus.next)
      .firstOrNull;
}

Iterable<Slice> _walk(Slice slice) sync* {
  yield slice;
  for (final child in slice.slices) {
    yield* _walk(child);
  }
}

/// `progress.yaml` as read, and what is wrong with it.
final class ProgressRead {
  /// Creates the result.
  const ProgressRead(this.progress, this.problems);

  /// The record, or null when there are [problems].
  final Progress? progress;

  /// Everything wrong with the file, each with its line where it has one.
  final List<GuideProblem> problems;
}

/// Reads [progressFile] in [repoRoot]. A missing or unreadable file is a
/// problem.
ProgressRead readProgress(String repoRoot) {
  final file = File(p.join(repoRoot, progressFile));
  final String text;
  try {
    text = file.readAsStringSync();
  } on FileSystemException catch (error) {
    final message = file.existsSync()
        ? "Can't be read: ${error.osError?.message ?? error.message}."
        : 'Missing. It records where each milestone and slice stands '
              '(spec §19.6).';
    return ProgressRead(null, [GuideProblem(progressFile, null, message)]);
  }
  return parseProgress(text);
}

/// Parses the text of `progress.yaml` and checks every rule the file can
/// check on its own. A leading byte order mark is ignored. Every problem is
/// reported; the record is null when there is any.
ProgressRead parseProgress(String text) {
  final YamlNode root;
  try {
    root = loadYamlNode(text.startsWith('﻿') ? text.substring(1) : text);
  } on YamlException catch (error) {
    final span = error.span;
    return ProgressRead(null, [
      GuideProblem(
        progressFile,
        span == null ? null : span.start.line + 1,
        'Not valid YAML: ${error.message}',
      ),
    ]);
  }
  final parser = _Parser();
  final progress = parser.progress(root);
  return parser.problems.isEmpty
      ? ProgressRead(progress, const [])
      : ProgressRead(null, parser.problems);
}

final _milestoneId = RegExp(r'^M[1-9][0-9]*$');
final _sliceId = RegExp(r'^[0-9]+[a-z]+(\.[0-9]+)*$');
final _day = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

const _fileKeys = {'repository', 'milestones'};
const _milestoneKeys = {'id', 'title', 'summary', 'slices'};
const _sliceKeys = {
  'id',
  'title',
  'summary',
  'status',
  'plan',
  'pr',
  'finished',
  'tooling',
  'slices',
};

/// Reads the YAML tree into the model, collecting every problem.
final class _Parser {
  final problems = <GuideProblem>[];
  final _ids = <String, int>{};

  void _problem(YamlNode node, String message) => problems.add(
    GuideProblem(progressFile, node.span.start.line + 1, message),
  );

  Progress? progress(YamlNode root) {
    final map = _map(root, 'The file');
    if (map == null) return null;
    _keys(map, 'The file', _fileKeys);
    final repository = _string(map, 'repository', 'The file');
    if (repository != null &&
        (!repository.startsWith('https://') || repository.endsWith('/'))) {
      _problem(
        map.nodes['repository']!,
        'repository must be an https:// address without a trailing slash, '
        'such as https://github.com/owner/repo.',
      );
    }
    final milestones = <Milestone>[
      for (final node in _list(map, 'milestones', 'The file', required: true))
        ?_milestone(node),
    ];
    final progress = Progress(
      repository: repository ?? '',
      milestones: milestones,
    );
    final next = [
      for (final slice in progress.allSlices)
        if (slice.status == SliceStatus.next) slice,
    ];
    if (next.length > 1) {
      problems.add(
        GuideProblem(
          progressFile,
          next[1].line,
          'More than one slice is next '
          '(${next.map((slice) => slice.id).join(', ')}). Only one slice can '
          'be next.',
        ),
      );
    }
    return progress;
  }

  Milestone? _milestone(YamlNode node) {
    final map = _map(node, 'A milestone');
    if (map == null) return null;
    final id = _string(map, 'id', 'A milestone');
    final what = id == null ? 'A milestone' : 'Milestone $id';
    _keys(map, what, _milestoneKeys);
    if (id != null) {
      final idNode = map.nodes['id']!;
      if (!_milestoneId.hasMatch(id)) {
        _problem(idNode, '$what: id must look like M1.');
      }
      _unique(id, idNode);
    }
    final title = _string(map, 'title', what);
    final summary = _string(map, 'summary', what);
    final slices = <Slice>[
      for (final child in _list(map, 'slices', what))
        ?_slice(child, parent: null),
    ];
    if (id == null || title == null || summary == null) return null;
    return Milestone(
      id: id,
      title: title,
      summary: summary,
      line: node.span.start.line + 1,
      slices: slices,
    );
  }

  Slice? _slice(YamlNode node, {required String? parent}) {
    final map = _map(node, 'A slice');
    if (map == null) return null;
    final id = _string(map, 'id', 'A slice');
    final what = id == null ? 'A slice' : 'Slice $id';
    _keys(map, what, _sliceKeys);
    if (id != null) {
      final idNode = map.nodes['id']!;
      if (!_sliceId.hasMatch(id)) {
        _problem(idNode, '$what: id must look like 1a or 1a.1.');
      } else if (parent != null && !id.startsWith('$parent.')) {
        _problem(
          idNode,
          '$what: a sub-slice of $parent needs an id starting with $parent.',
        );
      }
      _unique(id, idNode);
    }
    final title = _string(map, 'title', what);
    final summary = _string(map, 'summary', what);
    final statusText = _string(map, 'status', what, required: false);
    SliceStatus? status;
    if (statusText != null) {
      status = SliceStatus.values
          .where((value) => value.name == statusText)
          .firstOrNull;
      if (status == null) {
        _problem(
          map.nodes['status']!,
          '$what: status must be done, next or planned, not $statusText.',
        );
      }
    }
    final plan = _string(map, 'plan', what, required: false);
    if (plan != null &&
        (plan.contains('/') || plan.contains(r'\') || !plan.endsWith('.md'))) {
      _problem(
        map.nodes['plan']!,
        '$what: plan must be a file name in docs/superpowers/plans/, such as '
        '2026-09-29-slice-1a-workspace-cli-doctor.md.',
      );
    }
    final pr = _positiveInt(map, 'pr', what);
    final finished = _date(map, 'finished', what);
    final tooling = _bool(map, 'tooling', what);
    final children = <Slice>[
      for (final child in _list(map, 'slices', what)) ?_slice(child, parent: id),
    ];
    if (statusText == null && children.isEmpty) {
      _problem(
        map,
        '$what needs a status (done, next or planned), or sub-slices.',
      );
    }
    if (status == SliceStatus.done) {
      final missing = [
        if (map.nodes['plan'] == null) 'plan',
        if (map.nodes['pr'] == null) 'pr',
        if (map.nodes['finished'] == null) 'finished',
      ];
      if (missing.isNotEmpty) {
        _problem(map, '$what is done, so it needs ${_and(missing)}.');
      }
    } else if (status != null) {
      for (final key in const ['pr', 'finished']) {
        final value = map.nodes[key];
        if (value != null) {
          _problem(value, '$what: $key is only for a done slice.');
        }
      }
    }
    if (id == null || title == null || summary == null) return null;
    return Slice(
      id: id,
      title: title,
      summary: summary,
      line: node.span.start.line + 1,
      status: status,
      plan: plan,
      pr: pr,
      finished: finished,
      tooling: tooling,
      slices: children,
    );
  }

  YamlMap? _map(YamlNode node, String what) {
    if (node is YamlMap) return node;
    _problem(node, '$what must be a map.');
    return null;
  }

  /// Reports every key of [map] that isn't one of [keys]. Called once the
  /// entry's ID is known, so the problem can name the entry.
  void _keys(YamlMap map, String what, Set<String> keys) {
    final known = (keys.toList()..sort()).join(', ');
    for (final key in map.nodes.keys) {
      final name = key is YamlScalar ? '${key.value}' : '$key';
      if (!keys.contains(name)) {
        _problem(
          key is YamlNode ? key : map,
          '$what has an unknown key: $name. Known: $known.',
        );
      }
    }
  }

  String? _string(
    YamlMap map,
    String key,
    String what, {
    bool required = true,
  }) {
    final node = map.nodes[key];
    if (node == null) {
      if (required) _problem(map, '$what needs $key.');
      return null;
    }
    final value = node.value;
    if (value is! String || value.trim().isEmpty) {
      _problem(node, '$what: $key must be text.');
      return null;
    }
    return value.trim();
  }

  List<YamlNode> _list(
    YamlMap map,
    String key,
    String what, {
    bool required = false,
  }) {
    final node = map.nodes[key];
    if (node == null) {
      if (required) _problem(map, '$what needs $key.');
      return const [];
    }
    if (node is! YamlList || (required && node.nodes.isEmpty)) {
      _problem(
        node,
        '$what: $key must be a list'
        '${required ? ' with at least one entry' : ''}.',
      );
      return const [];
    }
    return node.nodes;
  }

  int? _positiveInt(YamlMap map, String key, String what) {
    final node = map.nodes[key];
    if (node == null) return null;
    final value = node.value;
    if (value is int && value > 0) return value;
    _problem(node, '$what: $key must be a whole number above 0.');
    return null;
  }

  String? _date(YamlMap map, String key, String what) {
    final node = map.nodes[key];
    if (node == null) return null;
    final value = '${node.value}';
    final match = _day.firstMatch(value);
    if (match != null) {
      final year = int.parse(match[1]!);
      final month = int.parse(match[2]!);
      final day = int.parse(match[3]!);
      final date = DateTime.utc(year, month, day);
      if (date.year == year && date.month == month && date.day == day) {
        return value;
      }
    }
    _problem(node, '$what: $key must be a date like 2026-10-01, not $value.');
    return null;
  }

  bool _bool(YamlMap map, String key, String what) {
    final node = map.nodes[key];
    if (node == null) return false;
    final value = node.value;
    if (value is bool) return value;
    _problem(node, '$what: $key must be true or false.');
    return false;
  }

  void _unique(String id, YamlNode node) {
    final first = _ids[id];
    if (first == null) {
      _ids[id] = node.span.start.line + 1;
    } else {
      _problem(node, '$id is used twice (first on line $first). IDs must be '
          'unique.');
    }
  }
}

String _and(List<String> items) => items.length == 1
    ? items.single
    : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
```

`?_milestone(node)` and `?_slice(…)` are Dart 3.8 null-aware collection elements: the entry is left out when the value is null. The workspace's SDK floor is `^3.12.0`, so they are available.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fvm dart test test/progress_test.dart`
Expected: PASS. If a line number in an expectation disagrees, recount against `_valid` per the note in Step 1 before touching the code.

- [ ] **Step 5: Format and analyze**

Run: `fvm dart format tool/src/progress.dart test/progress_test.dart && fvm dart analyze tool test`
Expected: no issues.

- [ ] **Step 6: Commit**

```bash
git add tool/src/progress.dart test/progress_test.dart
git commit -m "feat(tool): read and validate docs/superpowers/progress.yaml"
```

---

### Task 2: Checking progress against the plans and spec §18

**Files:**
- Create: `tool/src/progress_check.dart`
- Test: `test/progress_check_test.dart`

**Interfaces:**
- Consumes: from Task 1, `Progress`, `Milestone`, `Slice`, `SliceStatus`, `progressFile`, `parseProgress`. `GuideProblem` from `guide_checker.dart`.
- Produces (used by Task 4):
  - `const specFile = 'docs/superpowers/specs/2026-09-29-appstein-design.md';`
  - `const plansFolder = 'docs/superpowers/plans';`
  - `List<GuideProblem> checkProgress(String repoRoot, Progress progress)`
  - `({List<String> milestones, Map<String, List<String>> slices})? specMilestones(String spec)`

- [ ] **Step 1: Write the failing tests**

Create `test/progress_check_test.dart`:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/progress.dart';
import '../tool/src/progress_check.dart';
import 'support/temp_repo.dart';

const _spec = '''
# Spec

## 18. Milestones

### M1: Foundation (this spec)

| Slice | Delivers | Exit criteria |
|---|---|---|
| **1a** | Workspace | Green |
| **1b** | Knowledge | Golden |

**M1 is done when:**

- all pass.

### Later milestones (direction only; each gets its own spec)

- **M2: Pipeline.**
  - More.
- **M3: Adopt.**

---

## 19. Development workflow

| **9z** | Not a slice | Outside §18 |
''';

const _progress = '''
repository: https://github.com/owner/repo
milestones:
  - id: M1
    title: Foundation
    summary: S
    slices:
      - id: 1a
        title: Workspace
        summary: S
        status: done
        plan: 2026-09-29-slice-1a.md
        pr: 1
        finished: 2026-09-30
      - id: 1b
        title: Knowledge
        summary: S
        slices:
          - id: 1b.1
            title: Gaps
            summary: S
            status: next
            plan: 2026-09-30-slice-1b1.md
  - id: M2
    title: Pipeline
    summary: S
  - id: M3
    title: Adopt
    summary: S
''';

void main() {
  late Directory repo;

  Progress progressOf(String text) {
    final read = parseProgress(text);
    expect(read.problems, isEmpty);
    return read.progress!;
  }

  List<String> check([String text = _progress]) => [
    for (final problem in checkProgress(repo.path, progressOf(text)))
      '$problem',
  ];

  setUp(() {
    repo = tempFolder();
    writeFile(repo, specFile, _spec);
    writeFile(repo, '$plansFolder/2026-09-29-slice-1a.md', '# 1a\n');
    writeFile(repo, '$plansFolder/2026-09-30-slice-1b1.md', '# 1b.1\n');
  });

  test('a record that matches the plans and §18 has no problems', () {
    expect(check(), isEmpty);
  });

  test('a plan no slice names is a problem', () {
    writeFile(repo, '$plansFolder/2026-10-02-slice-1b2.md', '# 1b.2\n');
    expect(check(), [
      'docs/superpowers/plans/2026-10-02-slice-1b2.md: No slice in '
          'docs/superpowers/progress.yaml names this plan. Set it as the plan '
          'of the slice it builds.',
    ]);
  });

  // Review Focus 4.
  test('ignores files that are not plans', () {
    writeFile(repo, '$plansFolder/.DS_Store', 'x');
    writeFile(repo, '$plansFolder/notes.txt', 'x');
    writeFile(repo, '$plansFolder/old/2026-01-01-slice-0.md', '# old\n');
    expect(check(), isEmpty);
  });

  test('a plan a slice names but that does not exist is a problem', () {
    File(p.join(repo.path, plansFolder, '2026-09-30-slice-1b1.md'))
        .deleteSync();
    expect(check(), [
      'docs/superpowers/progress.yaml:18: Slice 1b.1 names the plan '
          '2026-09-30-slice-1b1.md, which is not in docs/superpowers/plans/.',
    ]);
  });

  test('two slices naming one plan is a problem', () {
    final text = _progress.replaceFirst(
      'plan: 2026-09-30-slice-1b1.md',
      'plan: 2026-09-29-slice-1a.md',
    );
    File(p.join(repo.path, plansFolder, '2026-09-30-slice-1b1.md'))
        .deleteSync();
    expect(check(text), [
      'docs/superpowers/progress.yaml:18: Slices 1a and 1b.1 both name the '
          'plan 2026-09-29-slice-1a.md. A plan belongs to one slice.',
    ]);
  });

  test('a plan with notes from execution needs its slice done', () {
    writeFile(
      repo,
      '$plansFolder/2026-09-30-slice-1b1.md',
      '# 1b.1\r\n\r\n## Notes from execution (2026-10-01)\r\n\r\nDone.\r\n',
    );
    expect(check(), [
      "docs/superpowers/progress.yaml:18: Slice 1b.1's plan has notes from "
          'execution, so the slice is finished. Mark it done, with its pr and '
          'finished date.',
    ]);
  });

  test('a §18 slice missing from the record is a problem', () {
    writeFile(
      repo,
      specFile,
      _spec.replaceFirst(
        '| **1b** | Knowledge | Golden |',
        '| **1b** | Knowledge | Golden |\n| **1c** | MCP | Tools |',
      ),
    );
    expect(check(), [
      'docs/superpowers/progress.yaml: Spec §18 has the M1 slice 1c, but '
          'docs/superpowers/progress.yaml does not. Add it.',
    ]);
  });

  test('a slice the record has but §18 does not is a problem', () {
    writeFile(
      repo,
      specFile,
      _spec.replaceFirst('| **1b** | Knowledge | Golden |\n', ''),
    );
    expect(check(), [
      'docs/superpowers/progress.yaml: docs/superpowers/progress.yaml has the '
          'M1 slice 1b, but spec §18 does not. Remove it, or add it to the '
          'spec first.',
    ]);
  });

  test('a §18 milestone missing from the record is a problem', () {
    writeFile(
      repo,
      specFile,
      _spec.replaceFirst('- **M3: Adopt.**', '- **M3: Adopt.**\n- **M4: App.**'),
    );
    expect(check(), [
      'docs/superpowers/progress.yaml: Spec §18 has the milestone M4, but '
          'docs/superpowers/progress.yaml does not. Add it.',
    ]);
  });

  test('a spec without §18 is a problem', () {
    writeFile(repo, specFile, '# Spec\n\n## 17. Benchmark\n');
    expect(check(), [
      'docs/superpowers/specs/2026-09-29-appstein-design.md: Has no '
          '"## 18. Milestones" section, so progress can\'t be checked against '
          'it.',
    ]);
  });

  group('specMilestones', () {
    test('reads the milestones and each table of slices, and stops at the '
        'next section', () {
      final spec = specMilestones(_spec)!;
      expect(spec.milestones, ['M1', 'M2', 'M3']);
      expect(spec.slices, {
        'M1': ['1a', '1b'],
      });
    });

    // Review Focus 5.
    test('reads §18 with CRLF line endings', () {
      final spec = specMilestones(_spec.replaceAll('\n', '\r\n'))!;
      expect(spec.milestones, ['M1', 'M2', 'M3']);
      expect(spec.slices['M1'], ['1a', '1b']);
    });

    test('is null without §18', () {
      expect(specMilestones('# Spec\n'), isNull);
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fvm dart test test/progress_check_test.dart`
Expected: FAIL, because `tool/src/progress_check.dart` doesn't exist.

- [ ] **Step 3: Write the implementation**

Create `tool/src/progress_check.dart`:

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

import 'guide_checker.dart';
import 'progress.dart';

/// The design spec, whose §18 lists the milestones and each milestone's
/// slices.
const specFile = 'docs/superpowers/specs/2026-09-29-appstein-design.md';

/// The folder of slice plans, one Markdown file per slice.
const plansFolder = 'docs/superpowers/plans';

final _notes = RegExp(r'^## Notes from execution\b', multiLine: true);

/// Checks [progress] against the repo at [repoRoot] (spec §19.6):
/// - every plan in [plansFolder] (a `.md` file directly in it) is named by
///   exactly one slice, and every plan a slice names exists;
/// - a slice whose plan has a `## Notes from execution` heading is done;
/// - the milestones match spec §18, and so do the slices of each milestone
///   §18 has a table for.
List<GuideProblem> checkProgress(String repoRoot, Progress progress) => [
  ..._checkPlans(repoRoot, progress),
  ..._checkSpec(repoRoot, progress),
];

List<GuideProblem> _checkPlans(String repoRoot, Progress progress) {
  final problems = <GuideProblem>[];
  final owners = <String, List<Slice>>{};
  for (final slice in progress.allSlices) {
    final plan = slice.plan;
    if (plan != null) owners.putIfAbsent(plan, () => []).add(slice);
  }
  final folder = Directory(p.join(repoRoot, plansFolder));
  final plans = <String>[
    if (folder.existsSync())
      for (final entry in folder.listSync())
        if (entry is File && entry.path.endsWith('.md'))
          p.basename(entry.path),
  ]..sort();
  for (final plan in plans) {
    final slices = owners[plan] ?? const <Slice>[];
    if (slices.isEmpty) {
      problems.add(
        GuideProblem(
          '$plansFolder/$plan',
          null,
          'No slice in $progressFile names this plan. Set it as the plan of '
          'the slice it builds.',
        ),
      );
      continue;
    }
    if (slices.length > 1) {
      problems.add(
        GuideProblem(
          progressFile,
          slices[1].line,
          'Slices ${slices.map((slice) => slice.id).join(' and ')} both name '
          'the plan $plan. A plan belongs to one slice.',
        ),
      );
    }
    final String text;
    try {
      text = File(p.join(folder.path, plan)).readAsStringSync();
    } on FileSystemException {
      problems.add(
        GuideProblem(
          '$plansFolder/$plan',
          null,
          "Can't be read, so its notes from execution can't be checked.",
        ),
      );
      continue;
    }
    if (!_notes.hasMatch(text.replaceAll('\r\n', '\n'))) continue;
    for (final slice in slices) {
      if (slice.status != SliceStatus.done) {
        problems.add(
          GuideProblem(
            progressFile,
            slice.line,
            "Slice ${slice.id}'s plan has notes from execution, so the slice "
            'is finished. Mark it done, with its pr and finished date.',
          ),
        );
      }
    }
  }
  for (final entry in owners.entries) {
    if (plans.contains(entry.key)) continue;
    for (final slice in entry.value) {
      problems.add(
        GuideProblem(
          progressFile,
          slice.line,
          'Slice ${slice.id} names the plan ${entry.key}, which is not in '
          '$plansFolder/.',
        ),
      );
    }
  }
  return problems;
}

List<GuideProblem> _checkSpec(String repoRoot, Progress progress) {
  final String text;
  try {
    text = File(p.join(repoRoot, specFile)).readAsStringSync();
  } on FileSystemException {
    return const [
      GuideProblem(
        specFile,
        null,
        "Can't be read, so progress can't be checked against §18.",
      ),
    ];
  }
  final spec = specMilestones(text);
  if (spec == null) {
    return const [
      GuideProblem(
        specFile,
        null,
        'Has no "## 18. Milestones" section, so progress can\'t be checked '
        'against it.',
      ),
    ];
  }
  final recorded = {
    for (final milestone in progress.milestones) milestone.id: milestone,
  };
  return [
    ..._compare('milestone', spec.milestones, recorded.keys.toList()),
    for (final entry in spec.slices.entries)
      if (recorded[entry.key] case final milestone?)
        ..._compare('${entry.key} slice', entry.value, [
          for (final slice in milestone.slices) slice.id,
        ]),
  ];
}

List<GuideProblem> _compare(
  String kind,
  List<String> inSpec,
  List<String> recorded,
) => [
  for (final id in inSpec)
    if (!recorded.contains(id))
      GuideProblem(
        progressFile,
        null,
        'Spec §18 has the $kind $id, but $progressFile does not. Add it.',
      ),
  for (final id in recorded)
    if (!inSpec.contains(id))
      GuideProblem(
        progressFile,
        null,
        '$progressFile has the $kind $id, but spec §18 does not. Remove it, '
        'or add it to the spec first.',
      ),
];

final _section18 = RegExp(r'^## 18\. ');
final _milestoneHeading = RegExp(r'^### (M\d+):');
final _laterMilestone = RegExp(r'^- \*\*(M\d+):');
final _sliceRow = RegExp(r'^\| \*\*([0-9a-z.]+)\*\* \|');

/// The milestones spec §18 names, in order, and the slices each milestone's
/// table lists, in order. A milestone with a `### M<n>:` heading owns the
/// `| **<id>** |` table rows below it; one named only in a `- **M<n>:`
/// bullet has no slices yet. Null when the spec has no `## 18.` section.
({List<String> milestones, Map<String, List<String>> slices})?
specMilestones(String spec) {
  final lines = spec.replaceAll('\r\n', '\n').split('\n');
  final start = lines.indexWhere(_section18.hasMatch);
  if (start < 0) return null;
  final milestones = <String>[];
  final slices = <String, List<String>>{};
  String? current;
  for (final line in lines.skip(start + 1)) {
    if (line.startsWith('## ')) break;
    final heading = _milestoneHeading.firstMatch(line);
    if (heading != null) {
      current = heading[1]!;
      milestones.add(current);
      slices[current] = [];
      continue;
    }
    if (line.startsWith('### ')) {
      current = null;
      continue;
    }
    final later = _laterMilestone.firstMatch(line);
    if (later != null) {
      milestones.add(later[1]!);
      continue;
    }
    final row = _sliceRow.firstMatch(line);
    if (row != null && current != null) slices[current]!.add(row[1]!);
  }
  return (milestones: milestones, slices: slices);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fvm dart test test/progress_check_test.dart`
Expected: PASS. Line numbers in expectations count from line 1 of `_progress`; `1b.1`'s entry (its `- id: 1b.1` map) starts on line 18.

- [ ] **Step 5: Format and analyze**

Run: `fvm dart format tool/src/progress_check.dart test/progress_check_test.dart && fvm dart analyze tool test`
Expected: no issues.

- [ ] **Step 6: Commit**

```bash
git add tool/src/progress_check.dart test/progress_check_test.dart
git commit -m "feat(tool): check progress against the plans and spec §18"
```

---

### Task 3: Rendering the progress sections as HTML

**Files:**
- Create: `tool/src/progress_html.dart`
- Test: `test/progress_html_test.dart`

**Interfaces:**
- Consumes: from Task 1, `Progress`, `Milestone`, `Slice`, `SliceStatus`, `Stage`.
- Produces (used by Task 4): `Map<String, String> renderProgressSections(Progress progress)` with keys `progress-status` and `progress`; also `String renderProgressStatus(Progress progress)` and `String renderProgress(Progress progress)`.

The CSS classes the markup uses (`pg-*`, plus the page's existing `pill`, `dot`, `tag ok|info|warn|neutral`) are styled by the CSS that Task 5 adds to the page. The class names here and there must match exactly.

- [ ] **Step 1: Write the failing tests**

Create `test/progress_html_test.dart`:

```dart
import 'package:test/test.dart';

import '../tool/src/progress.dart';
import '../tool/src/progress_html.dart';

const _tooling = Slice(
  id: '1a.1',
  title: 'Guide tooling',
  summary: 'Keeps the guide current.',
  line: 1,
  status: SliceStatus.done,
  tooling: true,
  plan: '2026-09-30-slice-1a1.md',
  pr: 2,
  finished: '2026-09-30',
);

const _progress = Progress(
  repository: 'https://github.com/owner/repo',
  milestones: [
    Milestone(
      id: 'M1',
      title: 'Foundation',
      summary: 'The first milestone.',
      line: 1,
      slices: [
        Slice(
          id: '1a',
          title: 'Workspace',
          summary: 'The `appstein` CLI.',
          line: 1,
          status: SliceStatus.done,
          plan: '2026-09-29-slice-1a.md',
          pr: 1,
          finished: '2026-09-30',
          slices: [_tooling],
        ),
        Slice(
          id: '1b',
          title: 'Knowledge',
          summary: 'The layers.',
          line: 1,
          slices: [
            Slice(
              id: '1b.1',
              title: 'Gaps',
              summary: 'Doctor.',
              line: 1,
              status: SliceStatus.done,
              plan: '2026-09-30-slice-1b1.md',
              pr: 4,
              finished: '2026-10-01',
            ),
            Slice(
              id: '1b.2',
              title: 'Store',
              summary: 'The store.',
              line: 1,
              status: SliceStatus.next,
            ),
            Slice(
              id: '1b.3',
              title: 'Map',
              summary: 'The map.',
              line: 1,
              status: SliceStatus.planned,
            ),
            Slice(
              id: '1b.4',
              title: 'Sync',
              summary: 'Sync.',
              line: 1,
              status: SliceStatus.planned,
            ),
          ],
        ),
        Slice(
          id: '1c',
          title: 'MCP',
          summary: 'The server.',
          line: 1,
          status: SliceStatus.planned,
        ),
      ],
    ),
    Milestone(id: 'M2', title: 'Pipeline', summary: 'Next.', line: 1),
  ],
);

void main() {
  test('renders both sections by name', () {
    expect(renderProgressSections(_progress).keys, [
      'progress-status',
      'progress',
    ]);
  });

  group('the status pill', () {
    test('names the milestone being built and the next slice', () {
      expect(
        renderProgressStatus(_progress),
        '<a class="pill pg-status" href="#progress"><span class="dot" '
        'aria-hidden="true"></span>Building M1 · next: <b>1b.2</b> Store</a>',
      );
    });

    test('says Starting when nothing in the milestone is done', () {
      const progress = Progress(
        repository: 'https://github.com/owner/repo',
        milestones: [
          Milestone(
            id: 'M1',
            title: 'F',
            summary: 'S',
            line: 1,
            slices: [
              Slice(
                id: '1a',
                title: 'W',
                summary: 'S',
                line: 1,
                status: SliceStatus.planned,
              ),
            ],
          ),
        ],
      );
      expect(renderProgressStatus(progress), contains('>Starting M1</a>'));
    });

    test('says so when every milestone is done', () {
      const progress = Progress(
        repository: 'https://github.com/owner/repo',
        milestones: [
          Milestone(
            id: 'M1',
            title: 'F',
            summary: 'S',
            line: 1,
            slices: [_tooling],
          ),
        ],
      );
      expect(
        renderProgressStatus(progress),
        contains('>Every milestone is done</a>'),
      );
    });
  });

  group('the progress section', () {
    late String html;

    setUp(() => html = renderProgress(_progress));

    test('has a rail with each milestone and its stage', () {
      expect(
        html,
        contains(
          '  <li class="pg-underway" title="The first milestone."><b>M1</b>'
          '<span>Foundation</span><em>In progress</em></li>',
        ),
      );
      expect(
        html,
        contains(
          '  <li class="pg-planned" title="Next."><b>M2</b>'
          '<span>Pipeline</span><em>Planned</em></li>',
        ),
      );
    });

    test('fills each bar segment by its product parts', () {
      expect(
        html,
        contains(
          '<a class="pg-seg pg-done" href="#pg-1a" style="--fill:100%">'
          '<b>1a</b><span>Workspace</span><i>1 of 1 done</i></a>',
        ),
      );
      expect(
        html,
        contains(
          '<a class="pg-seg pg-underway" href="#pg-1b" style="--fill:25%">'
          '<b>1b</b><span>Knowledge</span><i>1 of 4 done</i></a>',
        ),
      );
      expect(
        html,
        contains(
          '<a class="pg-seg pg-planned" href="#pg-1c" style="--fill:0%">',
        ),
      );
    });

    test('shows a done slice with its date, PR and plan', () {
      expect(
        html,
        contains(
          '<li class="pg-item pg-done" id="pg-1a">\n'
          '      <p class="pg-title"><b>1a</b> Workspace '
          '<span class="tag ok">Done</span></p>\n'
          '      <p class="pg-summary">The <code>appstein</code> CLI.</p>\n'
          '      <p class="pg-meta"><time datetime="2026-09-30">30 Sep 2026'
          '</time> · <a href="https://github.com/owner/repo/pull/1">PR #1</a>'
          ' · <a href="../plans/2026-09-29-slice-1a.md">Plan</a></p>',
        ),
      );
    });

    test('nests sub-slices and tags tooling', () {
      expect(
        html,
        contains(
          '<p class="pg-title"><b>1a.1</b> Guide tooling '
          '<span class="tag ok">Done</span> '
          '<span class="tag neutral">Repo tooling</span></p>',
        ),
      );
      expect(html, contains('<ol class="pg-timeline pg-sub">'));
    });

    test('marks the next slice, the underway parent and planned slices', () {
      expect(
        html,
        contains(
          '<li class="pg-item pg-next" id="pg-1b-2">\n'
          '          <p class="pg-title"><b>1b.2</b> Store '
          '<span class="tag info">Next</span></p>',
        ),
      );
      expect(html, contains('<span class="tag warn">In progress</span>'));
      expect(html, contains('<span class="tag neutral">Planned</span>'));
    });

    test('leaves out milestones without slices after the rail', () {
      expect('<div class="pg-milestone">'.allMatches(html), hasLength(1));
    });

    test('is the same every time', () {
      expect(renderProgress(_progress), html);
    });
  });

  // Review Focus 2.
  test('escapes HTML in titles and summaries', () {
    const progress = Progress(
      repository: 'https://github.com/owner/repo',
      milestones: [
        Milestone(
          id: 'M1',
          title: 'A & B',
          summary: 'Say "hi"',
          line: 1,
          slices: [
            Slice(
              id: '1a',
              title: '<script>',
              summary: 'Returns `List<String>` & more',
              line: 1,
              status: SliceStatus.next,
            ),
          ],
        ),
      ],
    );
    final html = renderProgress(progress);
    expect(html, isNot(contains('<script>')));
    expect(html, contains('<b>1a</b> &lt;script&gt; '));
    expect(
      html,
      contains('Returns <code>List&lt;String&gt;</code> &amp; more'),
    );
    expect(html, contains('title="Say &quot;hi&quot;"'));
    expect(html, contains('<span>A &amp; B</span>'));
    expect(renderProgressStatus(progress), contains('&lt;script&gt;'));
  });

  test('leaves an unmatched backtick as text', () {
    const progress = Progress(
      repository: 'https://github.com/owner/repo',
      milestones: [
        Milestone(
          id: 'M1',
          title: 'F',
          summary: 'S',
          line: 1,
          slices: [
            Slice(
              id: '1a',
              title: 'W',
              summary: 'A ` alone',
              line: 1,
              status: SliceStatus.planned,
            ),
          ],
        ),
      ],
    );
    expect(renderProgress(progress), contains('A ` alone'));
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fvm dart test test/progress_html_test.dart`
Expected: FAIL, because `tool/src/progress_html.dart` doesn't exist.

- [ ] **Step 3: Write the implementation**

Create `tool/src/progress_html.dart`:

```dart
import 'progress.dart';

/// The generated sections of the spec's visual page that show progress
/// (spec §19.6), by section name: `progress-status`, a pill at the top of
/// the page, and `progress`, the milestone rail with each milestone's slice
/// bar and timeline. The page's own CSS styles the `pg-*` classes.
Map<String, String> renderProgressSections(Progress progress) => {
  'progress-status': renderProgressStatus(progress),
  'progress': renderProgress(progress),
};

/// A pill naming the milestone being built and the slice that is next,
/// linking to the progress section.
String renderProgressStatus(Progress progress) {
  final current = progress.milestones
      .where((milestone) => milestone.stage != Stage.done)
      .firstOrNull;
  final next = progress.next;
  final String text;
  if (current == null) {
    text = 'Every milestone is done';
  } else {
    final verb = current.stage == Stage.underway ? 'Building' : 'Starting';
    final lead = '$verb ${_escape(current.id)}';
    text = next == null
        ? lead
        : '$lead · next: <b>${_escape(next.id)}</b> ${_escape(next.title)}';
  }
  return '<a class="pill pg-status" href="#progress"><span class="dot" '
      'aria-hidden="true"></span>$text</a>';
}

/// The milestone rail, then for each milestone with slices its bar (one
/// segment per slice, filled by the share of its product parts that are
/// done) and its timeline of slices and sub-slices. Pull requests link to
/// the repository; plans link relative to `docs/superpowers/specs/`.
String renderProgress(Progress progress) {
  final out = <String>['<ol class="pg-rail" aria-label="Milestones">'];
  for (final milestone in progress.milestones) {
    out.add(
      '  <li class="pg-${milestone.stage.name}" '
      'title="${_escape(milestone.summary)}"><b>${_escape(milestone.id)}</b>'
      '<span>${_escape(milestone.title)}</span>'
      '<em>${_stageLabel(milestone.stage)}</em></li>',
    );
  }
  out.add('</ol>');
  for (final milestone in progress.milestones) {
    if (milestone.slices.isEmpty) continue;
    out
      ..add('<div class="pg-milestone">')
      ..add('  <h3>${_escape(milestone.id)} slices</h3>')
      ..add('  <div class="pg-bar">');
    for (final slice in milestone.slices) {
      final parts = slice.productParts;
      final done = parts
          .where((part) => part.status == SliceStatus.done)
          .length;
      final fill = parts.isEmpty ? 0 : (done * 100 / parts.length).round();
      out.add(
        '    <a class="pg-seg pg-${_state(slice)}" href="#${_anchor(slice)}" '
        'style="--fill:$fill%"><b>${_escape(slice.id)}</b>'
        '<span>${_escape(slice.title)}</span>'
        '<i>$done of ${parts.length} done</i></a>',
      );
    }
    out
      ..add('  </div>')
      ..add('  <ol class="pg-timeline">');
    for (final slice in milestone.slices) {
      _item(progress, slice, out, '    ');
    }
    out
      ..add('  </ol>')
      ..add('</div>');
  }
  return out.join('\n');
}

void _item(Progress progress, Slice slice, List<String> out, String indent) {
  final state = _state(slice);
  final tooling = slice.tooling
      ? ' <span class="tag neutral">Repo tooling</span>'
      : '';
  out
    ..add('$indent<li class="pg-item pg-$state" id="${_anchor(slice)}">')
    ..add(
      '$indent  <p class="pg-title"><b>${_escape(slice.id)}</b> '
      '${_escape(slice.title)} ${_badge(state)}$tooling</p>',
    )
    ..add('$indent  <p class="pg-summary">${_inline(slice.summary)}</p>');
  final finished = slice.finished;
  final pr = slice.pr;
  final plan = slice.plan;
  final meta = [
    if (finished != null)
      '<time datetime="$finished">${_longDate(finished)}</time>',
    if (pr != null)
      '<a href="${_escape(progress.repository)}/pull/$pr">PR #$pr</a>',
    if (plan != null)
      '<a href="../plans/${_escape(Uri.encodeComponent(plan))}">Plan</a>',
  ];
  if (meta.isNotEmpty) {
    out.add('$indent  <p class="pg-meta">${meta.join(' · ')}</p>');
  }
  if (slice.slices.isNotEmpty) {
    out.add('$indent  <ol class="pg-timeline pg-sub">');
    for (final child in slice.slices) {
      _item(progress, child, out, '$indent    ');
    }
    out.add('$indent  </ol>');
  }
  out.add('$indent</li>');
}

/// `done`, `next` or `planned` for a slice with a status of its own, else
/// its stage: `done`, `underway` or `planned`.
String _state(Slice slice) => slice.status?.name ?? slice.stage.name;

String _anchor(Slice slice) => 'pg-${slice.id.replaceAll('.', '-')}';

String _badge(String state) => switch (state) {
  'done' => '<span class="tag ok">Done</span>',
  'next' => '<span class="tag info">Next</span>',
  'underway' => '<span class="tag warn">In progress</span>',
  _ => '<span class="tag neutral">Planned</span>',
};

String _stageLabel(Stage stage) => switch (stage) {
  Stage.done => 'Done',
  Stage.underway => 'In progress',
  Stage.planned => 'Planned',
};

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `2026-09-30` as `30 Sep 2026`. The parser only lets real dates through.
String _longDate(String day) {
  final parts = day.split('-');
  return '${int.parse(parts[2])} ${_months[int.parse(parts[1]) - 1]} '
      '${parts[0]}';
}

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// [text] escaped, with each `` `code` `` span shown as code.
String _inline(String text) => _escape(
  text,
).replaceAllMapped(RegExp('`([^`]+)`'), (match) => '<code>${match[1]}</code>');
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `fvm dart test test/progress_html_test.dart`
Expected: PASS.

- [ ] **Step 5: Format and analyze**

Run: `fvm dart format tool/src/progress_html.dart test/progress_html_test.dart && fvm dart analyze tool test`
Expected: no issues. If `dart format` reflows a line that an exact-string test pins (the tests pin output, not source), nothing changes in the output.

- [ ] **Step 6: Commit**

```bash
git add tool/src/progress_html.dart test/progress_html_test.dart
git commit -m "feat(tool): render progress as HTML for the spec's visual page"
```

---

### Task 4: Wiring progress into gen_docs and the guide check

**Files:**
- Modify: `tool/src/generated_sections.dart` (`regenerate`, lines 26–131)
- Modify: `tool/src/generated_docs.dart`
- Modify: `tool/gen_docs.dart`
- Modify: `tool/src/guide_check.dart`
- Test: `test/generated_sections_test.dart`, `test/generated_docs_test.dart`, `test/guide_check_test.dart`

**Interfaces:**
- Consumes: `readProgress`, `progressFile` (Task 1); `checkProgress` (Task 2); `renderProgressSections` (Task 3); existing `regenerate`, `GuideRegeneration`, `GuideProblem`.
- Produces:
  - `RegeneratedPage regenerate(String page, String markdown, Map<String, String> bodies, {bool guideLinks = true})`
  - `const visualPage = 'docs/superpowers/specs/2026-09-29-appstein-design.html';`
  - `GuideRegeneration regenerateVisualPage(String repoRoot, {required bool write, Map<String, String>? bodies})`

- [ ] **Step 1: Write the failing tests**

Append to the `main()` of `test/generated_sections_test.dart` (inside `main`, after the existing `refuses sections in pages below docs/guide/` test):

```dart
  test('with guideLinks off, a page outside docs/guide/ may have sections', () {
    final result = regenerate(
      'docs/superpowers/specs/page.html',
      '<p>\n<!-- generated:alpha -->\nold\n<!-- /generated:alpha -->\n</p>\n',
      {'alpha': '<b>A</b>'},
      guideLinks: false,
    );
    expect(result.problems, isEmpty);
    expect(
      result.text,
      '<p>\n<!-- generated:alpha -->\n\n<b>A</b>\n\n'
      '<!-- /generated:alpha -->\n</p>\n',
    );
  });
```

Append to `test/generated_docs_test.dart`, inside `main()` after the last test:

```dart
  group('regenerateVisualPage', () {
    const sections = {'progress-status': '<a>S</a>', 'progress': '<ol></ol>'};
    const page = '<header>\n'
        '<!-- generated:progress-status -->\n'
        '<!-- /generated:progress-status -->\n'
        '</header>\n'
        '<section>\n'
        '<!-- generated:progress -->\n'
        '<!-- /generated:progress -->\n'
        '</section>\n';

    test('rewrites the page with write, and a second run finds nothing', () {
      writeFile(repo, visualPage, page);
      final first = regenerateVisualPage(
        repo.path,
        write: true,
        bodies: sections,
      );
      expect(first.problems, isEmpty);
      expect(first.changedPages, [visualPage]);
      expect(read(visualPage), contains('\n\n<a>S</a>\n\n'));
      final again = regenerateVisualPage(
        repo.path,
        write: false,
        bodies: sections,
      );
      expect(again.changedPages, isEmpty);
      expect(again.problems, isEmpty);
    });

    test('without write, reports the page and writes nothing', () {
      writeFile(repo, visualPage, page);
      final result = regenerateVisualPage(
        repo.path,
        write: false,
        bodies: sections,
      );
      expect(result.changedPages, [visualPage]);
      expect(read(visualPage), page);
    });

    // Review Focus 1.
    test('keeps CRLF', () {
      writeFile(repo, visualPage, page.replaceAll('\n', '\r\n'));
      regenerateVisualPage(repo.path, write: true, bodies: sections);
      final text = read(visualPage);
      expect(text, contains('\r\n<a>S</a>\r\n'));
      expect(text.replaceAll('\r\n', ''), isNot(contains('\n')));
      expect(
        regenerateVisualPage(
          repo.path,
          write: false,
          bodies: sections,
        ).changedPages,
        isEmpty,
      );
    });

    test('a section the page does not show is a problem', () {
      writeFile(
        repo,
        visualPage,
        '<!-- generated:progress -->\n<!-- /generated:progress -->\n',
      );
      final result = regenerateVisualPage(
        repo.path,
        write: false,
        bodies: sections,
      );
      expect(result.problems.map((x) => '$x'), [
        "$visualPage: The page doesn't show the generated section "
            'progress-status. Add <!-- generated:progress-status --> and '
            '<!-- /generated:progress-status --> where it belongs.',
      ]);
    });

    test('a missing page is a problem', () {
      final result = regenerateVisualPage(
        repo.path,
        write: false,
        bodies: sections,
      );
      expect(result.problems.map((x) => '$x'), [
        "$visualPage: Missing. It shows the progress sections.",
      ]);
    });

    test('without bodies, an unreadable progress file is its problems', () {
      writeFile(repo, visualPage, page);
      final result = regenerateVisualPage(repo.path, write: false);
      expect(result.problems.map((x) => '$x'), [
        'docs/superpowers/progress.yaml: Missing. It records where each '
            'milestone and slice stands (spec §19.6).',
      ]);
    });
  });
```

Append to `test/guide_check_test.dart`, inside `main()` after the first test:

```dart
  test('reports progress problems', () async {
    final repo = tempRepo();
    writeFile(repo, 'docs/guide/README.md', '<!-- covers: none -->\n# G\n');
    runGit(repo, ['add', '.']);
    runGit(repo, ['commit', '-q', '-m', 'first']);
    final problems = await checkGuide(repo.path);
    expect(
      problems.map((problem) => '$problem'),
      contains(
        'docs/superpowers/progress.yaml: Missing. It records where each '
        'milestone and slice stands (spec §19.6).',
      ),
    );
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `fvm dart test test/generated_sections_test.dart test/generated_docs_test.dart test/guide_check_test.dart`
Expected: FAIL: `guideLinks` isn't a parameter, `visualPage` and `regenerateVisualPage` don't exist, and `checkGuide` doesn't report progress.

- [ ] **Step 3: Add `guideLinks` to `regenerate`**

In `tool/src/generated_sections.dart`, change the doc comment's last sentences and the signature of `regenerate`:

```dart
/// Replaces the body of each generated section in [markdown], the text of
/// [page], with its entry in [bodies] (spec §19.6).
///
/// A section is a `<!-- generated:<name> -->` line, then anything, then a
/// `<!-- /generated:<name> -->` line. The body is written with a blank line
/// after the start marker and before the end marker. Markers inside code
/// fences are examples and are left alone. The page's line endings (LF or
/// CRLF) are kept. Guide sections link relative to `docs/guide/`, so with
/// [guideLinks] (the default) a page elsewhere, such as one in a subfolder,
/// may not have sections. The spec's visual page turns it off: its sections
/// write their own links.
RegeneratedPage regenerate(
  String page,
  String markdown,
  Map<String, String> bodies, {
  bool guideLinks = true,
}) {
```

and the check near the end:

```dart
  if (guideLinks &&
      sections.isNotEmpty &&
      p.posix.dirname(page) != 'docs/guide') {
```

- [ ] **Step 4: Add `regenerateVisualPage`**

In `tool/src/generated_docs.dart`, add the imports:

```dart
import 'progress.dart';
import 'progress_html.dart';
```

and append:

```dart
/// The spec's visual page, which shows the progress sections (spec §19.6).
const visualPage = 'docs/superpowers/specs/2026-09-29-appstein-design.html';

/// Renders the progress sections of [visualPage] again (spec §19.6). With
/// [write], an out-of-date page is rewritten; without it, nothing is
/// written. [bodies] replaces the sections rendered from
/// `docs/superpowers/progress.yaml`, for tests; without it, a progress file
/// with problems is reported as those problems. A missing page, a section
/// the page doesn't show and a malformed or unknown marker are problems.
GuideRegeneration regenerateVisualPage(
  String repoRoot, {
  required bool write,
  Map<String, String>? bodies,
}) {
  var rendered = bodies;
  if (rendered == null) {
    final read = readProgress(repoRoot);
    final progress = read.progress;
    if (progress == null) return GuideRegeneration(const [], read.problems);
    rendered = renderProgressSections(progress);
  }
  final file = File(p.join(repoRoot, visualPage));
  if (!file.existsSync()) {
    return const GuideRegeneration([], [
      GuideProblem(visualPage, null, 'Missing. It shows the progress sections.'),
    ]);
  }
  final before = file.readAsStringSync();
  final result = regenerate(visualPage, before, rendered, guideLinks: false);
  final problems = [
    ...result.problems,
    for (final name in rendered.keys)
      if (!result.sections.contains(name))
        GuideProblem(
          visualPage,
          null,
          "The page doesn't show the generated section $name. Add "
          '<!-- generated:$name --> and <!-- /generated:$name --> where it '
          'belongs.',
        ),
  ];
  if (problems.isNotEmpty) return GuideRegeneration(const [], problems);
  if (result.text == before) return const GuideRegeneration([], []);
  if (write) file.writeAsStringSync(result.text);
  return const GuideRegeneration([visualPage], []);
}
```

- [ ] **Step 5: Regenerate the visual page in `gen_docs`**

Replace the body of `main` in `tool/gen_docs.dart` after the usage check (from `final root = …` to the end) with:

```dart
  final root = Directory.current.path;
  final guide = await regenerateGuide(root, guidePages(root), write: !check);
  final visual = regenerateVisualPage(root, write: !check);
  final problems = [...guide.problems, ...visual.problems];
  final changed = [...guide.changedPages, ...visual.changedPages];
  for (final problem in problems) {
    stderr.writeln(problem);
  }
  for (final page in changed) {
    stdout.writeln(
      check ? '$page: generated sections are out of date.' : 'Updated $page',
    );
  }
  if (problems.isNotEmpty || (check && changed.isNotEmpty)) {
    exitCode = 1;
  } else if (changed.isEmpty) {
    stdout.writeln('Generated sections are up to date.');
  }
```

and change its doc comment's first line to:

```dart
/// Regenerates the generated sections of the developer guide and the
/// progress sections of the spec's visual page (spec §19.6).
```

- [ ] **Step 6: Check progress in `checkGuide`**

In `tool/src/guide_check.dart`, add imports:

```dart
import 'progress.dart';
import 'progress_check.dart';
import 'progress_html.dart';
```

extend the doc comment's list with two items after "generated sections up to date;":

```dart
/// - `docs/superpowers/progress.yaml` valid, and consistent with the plans
///   and spec §18;
/// - the progress sections of the spec's visual page up to date;
```

and before `return problems;` add:

```dart
  final progress = readProgress(repoRoot);
  problems.addAll(progress.problems);
  final record = progress.progress;
  if (record != null) {
    problems.addAll(checkProgress(repoRoot, record));
    final visual = regenerateVisualPage(
      repoRoot,
      write: false,
      bodies: renderProgressSections(record),
    );
    problems
      ..addAll(visual.problems)
      ..addAll([
        for (final page in visual.changedPages)
          GuideProblem(
            page,
            null,
            'The progress sections are out of date. Run: '
            'fvm dart run tool/gen_docs.dart',
          ),
      ]);
  }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `fvm dart test test/generated_sections_test.dart test/generated_docs_test.dart test/guide_check_test.dart test/progress_test.dart test/progress_check_test.dart test/progress_html_test.dart`
Expected: PASS.

- [ ] **Step 8: Format, analyze, full suite**

Run: `fvm dart format tool test && fvm dart analyze && fvm dart test`
Expected: no format changes beyond the touched files, no analyzer issues, all tests pass. (The integration tests that cross-check the real machine may be skipped or slow; they must not fail.)

- [ ] **Step 9: Commit**

```bash
git add tool/src/generated_sections.dart tool/src/generated_docs.dart tool/gen_docs.dart tool/src/guide_check.dart test/generated_sections_test.dart test/generated_docs_test.dart test/guide_check_test.dart
git commit -m "feat(tool): gen_docs renders progress into the visual page; check_guide checks it"
```

---

### Task 5: The progress record, the page, the spec and the docs

**Files:**
- Create: `docs/superpowers/progress.yaml`
- Modify: `docs/superpowers/specs/2026-09-29-appstein-design.html`
- Modify: `docs/superpowers/specs/2026-09-29-appstein-design.md` (§19.3, §19.4, §19.6)
- Modify: `docs/guide/docs-tooling.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: everything from Tasks 1–4. `fvm dart run tool/gen_docs.dart` and `fvm dart run tool/check_guide.dart --since main` must pass at the end.

- [ ] **Step 1: Create `docs/superpowers/progress.yaml`**

```yaml
# Where Appstein stands (spec §19.6). This file is the only place progress
# is written: `fvm dart run tool/gen_docs.dart` renders it into the spec's
# visual page, and the guide check fails when the page, the plans or spec
# §18 disagree with it. See docs/guide/docs-tooling.md#progress.
repository: https://github.com/UTTAM-VAGHASIA/appstein
milestones:
  - id: M1
    title: Knowledge + verification foundation
    summary: What an agent needs to know before it writes Flutter code, and a deterministic check after.
    slices:
      - id: 1a
        title: Workspace, CLI, doctor and CI
        summary: The pub workspace with four packages, the `appstein` CLI with `doctor`, and CI on Linux, macOS and Windows.
        status: done
        plan: 2026-09-29-slice-1a-workspace-cli-doctor.md
        pr: 1
        finished: 2026-09-30
        slices:
          - id: 1a.1
            title: Keep the developer guide current
            summary: Every source file is covered by a guide page, stale pages fail CI, facts the code knows are generated, and git hooks warn early.
            status: done
            tooling: true
            plan: 2026-09-30-slice-1a1-docs-freshness.md
            pr: 2
            finished: 2026-09-30
          - id: 1a.2
            title: Warn when the knowledge graph is behind
            summary: "`tool/check_graph.py` and a hook warning name the docs whose current content isn't in the graph."
            status: done
            tooling: true
            plan: 2026-09-30-slice-1a2-graph-staleness.md
            pr: 3
            finished: 2026-09-30
          - id: 1a.3
            title: The knowledge graph repairs itself
            summary: Docs a code rebuild dropped are put back from graphify's cache in the background after each checkout, merge and rebase.
            status: done
            tooling: true
            plan: 2026-10-01-slice-1a3-graph-self-repair.md
            pr: 5
            finished: 2026-10-01
          - id: 1a.4
            title: Project progress on the visual page
            summary: This record, rendered on the spec's visual page and kept consistent with the plans and §18 by the guide check.
            status: next
            tooling: true
            plan: 2026-10-01-slice-1a4-progress.md
      - id: 1b
        title: Knowledge layers 1–2
        summary: What an agent needs to know about the SDK, the native toolchain and the project, written into `.appstein/`.
        slices:
          - id: 1b.1
            title: doctor agrees with flutter doctor -v
            summary: Build-tools and platforms, the aapt/adb fallback, macOS Android Studio discovery, FVM channel pins and cache, and file error reasons, on every OS.
            status: done
            plan: 2026-09-30-slice-1b1-sdk-gaps.md
            pr: 4
            finished: 2026-10-01
          - id: 1b.2
            title: Knowledge store and platform layer
            summary: The `.appstein/` store with its lock and freshness state, `sdk.json`, curated notes for Flutter 3.44–3.47, `delta.md`, `toolchain.json` and `appstein sync`.
            status: planned
          - id: 1b.3
            title: Project map
            summary: The map of the user's app (features, symbols with doc-comment summaries, routes, layers, dependencies, native config) through `official_mvvm` and the platform extractors.
            status: planned
          - id: 1b.4
            title: Incremental sync, INDEX.md and package skills
            summary: Sync that rebuilds only what changed, the always-in-view `INDEX.md`, and the package skills refresh.
            status: planned
      - id: 1c
        title: MCP server
        summary: The MCP server with every §8 tool, knowledge layers 3–4 (decisions and memory) and the human docs renderer with `appstein docs`.
        status: planned
      - id: 1d
        title: Verifier
        summary: Fast and full checks, Android and iOS checks with static release readiness, the package gate, the M1 lint rules, `docs.stale` and suppressions.
        status: planned
      - id: 1e
        title: create + integrate
        summary: "`appstein create` with its CI template and first human docs, and `integrate` for Claude Code and Codex with hooks."
        status: planned
      - id: 1f
        title: upgrade, skills, benchmark
        summary: The `upgrade` framework with the 3.47 migration, the lifecycle skills and the first published benchmark run.
        status: planned
  - id: M2
    title: Single-agent pipeline
    summary: Plan, implement, review and verify with hard gates, driving the official agent CLIs; visual verification; a guided mode for beginners.
  - id: M3
    title: Existing apps, more stacks
    summary: "`appstein adopt` for existing projects; Riverpod and Bloc packs, community packs and a pack scaffold."
  - id: M4
    title: Desktop app, every platform
    summary: A Flutter desktop app with several agents at once; web, Windows, macOS and Linux packs; then a web UI.
```

While this branch is being built, 1a.4 is `next` and 1b.2 is `planned`. Task 6 marks 1a.4 done and 1b.2 next, after the pull request opens.

- [ ] **Step 2: Add the CSS to the visual page**

In `docs/superpowers/specs/2026-09-29-appstein-design.html`, directly before the line `@media (prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{transition-duration:0s!important}}`, insert:

```css
/* ---------- progress (the markup is generated from docs/superpowers/progress.yaml) ---------- */
.pg-status{color:var(--ink);border-color:var(--accent)}
.pg-status:hover{text-decoration:none;background:var(--accent-soft)}
.pg-status .dot{animation:pg-pulse 2.4s ease-in-out infinite}
@keyframes pg-pulse{0%,100%{box-shadow:0 0 0 0 var(--accent-soft)}50%{box-shadow:0 0 0 5px var(--accent-soft)}}
.pg-rail{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:repeat(4,1fr)}
.pg-rail li{position:relative;padding:30px 20px 0 0}
.pg-rail li::before{content:"";position:absolute;top:7px;left:0;right:0;height:2px;background:var(--line-2)}
.pg-rail li:last-child::before{right:auto;width:16px}
.pg-rail li::after{content:"";position:absolute;top:0;left:0;width:16px;height:16px;box-sizing:border-box;border-radius:50%;background:var(--bg);border:2px solid var(--line-2)}
.pg-rail li.pg-done::before{background:var(--ok)}
.pg-rail li.pg-done::after{background:var(--ok);border-color:var(--ok)}
.pg-rail li.pg-underway::before{background:linear-gradient(90deg,var(--accent) 0 40%,var(--line-2) 40%)}
.pg-rail li.pg-underway::after{border-color:var(--accent);background:var(--accent);box-shadow:0 0 0 5px var(--accent-soft)}
.pg-rail b{display:block;font:500 1.05rem/1 var(--mono);letter-spacing:-.02em}
.pg-rail span{display:block;margin-top:8px;font-size:.88rem;color:var(--ink-2);line-height:1.35;max-width:24ch}
.pg-rail em{display:block;margin-top:8px;font-style:normal;font-size:.74rem;letter-spacing:.02em;color:var(--ink-3)}
.pg-rail li.pg-done em{color:var(--ok)}
.pg-rail li.pg-underway em{color:var(--accent)}
.pg-milestone{margin-top:56px}
.pg-milestone h3{margin:0 0 14px;font-size:.8rem;font-weight:500;letter-spacing:.02em;color:var(--ink-3)}
.pg-bar{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:8px}
.pg-seg{position:relative;overflow:hidden;display:flex;flex-direction:column;padding:14px 14px 18px;border-radius:var(--r-sm);background:var(--surface);border:1px solid var(--line);color:var(--ink);transition:border-color .2s,transform .1s ease-out}
.pg-seg:hover{border-color:var(--line-2);text-decoration:none}
.pg-seg:active{transform:scale(.98)}
.pg-seg::before{content:"";position:absolute;left:0;right:0;bottom:0;height:4px;background:var(--line)}
.pg-seg::after{content:"";position:absolute;left:0;bottom:0;height:4px;width:var(--fill);background:var(--ok)}
.pg-seg.pg-underway::after,.pg-seg.pg-next::after{background:var(--accent)}
.pg-seg.pg-next{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
.pg-seg b{font:500 1.05rem/1 var(--mono);letter-spacing:-.02em}
.pg-seg span{margin-top:8px;font-size:.8rem;line-height:1.35;color:var(--ink-2)}
.pg-seg i{margin-top:auto;padding-top:12px;font-style:normal;font-size:.72rem;color:var(--ink-3)}
.pg-timeline{list-style:none;margin:32px 0 0;padding:0;position:relative}
.pg-timeline::before{content:"";position:absolute;left:7px;top:8px;bottom:8px;width:2px;background:var(--line)}
.pg-item{position:relative;padding:0 0 26px 36px}
.pg-item:last-child{padding-bottom:0}
.pg-item::before{content:"";position:absolute;left:0;top:2px;width:16px;height:16px;box-sizing:border-box;border-radius:50%;background:var(--bg);border:2px solid var(--line-2)}
.pg-item.pg-done::before{background:var(--ok);border-color:var(--ok)}
.pg-item.pg-done::after{content:"";position:absolute;left:5.5px;top:5px;width:4px;height:7px;border:solid var(--on-fill);border-width:0 2px 2px 0;transform:rotate(45deg)}
.pg-item.pg-next::before{border-color:var(--accent);background:var(--accent);box-shadow:0 0 0 5px var(--accent-soft)}
.pg-item.pg-underway::before{border-color:var(--accent);background:linear-gradient(90deg,var(--accent) 50%,var(--bg) 50%)}
.pg-item.pg-planned>.pg-title,.pg-item.pg-planned>.pg-summary{opacity:.6}
.pg-title{margin:0;display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;font-weight:500}
.pg-title b{font:500 .95rem/1.2 var(--mono);letter-spacing:-.02em}
.pg-item.pg-next>.pg-title{color:var(--accent)}
.pg-summary{margin:6px 0 0;max-width:72ch;font-size:.9rem;color:var(--ink-2)}
.pg-meta{margin:6px 0 0;font-size:.8rem;color:var(--ink-3)}
.pg-sub{margin-top:20px}
.pg-sub .pg-item{padding-bottom:18px}
@media (max-width:860px){.pg-rail{grid-template-columns:repeat(2,1fr);row-gap:28px}.pg-rail li:nth-child(2n)::before{right:auto;width:16px}}
@media (max-width:600px){.pg-bar{grid-template-columns:repeat(3,1fr)}.pg-item{padding-left:30px}}
@media (prefers-reduced-motion:reduce){.pg-status .dot{animation:none}}
```

- [ ] **Step 3: Add the nav link, hero markers and the section**

In the nav list, make Progress the first link. Replace:

```html
      <li><a href="#how">How it works</a></li>
```

with:

```html
      <li><a href="#progress">Progress</a></li>
      <li><a href="#how">How it works</a></li>
```

In the hero, replace:

```html
      <div class="meta">
        <span class="pill"><span class="dot"></span>Approved by the owner</span>
```

with:

```html
      <div class="meta">
<!-- generated:progress-status -->
<!-- /generated:progress-status -->
        <span class="pill"><span class="dot"></span>Approved by the owner</span>
```

Directly before the line `<!-- ================= WHY (§1, §2, §3) ================= -->`, insert:

```html
<!-- ================= PROGRESS (§18; generated from docs/superpowers/progress.yaml) ================= -->
<section id="progress">
  <div class="wrap">
    <div class="head">
      <p class="eyebrow">Progress</p>
      <h2>Where the build stands.</h2>
      <p class="lead">Written once in <code>docs/superpowers/progress.yaml</code> and drawn here by <code>gen_docs</code>. CI fails when this page, the plans or §18 disagree with it.</p>
    </div>
<!-- generated:progress -->
<!-- /generated:progress -->
  </div>
</section>

```

- [ ] **Step 4: Generate and check**

Run: `fvm dart run tool/gen_docs.dart`
Expected: `Updated docs/superpowers/specs/2026-09-29-appstein-design.html`.

Run: `fvm dart run tool/gen_docs.dart --check`
Expected: `Generated sections are up to date.`

Open the page in a browser (in PowerShell: `Start-Process docs/superpowers/specs/2026-09-29-appstein-design.html`) and look at it in light and dark mode and at a phone width. The controller does this and shows it to the owner; an implementer only checks that the file opens without layout breakage it can see in the HTML.

- [ ] **Step 5: Apply the approved spec wording**

In `docs/superpowers/specs/2026-09-29-appstein-design.md`, apply the three edits in **Approved spec wording** at the top of this plan, verbatim: the §19.3 `docs` row, the §19.4 per-slice bullet, and the new §19.6 bullet after "**Facts the code already knows are generated, not typed.**".

Then check the visual page against the spec (AGENTS.md: "Whenever the spec changes, update it to match and re-check every claim on it against the spec"): the page makes no claim about §19.3, §19.4 or §19.6 beyond the new Progress section's lead, which says what §19.6 now says. Record that in the commit message body.

- [ ] **Step 6: Update `AGENTS.md`**

Replace the whole `**Current phase:** …` paragraph with:

```markdown
**Current phase:** M1. Where every milestone and slice stands, with its plan and pull request, is recorded in `docs/superpowers/progress.yaml` and drawn at the top of the visual summary (below). The slice 1a and 1b.1 plans list what later slices inherit ("Carried to later slices").
```

In **Source of truth**, after the **Plans** bullet, add:

```markdown
- **Progress:** `docs/superpowers/progress.yaml` is the only place progress is written. When a slice's plan is committed, name it as the slice's `plan`; once the slice's PR is open, mark it done with its `pr` and `finished` date and mark the next slice `next`. Run `fvm dart run tool/gen_docs.dart` to redraw the visual summary. See `docs/guide/docs-tooling.md`.
```

- [ ] **Step 7: Update `docs/guide/docs-tooling.md`**

1. In **The rules**, after the bullet "**Facts the code already knows are generated, not typed.** …", add:

```markdown
- **Progress is data, not prose.** Where each milestone and slice stands is written once, in `docs/superpowers/progress.yaml`, and drawn on the spec's visual page (see [Progress](#progress)).
```

2. In **Generated sections**, add two rows to the end of the table:

```markdown
| `progress-status` | the spec's [visual page](../superpowers/specs/2026-09-29-appstein-design.html) | `docs/superpowers/progress.yaml`: the milestone being built and the slice that is next |
| `progress` | the spec's [visual page](../superpowers/specs/2026-09-29-appstein-design.html) | `docs/superpowers/progress.yaml`: the milestone rail, each milestone's slice bar and its timeline |
```

and replace the rule bullet "**Sections go only in pages directly in `docs/guide/`.** …" with:

```markdown
- **Guide sections go only in pages directly in `docs/guide/`.** Generated links are written relative to that folder, so they would break in a subfolder such as `how-to/`. The two progress sections are the exception: they live in the spec's visual page, and [`progress_html.dart`](../../tool/src/progress_html.dart) writes their links relative to its folder.
```

3. In **Commands**, change the first row's description to: `Rewrites every out-of-date generated section, in the guide and on the spec's visual page, and prints \`Updated <page>\` for each`.

4. In the numbered list of what `check_guide` runs, add after item 5:

```markdown
6. **Progress** ([`progress.dart`](../../tool/src/progress.dart) and [`progress_check.dart`](../../tool/src/progress_check.dart)): `progress.yaml` is valid and agrees with the plans and spec §18, and the visual page's progress sections are up to date. See [Progress](#progress).
```

5. Add a new section directly before `## The docs step of each slice`:

````markdown
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
| `status` | `done` (merged), `next` (being built, or the one to build next) or `planned`. At most one slice is `next`. A slice without a status must have sub-slices, and its stage comes from them |
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
3. Once the pull request is open, one more commit records the result: the plan's notes from execution, the slice `done` with `pr` and `finished`, and the following slice `next`. Then `fvm dart run tool/gen_docs.dart`. It comes after the PR opens because GitHub gives the number only then; before that commit, the slice is still `next` and its plan has no notes, so every check passes on both CI runs.
````

6. In **The docs step of each slice**, replace the numbered list with:

```markdown
1. `fvm dart run tool/gen_docs.dart`
2. `fvm dart run tool/check_guide.dart --since main`
3. `/graphify . --update`, then the [graph check](#is-the-graph-current), until it reports nothing. The hooks rebuild only the code structure, not what the docs mean.
4. Once the pull request is open, mark the slice done in `progress.yaml` (see [Progress](#progress)), run steps 1–3 again, and push.
```

7. In **Limits**, add:

```markdown
- **Progress is only as true as its last edit.** The check proves the page matches the file and the file agrees with the plans and §18. It can't tell that a slice marked `next` is really being built, or that a summary is accurate.
```

- [ ] **Step 8: Run every check**

Run: `fvm dart run tool/gen_docs.dart && fvm dart run tool/check_guide.dart --since main && fvm dart format --set-exit-if-changed . && fvm dart analyze && fvm dart test`
Expected: `Generated sections are up to date.`, `Guide check passed.`, no format changes, no analyzer issues, every test passes.

- [ ] **Step 9: Commit**

```bash
git add docs/superpowers/progress.yaml docs/superpowers/specs/2026-09-29-appstein-design.html docs/superpowers/specs/2026-09-29-appstein-design.md docs/guide/docs-tooling.md AGENTS.md
git commit -m "docs: record progress in progress.yaml and draw it on the visual page (spec §19.3, §19.4, §19.6)"
```

---

### Task 6: Finish (controller only)

Not for an implementer subagent: it pushes, opens the pull request and merges, under the owner's approved PR flow.

- [ ] **Step 1:** Final whole-branch review (most capable model), one fix wave, scoped re-review.
- [ ] **Step 2:** Open the page in the browser; check light and dark mode and a phone width; show the owner.
- [ ] **Step 3:** Push `slice-1a4` and open the pull request. CI runs with 1a.4 still `next`; every check passes.
- [ ] **Step 4:** Add "Notes from execution" to this plan; in `progress.yaml` set 1a.4 `status: done`, `pr: <number>`, `finished: <today>`, and 1b.2 `status: next`; run `fvm dart run tool/gen_docs.dart` and `fvm dart run tool/check_guide.dart --since main`; commit `docs: mark slice 1a.4 done` and push.
- [ ] **Step 5:** `/graphify . --update` until `tool/check_graph.py` reports nothing.
- [ ] **Step 6:** CI green and verified → merge with a merge commit (`gh pr merge <n> --merge`), `git fetch --prune`, `git switch -C main origin/main`, delete the branch locally and on GitHub, run the graph check on `main`.

## Notes from execution

Executed 2026-10-01 in quick subagent-driven mode (one implementer at a time, each task's review alongside the next implementer, one final Opus review). Pull request #6.

**What happened**
- Tasks 1–4 each passed their task review on the first round (spec ✅, Approved). Task 5 was docs-only, so its review folded into the final whole-branch review.
- The final review found no Critical or Important issues and eight Minor ones, all fixed in one wave (3edf141) and confirmed by a scoped re-review:
  - planned timeline text used opacity, which fell below WCAG AA contrast; it now uses the page's `--ink-2`/`--ink-3` colours;
  - the last sub-slice kept its bottom padding (a CSS specificity tie);
  - "done" was described as "merged", but a slice is marked done once its PR is open; `SliceStatus.done` and docs-tooling now say "finished: its pull request is open or merged";
  - backticks showed literally in milestone tooltips; attributes now drop them, and tests pin attribute escaping;
  - the notes-from-execution check matched a heading inside a code fence; it now reads plans through `FenceTracker` like every other check;
  - wording in docs-tooling ("both CI runs") and `AGENTS.md` (notes go in the done commit); a border between the hero and Progress.
- While writing these notes, the controller found a stray unclosed ```` fence at the end of this plan. With the fence-aware check, a notes heading after it would not have counted, and the check would not have required the slice to be done. It was removed. The lesson: a plan must end outside any fence.
- CI's `analyze` job failed on the PR: `tool/src/progress.dart` and `test/progress_test.dart` held a raw U+FEFF character, and the repo's CI rejects that. The Task 1 implementer reported writing the `﻿` escape. The Task 1 reviewer flagged the character as invisible in the diff, but nobody followed that up. Every local check passed, because the raw character is valid Dart. Fixed by writing the escape. The lesson: when a report and a reviewer disagree about invisible characters, check the bytes (`LC_ALL=C grep -rl $'\xEF\xBB\xBF' --include='*.dart' .`).

**Rulings**
- Fix all eight final-review minors in one wave, because each was a line or two and three touched correctness or accessibility.
- Deferred minors left as they are (the final review agreed):
  - Bad UTF-8 in `progress.yaml` was claimed to throw `FormatException`. Dart's `readAsStringSync` throws `FileSystemException` there, which is caught.
  - A directory at the file's path is reported as "Missing".
  - Some parser and check error branches have no test.
  - `_badge` switches on a string.
  - `gen_docs` would print a stack trace for an unreadable page. `check_guide` catches it.
- The visual check ran on the controller's browser. Desktop light and dark rendered correctly. At a 390 px width there was no horizontal overflow (checked in the DOM), but the browser tool's screenshots at that width timed out.
