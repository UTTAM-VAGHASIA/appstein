/// One entry of a Java `.properties` file.
final class PropertiesEntry {
  /// Creates the entry.
  const PropertiesEntry(this.value, this.line);

  /// The value, with its escapes decoded.
  final String value;

  /// The 1-based line its key is on.
  final int line;
}

/// Reads a `.properties` file the way Java's `Properties.load` does. Gradle
/// reads `gradle.properties` and `gradle-wrapper.properties` with it:
/// - `#` and `!` start comment lines;
/// - `=`, `:` or white space separates a key from its value;
/// - a line ending in an odd number of `\` goes on to the next line;
/// - `\t`, `\n`, `\r`, `\f` and `\uXXXX` are decoded, and `\` before any
///   other character keeps that character.
///
/// A key set twice keeps its last value, as in Java.
Map<String, PropertiesEntry> readProperties(String text) {
  final lines = text.split(RegExp(r'\r\n|\r|\n'));
  final entries = <String, PropertiesEntry>{};
  for (var i = 0; i < lines.length; i++) {
    final first = i;
    var line = _trimStart(lines[i]);
    if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) continue;
    while (_continues(line) && i + 1 < lines.length) {
      i++;
      line = line.substring(0, line.length - 1) + _trimStart(lines[i]);
    }
    if (_continues(line)) line = line.substring(0, line.length - 1);
    final (key, value) = _split(line);
    entries.remove(_unescape(key));
    entries[_unescape(key)] = PropertiesEntry(_unescape(value), first + 1);
  }
  return entries;
}

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\f';

String _trimStart(String line) {
  var i = 0;
  while (i < line.length && _isSpace(line[i])) {
    i++;
  }
  return line.substring(i);
}

bool _continues(String line) {
  var slashes = 0;
  for (var i = line.length - 1; i >= 0 && line[i] == r'\'; i--) {
    slashes++;
  }
  return slashes.isOdd;
}

(String, String) _split(String line) {
  var i = 0;
  while (i < line.length) {
    final c = line[i];
    if (c == r'\') {
      i += 2;
      continue;
    }
    if (c == '=' || c == ':' || _isSpace(c)) break;
    i++;
  }
  final end = i < line.length ? i : line.length;
  var j = end;
  while (j < line.length && _isSpace(line[j])) {
    j++;
  }
  if (j < line.length && (line[j] == '=' || line[j] == ':')) {
    j++;
    while (j < line.length && _isSpace(line[j])) {
      j++;
    }
  }
  return (line.substring(0, end), line.substring(j));
}

String _unescape(String text) {
  if (!text.contains(r'\')) return text;
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c != r'\' || i + 1 >= text.length) {
      out.write(c);
      continue;
    }
    final next = text[++i];
    if (next == 'u' && i + 4 < text.length) {
      final code = int.tryParse(text.substring(i + 1, i + 5), radix: 16);
      if (code != null) {
        out.writeCharCode(code);
        i += 4;
        continue;
      }
    }
    out.write(switch (next) {
      't' => '\t',
      'n' => '\n',
      'r' => '\r',
      'f' => '\f',
      _ => next,
    });
  }
  return out.toString();
}
