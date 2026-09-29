/// The first non-empty line of [text], trimmed. Tools often print their
/// version on the first line.
String firstLine(String text) {
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}
