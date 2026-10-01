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
  const PodfileFacts({this.version, this.line, this.isExpression = false});

  /// Whether the line has a version argument that is not a quoted literal,
  /// such as `$iOSVersion`: the version is set by a Ruby expression.
  final bool isExpression;

  /// The version of its `platform :ios, '…'` line; null when the line has
  /// none, or there is no such line.
  final String? version;

  /// The 1-based line of its `platform :ios` line; null when there is none.
  final int? line;
}

/// Reads a `Podfile`'s `platform :ios` line. Commented lines don't count.
PodfileFacts readPodfile(String text) {
  final platform = RegExp(
    r'''^platform\s+:ios\b\s*(?:(,)\s*(?:['"]([^'"]+)['"])?)?''',
  );
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final match = platform.firstMatch(lines[i].trim());
    if (match != null) {
      return PodfileFacts(
        version: match[2],
        line: i + 1,
        isExpression: match[1] != null && match[2] == null,
      );
    }
  }
  return const PodfileFacts();
}
