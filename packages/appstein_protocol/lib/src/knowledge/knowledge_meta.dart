import '../json_fields.dart';

/// The version of the formats of the files Appstein writes into
/// `.appstein/` (spec §6.2, §19.5). It rises when a format changes, so
/// `upgrade` can migrate older files.
const knowledgeFormatVersion = 1;

/// What every generated `.appstein/` file records about itself, under its
/// `meta` key (spec §6.2).
final class KnowledgeMeta {
  /// Creates the metadata.
  const KnowledgeMeta({
    required this.generatedAt,
    required this.appsteinVersion,
    required this.formatVersion,
    required this.sdkVersion,
    required this.inputHash,
  });

  /// Reads the metadata from its JSON form. [file] names the file in error
  /// messages.
  ///
  /// Throws a [FormatException] when a field is missing or has the wrong
  /// type.
  factory KnowledgeMeta.fromJson(
    Map<String, Object?> json, {
    String file = 'meta',
  }) {
    final fields = JsonFields(file, json);
    return KnowledgeMeta(
      generatedAt: fields.string('generatedAt'),
      appsteinVersion: fields.string('appsteinVersion'),
      formatVersion: fields.integer('formatVersion'),
      sdkVersion: fields.string('sdkVersion'),
      inputHash: fields.string('inputHash'),
    );
  }

  /// When the file was generated, as [formatKnowledgeTime] writes it.
  final String generatedAt;

  /// The Appstein version that wrote it, such as `0.1.0-dev`.
  final String appsteinVersion;

  /// The format version it was written in ([knowledgeFormatVersion]).
  final int formatVersion;

  /// The Flutter version it was generated for, such as `3.47.5`.
  final String sdkVersion;

  /// The SHA-256 of everything the file was built from, as hex. The file is
  /// rewritten only when this changes (spec §6.2).
  final String inputHash;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'generatedAt': generatedAt,
    'appsteinVersion': appsteinVersion,
    'formatVersion': formatVersion,
    'sdkVersion': sdkVersion,
    'inputHash': inputHash,
  };
}

/// Formats [time] the way `.appstein/` files record times: in UTC, to the
/// second, such as `2026-10-01T09:30:05Z`.
String formatKnowledgeTime(DateTime time) {
  final utc = time.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
      '${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:'
      '${two(utc.second)}Z';
}
