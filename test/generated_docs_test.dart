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
    expect(result.problems, isNotEmpty);
    expect(result.changedPages, isEmpty);
  });
}
