import '../json_fields.dart';

/// The contents of `.appstein/state.json` (spec §6.2): when the knowledge was
/// last synced, the input hash of each generated file and the hash of its
/// bytes, the hash of each file the map is built from, and what changed in the
/// last sync.
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
  });

  /// Reads the state from its JSON form.
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
    );
  }

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

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'appsteinVersion': appsteinVersion,
    'lastSync': lastSync,
    'files': files,
    'sources': sources,
    'written': written,
    'changed': changed,
  };
}
