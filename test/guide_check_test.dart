import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/guide_check.dart';
import 'support/temp_repo.dart';

void main() {
  test('reports a --since that is not a commit instead of crashing', () async {
    final repo = tempRepo();
    writeFile(repo, 'docs/guide/README.md', '<!-- covers: none -->\n# G\n');
    runGit(repo, ['add', '.']);
    runGit(repo, ['commit', '-q', '-m', 'first']);
    final problems = await checkGuide(repo.path, since: 'nope');
    expect(
      problems.map((problem) => '$problem'),
      contains('--since: nope is not a commit.'),
    );
  });

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

  group('the stale-page check, end to end', () {
    const page = 'docs/guide/README.md';
    const pageText = '<!-- covers: tool/a.dart -->\n# G\n';
    const staleA =
        'tool/a.dart: Changed, but the page that explains it did not: '
        'docs/guide/README.md. Update the page, or if it is still right, add '
        'a commit trailer: Docs-Checked: README.md - <why it is still right>';

    // The temp repo has none of Appstein's generated facts, so the
    // generated-section check reports problems there; keep only the
    // stale-page ones.
    Future<List<String>> stale(String repoRoot) async => [
      for (final problem in await checkGuide(repoRoot, since: 'main'))
        if (problem.message.startsWith('Changed, but') ||
            problem.file == 'commit message')
          '$problem',
    ];

    late Directory repo;

    // main has the page and the file it covers; the branch feature changes
    // the file.
    setUp(() async {
      repo = tempRepo();
      writeFile(repo, page, pageText);
      writeFile(repo, 'tool/a.dart', '// a\n');
      runGit(repo, ['add', '.']);
      runGit(repo, ['commit', '-q', '-m', 'first']);
      runGit(repo, ['switch', '-q', '-c', 'feature']);
      writeFile(repo, 'tool/a.dart', '// a, changed\n');
      expect(await stale(repo.path), [staleA]);
    });

    test('an edit to the covering page clears it', () async {
      writeFile(repo, page, '$pageText\nNow explains the change.\n');
      expect(await stale(repo.path), isEmpty);
    });

    test('a Docs-Checked trailer naming the page clears it', () async {
      runGit(repo, ['add', 'tool/a.dart']);
      runGit(repo, [
        'commit',
        '-q',
        '-m',
        'Change a\n\nDocs-Checked: README.md - the page is still right',
      ]);
      expect(await stale(repo.path), isEmpty);
    });
  });

  group('a page whose only change is a regenerated section', () {
    const page = 'docs/guide/README.md';
    const covers = '<!-- covers: tool/a.dart -->\n# G\n\n';
    const staleA =
        'tool/a.dart: Changed, but the page that explains it did not: '
        'docs/guide/README.md. Update the page, or if it is still right, add '
        'a commit trailer: Docs-Checked: README.md - <why it is still right>';

    String section(String body) =>
        '<!-- generated:facts -->\n\n$body\n\n<!-- /generated:facts -->\n';

    // Only the stale-page problems; the temp repo has none of Appstein's
    // generated facts, so the generated-section check complains too.
    Future<List<String>> stale(String repoRoot) async => [
      for (final problem in await checkGuide(repoRoot, since: 'main'))
        if (problem.message.startsWith('Changed, but') ||
            problem.file == 'commit message')
          '$problem',
    ];

    late Directory repo;

    setUp(() {
      repo = tempRepo();
      writeFile(repo, page, '$covers${section('old fact')}');
      writeFile(repo, 'tool/a.dart', '// a\n');
      runGit(repo, ['add', '.']);
      runGit(repo, ['commit', '-q', '-m', 'first']);
      runGit(repo, ['switch', '-q', '-c', 'feature']);
      writeFile(repo, 'tool/a.dart', '// a, changed\n');
    });

    test('does not clear the stale check', () async {
      writeFile(repo, page, '$covers${section('new fact')}');
      expect(await stale(repo.path), [staleA]);
    });

    // Review Focus 5.
    test('does not clear it with CRLF line endings either', () async {
      writeFile(
        repo,
        page,
        '$covers${section('new fact')}'.replaceAll('\n', '\r\n'),
      );
      expect(await stale(repo.path), [staleA]);
    });

    test('a hand-written change next to it clears it', () async {
      writeFile(
        repo,
        page,
        '$covers${section('new fact')}\nExplains the change.\n',
      );
      expect(await stale(repo.path), isEmpty);
    });

    test('a page with broken markers counts as changed', () async {
      writeFile(repo, page, '$covers<!-- generated:facts -->\n\nnew fact\n');
      expect(await stale(repo.path), isEmpty);
    });

    test('a page that is new since the merge base counts as changed', () async {
      writeFile(
        repo,
        'docs/guide/new.md',
        '<!-- covers: tool/a.dart -->\n# New\n',
      );
      expect(await stale(repo.path), isEmpty);
    });
  });
}
