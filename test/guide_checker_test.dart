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

  test('covers the guide and every package README', () {
    File(p.join(repo.path, 'docs', 'guide', 'page.md')).writeAsStringSync('');
    expect(guideFiles(repo.path), [
      p.join('docs', 'guide', 'page.md'),
      p.join('packages', 'appstein_cli', 'README.md'),
    ]);
  });
}
