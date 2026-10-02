import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../../native/native_files.dart';
import 'plist_value.dart';

const _leaves = {
  'key', 'string', 'integer', 'real', 'date', 'data', 'true', 'false', //
};

/// Reads an XML property list such as `Info.plist`, keeping each value's
/// line.
///
/// Throws a [PlistFormatException] for a binary property list, text that
/// isn't well-formed XML, or a property list whose root isn't a `<dict>`.
PlistDict readXmlPlist(String text) {
  if (text.startsWith('bplist')) {
    throw const PlistFormatException(
      "a binary property list, which Appstein doesn't read",
    );
  }
  // XML turns `\r\n` and a lone `\r` into `\n` before anything else (XML 1.0
  // §2.11), so a multi-line value reads the same under any checkout
  // (spec §15). A `&#13;` reference is still a `\r`: it is decoded later.
  final xml = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final builder = _PlistBuilder(xml);
  try {
    for (final event in parseEvents(
      xml,
      withLocation: true,
      validateNesting: true,
      validateDocument: true,
    )) {
      builder.add(event);
    }
  } on XmlParserException catch (error) {
    throw PlistFormatException(
      'not valid XML: ${error.message}',
      error.line > 0 ? error.line : null,
    );
  } on XmlTagException catch (error) {
    throw PlistFormatException(
      'not valid XML: ${error.message}',
      error.line > 0 ? error.line : null,
    );
  } on XmlException catch (error) {
    throw PlistFormatException('not valid XML: ${error.message}');
  }
  final root = builder.root;
  if (root is! PlistDict) {
    throw const PlistFormatException(
      'the property list has no <dict> at its root',
    );
  }
  return root;
}

/// An element being read.
final class _Open {
  _Open(this.name, this.line);

  final String name;
  final int line;
  final items = <PlistValue>[];
  final entries = <String, PlistValue>{};
  final keyLines = <String, int>{};
  final text = StringBuffer();

  /// In a dict: the key waiting for its value, and its line.
  String? key;
  int? keyLine;
}

final class _PlistBuilder {
  _PlistBuilder(this.source);

  final String source;
  final _stack = <_Open>[];
  PlistValue? root;
  var _sawPlist = false;

  void add(XmlEvent event) {
    switch (event) {
      case XmlStartElementEvent(:final name, :final isSelfClosing):
        final line = lineAt(source, event.start!);
        if (name == 'plist') {
          if (_sawPlist) {
            throw PlistFormatException('a second <plist>', line);
          }
          _sawPlist = true;
        } else if (_stack.isEmpty) {
          throw PlistFormatException('<$name> outside <plist>', line);
        } else if (!_leaves.contains(name) &&
            name != 'dict' &&
            name != 'array') {
          throw PlistFormatException('unexpected <$name>', line);
        } else if (_leaves.contains(_stack.last.name)) {
          throw PlistFormatException(
            '<$name> inside <${_stack.last.name}>',
            line,
          );
        }
        _stack.add(_Open(name, line));
        if (isSelfClosing) _close();
      case XmlEndElementEvent():
        _close();
      case XmlTextEvent(:final value) || XmlCDATAEvent(:final value):
        if (_stack.isNotEmpty) _stack.last.text.write(value);
      default:
        break;
    }
  }

  void _close() {
    final open = _stack.removeLast();
    if (open.name == 'plist') {
      if (open.items.length != 1) {
        throw PlistFormatException(
          '<plist> must hold exactly one value',
          open.line,
        );
      }
      root = open.items.single;
      return;
    }
    final parent = _stack.last;
    if (open.name == 'key') {
      if (parent.name != 'dict') {
        throw PlistFormatException('<key> outside <dict>', open.line);
      }
      if (parent.key != null) {
        throw PlistFormatException(
          'the key "${parent.key}" has no value',
          parent.keyLine,
        );
      }
      parent
        ..key = open.text.toString()
        ..keyLine = open.line;
      return;
    }
    final PlistValue value;
    switch (open.name) {
      case 'dict':
        if (open.key != null) {
          throw PlistFormatException(
            'the key "${open.key}" has no value',
            open.keyLine,
          );
        }
        value = PlistDict(
          Map.unmodifiable(open.entries),
          Map.unmodifiable(open.keyLines),
          open.line,
        );
      case 'array':
        value = PlistArray(List.unmodifiable(open.items), open.line);
      case 'string':
        value = PlistString(open.text.toString(), open.line);
      case 'true' || 'false':
        value = PlistBool(open.name == 'true', open.line);
      default:
        value = PlistOther(open.name, open.text.toString().trim(), open.line);
    }
    if (parent.name == 'dict') {
      final key = parent.key;
      if (key == null) {
        throw PlistFormatException('a value without a <key>', open.line);
      }
      parent.entries[key] = value;
      parent.keyLines[key] = parent.keyLine!;
      parent
        ..key = null
        ..keyLine = null;
    } else {
      parent.items.add(value);
    }
  }
}
