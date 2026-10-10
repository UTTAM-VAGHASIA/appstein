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
      'docs/project/plans/2026-10-02-slice-1b2.md: No slice in '
          'docs/project/progress.yaml names this plan. Set it as the plan '
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
      'docs/project/progress.yaml:18: Slice 1b.1 names the plan '
          '2026-09-30-slice-1b1.md, which is not in docs/project/plans/.',
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
      'docs/project/progress.yaml:18: Slices 1a and 1b.1 both name the '
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
      "docs/project/progress.yaml:18: Slice 1b.1's plan has notes from "
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

  group('slice folders', () {
    // Slice 1b.1 names a spec folder in place of its plan.
    final withSpec = _progress.replaceFirst(
      'plan: 2026-09-30-slice-1b1.md',
      'spec: 1b1-gaps',
    );

    setUp(() {
      File(
        p.join(repo.path, plansFolder, '2026-09-30-slice-1b1.md'),
      ).deleteSync();
      writeFile(repo, '$slicesFolder/1b1-gaps/spec.md', '# 1b.1\n');
      writeFile(repo, '$slicesFolder/1b1-gaps/issues/01-first.md', '# 1\n');
    });

    test('a slice whose folder has its spec has no problems', () {
      expect(check(withSpec), isEmpty);
    });

    test('a folder no slice names is a problem', () {
      writeFile(repo, '$slicesFolder/1b2-store/spec.md', '# 1b.2\n');
      expect(check(withSpec), [
        'docs/project/slices/1b2-store: No slice in '
            'docs/project/progress.yaml names this folder. Set it as the spec '
            'of the slice it builds.',
      ]);
    });

    test('ignores files directly in the slices folder', () {
      writeFile(repo, '$slicesFolder/.DS_Store', 'x');
      writeFile(repo, '$slicesFolder/README.md', '# Slices\n');
      expect(check(withSpec), isEmpty);
    });

    test('a folder a slice names but that does not exist is a problem', () {
      Directory(
        p.join(repo.path, slicesFolder, '1b1-gaps'),
      ).deleteSync(recursive: true);
      expect(check(withSpec), [
        'docs/project/progress.yaml:18: Slice 1b.1 names the spec folder '
            '1b1-gaps, which is not in docs/project/slices/.',
      ]);
    });

    test('a folder without spec.md is a problem', () {
      File(p.join(repo.path, slicesFolder, '1b1-gaps', 'spec.md')).deleteSync();
      expect(check(withSpec), [
        'docs/project/progress.yaml:18: Slice 1b.1 names the spec folder '
            '1b1-gaps, which has no spec.md.',
      ]);
    });

    test('two slices naming one folder is a problem', () {
      File(
        p.join(repo.path, plansFolder, '2026-09-29-slice-1a.md'),
      ).deleteSync();
      final text = withSpec.replaceFirst(
        'plan: 2026-09-29-slice-1a.md',
        'spec: 1b1-gaps',
      );
      expect(check(text), [
        'docs/project/progress.yaml:18: Slices 1a and 1b.1 both name the '
            'spec folder 1b1-gaps. A spec folder belongs to one slice.',
      ]);
    });

    test('a folder with notes.md needs its slice done', () {
      writeFile(repo, '$slicesFolder/1b1-gaps/notes.md', '# Notes\n');
      expect(check(withSpec), [
        "docs/project/progress.yaml:18: Slice 1b.1's spec folder has "
            'notes.md, so the slice is finished. Mark it done, with its pr '
            'and finished date.',
      ]);
    });

    test('a done slice may have notes.md', () {
      writeFile(repo, '$slicesFolder/1b1-gaps/notes.md', '# Notes\n');
      final text = withSpec.replaceFirst(
        'status: next\n',
        'status: done\n            pr: 2\n            finished: 2026-10-01\n',
      );
      expect(check(text), isEmpty);
    });

    test('notes.md deeper in the folder does not count', () {
      writeFile(repo, '$slicesFolder/1b1-gaps/issues/notes.md', '# Notes\n');
      expect(check(withSpec), isEmpty);
    });
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
      'docs/project/progress.yaml: Spec §18 has the M1 slice 1c, but '
          'docs/project/progress.yaml does not. Add it.',
    ]);
  });

  test('a slice the record has but §18 does not is a problem', () {
    writeFile(
      repo,
      specFile,
      _spec.replaceFirst('| **1b** | Knowledge | Golden |\n', ''),
    );
    expect(check(), [
      'docs/project/progress.yaml: docs/project/progress.yaml has the '
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
      'docs/project/progress.yaml: Spec §18 has the milestone M4, but '
          'docs/project/progress.yaml does not. Add it.',
    ]);
  });

  test('a spec without §18 is a problem', () {
    writeFile(repo, specFile, '# Spec\n\n## 17. Benchmark\n');
    expect(check(), [
      'docs/project/specs/2026-09-29-appstein-design.md: Has no '
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
        'docs/project/progress.yaml:7: Slice 1a: merge 758c535 is not a '
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
}
