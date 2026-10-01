import '../json_fields.dart';

/// What part of building a Flutter app a curated note is about.
enum NoteArea {
  /// The Flutter framework: widgets, Material, Cupertino, rendering.
  framework,

  /// The Dart language and its core libraries.
  dart,

  /// Android builds: Gradle, AGP, Kotlin, SDK levels.
  android,

  /// iOS and macOS builds: Xcode, deployment targets, Swift Package Manager.
  ios,

  /// Flutter's tools and project templates.
  tooling,
}

/// One curated note (spec §6.4): a change in Flutter that the SDK's own
/// files can't express, such as a new default or a language feature gated
/// by the project's language version.
final class CuratedNote {
  /// Creates a note.
  const CuratedNote({
    required this.id,
    required this.since,
    this.languageVersion,
    required this.priority,
    required this.area,
    required this.summary,
    required this.use,
    required this.avoid,
    required this.source,
  });

  /// Reads a note from its JSON form.
  ///
  /// Throws a [FormatException] when a field is missing or has the wrong
  /// type, the priority isn't 1 to 3, or the area is unknown.
  factory CuratedNote.fromJson(Map<String, Object?> json) {
    final fields = JsonFields('note', json);
    final priority = fields.integer('priority');
    if (priority < 1 || priority > 3) {
      throw const FormatException('note: "priority" must be 1, 2 or 3.');
    }
    final area = NoteArea.values.asNameMap()[fields.string('area')];
    if (area == null) {
      throw FormatException(
        'note: "area" must be one of '
        '${NoteArea.values.map((a) => a.name).join(', ')}.',
      );
    }
    return CuratedNote(
      id: fields.string('id'),
      since: fields.string('since'),
      languageVersion: fields.optionalString('languageVersion'),
      priority: priority,
      area: area,
      summary: fields.string('summary'),
      use: fields.string('use'),
      avoid: fields.string('avoid'),
      source: fields.string('source'),
    );
  }

  /// A stable kebab-case name, such as `dot-shorthands`.
  final String id;

  /// The stable Flutter minor version it first applies to, such as `3.38`.
  final String since;

  /// For a Dart language feature, the language version that enables it,
  /// such as `3.10`. Null for everything else.
  final String? languageVersion;

  /// 1 when agents get it wrong often and it matters, 2 when it is common,
  /// 3 when it is niche.
  final int priority;

  /// What part of building an app it is about.
  final NoteArea area;

  /// What changed, in one sentence.
  final String summary;

  /// What to write now.
  final String use;

  /// What not to write.
  final String avoid;

  /// A URL to the official docs that state it.
  final String source;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'id': id,
    'since': since,
    'languageVersion': languageVersion,
    'priority': priority,
    'area': area.name,
    'summary': summary,
    'use': use,
    'avoid': avoid,
    'source': source,
  };
}
