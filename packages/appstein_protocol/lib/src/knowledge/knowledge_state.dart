import '../json_fields.dart';

/// The contents of `.appstein/state.json` (spec §6.2): when the knowledge
/// was last synced, and the input hash of each generated file.
final class KnowledgeState {
  /// Creates the state.
  const KnowledgeState({
    required this.formatVersion,
    required this.appsteinVersion,
    required this.lastSync,
    required this.files,
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

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'appsteinVersion': appsteinVersion,
    'lastSync': lastSync,
    'files': files,
  };
}
