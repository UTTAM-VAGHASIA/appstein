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

  test('regenerating a section with multi-line body containing code fences is '
      'idempotent', () {
    const bodiesWithFence = {
      'help':
          '```text\n\$ appstein --help\nUsage\n```\n\n```mermaid\ngraph LR\n  a --> b\n```',
    };
    const markdownLf =
        '# Title\n\n<!-- generated:help -->\nold content here\n'
        '<!-- /generated:help -->\n';

    final first = regenerate(page, markdownLf, bodiesWithFence);
    expect(first.problems, isEmpty);
    expect(first.sections, ['help']);
    expect(first.text, contains(bodiesWithFence['help']!));

    final second = regenerate(page, first.text, bodiesWithFence);
    expect(second.problems, isEmpty);
    expect(second.text, first.text);
  });

  test('regenerating a CRLF section with multi-line body containing code '
      'fences is idempotent', () {
    const bodiesWithFence = {
      'help':
          '```text\n\$ appstein --help\nUsage\n```\n\n```mermaid\ngraph LR\n  a --> b\n```',
    };
    const markdownCrlf =
        '# Title\r\n\r\n<!-- generated:help -->\r\nold content\r\n'
        '<!-- /generated:help -->\r\n';

    final first = regenerate(page, markdownCrlf, bodiesWithFence);
    expect(first.problems, isEmpty);
    expect(first.sections, ['help']);
    expect(
      first.text.replaceAll('\r\n', '\n'),
      contains(bodiesWithFence['help']!),
    );
    expect(first.text, contains('\r\n'));

    final second = regenerate(page, first.text, bodiesWithFence);
    expect(second.problems, isEmpty);
    expect(second.text, first.text);
  });

  group('stripGeneratedBodies', () {
    test('drops section bodies, keeps the markers and the text around them, '
        'and uses LF', () {
      expect(
        stripGeneratedBodies(
          '# T\r\n<!-- generated:alpha -->\r\nold\r\n\r\n'
          '<!-- /generated:alpha -->\r\nText\r\n',
        ),
        '# T\n<!-- generated:alpha -->\n<!-- /generated:alpha -->\nText\n',
      );
    });

    test('gives the same text before and after regenerating', () {
      const before =
          '# T\n\n<!-- generated:beta -->\nold\n<!-- /generated:beta -->\n';
      final after = regenerate(page, before, bodies).text;
      expect(after, isNot(before));
      expect(stripGeneratedBodies(after), stripGeneratedBodies(before));
    });

    test('leaves markers inside code fences alone', () {
      const markdown = '```text\n<!-- generated:alpha -->\nexample\n```\n';
      expect(stripGeneratedBodies(markdown), markdown);
    });

    test('accepts section names gen_docs does not know', () {
      expect(
        stripGeneratedBodies(
          '<!-- generated:gamma -->\nx\n<!-- /generated:gamma -->\n',
        ),
        '<!-- generated:gamma -->\n<!-- /generated:gamma -->\n',
      );
    });

    for (final (name, markdown) in [
      ('a section never closed', '<!-- generated:alpha -->\ntext\n'),
      ('an end marker without a start', '<!-- /generated:alpha -->\n'),
      (
        'mismatched markers',
        '<!-- generated:alpha -->\n<!-- /generated:beta -->\n',
      ),
      (
        'nested sections',
        '<!-- generated:alpha -->\n<!-- generated:beta -->\n'
            '<!-- /generated:alpha -->\n',
      ),
    ]) {
      test('is null for $name', () {
        expect(stripGeneratedBodies(markdown), isNull);
      });
    }
  });
}
