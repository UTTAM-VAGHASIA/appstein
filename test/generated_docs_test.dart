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
    expect(result.problems, hasLength(1));
    expect(result.problems.single.file, 'tool/src/generators.dart');
    expect(result.problems.single.message, contains('exit_codes.dart'));
    expect(result.changedPages, isEmpty);
  });

  group('regenerateVisualPage', () {
    const sections = {'progress-status': '<a>S</a>', 'progress': '<ol></ol>'};
    const page =
        '<header>\n'
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
}
