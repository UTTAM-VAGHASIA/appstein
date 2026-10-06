import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../knowledge/plain_text.dart';

/// The task in progress, as a path from the project folder (spec §6.8).
const memoryCurrentPath = '.appstein/memory/current.md';

/// The lessons, as a path from the project folder (spec §6.8).
const memoryLessonsPath = '.appstein/memory/lessons.md';

/// The file at [path] (one of the memory paths) in the project at
/// [projectRoot].
File memoryFile(String projectRoot, String path) =>
    File(p.joinAll([projectRoot, ...path.split('/')]));

/// A memory file as it was read: its bytes, or why it can't be read. Both
/// are null when the file doesn't exist.
typedef MemoryBytes = ({List<int>? bytes, String? problem});

/// Reads [file]. It never throws for a file that is missing or unreadable.
MemoryBytes readMemoryFile(File file) {
  try {
    return (bytes: file.readAsBytesSync(), problem: null);
  } on FileSystemException catch (error) {
    final missing =
        FileSystemEntity.typeSync(file.path) == FileSystemEntityType.notFound;
    return (bytes: null, problem: missing ? null : fileErrorReason(error));
  }
}

/// The text of a memory file's [bytes], without a byte order mark.
String memoryText(List<int> bytes) =>
    withoutBom(utf8.decode(bytes, allowMalformed: true));

/// One lesson line for `lessons.md` (spec §6.8): a list item with [date]
/// and [text] on one line, such as `- 2026-10-03: plugin X needs minSdk 26`.
String lessonLine(String date, String text) => '- $date: ${oneLine(text)}';

/// The lessons in the [text] of a `lessons.md`: its lines that aren't
/// blank or headings, each without its list marker.
List<String> lessonsIn(String text) => [
  for (final line in const LineSplitter().convert(withoutBom(text)))
    if (line.trim().isNotEmpty && !line.trimLeft().startsWith('#'))
      line.trim().replaceFirst(RegExp(r'^[-*]\s+'), ''),
];

final _dated = RegExp(r'^\d{4}-\d{2}-\d{2}:\s*');

/// The [bytes] of a `lessons.md` (null without the file) with the lesson
/// [line] appended. Every byte already there is kept; the new line uses the
/// file's line breaks. Null when the file already holds that lesson, on
/// whatever date.
List<int>? withLesson(List<int>? bytes, String line) {
  String withoutDate(String lesson) => lesson.replaceFirst(_dated, '');
  final lesson = withoutDate(lessonsIn(line).single);
  final existing = bytes ?? const <int>[];
  final text = utf8.decode(existing, allowMalformed: true);
  if (lessonsIn(text).map(withoutDate).contains(lesson)) return null;
  final eol = text.contains('\r\n') ? '\r\n' : '\n';
  return [
    ...existing,
    if (existing.isNotEmpty && existing.last != 0x0A) ...utf8.encode(eol),
    ...utf8.encode('$line$eol'),
  ];
}
