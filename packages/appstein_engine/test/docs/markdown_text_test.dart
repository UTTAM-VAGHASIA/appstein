import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  test('a Mermaid label keeps a # from starting an entity', () {
    expect(mermaidLabel('C#'), '"C#35;"');
    expect(mermaidLabel('a "b" <c>'), '"a #quot;b#quot; #lt;c#gt;"');
  });

  test('a link shows a file name with ~, \$ or & as it is', () {
    expect(
      projectLink(
        docsPath: 'docs',
        page: 'a.md',
        target: r'lib/$gen~1&co.dart',
      ),
      r'[lib/\$gen\~1&amp;co.dart](../lib/%24gen~1%26co.dart)',
    );
  });

  group('mdText', () {
    test('escapes what Markdown would read as markup', () {
      expect(mdText(r'a\b'), r'a\\b');
      expect(mdText('a|b'), r'a\|b');
      expect(mdText('a`b'), r'a\`b');
      expect(mdText('*a* _b_'), r'\*a\* \_b\_');
      expect(mdText('[x](y)'), r'\[x\](y)');
      expect(mdText('<br>'), r'\<br\>');
    });

    test('escapes entities, strike-through and math too', () {
      expect(mdText(r'a & b ~c~ $x$'), r'a &amp; b \~c\~ \$x\$');
      expect(mdText('&copy;'), '&amp;copy;');
    });

    test('a leading # is not a heading', () {
      expect(mdText('# x'), r'\# x');
      expect(mdText('a # b'), 'a # b');
    });

    test('puts several lines on one', () {
      expect(mdText('a\r\nb\n\nc\td'), 'a b c d');
      expect(mdText('  a  '), 'a');
    });

    test('leaves other text alone', () {
      expect(mdText('Zürich, 東京 (ok).'), 'Zürich, 東京 (ok).');
    });

    test('keeps a table row in its columns', () {
      final table = mdTable(
        ['A', 'B'],
        [
          [mdText('x|y'), mdText('z')],
        ],
      );
      final row = table.trimRight().split('\n').last;
      expect(row.replaceAll(r'\|', '').split('|').length, 4);
    });
  });

  group('mdCode', () {
    test('wraps plain text in backticks', () {
      expect(mdCode('lib/main.dart'), '`lib/main.dart`');
    });

    test('uses a longer fence around backticks', () {
      expect(mdCode('a`b'), '`` a`b ``');
      expect(mdCode('``'), '``` `` ```');
    });

    test('leaves a pipe alone: only a table needs it escaped', () {
      expect(mdCode('/a|b'), '`/a|b`');
    });

    test('puts several lines on one', () {
      expect(mdCode('a\nb'), '`a b`');
    });

    test('an empty text is no code at all', () {
      expect(mdCode(''), '');
    });
  });

  group('mdTable', () {
    test('writes the header, the separator and the rows', () {
      expect(
        mdTable(
          ['Class', 'File'],
          [
            ['A', 'a.dart'],
            ['B', 'b.dart'],
          ],
        ),
        '| Class | File |\n'
        '|---|---|\n'
        '| A | a.dart |\n'
        '| B | b.dart |\n',
      );
    });

    test('escapes the pipes in its cells, once', () {
      expect(
        mdTable(
          ['Path', 'Text'],
          [
            [mdCode('/a|b'), mdText('x|y')],
            ['a||b', r'\| c'],
          ],
        ),
        '| Path | Text |\n'
        '|---|---|\n'
        r'| `/a\|b` | x\|y |'
        '\n'
        r'| a\|\|b | \| c |'
        '\n',
      );
    });

    test('is empty without rows', () {
      expect(mdTable(['A'], const []), '');
    });
  });

  group('mdQuote', () {
    test('quotes each line', () {
      expect(mdQuote('one'), '> one');
      expect(mdQuote('one\n\nthree\r\nfour'), '> one\n>\n> three\n> four');
    });

    test('keeps a heading and a marker inside the quote', () {
      expect(
        mdQuote('# big\n<!-- appstein:generated x -->'),
        '> # big\n> <!-- appstein:generated x -->',
      );
    });

    test('drops blank lines at both ends', () {
      expect(mdQuote('\n\na\n\n'), '> a');
    });
  });

  group('projectLink', () {
    test('climbs out of the docs folder', () {
      expect(
        projectLink(
          docsPath: 'docs/app',
          page: 'README.md',
          target: 'lib/main.dart',
        ),
        '[lib/main.dart](../../lib/main.dart)',
      );
    });

    test('climbs out of a nested page too', () {
      expect(
        projectLink(
          docsPath: 'docs/app',
          page: 'features/auth/login.md',
          target: 'lib/ui/auth/login/widgets/login_screen.dart',
          line: 8,
        ),
        '[lib/ui/auth/login/widgets/login_screen.dart:8]'
        '(../../../../lib/ui/auth/login/widgets/login_screen.dart#L8)',
      );
    });

    test('follows the docs path', () {
      expect(
        projectLink(docsPath: 'docs', page: 'a.md', target: 'lib/x.dart'),
        '[lib/x.dart](../lib/x.dart)',
      );
      expect(
        projectLink(docsPath: 'a/b/c', page: 'a.md', target: 'lib/x.dart'),
        '[lib/x.dart](../../../lib/x.dart)',
      );
    });

    test('encodes what a link would misread', () {
      expect(
        projectLink(
          docsPath: 'docs/app',
          page: 'a.md',
          target: 'lib/my file#1 (x).dart',
        ),
        r'[lib/my file#1 (x).dart](../../lib/my%20file%231%20%28x%29.dart)',
      );
    });

    test('takes its own text', () {
      expect(
        projectLink(
          docsPath: 'docs/app',
          page: 'a.md',
          target: 'lib/x.dart',
          line: 3,
          text: 'here',
        ),
        '[here](../../lib/x.dart#L3)',
      );
    });
  });

  group('pageLink', () {
    test('links from the top to a nested page and back', () {
      expect(
        pageLink(
          page: 'README.md',
          other: 'features/auth/login.md',
          text: 'auth/login',
        ),
        '[auth/login](features/auth/login.md)',
      );
      expect(
        pageLink(
          page: 'features/auth/login.md',
          other: 'README.md',
          text: 'Home',
        ),
        '[Home](../../README.md)',
      );
    });

    test('links between pages in different folders', () {
      expect(
        pageLink(
          page: 'features/auth/login.md',
          other: 'features/home.md',
          text: 'home',
        ),
        '[home](../home.md)',
      );
    });

    test('encodes a space and escapes the text', () {
      expect(
        pageLink(page: 'README.md', other: 'my notes/a b.md', text: 'a|b'),
        r'[a\|b](my%20notes/a%20b.md)',
      );
    });
  });

  group('mermaid', () {
    test('ids are plain', () {
      expect(mermaidId('vm', 0), 'vm_0');
    });

    test('labels are quoted and safe', () {
      expect(mermaidLabel('Home'), '"Home"');
      expect(mermaidLabel('a "b" <c>\nd'), '"a #quot;b#quot; #lt;c#gt; d"');
    });
  });
}
