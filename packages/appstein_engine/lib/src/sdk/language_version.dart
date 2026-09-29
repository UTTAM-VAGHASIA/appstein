import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// The project's Dart language version, such as `3.9`: the lower bound of the
/// `environment: sdk:` constraint in `pubspec.yaml`.
///
/// New syntax (for example dot shorthands) depends on this, not on the
/// installed SDK (spec §3). Returns null when there is no lower bound or the
/// file can't be read.
String? languageVersionFromPubspec(String pubspecContent) {
  final Object? doc;
  try {
    doc = loadYaml(pubspecContent);
  } on YamlException {
    return null;
  }
  if (doc is! Map<Object?, Object?>) return null;
  final environment = doc['environment'];
  if (environment is! Map<Object?, Object?>) return null;
  final sdk = environment['sdk'];
  if (sdk is! String) return null;
  final VersionConstraint constraint;
  try {
    constraint = VersionConstraint.parse(sdk);
  } on FormatException {
    return null;
  }
  final Version? min = switch (constraint) {
    final Version version => version,
    final VersionRange range => range.min,
    _ => null,
  };
  return min == null ? null : '${min.major}.${min.minor}';
}
