import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';

/// [markdown] with [meta] in a YAML front matter block before it (spec
/// §6.2): `---`, one `key: value` line per field in key order, `---`, a
/// blank line, then the text.
///
/// Each value is written as JSON, which is also valid YAML; the quotes keep
/// `generatedAt` a string for YAML readers that know timestamps. Line ends
/// are `\n`, and the text ends with exactly one `\n`.
String markdownWithFrontMatter(String markdown, KnowledgeMeta meta) {
  final fields = meta.toJson();
  final keys = fields.keys.toList()..sort();
  final buffer = StringBuffer('---\n');
  for (final key in keys) {
    buffer.writeln('$key: ${jsonEncode(fields[key])}');
  }
  buffer
    ..write('---\n\n')
    ..write(markdown.replaceAll('\r\n', '\n').trimRight())
    ..write('\n');
  return buffer.toString();
}

/// The metadata in the front matter of a generated Markdown [text], as
/// [markdownWithFrontMatter] writes it, or null when the text has none or
/// it is damaged.
KnowledgeMeta? readFrontMatter(String text) {
  if (!text.startsWith('---\n')) return null;
  final end = text.indexOf('\n---\n', 3);
  if (end < 4) return null;
  final fields = <String, Object?>{};
  for (final line in text.substring(4, end).split('\n')) {
    final colon = line.indexOf(': ');
    if (colon <= 0) return null;
    try {
      fields[line.substring(0, colon)] = jsonDecode(line.substring(colon + 2));
    } on FormatException {
      return null;
    }
  }
  try {
    return KnowledgeMeta.fromJson(fields, file: 'front matter');
  } on FormatException {
    return null;
  }
}
