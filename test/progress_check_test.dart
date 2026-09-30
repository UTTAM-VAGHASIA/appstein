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
    File(
      p.join(repo.path, plansFolder, '2026-09-30-slice-1b1.md'),
    ).deleteSync();
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
    File(
      p.join(repo.path, plansFolder, '2026-09-30-slice-1b1.md'),
    ).deleteSync();
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

  test('a notes heading inside a code fence does not count', () {
    writeFile(
      repo,
      '$plansFolder/2026-09-30-slice-1b1.md',
      '# 1b.1\n\n```text\n## Notes from execution (2026-10-01)\n```\n',
    );
    expect(check(), isEmpty);
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
      _spec.replaceFirst(
        '- **M3: Adopt.**',
        '- **M3: Adopt.**\n- **M4: App.**',
      ),
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
