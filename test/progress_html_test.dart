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

  test('strips backticks from the milestone tooltip', () {
    const progress = Progress(
      repository: 'https://github.com/owner/repo',
      milestones: [
        Milestone(
          id: 'M1',
          title: 'F',
          summary: '`appstein adopt` for "apps"',
          line: 1,
        ),
      ],
    );
    expect(
      renderProgress(progress),
      contains('title="appstein adopt for &quot;apps&quot;"'),
    );
  });

  test('encodes and escapes a plan name in its link', () {
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
              status: SliceStatus.done,
              plan: 'a b&c.md',
              pr: 1,
              finished: '2026-09-30',
            ),
          ],
        ),
      ],
    );
    expect(renderProgress(progress), contains('href="../plans/a%20b%26c.md"'));
  });

  test('links a spec folder to its spec, encoded and escaped', () {
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
              status: SliceStatus.done,
              spec: '1a b&c',
              pr: 1,
              finished: '2026-09-30',
            ),
          ],
        ),
      ],
    );
    expect(
      renderProgress(progress),
      contains(
        '<p class="pg-meta"><time datetime="2026-09-30">30 Sep 2026</time>'
        ' · <a href="https://github.com/owner/repo/pull/1">PR #1</a>'
        ' · <a href="../slices/1a%20b%26c/spec.md">Spec</a></p>',
      ),
    );
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
