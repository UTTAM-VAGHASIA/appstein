import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// A backslash that is a path separator when it escapes nothing: every one
/// except a backslash right before `[`, `]`, `{` or `}`.
final _separator = RegExp(r'\\(?![\[\]{}])');

/// One way to read the path pattern of a decision (see
/// [decisionPathReadings]).
final class DecisionPathReading {
  /// A reading that is [pattern], which is a valid glob unless [problem]
  /// says why not.
  const DecisionPathReading(this.pattern, this.problem);

  /// The pattern, with `/` separators, without a leading `./` and without
  /// trailing `/`.
  final String pattern;

  /// Why [pattern] is not a valid glob; null when it is.
  final String? problem;

  /// Whether [pattern] is a valid glob.
  bool get valid => problem == null;
}

/// The ways to read [raw], a path pattern from a decision's `paths` (spec
/// §6.7).
///
/// A `\` in a decision's path is ambiguous: it is a Windows separator
/// (`lib\ui\x.dart`) or it escapes a glob character (`a\[1\].dart` names the
/// file `a[1].dart`). So a path has up to two readings:
///
/// - **the escape reading:** a `\` right before `[`, `]`, `{` or `}` escapes
///   that character, and every other `\` is a separator;
/// - **the separator reading:** every `\` is a separator, which is how a path
///   was read before escapes were.
///
/// The readings come in that order, and only once when they are the same,
/// which is always so for a path with no `\` before one of those four
/// characters. A path matches when any reading that is a valid glob matches
/// it, and is not a valid pattern only when no reading is valid. Whoever
/// matches applies its own guards (the project's edge, letter case) to every
/// reading, not only to the valid ones.
List<DecisionPathReading> decisionPathReadings(String raw) {
  final patterns = <String>{
    _clean(raw.replaceAll(_separator, '/')),
    _clean(raw.replaceAll(r'\', '/')),
  };
  return [
    for (final pattern in patterns)
      DecisionPathReading(pattern, _problem(pattern)),
  ];
}

/// [pattern] without a leading `./` and a trailing `/`. A pattern made of
/// slashes only is left alone, so it still shows as an absolute path.
String _clean(String pattern) {
  var cleaned = pattern;
  while (cleaned.startsWith('./')) {
    cleaned = cleaned.substring(2);
  }
  return cleaned.replaceFirst(RegExp(r'(?<=[^/])/+$'), '');
}

String? _problem(String pattern) {
  try {
    Glob(pattern, context: p.posix);
    return null;
  } on FormatException catch (error) {
    return error.message;
  }
}
