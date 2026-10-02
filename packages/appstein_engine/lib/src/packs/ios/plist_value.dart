/// A value of a property list (`Info.plist`, `project.pbxproj`), with the
/// 1-based line it starts on.
sealed class PlistValue {
  const PlistValue(this.line);

  /// The line it starts on.
  final int line;
}

/// A string.
final class PlistString extends PlistValue {
  /// Creates the value.
  const PlistString(this.value, super.line);

  /// The text, with entities and escapes decoded.
  final String value;
}

/// `<true/>` or `<false/>`.
final class PlistBool extends PlistValue {
  /// Creates the value.
  const PlistBool(this.value, super.line);

  /// The boolean.
  final bool value;
}

/// An `<integer>`, `<real>`, `<date>` or `<data>`, kept as written.
final class PlistOther extends PlistValue {
  /// Creates the value.
  const PlistOther(this.kind, this.text, super.line);

  /// The element's name, such as `integer`.
  final String kind;

  /// Its text, trimmed.
  final String text;
}

/// An array.
final class PlistArray extends PlistValue {
  /// Creates the value.
  const PlistArray(this.items, super.line);

  /// The items, in order.
  final List<PlistValue> items;
}

/// A dictionary.
final class PlistDict extends PlistValue {
  /// Creates the value.
  const PlistDict(this.entries, this.keyLines, super.line);

  /// The values, by key, in file order.
  final Map<String, PlistValue> entries;

  /// The line of each key.
  final Map<String, int> keyLines;
}

/// A property list Appstein can't read.
final class PlistFormatException implements Exception {
  /// Creates the exception.
  const PlistFormatException(this.message, [this.line]);

  /// What is wrong.
  final String message;

  /// The 1-based line, when known.
  final int? line;

  @override
  String toString() => line == null ? message : 'line $line: $message';
}
