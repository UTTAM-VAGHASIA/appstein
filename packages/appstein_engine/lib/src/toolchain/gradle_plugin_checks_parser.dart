import 'package:appstein_protocol/appstein_protocol.dart';

import 'toolchain_files.dart';

/// Reads the versions below which Flutter's Gradle plugin warns or fails a
/// build, from the text of its `DependencyVersionChecker.kt` (spec §12).
///
/// Each threshold is a declaration such as
/// `internal val warnGradleVersion: Version = Version(9, 1, 0)`. Values are
/// `Version(a, b, c)` or `AndroidPluginVersion(a, b, c)` calls,
/// `JavaVersion.VERSION_17` constants, or whole numbers. Throws
/// [ToolchainParseException] when a threshold is missing, declared twice,
/// or has another shape.
AndroidBuildChecks parseGradlePluginChecks(String text) {
  final found = <String, String>{};
  for (final match in _declaration.allMatches(text)) {
    final name = '${match[1]}${match[2]}Version';
    if (found.containsKey(name)) {
      throw ToolchainParseException(
        ToolchainFiles.gradlePluginChecks,
        '$name is declared twice',
      );
    }
    found[name] = _value(name, match[3]!.split('//').first.trim());
  }
  VersionThreshold threshold(String kind) => VersionThreshold(
    warnBelow: _required(found, 'warn${kind}Version'),
    errorBelow: _required(found, 'error${kind}Version'),
  );
  return AndroidBuildChecks(
    gradle: threshold('Gradle'),
    agp: threshold('AGP'),
    kgp: threshold('KGP'),
    java: threshold('Java'),
    minSdk: threshold('MinSdk'),
  );
}

final _declaration = RegExp(
  r'\bval\s+(warn|error)(Gradle|Java|AGP|KGP|MinSdk)Version\s*:\s*\w+\s*=\s*'
  r'([^\r\n]+)',
);
final _versionCall = RegExp(
  r'^(?:Version|AndroidPluginVersion)\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)$',
);
final _javaVersion = RegExp(r'^JavaVersion\.VERSION_(\d+)(?:_(\d+))?$');
final _wholeNumber = RegExp(r'^\d+$');

String _value(String name, String text) {
  final version = _versionCall.firstMatch(text);
  if (version != null) return '${version[1]}.${version[2]}.${version[3]}';
  final java = _javaVersion.firstMatch(text);
  if (java != null) return java[2] == null ? java[1]! : '${java[1]}.${java[2]}';
  if (_wholeNumber.hasMatch(text)) return text;
  throw ToolchainParseException(
    ToolchainFiles.gradlePluginChecks,
    '$name has an unexpected value: $text',
  );
}

String _required(Map<String, String> found, String name) =>
    found[name] ??
    (throw ToolchainParseException(
      ToolchainFiles.gradlePluginChecks,
      'no $name',
    ));
