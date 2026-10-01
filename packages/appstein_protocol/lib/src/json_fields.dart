/// Reads typed fields from a decoded JSON object, with errors that name the
/// file and the key, so a damaged `.appstein/` file or curated note is
/// reported clearly.
final class JsonFields {
  /// Wraps [json], which was read from [file] (such as `sdk.json`).
  const JsonFields(this.file, this.json);

  /// The file named in error messages.
  final String file;

  /// The decoded object.
  final Map<String, Object?> json;

  /// The string at [key].
  ///
  /// Throws a [FormatException] when it is missing or not a string.
  String string(String key) => switch (json[key]) {
    final String value => value,
    _ => throw _wrong(key, 'a string'),
  };

  /// The string at [key], or null when it is missing or null.
  String? optionalString(String key) => switch (json[key]) {
    null => null,
    final String value => value,
    _ => throw _wrong(key, 'a string or null'),
  };

  /// The integer at [key].
  int integer(String key) => switch (json[key]) {
    final int value => value,
    _ => throw _wrong(key, 'an integer'),
  };

  /// The object at [key], read as part of the same file.
  JsonFields object(String key) => switch (json[key]) {
    final Map<String, Object?> value => JsonFields(file, value),
    _ => throw _wrong(key, 'an object'),
  };

  /// The object at [key], or null when it is missing or null.
  JsonFields? optionalObject(String key) =>
      json[key] == null ? null : object(key);

  /// The list of objects at [key].
  List<JsonFields> objects(String key) {
    final value = json[key];
    if (value is List<Object?> &&
        value.every((item) => item is Map<String, Object?>)) {
      return [
        for (final item in value)
          JsonFields(file, item! as Map<String, Object?>),
      ];
    }
    throw _wrong(key, 'a list of objects');
  }

  /// The object of strings at [key].
  Map<String, String> stringMap(String key) {
    final value = json[key];
    if (value is Map<String, Object?> &&
        value.values.every((item) => item is String)) {
      return {
        for (final entry in value.entries) entry.key: entry.value! as String,
      };
    }
    throw _wrong(key, 'an object of strings');
  }

  /// The boolean at [key].
  bool boolean(String key) => switch (json[key]) {
    final bool value => value,
    _ => throw _wrong(key, 'true or false'),
  };

  /// The integer at [key], or null when it is missing or null.
  int? optionalInteger(String key) => switch (json[key]) {
    null => null,
    final int value => value,
    _ => throw _wrong(key, 'an integer or null'),
  };

  /// The list of strings at [key].
  List<String> strings(String key) {
    final value = json[key];
    if (value is List<Object?> && value.every((item) => item is String)) {
      return value.cast<String>();
    }
    throw _wrong(key, 'a list of strings');
  }

  /// The object of objects at [key], by key.
  Map<String, JsonFields> objectMap(String key) {
    final value = json[key];
    if (value is Map<String, Object?> &&
        value.values.every((item) => item is Map<String, Object?>)) {
      return {
        for (final MapEntry(key: name, value: item) in value.entries)
          name: JsonFields(file, item! as Map<String, Object?>),
      };
    }
    throw _wrong(key, 'an object of objects');
  }

  FormatException _wrong(String key, String expected) =>
      FormatException('$file: "$key" must be $expected.');
}
