/// Regenerates `bundled_notes.g.dart` from `notes/*.yaml`, so the curated
/// notes are compiled into the `appstein` binary (spec §6.4).
///
/// Run it from the repo root after editing a notes file:
/// `fvm dart run tool/gen_notes.dart`. `test/notes_bundle_test.dart` fails
/// while the generated file is out of date.
library;

import 'dart:io';

import 'src/notes_bundle.dart';

void main() {
  final target = File(notesBundleFile);
  final text = renderNotesBundle(readNotesSources(Directory.current.path));
  if (target.existsSync() && target.readAsStringSync() == text) {
    stdout.writeln('$notesBundleFile is up to date.');
    return;
  }
  target.writeAsStringSync(text);
  stdout.writeln('Wrote $notesBundleFile.');
}
