import 'plist_value.dart';

/// Reads an Xcode project file (`project.pbxproj`), written in the old
/// "OpenStep" property list format, keeping each value's line.
///
/// Throws a [PlistFormatException] when the text isn't in that format.
/// Xcode can also read a JSON project, but it never writes one.
PlistDict readPbxproj(String text) {
  final reader = _OpenStepReader(text)..skipSpace();
  if (!reader.at('{')) {
    throw PlistFormatException("not in Xcode's text format", reader.line);
  }
  final root = reader.value() as PlistDict;
  reader.skipSpace();
  if (!reader.done) {
    throw PlistFormatException(
      'text after the end of the project',
      reader.line,
    );
  }
  return root;
}

final class _OpenStepReader {
  _OpenStepReader(this.source);

  final String source;
  var _i = 0;
  var line = 1;

  bool get done => _i >= source.length;

  bool at(String char) => _i < source.length && source[_i] == char;

  void skipSpace() {
    while (_i < source.length) {
      final c = source.codeUnitAt(_i);
      if (c == 0x0A) {
        line++;
        _i++;
      } else if (c == 0x20 || c == 0x09 || c == 0x0D) {
        _i++;
      } else if (source.startsWith('//', _i)) {
        while (_i < source.length && source.codeUnitAt(_i) != 0x0A) {
          _i++;
        }
      } else if (source.startsWith('/*', _i)) {
        final end = source.indexOf('*/', _i + 2);
        if (end < 0) {
          throw PlistFormatException('a comment is never closed', line);
        }
        for (var k = _i; k < end; k++) {
          if (source.codeUnitAt(k) == 0x0A) line++;
        }
        _i = end + 2;
      } else {
        return;
      }
    }
  }

  void _expect(String char) {
    skipSpace();
    if (!at(char)) {
      throw PlistFormatException(
        done
            ? 'the project ends early'
            : 'expected "$char" but found "${source[_i]}"',
        line,
      );
    }
    _i++;
  }

  PlistValue value() {
    skipSpace();
    if (done) throw PlistFormatException('the project ends early', line);
    final start = line;
    if (at('{')) {
      _i++;
      final entries = <String, PlistValue>{};
      final keyLines = <String, int>{};
      while (true) {
        skipSpace();
        if (at('}')) {
          _i++;
          return PlistDict(entries, keyLines, start);
        }
        final keyLine = line;
        final key = _string();
        _expect('=');
        entries[key] = value();
        keyLines[key] = keyLine;
        _expect(';');
      }
    }
    if (at('(')) {
      _i++;
      final items = <PlistValue>[];
      while (true) {
        skipSpace();
        if (at(')')) {
          _i++;
          return PlistArray(items, start);
        }
        items.add(value());
        skipSpace();
        if (at(',')) {
          _i++;
        } else if (!at(')')) {
          throw PlistFormatException('expected "," or ")"', line);
        }
      }
    }
    return PlistString(_string(), start);
  }

  String _string() {
    skipSpace();
    if (done) throw PlistFormatException('the project ends early', line);
    if (at('"')) return _quoted();
    final start = _i;
    while (_i < source.length && !_endsBare(source.codeUnitAt(_i))) {
      _i++;
    }
    if (_i == start) {
      throw PlistFormatException('unexpected "${source[_i]}"', line);
    }
    return source.substring(start, _i);
  }

  static bool _endsBare(int c) =>
      c == 0x20 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0D ||
      '{}();,="'.codeUnits.contains(c);

  String _quoted() {
    final startLine = line;
    _i++;
    final out = StringBuffer();
    while (true) {
      if (_i >= source.length) {
        throw PlistFormatException('a string is never closed', startLine);
      }
      final c = source[_i];
      if (c == '"') {
        _i++;
        return out.toString();
      }
      if (c == r'\' && _i + 1 < source.length) {
        final escaped = source[_i + 1];
        _i += 2;
        if (escaped == 'U' && _i + 4 <= source.length) {
          final code = int.tryParse(source.substring(_i, _i + 4), radix: 16);
          if (code != null) {
            out.writeCharCode(code);
            _i += 4;
            continue;
          }
        }
        out.write(switch (escaped) {
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          _ => escaped,
        });
        continue;
      }
      if (c == '\n') line++;
      out.write(c);
      _i++;
    }
  }
}
