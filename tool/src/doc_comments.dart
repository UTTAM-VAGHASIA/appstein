/// The `///` doc comment directly above line [index] of [lines], without
/// the slashes, with its lines joined by `\n`. Annotation lines, such as
/// `@override`, between the comment and the declaration are skipped. Null
/// when there is no doc comment.
///
/// This reads source text rather than parsing it: `package:analyzer` would
/// make every guide check several seconds slower, and `dart format` keeps
/// doc comments in this layout.
String? docCommentAbove(List<String> lines, int index) {
  var i = index - 1;
  while (i >= 0 && lines[i].trimLeft().startsWith('@')) {
    i--;
  }
  final doc = <String>[];
  while (i >= 0 && lines[i].trimLeft().startsWith('///')) {
    final text = lines[i].trimLeft().substring(3);
    doc.add(text.startsWith(' ') ? text.substring(1) : text);
    i--;
  }
  return doc.isEmpty ? null : doc.reversed.join('\n');
}

/// The first paragraph of [doc] on one line, with `[Name]` references shown
/// as code and `|` escaped, so it fits in a Markdown table cell.
String firstParagraph(String doc) {
  final paragraph = <String>[];
  for (final line in doc.split('\n')) {
    if (line.trim().isEmpty) {
      if (paragraph.isNotEmpty) break;
      continue;
    }
    paragraph.add(line.trim());
  }
  return paragraph
      .join(' ')
      .replaceAllMapped(
        RegExp(r'\[([^\]]+)\](?!\()'),
        (match) => '`${match[1]}`',
      )
      .replaceAll('|', r'\|');
}
