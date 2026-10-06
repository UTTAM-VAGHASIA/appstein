/// [text] without a leading byte order mark (Windows PowerShell 5.1 writes
/// one).
String withoutBom(String text) =>
    text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? text.substring(1) : text;

/// [text] with each run of white space, line breaks included, as one space.
String oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// [text], or its first [max] - 1 characters and `…` when it is longer. It
/// counts runes, so a character outside the Basic Multilingual Plane is
/// never split.
String capText(String text, int max) {
  final runes = text.runes.toList();
  if (runes.length <= max) return text;
  return '${String.fromCharCodes(runes.take(max - 1)).trimRight()}…';
}
