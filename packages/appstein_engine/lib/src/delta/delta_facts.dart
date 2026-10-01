/// What a deprecation forbids: Dart's `Deprecated` constructors
/// (`dart:core`).
enum DeprecationKind {
  /// `@Deprecated(...)` or `@deprecated`: any use.
  use,

  /// `@Deprecated.implement(...)`: implementing the class or mixin.
  implement,

  /// `@Deprecated.extend(...)`: extending the class.
  extend,

  /// `@Deprecated.subclass(...)`: extending or implementing it.
  subclass,

  /// `@Deprecated.instantiate(...)`: creating instances of the class.
  instantiate,

  /// `@Deprecated.mixin(...)`: mixing the class in.
  mixin,

  /// `@Deprecated.optional(...)`: leaving out the argument.
  optional;

  /// What not to do, as the delta says it; null for [use], whose message
  /// says it all.
  String? get rule => switch (this) {
    DeprecationKind.use => null,
    DeprecationKind.implement => "don't implement it.",
    DeprecationKind.extend => "don't extend it.",
    DeprecationKind.subclass => "don't extend or implement it.",
    DeprecationKind.instantiate => "don't create instances of it.",
    DeprecationKind.mixin => "don't mix it in.",
    DeprecationKind.optional =>
      'always pass this argument: it will become required.',
  };
}

/// A deprecated API the project can reach.
final class DeprecatedApi {
  /// Creates the entry.
  const DeprecatedApi({
    required this.group,
    required this.name,
    required this.kind,
    this.message,
    this.migrations = const [],
  });

  /// The library or package that declares it: `dart:core`,
  /// `package:flutter`.
  final String group;

  /// Its name as code writes it: `WillPopScope`, `Color.withOpacity`,
  /// `NewBox.new(width)` for a parameter, `NewBox.colour=` for a setter.
  final String name;

  /// What the deprecation forbids.
  final DeprecationKind kind;

  /// The library's own message on one line, or null when it has none.
  final String? message;

  /// The titles of the `fix_data` migrations that migrate it, sorted.
  final List<String> migrations;

  @override
  bool operator ==(Object other) =>
      other is DeprecatedApi && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;

  @override
  String toString() =>
      '$group $name [${kind.name}] ${message ?? '(no message)'}'
      '${migrations.isEmpty ? '' : ' | ${migrations.join(' | ')}'}';
}

/// Whether an API in a migration is gone, or is still there.
enum MigrationStatus {
  /// The element is gone, or, for an entry named with a parameter
  /// (`Stack.new(overflow)`), that parameter is gone from the element that
  /// is still there. Code that uses it doesn't compile.
  removed,

  /// The element (or the named parameter) is still there and isn't
  /// deprecated, and `dart fix` changes how it's used; the migration's
  /// title says how.
  changed,
}

/// An API a `fix_data` migration says is removed or changed.
///
/// A migration that names old parameters (it removes or renames them) is
/// listed once per parameter, named `Stack.new(overflow)`, except for a
/// parameter that is still there and deprecated: its migration is attached
/// to that deprecation ([DeprecatedApi.migrations]). One that names none is
/// listed under the element's own name.
final class MigratedApi {
  /// Creates the entry.
  const MigratedApi({
    required this.group,
    required this.name,
    required this.status,
    required this.title,
  });

  /// The library or package, as in [DeprecatedApi.group].
  final String group;

  /// Its name as code writes it, as in [DeprecatedApi.name]: `GoneBox`,
  /// `Stack.overflow`, or `Stack.new(overflow)` for a parameter.
  final String name;

  /// Removed or changed.
  final MigrationStatus status;

  /// The migration's title.
  final String title;

  @override
  bool operator ==(Object other) =>
      other is MigratedApi && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;

  @override
  String toString() => '$group $name ${status.name} $title';
}

/// A library that a `fix_data` migration moves elsewhere.
final class MovedLibrary {
  /// Creates the entry.
  const MovedLibrary({
    required this.from,
    required this.to,
    required this.title,
  });

  /// The library's URI, such as `package:flutter/material.dart`.
  final String from;

  /// Where it moves, or null when the migration doesn't say.
  final String? to;

  /// The migration's title.
  final String title;

  @override
  bool operator ==(Object other) =>
      other is MovedLibrary && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;

  @override
  String toString() => '$from -> ${to ?? '?'}: $title';
}

/// A migration file that couldn't be read.
final class UnreadMigrations {
  /// Creates the entry.
  const UnreadMigrations({required this.file, required this.reason});

  /// The file, named without any machine path:
  /// `package:delta_kit/fix_data/fix_broken.yaml` or
  /// `dart-sdk/lib/_internal/fix_data.yaml`.
  final String file;

  /// Why it couldn't be read.
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is UnreadMigrations && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;

  @override
  String toString() => '$file: $reason';
}

/// What the version delta lists besides the curated notes (spec §6.4), each
/// list sorted by group, then name.
final class DeltaFacts {
  /// Creates the facts.
  const DeltaFacts({
    this.deprecated = const [],
    this.migrated = const [],
    this.moved = const [],
    this.unread = const [],
  });

  /// The deprecated APIs the project's imports expose.
  final List<DeprecatedApi> deprecated;

  /// The removed and changed APIs from the migrations in scope.
  final List<MigratedApi> migrated;

  /// The libraries the migrations in scope move.
  final List<MovedLibrary> moved;

  /// The migration files that couldn't be read.
  final List<UnreadMigrations> unread;

  @override
  bool operator ==(Object other) =>
      other is DeltaFacts && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;

  @override
  String toString() =>
      [...deprecated, ...migrated, ...moved, ...unread].join('\n');
}
