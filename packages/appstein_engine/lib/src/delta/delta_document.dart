import 'package:appstein_protocol/appstein_protocol.dart';

import '../notes/curated_notes.dart';
import '../notes/flutter_minor.dart';
import 'delta_facts.dart';

/// Where the version delta lives inside `.appstein/` (spec §6.2).
const deltaPath = 'platform/delta.md';

/// What the version delta is built from.
final class DeltaInputs {
  /// Creates the inputs.
  const DeltaInputs({
    required this.flutterVersion,
    required this.languageVersion,
    required this.baseline,
    required this.coverage,
    required this.newestNotes,
    required this.notes,
    this.facts,
    this.skipped,
    this.internalError,
  });

  /// The installed Flutter version, such as `3.47.5`.
  final String flutterVersion;

  /// The project's Dart language version, such as `3.12`, or null when
  /// unknown.
  final String? languageVersion;

  /// How far back the notes reach (`delta.baseline`, spec §7).
  final String baseline;

  /// How well the curated notes cover this Flutter.
  final NotesCoverage coverage;

  /// The newest Flutter minor version the notes cover.
  final String newestNotes;

  /// The notes to list ([deltaNotes]), most important first.
  final List<CuratedNote> notes;

  /// The deprecated, removed and moved APIs; null when the project map was
  /// skipped or collecting them failed.
  final DeltaFacts? facts;

  /// Why [facts] is null when the project map was skipped: its skip reason,
  /// which the user can act on.
  final String? skipped;

  /// When collecting [facts] failed (an Appstein bug, not the project's),
  /// the type of the error, such as `StateError`; null otherwise. Only the
  /// type is shown, since the error's message may hold a machine path.
  final String? internalError;
}

/// The curated notes the delta lists: those for [flutterVersion] whose
/// `since` is at or after [baseline], most important first. None when
/// [flutterVersion] isn't a version number.
List<CuratedNote> deltaNotes(
  CuratedNotes notes, {
  required String flutterVersion,
  required String baseline,
}) {
  final floor = flutterMinorOf(baseline);
  return [
    for (final note in notes.notesFor(flutterVersion))
      if (floor == null ||
          compareFlutterMinors(flutterMinorOf(note.since)!, floor) >= 0)
        note,
  ];
}

/// The text of `delta.md` without its front matter (spec §6.4): the notes,
/// the notes that need a newer language version, then (when the map ran)
/// the deprecated, removed and moved APIs, and the migration files that
/// couldn't be read. Every line quotes a note, a library's message or a
/// migration's title.
String renderDelta(DeltaInputs inputs) {
  final out = StringBuffer();
  void paragraph(String text) => out
    ..writeln()
    ..writeln(text);

  out.writeln(
    '# Version delta: Flutter ${inputs.flutterVersion}, Dart language '
    '${inputs.languageVersion ?? 'unknown'}',
  );
  paragraph(
    "What changed in Flutter, Dart and this project's packages that matters "
    'for the code you write. `appstein sync` generates this file from the '
    "installed SDK, the project's packages and Appstein's curated notes; "
    "don't edit it.",
  );
  if (inputs.coverage == NotesCoverage.partial) {
    paragraph(
      'Curated notes may be incomplete for Flutter '
      '${_minorText(inputs.flutterVersion)}: the newest notes are for '
      '${inputs.newestNotes}.',
    );
  }
  final facts = inputs.facts;
  if (facts == null) {
    paragraph(switch (inputs.internalError) {
      final error? =>
        "Deprecated and removed APIs are missing: Appstein couldn't collect "
            'them because of an internal error (${_oneLine(error)}). Please '
            'report it.',
      null =>
        'Deprecated and removed APIs are missing: '
            "${_withFullStop(inputs.skipped ?? 'no reason was given')} "
            'Fix that, then run `appstein sync` again.',
    });
  }

  final usable = <CuratedNote>[];
  final later = <CuratedNote>[];
  for (final note in inputs.notes) {
    (needsNewerLanguage(note, inputs.languageVersion) ? later : usable).add(
      note,
    );
  }
  paragraph('## Notes');
  paragraph(
    "Appstein's curated notes since Flutter ${inputs.baseline}, most "
    'important first (priority 1 to 3).',
  );
  _notes(out, usable);
  if (later.isNotEmpty) {
    paragraph('## Needs a newer language version');
    paragraph(
      "The project's language version is ${inputs.languageVersion}, the "
      'lower bound of `environment: sdk:` in `pubspec.yaml`. These notes '
      'need a newer one: raise that bound to use them.',
    );
    _notes(out, later);
  }
  if (facts == null) return out.toString();

  paragraph('## Deprecated');
  paragraph(
    "APIs the project's imports expose that are deprecated, with each "
    "library's own message. `dart analyze` reports each use.",
  );
  _grouped(out, [
    for (final api in facts.deprecated) (api.group, _deprecatedLine(api)),
  ]);
  paragraph('## Removed');
  paragraph(
    'APIs from the migration lists (`fix_data`) of the SDKs and the '
    "packages, each with its migration's title; `dart fix` applies each "
    "migration. `removed`: gone; code that uses it doesn't compile. "
    "`changed`: it still exists, and `dart fix` changes how it's used; the "
    "migration's title says how.",
  );
  _grouped(out, [
    for (final api in facts.migrated)
      (
        api.group,
        '- `${api.name}`: ${api.status.name}. ${_withFullStop(api.title)}',
      ),
  ]);
  if (facts.moved.isNotEmpty) {
    paragraph('## Moved libraries');
    paragraph(
      'Libraries a migration (`fix_data`) moves elsewhere. Check the notes '
      'above before switching.',
    );
    out.writeln();
    for (final moved in facts.moved) {
      final to = moved.to == null ? '' : ' → `${moved.to}`';
      out.writeln('- `${moved.from}`$to: ${_withFullStop(moved.title)}');
    }
  }
  if (facts.unread.isNotEmpty) {
    paragraph('## Not read');
    paragraph(
      "Migration files Appstein couldn't read, so their migrations are "
      'missing above.',
    );
    out.writeln();
    for (final unread in facts.unread) {
      out.writeln('- `${unread.file}`: ${_oneLine(unread.reason)}');
    }
  }
  return out.toString();
}

void _notes(StringBuffer out, List<CuratedNote> notes) {
  out.writeln();
  if (notes.isEmpty) {
    out.writeln('None.');
    return;
  }
  for (final note in notes) {
    final language = note.languageVersion == null
        ? ''
        : ', language ${note.languageVersion}';
    out
      ..writeln(
        '- **${note.id}** (priority ${note.priority}, since '
        '${note.since}$language): ${note.summary}',
      )
      ..writeln('  - Use: ${note.use}')
      ..writeln('  - Avoid: ${note.avoid}')
      ..writeln('  - Source: ${note.source}');
  }
}

/// Writes [lines] under a `###` heading per group, in the order given.
void _grouped(StringBuffer out, List<(String, String)> lines) {
  if (lines.isEmpty) {
    out
      ..writeln()
      ..writeln('None.');
    return;
  }
  String? current;
  for (final (group, line) in lines) {
    if (group != current) {
      out
        ..writeln()
        ..writeln('### $group')
        ..writeln();
      current = group;
    }
    out.writeln(line);
  }
}

String _deprecatedLine(DeprecatedApi api) {
  final message = api.message;
  final parts = [
    ?api.kind.rule,
    if (message != null)
      // Two sentences follow when migrations come after the message, so the
      // message needs its own full stop (punctuation only, no advice).
      api.migrations.isEmpty ? message : _withFullStop(message)
    else if (api.kind == DeprecationKind.use)
      'deprecated, with no message.',
    for (final title in api.migrations)
      '`dart fix` migrates it: ${_withFullStop(title)}',
  ];
  return '- `${api.name}`: ${parts.join(' ')}';
}

/// Whether [note] needs a newer Dart language version than the project's
/// [languageVersion]: such notes are listed apart in `delta.md` and left
/// out of `INDEX.md`. False when either version is unknown.
bool needsNewerLanguage(CuratedNote note, String? languageVersion) {
  final needed = note.languageVersion;
  if (needed == null || languageVersion == null) return false;
  final neededMinor = flutterMinorOf(needed);
  final projectMinor = flutterMinorOf(languageVersion);
  if (neededMinor == null || projectMinor == null) return false;
  return compareFlutterMinors(neededMinor, projectMinor) > 0;
}

String _minorText(String version) {
  final minor = flutterMinorOf(version);
  return minor == null ? version : '${minor.major}.${minor.minor}';
}

/// [text] on one line, ending in a full stop.
String _withFullStop(String text) {
  final line = _oneLine(text);
  return line.endsWith('.') || line.endsWith('!') || line.endsWith('?')
      ? line
      : '$line.';
}

/// [text] with each run of white space, line breaks included, as one space,
/// so a quoted title or reason can't break a Markdown list.
String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
