import '../json_fields.dart';

/// One package in `deps.json`.
final class PackageDependency {
  /// Creates an entry.
  const PackageDependency({
    this.constraint,
    required this.version,
    required this.dependency,
    required this.source,
    required this.usages,
  });

  factory PackageDependency._read(JsonFields fields) => PackageDependency(
    constraint: fields.optionalString('constraint'),
    version: fields.string('version'),
    dependency: fields.string('dependency'),
    source: fields.string('source'),
    usages: fields.strings('usages'),
  );

  /// The version constraint in `pubspec.yaml`, such as `^18.0.0`. It is null
  /// for a transitive package, or for one given as an SDK, path or git
  /// dependency without a version.
  final String? constraint;

  /// The resolved version, from `pubspec.lock`.
  final String version;

  /// How it is depended on, as `pubspec.lock` says: `direct main`,
  /// `direct dev`, `direct overridden` or `transitive`.
  final String dependency;

  /// Where it comes from, as `pubspec.lock` says: `hosted`, `sdk`, `path` or
  /// `git`.
  final String source;

  /// The project files that import it, sorted.
  final List<String> usages;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'constraint': constraint,
    'version': version,
    'dependency': dependency,
    'source': source,
    'usages': usages,
  };
}

/// The contents of `map/deps.json` (spec §6.5). The health snapshot and
/// advisories are added once the package gate exists (§9.4).
final class DepsMap {
  /// Creates the map.
  const DepsMap({required this.packages});

  /// Reads the map from its JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory DepsMap.fromJson(Map<String, Object?> json) => DepsMap(
    packages: {
      for (final MapEntry(:key, :value) in JsonFields(
        'deps.json',
        json,
      ).objectMap('packages').entries)
        key: PackageDependency._read(value),
    },
  );

  /// Every package in `pubspec.lock`, by name.
  final Map<String, PackageDependency> packages;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'packages': {
      for (final MapEntry(:key, :value) in packages.entries)
        key: value.toJson(),
    },
  };
}
