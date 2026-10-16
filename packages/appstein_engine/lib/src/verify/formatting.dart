import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// How long one fast run may spend asking the analysis server which of the
/// unverified files its formatter would change ([VerifyGathering.formatting]),
/// so the questions can't push a fast run past its 5 s target (spec §9.1,
/// §15). The server answers many questions sent together in a few
/// milliseconds each, and keeps an answer while it runs, so a file that did
/// not change is asked about once. A file not answered in time is named among
/// the checks not run, never taken for formatted.
const formatBudgetFast = Duration(seconds: 1);

/// How long a full run may spend on the same questions about every Dart file
/// of the project. A full run has no target to meet; the limit only keeps a
/// server that has stopped answering from holding the run for good.
const formatBudgetFull = Duration(seconds: 60);

/// What the run learned about the formatting of the Dart files it looked at
/// ([VerifyGathering.formatting]).
final class FormatReading {
  /// Creates the reading.
  const FormatReading({
    this.unformatted = const [],
    this.unchecked = const [],
    this.checked = 0,
    this.why,
  });

  /// The files the formatter would change, from the project root with `/`,
  /// sorted.
  final List<String> unformatted;

  /// The files that were to be checked and were not, sorted: the server did
  /// not answer in time, or could not answer at all ([why]). A file here is
  /// not known to be formatted.
  final List<String> unchecked;

  /// How many files the run asked about, answered or not.
  final int checked;

  /// Why [unchecked] files were not answered, as the end of "the formatting
  /// of 3 of 12 files was not checked: …"; null when [unchecked] is empty.
  final String? why;
}

/// The words that mark a generated file, as generators write them in the
/// header: `// GENERATED CODE - DO NOT MODIFY BY HAND`.
const _generatedMarker = 'GENERATED CODE - DO NOT MODIFY';

/// How much of the start of a file is read to look for the header.
const _headBytes = 4096;

/// Whether [head], the start of a Dart file, begins with a header comment
/// that says the file is generated (`GENERATED CODE - DO NOT MODIFY`): in the
/// comment lines that come before the first line of code, whatever else the
/// header says (a license comes first in many generated files).
bool hasGeneratedHeader(String head) {
  for (final line in const LineSplitter().convert(head)) {
    // A byte order mark stands before the first character of the file.
    final text = line.replaceFirst('\u{FEFF}', '').trim();
    if (text.isEmpty) continue;
    if (!text.startsWith('//')) return false;
    if (text.contains(_generatedMarker)) return true;
  }
  return false;
}

/// What a look at the Dart file [relative] (from [projectRoot], with `/`)
/// found before the formatter is asked about it:
///
/// - `exists`: false when the file is no longer on disk. The analysis server
///   lists a file it has not yet noticed was deleted, and its formatter
///   would answer for the empty text of a file that is not there.
/// - `generated`: whether it starts with a generated-code header
///   ([hasGeneratedHeader]). A file that exists but can't be opened is not
///   taken for generated: it is asked about like any other.
Future<({bool exists, bool generated})> lookAtDartFile(
  String projectRoot,
  String relative,
) async {
  final path = p.joinAll([projectRoot, ...relative.split('/')]);
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final head = await file.read(_headBytes);
    return (
      exists: true,
      generated: hasGeneratedHeader(utf8.decode(head, allowMalformed: true)),
    );
  } on FileSystemException {
    return (exists: await File(path).exists(), generated: false);
  } finally {
    await file?.close();
  }
}
