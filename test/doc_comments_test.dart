import 'package:test/test.dart';

import '../tool/src/doc_comments.dart';

void main() {
  test('docCommentAbove reads the /// lines above a declaration, skipping '
      'annotations', () {
    final lines = [
      "import 'x.dart';",
      '',
      '/// Checks the JDK.',
      '///',
      '/// More detail.',
      '@immutable',
      'final class A {',
    ];
    expect(docCommentAbove(lines, 6), 'Checks the JDK.\n\nMore detail.');
  });

  test('docCommentAbove is null without a doc comment', () {
    expect(docCommentAbove(['// plain comment', 'class A {}'], 1), isNull);
  });

  test('firstParagraph joins the first paragraph, shows references as code '
      'and escapes pipes', () {
    expect(
      firstParagraph('Finds [JavaLocation] via\n`a|b` and [link](x).\n\nMore.'),
      r'Finds `JavaLocation` via `a\|b` and [link](x).',
    );
  });
}
