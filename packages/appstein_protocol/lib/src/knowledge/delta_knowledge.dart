import '../json_fields.dart';
import 'curated_note.dart';

const _file = 'delta.json';

/// A deprecated API in `delta.json` (spec §6.4).
final class DeltaDeprecatedApi {
  /// Creates the entry.
  const DeltaDeprecatedApi({
    required this.library,
    required this.name,
    required this.kind,
    this.rule,
    this.message,
    this.migrations = const [],
  });

  factory DeltaDeprecatedApi._read(JsonFields fields) => DeltaDeprecatedApi(
    library: fields.string('library'),
    name: fields.string('name'),
    kind: fields.string('kind'),
    rule: fields.optionalString('rule'),
    message: fields.optionalString('message'),
    migrations: fields.strings('migrations'),
  );

  /// The library or package that declares it, such as `package:flutter`.
  final String library;

  /// Its name as code writes it: `Color.withOpacity`, or
  /// `Text.new(textScaleFactor)` for a parameter.
  final String name;

  /// What the deprecation forbids, named after Dart's `Deprecated`
  /// constructors: `use`, `implement`, `extend`, `subclass`, `instantiate`,
  /// `mixin` or `optional`.
  final String kind;

  /// What not to do for a [kind] other than `use`, such as "don't implement
  /// it."; null for `use`.
  final String? rule;

  /// The library's own deprecation message on one line; null when it has
  /// none.
  final String? message;

  /// The titles of the `fix_data` migrations that migrate it.
  final List<String> migrations;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'library': library,
    'name': name,
    'kind': kind,
    'rule': rule,
    'message': message,
    'migrations': migrations,
  };
}

/// An API a `fix_data` migration says is removed or changed.
final class DeltaMigratedApi {
  /// Creates the entry.
  const DeltaMigratedApi({
    required this.library,
    required this.name,
    required this.status,
    required this.title,
  });

  factory DeltaMigratedApi._read(JsonFields fields) => DeltaMigratedApi(
    library: fields.string('library'),
    name: fields.string('name'),
    status: fields.string('status'),
    title: fields.string('title'),
  );

  /// The library or package, as in [DeltaDeprecatedApi.library].
  final String library;

  /// Its name as code writes it, as in [DeltaDeprecatedApi.name].
  final String name;

  /// `removed` (code that uses it doesn't compile) or `changed` (it still
  /// exists and `dart fix` changes how it's used).
  final String status;

  /// The migration's title.
  final String title;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'library': library,
    'name': name,
    'status': status,
    'title': title,
  };
}

/// A library a `fix_data` migration moves elsewhere.
final class DeltaMovedLibrary {
  /// Creates the entry.
  const DeltaMovedLibrary({required this.from, this.to, required this.title});

  factory DeltaMovedLibrary._read(JsonFields fields) => DeltaMovedLibrary(
    from: fields.string('from'),
    to: fields.optionalString('to'),
    title: fields.string('title'),
  );

  /// The library's URI, such as `package:flutter/material.dart`.
  final String from;

  /// Where it moves, or null when the migration doesn't say.
  final String? to;

  /// The migration's title.
  final String title;

  /// The JSON form.
  Map<String, Object?> toJson() => {'from': from, 'to': to, 'title': title};
}

/// A migration file that couldn't be read.
final class DeltaUnreadFile {
  /// Creates the entry.
  const DeltaUnreadFile({required this.file, required this.reason});

  factory DeltaUnreadFile._read(JsonFields fields) => DeltaUnreadFile(
    file: fields.string('file'),
    reason: fields.string('reason'),
  );

  /// The file, named without any machine path.
  final String file;

  /// Why it couldn't be read.
  final String reason;

  /// The JSON form.
  Map<String, Object?> toJson() => {'file': file, 'reason': reason};
}

/// The deprecated, removed, changed and moved APIs of a delta, each list
/// sorted by library, then name.
final class DeltaApis {
  /// Creates the lists.
  const DeltaApis({
    required this.deprecated,
    required this.migrated,
    required this.moved,
    required this.unread,
  });

  factory DeltaApis._read(JsonFields fields) => DeltaApis(
    deprecated: [
      for (final api in fields.objects('deprecated'))
        DeltaDeprecatedApi._read(api),
    ],
    migrated: [
      for (final api in fields.objects('migrated')) DeltaMigratedApi._read(api),
    ],
    moved: [
      for (final moved in fields.objects('moved')) DeltaMovedLibrary._read(moved),
    ],
    unread: [
      for (final unread in fields.objects('unread'))
        DeltaUnreadFile._read(unread),
    ],
  );

  /// The deprecated APIs the project's imports expose.
  final List<DeltaDeprecatedApi> deprecated;

  /// The removed and changed APIs from the migrations in scope.
  final List<DeltaMigratedApi> migrated;

  /// The libraries the migrations in scope move.
  final List<DeltaMovedLibrary> moved;

  /// The migration files that couldn't be read.
  final List<DeltaUnreadFile> unread;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'deprecated': [for (final api in deprecated) api.toJson()],
    'migrated': [for (final api in migrated) api.toJson()],
    'moved': [for (final moved in moved) moved.toJson()],
    'unread': [for (final unread in unread) unread.toJson()],
  };
}

/// The contents of `.appstein/platform/delta.json` (spec §6.2, §6.4): the
/// same delta as `delta.md`, as data, for the MCP tools `check_api` and
/// `what_changed` (spec §8).
final class DeltaKnowledge {
  /// Creates the delta.
  const DeltaKnowledge({
    required this.flutterVersion,
    this.languageVersion,
    required this.baseline,
    required this.coverage,
    required this.newestNotes,
    required this.notes,
    required this.laterNotes,
    this.apis,
    this.missing,
  });

  /// Reads the file's JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory DeltaKnowledge.fromJson(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    final apis = fields.optionalObject('apis');
    List<CuratedNote> notes(String key) => [
      for (final note in fields.objects(key)) CuratedNote.fromJson(note.json),
    ];
    return DeltaKnowledge(
      flutterVersion: fields.string('flutterVersion'),
      languageVersion: fields.optionalString('languageVersion'),
      baseline: fields.string('baseline'),
      coverage: fields.string('coverage'),
      newestNotes: fields.string('newestNotes'),
      notes: notes('notes'),
      laterNotes: notes('laterNotes'),
      apis: apis == null ? null : DeltaApis._read(apis),
      missing: fields.optionalString('missing'),
    );
  }

  /// The installed Flutter version, such as `3.47.5`.
  final String flutterVersion;

  /// The project's Dart language version, or null when unknown.
  final String? languageVersion;

  /// How far back the notes reach (`delta.baseline`, spec §7).
  final String baseline;

  /// How well the curated notes cover this Flutter: `complete` or
  /// `partial`.
  final String coverage;

  /// The newest Flutter minor version the curated notes cover.
  final String newestNotes;

  /// The notes the project can use, most important first.
  final List<CuratedNote> notes;

  /// The notes that need a newer language version than the project's.
  final List<CuratedNote> laterNotes;

  /// The API lists; null when they couldn't be collected ([missing] says
  /// why).
  final DeltaApis? apis;

  /// Why [apis] is null; null otherwise.
  final String? missing;

  /// The JSON form, without `meta` (the store adds it).
  Map<String, Object?> toJson() => {
    'flutterVersion': flutterVersion,
    'languageVersion': languageVersion,
    'baseline': baseline,
    'coverage': coverage,
    'newestNotes': newestNotes,
    'notes': [for (final note in notes) note.toJson()],
    'laterNotes': [for (final note in laterNotes) note.toJson()],
    'apis': apis?.toJson(),
    'missing': missing,
  };
}
