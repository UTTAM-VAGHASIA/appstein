import 'dart:convert';

/// Encodes [value] the way every `.appstein/` JSON file is written (spec
/// §15): object keys sorted at every level, a two-space indent, `\n` line
/// endings and a final newline. The same value always gives the same text,
/// so unchanged knowledge never shows up as a change.
String canonicalJson(Object? value) =>
    '${const JsonEncoder.withIndent('  ').convert(_sorted(value))}\n';

Object? _sorted(Object? value) {
  if (value is Map<Object?, Object?>) {
    final keys = [for (final key in value.keys) key! as String]..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List<Object?>) return [for (final item in value) _sorted(item)];
  return value;
}
