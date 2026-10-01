import '../../native/native_files.dart';

/// What `native.json` records from the `Package.swift` that
/// `flutter pub get` generates for the plugins.
final class GeneratedPackageFacts {
  /// Creates the facts.
  const GeneratedPackageFacts({
    required this.plugins,
    this.iosVersion,
    this.iosVersionLine,
  });

  /// The version in `.iOS("…")`, such as `15.0`; null when there is none.
  final String? iosVersion;

  /// The 1-based line of [iosVersion].
  final int? iosVersionLine;

  /// The plugins' package names, sorted, without Flutter's own
  /// `FlutterFramework`. Their paths are never read: they are absolute
  /// machine paths.
  final List<String> plugins;
}

/// Reads the generated `Package.swift`.
GeneratedPackageFacts readGeneratedPackage(String text) {
  final ios = RegExp(r'\.iOS\("([^"]+)"\)').firstMatch(text);
  final plugins = {
    for (final match in RegExp(
      r'\.package\(\s*name:\s*"([^"]+)"',
    ).allMatches(text))
      if (match[1] != 'FlutterFramework') match[1]!,
  }.toList()..sort();
  return GeneratedPackageFacts(
    plugins: plugins,
    iosVersion: ios?[1],
    iosVersionLine: ios == null ? null : lineAt(text, ios.start),
  );
}

/// What `native.json` records from a `Podfile`.
final class PodfileFacts {
  /// Creates the facts.
  const PodfileFacts({
    this.version,
    this.line,
    this.isExpression = false,
    this.uncertain,
  });

  /// Whether the line has a version argument that is not a quoted literal,
  /// such as `$iOSVersion`: the version is set by a Ruby expression.
  final bool isExpression;

  /// Why [version] can't be taken as the one CocoaPods uses, or null when
  /// the `platform :ios` line is a plain statement: it is interpolated
  /// (`"#{ver}"`), has an `if`/`unless` modifier, sits in a Ruby block, or
  /// there are several `platform :ios` lines. [version] is then null.
  final String? uncertain;

  /// The version of its `platform :ios, '…'` line; null when the line has
  /// none, or there is no such line.
  final String? version;

  /// The 1-based line of its `platform :ios` line; null when there is none.
  final int? line;
}

/// A line's code: [line] trimmed, without a trailing `#` comment (a `#{`
/// interpolation is not one).
String _code(String line) =>
    line.replaceFirst(RegExp(r'(^|\s)#(?!\{).*$'), '').trim();

/// Ruby statements that open a block closed by `end`.
final _blockOpener = RegExp(
  r'^(if|unless|case|while|until|begin|for|def|class|module)\b',
);

/// Reads a `Podfile`'s `platform :ios` line. Commented lines don't count.
///
/// The reader doesn't run Ruby, and tracks blocks only by counting the lines
/// that open one (`if`, `unless`, `case`, `while`, `begin`, `do`…) against
/// the lines that are `end`: a `platform :ios` line inside one, with a
/// modifier, with an interpolated version, or repeated is
/// [PodfileFacts.uncertain].
PodfileFacts readPodfile(String text) {
  final platform = RegExp(
    r'''^platform\s+:ios\b\s*(?:(,)\s*(?:['"]([^'"]+)['"])?)?''',
  );
  final lines = text.split('\n');
  final found = <({RegExpMatch match, int line, String rest, bool inBlock})>[];
  var depth = 0;
  for (var i = 0; i < lines.length; i++) {
    final code = _code(lines[i]);
    final match = platform.firstMatch(code);
    if (match != null) {
      found.add((
        match: match,
        line: i + 1,
        rest: code.substring(match.end).trim(),
        inBlock: depth > 0,
      ));
    }
    final closesItself = RegExp(r'(^|[\s;])end$').hasMatch(code);
    if (_blockOpener.hasMatch(code) ||
        RegExp(r'\bdo(\s*\|[^|]*\|)?$').hasMatch(code)) {
      if (!closesItself) depth++;
    } else if (RegExp(r'^end\b').hasMatch(code) && depth > 0) {
      depth--;
    }
  }
  if (found.isEmpty) return const PodfileFacts();
  final first = found.first;
  final version = first.match[2];
  PodfileFacts uncertain(String why, [int? line]) =>
      PodfileFacts(line: line ?? first.line, uncertain: why);
  if (found.length > 1) {
    return uncertain(
      'set more than once (lines '
      '${[for (final entry in found) entry.line].join(', ')})',
    );
  }
  if (first.inBlock) {
    return uncertain(
      'set conditionally (inside a Ruby block; the reader only counts '
      '`if`, `unless`, `case`, `while`, `begin` and `do` against `end`)',
    );
  }
  if (RegExp(r'^(if|unless|while|until)\b').hasMatch(first.rest)) {
    return uncertain('set conditionally (an `if` or `unless` modifier)');
  }
  if (version != null && version.contains('#{')) {
    return uncertain('set by an interpolated Ruby string');
  }
  // A quoted version with more after it, such as `'13.0' + suffix`.
  if (version != null && first.rest.isNotEmpty) {
    return uncertain('set by a Ruby expression');
  }
  return PodfileFacts(
    version: version,
    line: first.line,
    isExpression: first.match[1] != null && version == null,
  );
}
