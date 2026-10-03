import 'package:appstein_protocol/appstein_protocol.dart';

import '../notes/flutter_minor.dart';
import 'tool_answer.dart';

/// `what_changed` (spec §8): the curated notes since [since] (by default
/// the baseline; `since` narrows only the notes), and, per library, how
/// many deprecated, removed, changed and moved APIs [delta] lists. With
/// [library] (`package:go_router`; `go_router` works too), that library's
/// entries in full. Without it, no entry is listed: a real app's delta has
/// hundreds, too many for an agent's context; `check_api` answers for one
/// name.
///
/// A moved library counts under its package (`package:flutter/material.dart`
/// under `package:flutter`).
ToolAnswer whatChanged(DeltaKnowledge delta, {String? since, String? library}) {
  FlutterMinor? from;
  if (since != null) {
    from = flutterMinorOf(since.trim());
    if (from == null) {
      return ToolRefusal(
        '"$since" is not a Flutter version; give one such as `3.27`.',
      );
    }
  }
  final baseline = flutterMinorOf(delta.baseline);
  final beforeBaseline =
      from != null &&
      baseline != null &&
      compareFlutterMinors(from, baseline) < 0;
  final notesFrom = from == null || beforeBaseline
      ? delta.baseline
      : '${from.major}.${from.minor}';
  bool keep(CuratedNote note) {
    if (from == null) return true;
    final noteMinor = flutterMinorOf(note.since);
    return noteMinor == null || compareFlutterMinors(noteMinor, from) >= 0;
  }

  final notes = [
    for (final note in delta.notes)
      if (keep(note)) note,
  ];
  final laterNotes = [
    for (final note in delta.laterNotes)
      if (keep(note)) note,
  ];
  final apis = delta.apis;
  final counts = <String, Map<String, int>>{};
  Map<String, int> countsOf(String name) => counts.putIfAbsent(
    name,
    () => {'deprecated': 0, 'removed': 0, 'changed': 0, 'moved': 0},
  );
  if (apis != null) {
    for (final api in apis.deprecated) {
      countsOf(api.library).update('deprecated', (n) => n + 1);
    }
    for (final api in apis.migrated) {
      countsOf(api.library).update(api.status, (n) => n + 1, ifAbsent: () => 1);
    }
    for (final moved in apis.moved) {
      countsOf(_libraryOf(moved.from)).update('moved', (n) => n + 1);
    }
  }
  final names = counts.keys.toList()..sort();
  final libraries = [
    for (final name in names) {'library': name, ...counts[name]!},
  ];
  Map<String, Object?>? entries;
  String? wanted;
  if (library != null) {
    wanted = library.trim();
    if (!wanted.contains(':')) wanted = 'package:$wanted';
    if (apis == null) {
      return ToolRefusal('The API lists are missing: ${delta.missing}.');
    }
    if (!counts.containsKey(wanted)) {
      return ToolRefusal(
        'No library "$wanted" has deprecated, removed or moved APIs in the '
        'delta. Libraries that do: ${names.join(', ')}.',
      );
    }
    entries = {
      'library': wanted,
      'deprecated': [
        for (final api in apis.deprecated)
          if (api.library == wanted) api.toJson(),
      ],
      'migrated': [
        for (final api in apis.migrated)
          if (api.library == wanted) api.toJson(),
      ],
      'moved': [
        for (final moved in apis.moved)
          if (_libraryOf(moved.from) == wanted) moved.toJson(),
      ],
    };
  }
  int total(String key) =>
      libraries.fold(0, (sum, row) => sum + (row[key]! as int));
  final summary = [
    '${notes.length} curated ${notes.length == 1 ? 'note' : 'notes'} since '
        '$notesFrom'
        '${laterNotes.isEmpty ? '' : ' (${laterNotes.length} more '
                  '${laterNotes.length == 1 ? 'needs' : 'need'} a newer '
                  'language version)'}'
        '${beforeBaseline ? '; the notes start at the baseline, '
                  '${delta.baseline}' : ''};',
    if (apis == null)
      'the API lists are missing (${delta.missing}).'
    else
      '${total('deprecated')} deprecated, ${total('removed')} removed, '
          '${total('changed')} changed and ${total('moved')} moved APIs in '
          '${libraries.length} '
          '${libraries.length == 1 ? 'library' : 'libraries'}.',
    if (entries == null && apis != null)
      "Ask `check_api` about one name, or pass `library` for a library's "
          'list.',
    if (entries != null)
      '`$wanted`: ${(entries['deprecated']! as List).length} deprecated, '
          '${(entries['migrated']! as List).length} removed or changed and '
          '${(entries['moved']! as List).length} moved APIs listed.',
  ].join(' ');
  return ToolReply({
    'flutterVersion': delta.flutterVersion,
    'coverage': delta.coverage,
    'notesFrom': notesFrom,
    'notes': [for (final note in notes) note.toJson()],
    'laterNotes': [for (final note in laterNotes) note.toJson()],
    'libraries': libraries,
    'library': ?entries,
    'unread': [
      for (final unread in apis?.unread ?? const <DeltaUnreadFile>[])
        unread.toJson(),
    ],
    'apiListsMissing': ?(apis == null ? delta.missing : null),
  }, summary);
}

/// The library a URI belongs to: `package:<name>` for a package URI, the
/// URI itself otherwise (`dart:core`).
String _libraryOf(String uri) => uri.startsWith('package:')
    ? 'package:${uri.substring('package:'.length).split('/').first}'
    : uri;
