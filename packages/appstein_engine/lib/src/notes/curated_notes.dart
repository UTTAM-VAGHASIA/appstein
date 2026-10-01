import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';

import 'bundled_notes.g.dart';
import 'flutter_minor.dart';
import 'notes_parser.dart';

/// Appstein's curated notes (spec §6.4): one file per stable Flutter minor
/// version, and the stores' build minimums.
final class CuratedNotes {
  CuratedNotes._(this.files, this.stores, this.inputs);

  /// Reads [sources]: file name (such as `3.47.yaml` or `stores.yaml`) to
  /// YAML text.
  ///
  /// Throws [NotesFormatException] when a file is malformed, a note id
  /// appears in two files, or `stores.yaml` or every notes file is missing.
  factory CuratedNotes.parse(Map<String, String> sources) {
    final files = <NotesFile>[];
    StoreRequirements? stores;
    for (final name in sources.keys.toList()..sort()) {
      if (name == 'stores.yaml') {
        stores = parseStoreRequirements(name, sources[name]!);
      } else {
        files.add(parseNotesFile(name, sources[name]!));
      }
    }
    if (stores == null) {
      throw const NotesFormatException('stores.yaml', null, 'is missing.');
    }
    if (files.isEmpty) {
      throw const NotesFormatException('notes', null, 'has no notes files.');
    }
    files.sort(
      (a, b) => compareFlutterMinors(
        flutterMinorOf(a.flutter)!,
        flutterMinorOf(b.flutter)!,
      ),
    );
    final seen = <String, String>{};
    for (final file in files) {
      for (final note in file.notes) {
        final other = seen[note.id];
        if (other != null) {
          throw NotesFormatException(
            '${file.flutter}.yaml',
            null,
            'Note "${note.id}" is also in $other.',
          );
        }
        seen[note.id] = '${file.flutter}.yaml';
      }
    }
    return CuratedNotes._(files, stores, {
      for (final entry in sources.entries)
        'notes:${entry.key}': utf8.encode(entry.value),
    });
  }

  /// The notes compiled into this Appstein (`notes/` in its repo).
  factory CuratedNotes.bundled() => CuratedNotes.parse(bundledNotes);

  /// The notes files, oldest Flutter first.
  final List<NotesFile> files;

  /// The stores' build minimums.
  final StoreRequirements stores;

  /// Each source file's bytes by `notes:<file name>`, for input hashes.
  final Map<String, List<int>> inputs;

  /// The newest Flutter minor version the notes cover, such as `3.47`.
  String get newestMinor => files.last.flutter;

  /// How well the notes cover [flutterVersion] (spec §6.4): partial when it
  /// is newer than [newestMinor] or isn't a version number.
  NotesCoverage coverageFor(String flutterVersion) {
    final minor = flutterMinorOf(flutterVersion);
    final newest = flutterMinorOf(newestMinor)!;
    return minor != null && compareFlutterMinors(minor, newest) <= 0
        ? NotesCoverage.complete
        : NotesCoverage.partial;
  }

  /// The newest notes file at or below [flutterVersion]'s minor version,
  /// whose toolchain matrix is the fallback (spec §12), or null when there
  /// is none.
  NotesFile? fileFor(String flutterVersion) {
    final minor = flutterMinorOf(flutterVersion);
    if (minor == null) return null;
    NotesFile? found;
    for (final file in files) {
      if (compareFlutterMinors(flutterMinorOf(file.flutter)!, minor) <= 0) {
        found = file;
      }
    }
    return found;
  }

  /// The notes that apply to [flutterVersion] (their `since` is at or below
  /// its minor version), in [areas] when given. They're sorted by priority,
  /// then `since`, then id. Empty when [flutterVersion] isn't a version
  /// number.
  List<CuratedNote> notesFor(String flutterVersion, {Set<NoteArea>? areas}) {
    final minor = flutterMinorOf(flutterVersion);
    if (minor == null) return const [];
    return [
      for (final file in files)
        for (final note in file.notes)
          if (compareFlutterMinors(flutterMinorOf(note.since)!, minor) <= 0 &&
              (areas == null || areas.contains(note.area)))
            note,
    ]..sort((a, b) {
      final byPriority = a.priority.compareTo(b.priority);
      if (byPriority != 0) return byPriority;
      final bySince = compareFlutterMinors(
        flutterMinorOf(a.since)!,
        flutterMinorOf(b.since)!,
      );
      return bySince != 0 ? bySince : a.id.compareTo(b.id);
    });
  }
}
