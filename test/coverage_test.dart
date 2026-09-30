import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/coverage.dart';
import 'support/temp_repo.dart';

const uncovered =
    'No guide page covers this file. Add it to the covers comment of the '
    'page that explains it.';

void main() {
  group('parseCovers', () {
    test('reads globs split by spaces, commas and lines', () {
      final covers = parseCovers(
        '<!-- covers:\npackages/a/lib/**, tool/x.dart\n'
        '  .github/workflows/**\n-->\n# Title\n',
      )!;
      expect(covers.globs, [
        'packages/a/lib/**',
        'tool/x.dart',
        '.github/workflows/**',
      ]);
      expect(covers.line, 1);
    });

    test('reads a one-line comment after blank lines, and `none`', () {
      final covers = parseCovers('\n\n<!-- covers: none -->\n# Title\n')!;
      expect(covers.globs, isEmpty);
      expect(covers.line, 3);
    });

    test('accepts CRLF line endings', () {
      expect(parseCovers('<!-- covers:\r\ntool/**\r\n-->\r\n# T\r\n')!.globs, [
        'tool/**',
      ]);
    });

    test('returns null without a comment, ignoring examples in code '
        'fences', () {
      expect(
        parseCovers('# Title\n```text\n<!-- covers: tool/** -->\n```\n'),
        isNull,
      );
    });

    for (final (name, markdown, message) in [
      (
        'not first',
        '# Title\n<!-- covers: tool/** -->\n',
        'must be the first line',
      ),
      (
        'repeated',
        '<!-- covers: tool/** -->\n<!-- covers: none -->\n',
        'only one covers comment',
      ),
      ('never closed', '<!-- covers: tool/**\n# Title\n', 'never closed'),
      ('empty', '<!-- covers: -->\n', 'or write `none`'),
      ('none with paths', '<!-- covers: none tool/** -->\n', "can't be"),
      ('using backslashes', '<!-- covers: tool\\x.dart -->\n', 'forward'),
      ('absolute', '<!-- covers: /tool/** -->\n', 'forward slashes'),
      ('on a drive', '<!-- covers: C:/tool/** -->\n', 'forward slashes'),
      ('above the repo', '<!-- covers: ../tool/** -->\n', 'forward slashes'),
      (
        'followed by text',
        '<!-- covers: tool/** --> # Title\n',
        'Nothing may follow',
      ),
    ]) {
      test('rejects a comment that is $name', () {
        expect(
          () => parseCovers(markdown),
          throwsA(
            isA<CoversException>().having(
              (e) => e.message,
              'message',
              contains(message),
            ),
          ),
        );
      });
    }
  });

  group('the cover map', () {
    test('pagesCovering lists every page whose globs match, sorted', () {
      final map = CoverMap({
        'docs/guide/z.md': const CoversComment(['packages/*/lib/**'], 1),
        'docs/guide/a.md': const CoversComment([
          'packages/engine/lib/src/sdk/**',
        ], 1),
      });
      expect(map.pagesCovering('packages/engine/lib/src/sdk/fvm.dart'), [
        'docs/guide/a.md',
        'docs/guide/z.md',
      ]);
      expect(map.pagesCovering('tool/x.dart'), isEmpty);
    });

    test('readCoverMap reports pages without a comment or with a bad '
        'one', () {
      final Directory dir = tempFolder();
      writeFile(dir, 'docs/guide/a.md', '<!-- covers: tool/** -->\n# A\n');
      writeFile(dir, 'docs/guide/b.md', '# B\n');
      writeFile(dir, 'docs/guide/c.md', '# C\n<!-- covers: tool/** -->\n');
      final result = readCoverMap(dir.path, [
        'docs/guide/a.md',
        'docs/guide/b.md',
        'docs/guide/c.md',
      ]);
      expect(result.map.pages.keys, ['docs/guide/a.md']);
      expect(result.problems.map((problem) => '$problem'), [
        'docs/guide/b.md:1: Start the page with a covers comment: '
            '<!-- covers: <paths> --> or <!-- covers: none -->.',
        'docs/guide/c.md:2: The covers comment must be the first line of '
            'the page.',
      ]);
    });

    test('checkCoverage reports uncovered source files and globs that '
        'match nothing', () {
      final map = CoverMap({
        'docs/guide/a.md': const CoversComment([
          'packages/*/lib/src/sdk/**',
          'tool/gone.dart',
        ], 1),
        'docs/guide/b.md': const CoversComment([], 1),
      });
      final problems = checkCoverage(map, [
        '.github/workflows/ci.yml',
        'README.md',
        'packages/engine/lib/src/sdk/fvm.dart',
        'packages/engine/lib/src/host/runner.dart',
        'packages/engine/test/sdk_test.dart',
        'packages/cli/bin/cli.dart',
      ]);
      expect(problems.map((problem) => '$problem'), [
        'docs/guide/a.md:1: Covers tool/gone.dart, which matches no file.',
        '.github/workflows/ci.yml: $uncovered',
        'packages/engine/lib/src/host/runner.dart: $uncovered',
        'packages/cli/bin/cli.dart: $uncovered',
      ]);
    });
  });
}
