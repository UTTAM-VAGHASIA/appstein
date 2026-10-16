import '../json_fields.dart';

/// The contents of `.appstein/state.json` (spec §6.2): when the knowledge was
/// last synced, the input hash of each generated file and the hash of its
/// bytes, the hash of each file the map is built from, what changed in the
/// last sync, and the unverified files (slice 1d.2).
final class KnowledgeState {
  /// Creates the state.
  const KnowledgeState({
    required this.formatVersion,
    required this.appsteinVersion,
    required this.lastSync,
    required this.files,
    required this.sources,
    required this.written,
    required this.changed,
    this.dartFiles,
    this.unverified = const [],
    this.dartStamps,
    this.dartScannedAt,
  });

  /// Reads the state from its JSON form. A state written before slice 1d.2
  /// has no `dartFiles`, `unverified`, `dartStamps` or `dartScannedAt`: it
  /// reads with none of them (the refresh then counts every Dart file as
  /// unverified).
  ///
  /// Throws a [FormatException] when a field is missing or has the wrong
  /// type.
  factory KnowledgeState.fromJson(Map<String, Object?> json) {
    final fields = JsonFields('state.json', json);
    return KnowledgeState(
      formatVersion: fields.integer('formatVersion'),
      appsteinVersion: fields.string('appsteinVersion'),
      lastSync: fields.string('lastSync'),
      files: fields.stringMap('files'),
      sources: fields.stringMap('sources'),
      written: fields.stringMap('written'),
      changed: fields.strings('changed'),
      dartFiles: json['dartFiles'] == null
          ? null
          : fields.stringMap('dartFiles'),
      unverified: json['unverified'] == null
          ? const []
          : fields.strings('unverified'),
      dartStamps: json['dartStamps'] == null
          ? null
          : fields.stringMap('dartStamps'),
      dartScannedAt: fields.optionalString('dartScannedAt'),
    );
  }

  /// The time of last change and the size of each Dart file of
  /// [dartFiles], as the scan that hashed it saw them, by the same path:
  /// `<microseconds since the epoch, UTC>/<bytes>`. A later scan hashes a
  /// file again only when these changed (or lie too close to the scan to
  /// trust). Null when no scan recorded them.
  final Map<String, String>? dartStamps;

  /// When the scan that recorded [dartStamps] was taken, as an ISO 8601 UTC
  /// time; null with them.
  final String? dartScannedAt;

  /// The format version it was written in.
  final int formatVersion;

  /// The Appstein version that wrote it.
  final String appsteinVersion;

  /// When `appstein sync` last ran, as `formatKnowledgeTime` writes it.
  final String lastSync;

  /// The input hash of each generated file, by its path inside `.appstein/`
  /// with `/` separators, such as `platform/sdk.json`.
  final Map<String, String> files;

  /// The SHA-256 of each file the project map is built from, by input name
  /// (such as `project:lib/main.dart`), or `missing` (spec §6.2).
  final Map<String, String> sources;

  /// The SHA-256 of each generated file as it was written, by its path
  /// inside `.appstein/`. A file whose bytes differ was changed by hand.
  final Map<String, String> written;

  /// The input names whose hash changed in the sync that wrote this state,
  /// sorted. The next `sync --detect` that finds nothing changed empties it
  /// (spec §5.4), so `verify --fast` checks each change once.
  final List<String> changed;

  /// The SHA-256 of every Dart file the analysis server covers, by its path
  /// from the project root with `/` separators, as the last knowledge
  /// refresh saw them; `unreadable` for a file that could not be read. The
  /// refresh compares them with the files as they are now, to find the
  /// files that join [unverified]. Null in a state written before slice
  /// 1d.2: there is nothing to compare with yet.
  final Map<String, String>? dartFiles;

  /// The unverified files (slice 1d.2, spec §9.1): the files changed since
  /// a `verify` run last found no error in them, by their path from the
  /// project root with `/` separators, sorted. A fast run reports warnings
  /// and lints only on these.
  final List<String> unverified;

  /// A copy with [dartFiles], [unverified], [changed], [dartStamps] and
  /// [dartScannedAt] replaced where given.
  KnowledgeState copyWith({
    Map<String, String>? dartFiles,
    List<String>? unverified,
    List<String>? changed,
    Map<String, String>? dartStamps,
    String? dartScannedAt,
  }) => KnowledgeState(
    formatVersion: formatVersion,
    appsteinVersion: appsteinVersion,
    lastSync: lastSync,
    files: files,
    sources: sources,
    written: written,
    changed: changed ?? this.changed,
    dartFiles: dartFiles ?? this.dartFiles,
    unverified: unverified ?? this.unverified,
    dartStamps: dartStamps ?? this.dartStamps,
    dartScannedAt: dartScannedAt ?? this.dartScannedAt,
  );

  /// The JSON form. `dartFiles`, `dartStamps` and `dartScannedAt` are left
  /// out while they are null, and `unverified` while it is empty, so a state
  /// with none of them is written as before slice 1d.2.
  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'appsteinVersion': appsteinVersion,
    'lastSync': lastSync,
    'files': files,
    'sources': sources,
    'written': written,
    'changed': changed,
    'dartFiles': ?dartFiles,
    if (unverified.isNotEmpty) 'unverified': unverified,
    'dartStamps': ?dartStamps,
    'dartScannedAt': ?dartScannedAt,
  };
}
