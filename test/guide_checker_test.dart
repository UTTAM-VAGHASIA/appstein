import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/guide_checker.dart';

void main() {
  late Directory repo;

  setUp(() {
    repo = Directory.systemTemp.createTempSync('appstein guide tëst ');
    addTearDown(() => repo.deleteSync(recursive: true));
    Directory(p.join(repo.path, 'docs', 'guide')).createSync(recursive: true);
    Directory(
      p.join(repo.path, 'packages', 'appstein_cli', 'bin'),
    ).createSync(recursive: true);
    File(
      p.join(repo.path, 'packages', 'appstein_cli', 'README.md'),
    ).writeAsStringSync('# cli\n');
  });

  List<String> check(String markdown) {
    File(
      p.join(repo.path, 'docs', 'guide', 'page.md'),
    ).writeAsStringSync(markdown);
    return [
      for (final problem in checkMarkdown(
        repo.path,
        p.join('docs', 'guide', 'page.md'),
      ))
        '${problem.line}: ${problem.message}',
    ];
  }

  test('accepts good links, existing paths and non-Dart code blocks', () {
    expect(
      check(
        'See [the CLI](../../packages/appstein_cli/README.md#top) and '
        '`packages/appstein_cli/bin/` and [web](https://dart.dev).\n'
        '```powershell\nfvm dart test\n```\n',
      ),
      isEmpty,
    );
  });

  test('reports broken links and missing paths with line numbers', () {
    expect(check('# Title\n[x](missing.md)\n`packages/nope/lib/`\n'), [
      '2: Broken link: missing.md',
      '3: Path does not exist: packages/nope/lib/',
    ]);
  });

  test('refuses Dart code blocks until snippet analysis exists', () {
    expect(
      check('```dart\nvoid main() {}\n```\n').single,
      contains('Dart code blocks are not analyzed yet'),
    );
  });

  test('ignores links and paths inside code blocks', () {
    expect(check('```text\n[x](missing.md) `packages/nope/`\n```\n'), isEmpty);
  });

  test('a problem about a whole file has no line number', () {
    expect('${const GuideProblem('a.md', null, 'x')}', 'a.md: x');
    expect('${const GuideProblem('a.md', 3, 'x')}', 'a.md:3: x');
  });

  test('covers the guide and every package README', () {
    File(p.join(repo.path, 'docs', 'guide', 'page.md')).writeAsStringSync('');
    expect(guideFiles(repo.path), [
      'docs/guide/page.md',
      'packages/appstein_cli/README.md',
    ]);
  });

  test('toPosix writes a relative path with forward slashes', () {
    expect(toPosix(p.join('a', 'b')), 'a/b');
  });

  group('checkLinked', () {
    void page(String path, String text) => File(p.join(repo.path, path))
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
}
