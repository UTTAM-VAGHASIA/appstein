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

List<String> problemsOf(String text) => [
  for (final problem in parseProgress(text).problems) '$problem',
];

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
    final read = parseProgress('\uFEFF$_valid');
    expect(read.problems, isEmpty);
    expect(read.progress!.milestones, hasLength(2));
  });

  test('invalid YAML is one problem with its line', () {
    expect(problemsOf('repository: x\nmilestones: [\n'), [
      matches(RegExp(r'^docs/project/progress\.yaml:\d+: Not valid YAML: ')),
    ]);
  });

  test('an empty file is a problem', () {
    expect(problemsOf(''), [
      'docs/project/progress.yaml:1: The file must be a map.',
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
        'docs/project/progress.yaml:1: repository must be an https:// '
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
        'docs/project/progress.yaml:43: Milestone M2 has an unknown key: '
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
      'docs/project/progress.yaml:7: Slice 1a is done, so it needs plan (or '
          'spec), pr (or merge) and finished.',
    ]);
  });

  group('spec', () {
    test('a done slice may name its spec folder instead of a plan', () {
      final read = parseProgress(
        _valid.replaceFirst(
          'plan: 2026-09-30-slice-1b1.md',
          'spec: 1b1-sdk-gaps',
        ),
      );
      expect(read.problems, isEmpty);
      final slice = read.progress!.allSlices.singleWhere((s) => s.id == '1b.1');
      expect(slice.spec, '1b1-sdk-gaps');
      expect(slice.plan, isNull);
    });

    test('a slice that is not done may name its spec folder', () {
      final read = parseProgress(
        _valid.replaceFirst(
          '            status: next\n',
          '            status: next\n            spec: 1b2-store\n',
        ),
      );
      expect(read.problems, isEmpty);
      expect(read.progress!.next?.spec, '1b2-store');
    });

    test('a spec must be a folder name', () {
      const message =
          'docs/project/progress.yaml:31: Slice 1b.1: spec must be a folder '
          'name in docs/project/slices/, such as 1d2-code-checks.';
      for (final spec in const [
        'slices/1b1-sdk-gaps',
        r'slices\1b1-sdk-gaps',
      ]) {
        expect(
          problemsOf(
            _valid.replaceFirst('plan: 2026-09-30-slice-1b1.md', 'spec: $spec'),
          ),
          [message],
        );
      }
    });

    test('plan and spec together are a problem', () {
      expect(
        problemsOf(
          _valid.replaceFirst(
            'plan: 2026-09-30-slice-1b1.md\n',
            'plan: 2026-09-30-slice-1b1.md\n'
                '            spec: 1b1-sdk-gaps\n',
          ),
        ),
        [
          'docs/project/progress.yaml:32: Slice 1b.1 has both plan and spec. '
              'A slice names its plan or its spec folder, not both.',
        ],
      );
    });
  });

  group('merge', () {
    test('a done slice may give its merge commit instead of a pr', () {
      final read = parseProgress(
        _valid.replaceFirst('pr: 4', 'merge: a52fc1a'),
      );
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
          'docs/project/progress.yaml:33: Slice 1b.1 has both pr and '
              'merge. Use merge only for a pull request that no longer exists.',
        ],
      );
    });

    test('uppercase hex is a problem', () {
      expect(problemsOf(_valid.replaceFirst('pr: 4', 'merge: A52FC1A')), [
        'docs/project/progress.yaml:32: Slice 1b.1: merge must be a '
            'commit id of 7 to 40 lowercase hex digits, not A52FC1A.',
      ]);
    });

    test('a commit id shorter than 7 digits is a problem', () {
      expect(problemsOf(_valid.replaceFirst('pr: 4', 'merge: a52fc1')), [
        'docs/project/progress.yaml:32: Slice 1b.1: merge must be a '
            'commit id of 7 to 40 lowercase hex digits, not a52fc1.',
      ]);
    });

    test('a commit id YAML reads as a number must be quoted', () {
      const message =
          'docs/project/progress.yaml:32: Slice 1b.1: merge must be '
          'text. Quote a commit id that YAML reads as a number, such as '
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
          'docs/project/progress.yaml:38: Slice 1b.2: merge is only for '
              'a done slice.',
        ],
      );
    });
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
        'docs/project/progress.yaml:38: Slice 1b.2: pr is only for a '
            'done slice.',
      ],
    );
  });

  test('a slice needs a status or sub-slices', () {
    expect(
      problemsOf(_valid.replaceFirst('            status: planned\n', '')),
      [
        'docs/project/progress.yaml:38: Slice 1b.3 needs a status (done, '
            'next or planned), or sub-slices.',
      ],
    );
  });

  test('an unknown status is a problem', () {
    expect(
      problemsOf(_valid.replaceFirst('status: planned', 'status: later')),
      [
        'docs/project/progress.yaml:41: Slice 1b.3: status must be done, '
            'next or planned, not later.',
      ],
    );
  });

  test('more than one next slice is a problem', () {
    expect(problemsOf(_valid.replaceFirst('status: planned', 'status: next')), [
      'docs/project/progress.yaml:38: More than one slice is next '
          '(1b.2, 1b.3). Only one slice can be next.',
    ]);
  });

  test('a sub-slice id must start with its parent id', () {
    expect(problemsOf(_valid.replaceFirst('id: 1b.3', 'id: 1c.3')), [
      'docs/project/progress.yaml:38: Slice 1c.3: a sub-slice of 1b '
          'needs an id starting with 1b.',
    ]);
  });

  test('a duplicate id is a problem', () {
    expect(problemsOf(_valid.replaceFirst('id: 1b.3', 'id: 1b.2')), [
      'docs/project/progress.yaml:38: 1b.2 is used twice (first on line '
          '34). IDs must be unique.',
    ]);
  });

  test('a date that does not exist is a problem', () {
    expect(
      problemsOf(
        _valid.replaceFirst('finished: 2026-10-01', 'finished: 2026-02-30'),
      ),
      [
        'docs/project/progress.yaml:33: Slice 1b.1: finished must be a '
            'date like 2026-10-01, not 2026-02-30.',
      ],
    );
  });

  test('a pr that is not a positive whole number is a problem', () {
    expect(problemsOf(_valid.replaceFirst('pr: 4', 'pr: four')), [
      'docs/project/progress.yaml:32: Slice 1b.1: pr must be a whole '
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
        'docs/project/progress.yaml:31: Slice 1b.1: plan must be a file '
            'name in docs/project/plans/, such as '
            '2026-09-29-slice-1a-workspace-cli-doctor.md.',
      ],
    );
  });

  group('readProgress', () {
    test('a missing file is a problem', () {
      final repo = tempFolder();
      expect(readProgress(repo.path).problems.map((x) => '$x'), [
        'docs/project/progress.yaml: Missing. It records where each '
            'milestone and slice stands (spec §19.6).',
      ]);
    });

    test('reads the file in the repo', () {
      final repo = tempFolder();
      writeFile(repo, 'docs/project/progress.yaml', _valid);
      final read = readProgress(repo.path);
      expect(read.problems, isEmpty);
      expect(read.progress!.next?.id, '1b.2');
    });
  });
}
