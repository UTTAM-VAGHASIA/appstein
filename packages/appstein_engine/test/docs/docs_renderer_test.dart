import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import 'support/docs_support.dart';

DocSection _readme(DocsKnowledge knowledge, List<RenderedPage> pages) =>
    DocSection(
      path: 'README.md',
      title: 'Home',
      markdown: [
        for (final page in pages) '- ${page.path}: ${page.title}',
      ].join('\n'),
    );

List<RenderedPage> _render(
  List<DocSource> sources, {
  DocSection Function(DocsKnowledge, List<RenderedPage>) readme = _readme,
}) =>
    renderPages(knowledge: sampleKnowledge(), sources: sources, readme: readme);

DocSource _source(String id, String version, List<DocSection> sections) =>
    (id: id, version: version, pages: [FakeDocPage(sections)]);

const _routes = DocSection(
  path: 'routes.md',
  title: 'Routes',
  markdown: '\n\nOne route.\n\n',
);

void main() {
  test('frames one section as a page, byte for byte', () {
    final page = _render([
      _source('official_mvvm', '2', const [_routes]),
    ]).singleWhere((page) => page.path == 'routes.md');
    const body =
        '$docNotice\n'
        '\n'
        '# Routes\n'
        '\n'
        'One route.\n';
    expect(page.title, 'Routes');
    expect(page.marker.templates, {'official_mvvm': '2'});
    expect(page.marker.body, bodyHash(body));
    expect(page.text, '${page.marker.line}\n$body');
    expect(DocMarker.of(page.text)!.body, bodyHash(bodyOf(page.text)));
  });

  test('joins the sections of several sources in order', () {
    final page = _render([
      _source('android', '3', const [
        DocSection(path: 'native.md', title: 'Native', markdown: '## Android'),
        DocSection(path: 'native.md', title: 'Other', markdown: 'More.'),
      ]),
      _source('ios', '2', const [
        DocSection(path: 'native.md', title: 'Else', markdown: '## iOS'),
      ]),
    ]).singleWhere((page) => page.path == 'native.md');
    expect(page.title, 'Native');
    expect(page.marker.templates, {'android': '3', 'ios': '2'});
    expect(page.marker.templates.keys, ['android', 'ios']);
    expect(
      bodyOf(page.text),
      '$docNotice\n\n# Native\n\n## Android\n\nMore.\n\n## iOS\n',
    );
  });

  test('pages are sorted by path, and the same input gives the same text', () {
    List<RenderedPage> render() => _render([
      _source('official_mvvm', '2', const [
        _routes,
        DocSection(path: 'features/b.md', title: 'B', markdown: 'b'),
        DocSection(path: 'architecture.md', title: 'A', markdown: 'a'),
        DocSection(path: 'features/a/x.md', title: 'X', markdown: 'x'),
      ]),
    ]);
    final first = render();
    expect(
      [for (final page in first) page.path],
      [
        'README.md',
        'architecture.md',
        'features/a/x.md',
        'features/b.md',
        'routes.md',
      ],
    );
    expect(
      [for (final page in render()) page.text],
      [for (final page in first) page.text],
    );
  });

  test('the README is rendered last, from the other pages, by the engine', () {
    final pages = _render([
      _source('official_mvvm', '2', const [
        _routes,
        DocSection(
          path: 'architecture.md',
          title: 'Architecture',
          markdown: 'a',
        ),
      ]),
    ]);
    final readme = pages.singleWhere((page) => page.path == 'README.md');
    expect(readme.marker.templates, {'engine': docsEngineVersion});
    expect(
      bodyOf(readme.text),
      '$docNotice\n\n# Home\n\n'
      '- architecture.md: Architecture\n- routes.md: Routes\n',
    );
  });

  test('a source with no sections is in no marker', () {
    final pages = _render([
      _source('android', '3', const []),
      _source('ios', '2', const [
        DocSection(path: 'native.md', title: 'Native', markdown: '## iOS'),
      ]),
    ]);
    expect(
      pages.singleWhere((page) => page.path == 'native.md').marker.templates,
      {'ios': '2'},
    );
  });

  test('a title from the project is escaped in the heading, once, by the '
      'frame', () {
    final page = _render([
      _source('official_mvvm', '2', const [
        DocSection(
          path: 'features/a.md',
          title: 'Feature: my_feature*2 # <x>',
          markdown: 'm',
        ),
      ]),
    ]).singleWhere((page) => page.path == 'features/a.md');
    expect(page.title, 'Feature: my_feature*2 # <x>');
    expect(
      page.text,
      contains(
        r'# Feature: my\_feature\*2 # \<x\>'
        '\n',
      ),
    );
  });

  group('pages that would be one file are refused, not rendered', () {
    // Names come from the project (feature folders), so this is something
    // its owner can fix: an exception with a message, not a page source bug.
    test('two paths that differ only in letter case', () {
      expect(
        () => _render([
          _source('official_mvvm', '2', const [
            DocSection(path: 'features/Home.md', title: 'T', markdown: 'm'),
            DocSection(path: 'features/home.md', title: 'T', markdown: 'm'),
          ]),
        ]),
        throwsA(
          isA<DocPagesCollide>()
              .having((e) => e.first, 'first', 'features/Home.md')
              .having((e) => e.second, 'second', 'features/home.md')
              .having(
                (e) => e.problem,
                'problem',
                'two pages would be the same file where letter case is '
                    'ignored (`features/Home.md` and `features/home.md`)',
              ),
        ),
      );
    });

    test('also across sources', () {
      expect(
        () => _render([
          _source('official_mvvm', '2', const [
            DocSection(path: 'Routes.md', title: 'T', markdown: 'm'),
          ]),
          _source('other', '1', const [_routes]),
        ]),
        throwsA(isA<DocPagesCollide>()),
      );
    });

    test('a page source that finds a collision itself is passed on as it '
        'is', () {
      const collision = DocPagesCollide(
        'features/a_b.md',
        'features/a_b.md',
        because: 'the features `a:b` and `a_b` would both be x',
      );
      expect(collision.problem, 'the features `a:b` and `a_b` would both be x');
      expect(
        () => _render([
          (
            id: 'official_mvvm',
            version: '2',
            pages: [const FakeDocPage([], failure: collision)],
          ),
        ]),
        throwsA(same(collision)),
      );
    });

    test('two sources may still share a page', () {
      final pages = _render([
        _source('android', '1', const [
          DocSection(path: 'native.md', title: 'Native', markdown: 'A.'),
        ]),
        _source('ios', '1', const [
          DocSection(path: 'native.md', title: 'Native', markdown: 'I.'),
        ]),
      ]);
      expect(pages.map((page) => page.path), ['README.md', 'native.md']);
    });
  });

  group('docFileName makes a name that is a file name on every system', () {
    test('keeps ordinary names', () {
      for (final name in ['login', 'my_feature-2', 'Ünïcode', 'a.b']) {
        expect(docFileName(name), name);
      }
    });

    test('replaces what Windows refuses in a file name', () {
      expect(docFileName('a:b'), 'a_b');
      expect(docFileName(r'a\b*c?d"e<f>g|h'), 'a_b_c_d_e_f_g_h');
      expect(docFileName('tab\there'), 'tab_here');
      expect(docFileName('dot.'), 'dot_');
      expect(docFileName('space '), 'space_');
      expect(docFileName('a/b'), 'a_b');
    });

    test('never gives a device name of Windows', () {
      expect(docFileName('con'), 'con_');
      expect(docFileName('NUL'), 'NUL_');
      expect(docFileName('com1'), 'com1_');
      expect(docFileName('console'), 'console');
    });

    test('never gives an empty name or a dot name', () {
      expect(docFileName(''), '_');
      expect(docFileName('.'), '_');
      expect(docFileName('..'), '._');
    });
  });

  group(
    'a page source that misbehaves is an error, and nothing is rendered',
    () {
      void fails(DocSection section, String message) {
        expect(
          () => _render([
            _source('official_mvvm', '2', [section]),
          ]),
          throwsA(
            isA<DocPageError>()
                .having((e) => e.source, 'source', 'official_mvvm')
                .having((e) => e.page, 'page', 'fake')
                .having((e) => e.message, 'message', contains(message)),
          ),
          reason: section.path,
        );
      }

      DocSection at(String path) =>
          DocSection(path: path, title: 'T', markdown: 'm');

      test('for a bad path', () {
        fails(at('README.md'), 'README.md');
        fails(at('readme.md'), 'README.md');
        fails(at('/routes.md'), 'path');
        fails(at('C:/routes.md'), 'path');
        fails(at('../routes.md'), 'path');
        fails(at('a/../routes.md'), 'path');
        fails(at(r'a\routes.md'), 'path');
        fails(at('a//routes.md'), 'path');
        fails(at('routes.txt'), 'path');
        fails(at('.md'), 'path');
        fails(at(''), 'path');
      });

      test('for an empty title or text', () {
        fails(
          const DocSection(path: 'a.md', title: ' ', markdown: 'm'),
          'title',
        );
        fails(
          const DocSection(path: 'a.md', title: 'T', markdown: ' \n'),
          'empty',
        );
      });

      test('for a title on more than one line', () {
        fails(
          const DocSection(path: 'a.md', title: 'T\nU', markdown: 'm'),
          'title',
        );
      });

      test('when it throws, keeping the cause', () {
        final cause = StateError('boom');
        expect(
          () => _render([
            (
              id: 'official_mvvm',
              version: '2',
              pages: [FakeDocPage(const [], id: 'features', failure: cause)],
            ),
          ]),
          throwsA(
            isA<DocPageError>()
                .having((e) => e.source, 'source', 'official_mvvm')
                .having((e) => e.page, 'page', 'features')
                .having((e) => e.cause, 'cause', same(cause))
                .having((e) => '$e', 'text', contains('boom')),
          ),
        );
      });

      test('when the README is not README.md', () {
        expect(
          () => _render(
            const [],
            readme: (_, _) =>
                const DocSection(path: 'home.md', title: 'T', markdown: 'm'),
          ),
          throwsA(isA<DocPageError>()),
        );
      });
    },
  );
}
