import 'package:path/path.dart' as p;

final _lineBreaks = RegExp(r'[\r\n\t]+');
final _markup = RegExp(r'[\\|`*_\[\]<>]');
final _linkMarkup = RegExp(r'[\\|`*\[\]<>]');
final _backticks = RegExp('`+');

String _oneLine(String text) => text.replaceAll(_lineBreaks, ' ').trim();

/// [text] on one line, safe inside a table cell or a sentence of a
/// generated page (spec §6.9): line breaks and tabs become one space, and
/// `\`, `|`, `` ` ``, `*`, `_`, `[`, `]`, `<`, `>` and a leading `#` are
/// escaped with a backslash, so text from the app is never read as markup.
String mdText(String text) {
  final escaped = _oneLine(
    text,
  ).replaceAllMapped(_markup, (match) => '\\${match[0]}');
  return escaped.startsWith('#') ? '\\$escaped' : escaped;
}

/// [text] as inline code, on one line. The fence is one backtick longer
/// than the longest run of backticks in [text], and `|` becomes `\|` so a
/// table cell survives. An empty [text] gives an empty string.
String mdCode(String text) {
  final line = _oneLine(text);
  if (line.isEmpty) return '';
  var longest = 0;
  for (final run in _backticks.allMatches(line)) {
    final length = run.end - run.start;
    if (length > longest) longest = length;
  }
  final fence = '`' * (longest + 1);
  final pad = longest == 0 ? '' : ' ';
  return '$fence$pad${line.replaceAll('|', r'\|')}$pad$fence';
}

/// A Markdown table with [headers] and [rows], whose cells the caller
/// already escaped ([mdText], [mdCode]). It ends with a line break. Without
/// rows it is the empty string, so a caller can leave its heading out.
String mdTable(List<String> headers, List<List<String>> rows) {
  if (rows.isEmpty) return '';
  final buffer = StringBuffer()
    ..writeln('| ${headers.join(' | ')} |')
    ..writeln('|${'---|' * headers.length}');
  for (final row in rows) {
    buffer.writeln('| ${row.join(' | ')} |');
  }
  return buffer.toString();
}

/// [text] as a block quote, line by line, without the blank lines at its
/// start and end. A blank line inside it is `>`. Headings and comments in
/// [text] stay inside the quote.
String mdQuote(String text) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  while (lines.isNotEmpty && lines.first.trim().isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  return [
    for (final line in lines)
      line.trim().isEmpty ? '>' : '> ${line.trimRight()}',
  ].join('\n');
}

String _encodePath(String path) => [
  for (final segment in path.split('/'))
    segment == '..' || segment == '.'
        ? segment
        : Uri.encodeComponent(
            segment,
          ).replaceAll('(', '%28').replaceAll(')', '%29'),
].join('/');

/// A link from the page at [page] (its path inside the docs folder, with
/// `/`) to the project file [target] (its path from the project root, with
/// `/`), at [line] when given. [docsPath] is the docs folder from the
/// project root, such as `docs/app`.
///
/// The link's text is [text], or the target with its line. Each segment of
/// the address is percent-encoded, so a space or a `#` in a file name can't
/// break it.
String projectLink({
  required String docsPath,
  required String page,
  required String target,
  int? line,
  String? text,
}) {
  final from = p.posix.dirname(p.posix.join(docsPath, page));
  final address = _encodePath(p.posix.relative(target, from: from));
  final shown = text == null
      ? '$target${line == null ? '' : ':$line'}'.replaceAllMapped(
          _linkMarkup,
          (match) => '\\${match[0]}',
        )
      : mdText(text);
  return '[$shown]($address${line == null ? '' : '#L$line'})';
}

/// A link from the page at [page] to the page at [other], both paths inside
/// the docs folder with `/`, shown as [text].
String pageLink({
  required String page,
  required String other,
  required String text,
}) {
  final address = _encodePath(
    p.posix.relative(other, from: p.posix.dirname(page)),
  );
  return '[${mdText(text)}]($address)';
}

/// A Mermaid node id made of ASCII letters, digits and `_`, from [prefix]
/// and [index], such as `vm_0`. Names from the app are never ids: they go
/// in labels ([mermaidLabel]).
String mermaidId(String prefix, int index) => '${prefix}_$index';

/// [text] as a quoted Mermaid label: `"` becomes `#quot;`, `<` and `>`
/// become `#lt;` and `#gt;`, and line breaks become a space.
String mermaidLabel(String text) =>
    '"${_oneLine(text).replaceAll('"', '#quot;').replaceAll('<', '#lt;').replaceAll('>', '#gt;')}"';
