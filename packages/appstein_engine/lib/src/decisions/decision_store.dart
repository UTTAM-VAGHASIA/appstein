import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import 'decision_file.dart';

/// The decision file named [file] as a path from the project folder, such
/// as `.appstein/decisions/0002-state.md`.
String decisionPath(String file) => '.appstein/decisions/$file';

/// The folder of the decision files of the project at [projectRoot].
String decisionsFolder(String projectRoot) =>
    p.join(projectRoot, '.appstein', 'decisions');

/// One decision as every reader sees it (spec §6.7, Reading).
final class DecisionEntry {
  /// Creates the entry.
  const DecisionEntry(this.record, {required this.status, this.supersededBy});

  /// The record as its file holds it.
  final DecisionRecord record;

  /// Its status for readers: `superseded` when its file says so or when
  /// [supersededBy] is set, and the file's status otherwise.
  final DecisionStatus status;

  /// The accepted or proposed decision that names this one in `supersedes`;
  /// null when none does.
  final DecisionRecord? supersededBy;

  /// Whether it is in force or waiting to be: accepted or proposed.
  bool get active => status != DecisionStatus.superseded;
}

/// The decisions of one project, read by the rules of spec §6.7.
final class DecisionSet {
  /// Creates the set.
  const DecisionSet({
    this.entries = const [],
    this.unreadable = const [],
    this.duplicates = const {},
    this.problems = const [],
    this.folderProblem,
    this.bytes = const {},
    this.readProblems = const {},
  });

  /// The decisions that were read, in file-name order.
  final List<DecisionEntry> entries;

  /// The files that can't be read, in file-name order.
  final List<UnreadableDecision> unreadable;

  /// The numbers more than one file uses, each with those files' names.
  final Map<int, List<String>> duplicates;

  /// What else is wrong, as sentences: decisions that supersede each other
  /// in a circle.
  final List<String> problems;

  /// Why the folder couldn't be listed; null when it could, or isn't there.
  final String? folderProblem;

  /// The bytes of each file that could be opened, by file name.
  final Map<String, List<int>> bytes;

  /// Why a file couldn't be opened, by file name. Each is in [unreadable]
  /// too.
  final Map<String, String> readProblems;

  /// The accepted and proposed decisions, in file-name order.
  List<DecisionEntry> get active => [
    for (final entry in entries)
      if (entry.active) entry,
  ];

  /// The number a new decision gets: one more than the highest number any
  /// file's name has, an unreadable file's included, so a number is never
  /// used twice.
  int get nextNumber {
    var highest = 0;
    for (final number in [
      for (final entry in entries) entry.record.number,
      for (final file in unreadable) file.number,
    ]) {
      if (number != null && number > highest) highest = number;
    }
    return highest + 1;
  }

  /// The one decision numbered [number]; null when no readable file has
  /// that number, or more than one has ([duplicates]).
  DecisionEntry? numbered(int number) {
    final found = [
      for (final entry in entries)
        if (entry.record.number == number) entry,
    ];
    return found.length == 1 && !duplicates.containsKey(number)
        ? found.single
        : null;
  }
}

/// Reads the decisions of the project at [projectRoot]: every `.md` file
/// directly in `.appstein/decisions/` (spec §6.7).
///
/// It never throws for the project's own files: a file or folder that
/// can't be read is reported in the set.
DecisionSet readDecisions(String projectRoot) {
  final folder = Directory(decisionsFolder(projectRoot));
  if (!folder.existsSync()) return const DecisionSet();

  final files = <DecisionFile>[];
  final bytes = <String, List<int>>{};
  final readProblems = <String, String>{};
  try {
    final found = [
      for (final entity in folder.listSync(followLinks: false))
        if (entity is File && entity.path.endsWith('.md')) entity,
    ]..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    for (final file in found) {
      final name = p.basename(file.path);
      try {
        final content = file.readAsBytesSync();
        bytes[name] = content;
        files.add(
          parseDecisionFile(name, utf8.decode(content, allowMalformed: true)),
        );
      } on FileSystemException catch (error) {
        final reason = fileErrorReason(error);
        readProblems[name] = reason;
        files.add(UnreadableDecision(name, reason));
      }
    }
  } on FileSystemException catch (error) {
    return DecisionSet(folderProblem: fileErrorReason(error));
  }

  final records = [
    for (final file in files)
      if (file is ReadDecision) file.record,
  ];
  final problems = <String>[];
  final replacedBy = _replacements(records, problems);

  final names = <int, List<String>>{};
  for (final file in files) {
    if (file.number case final number?) {
      (names[number] ??= []).add(file.file);
    }
  }
  return DecisionSet(
    entries: [
      for (final record in records)
        DecisionEntry(
          record,
          status: replacedBy.containsKey(record)
              ? DecisionStatus.superseded
              : record.status,
          supersededBy: replacedBy[record],
        ),
    ],
    unreadable: [
      for (final file in files)
        if (file is UnreadableDecision) file,
    ],
    duplicates: {
      for (final MapEntry(key: number, value: files) in names.entries)
        if (files.length > 1) number: files,
    },
    problems: problems,
    bytes: bytes,
    readProblems: readProblems,
  );
}

/// Which decision replaces which (spec §6.7): a record is replaced by the
/// record that names its number in `supersedes` and whose own status line
/// is accepted or proposed. When several do, the highest number counts.
///
/// Records that supersede each other in a circle would leave none in
/// force, so the one with the highest number stays; [problems] gets a
/// sentence about each circle.
Map<DecisionRecord, DecisionRecord> _replacements(
  List<DecisionRecord> records,
  List<String> problems,
) {
  bool replaces(DecisionRecord record) =>
      record.supersedes != null && record.status != DecisionStatus.superseded;
  final byNumber = <int, List<DecisionRecord>>{};
  for (final record in records) {
    if (record.number case final number?) {
      (byNumber[number] ??= []).add(record);
    }
  }

  /// The numbers on the circle through [start], or null when following
  /// `supersedes` from it never comes back.
  List<int>? circleThrough(int start) {
    final seen = <int>[start];
    var at = start;
    while (true) {
      final next = [
        for (final record in byNumber[at] ?? const <DecisionRecord>[])
          if (replaces(record)) record.supersedes!,
      ];
      if (next.isEmpty) return null;
      at = next.first;
      if (at == start) return seen;
      if (seen.contains(at)) return null;
      seen.add(at);
    }
  }

  final reported = <String>{};
  final replacedBy = <DecisionRecord, DecisionRecord>{};
  for (final record in records.where(replaces)) {
    final target = record.supersedes!;
    final circle = circleThrough(target);
    if (circle != null && circle.contains(record.number)) {
      final kept = circle.reduce((a, b) => a > b ? a : b);
      final sorted = [...circle]..sort();
      final key = sorted.join(',');
      if (reported.add(key)) {
        final names = sorted.map(decisionNumberText).toList();
        problems.add(
          'Decisions ${names.take(names.length - 1).join(', ')} and '
          '${names.last} supersede each other in a circle; '
          '${decisionNumberText(kept)} is counted as the one in force.',
        );
      }
      if (target == kept) continue;
    }
    for (final replaced in byNumber[target] ?? const <DecisionRecord>[]) {
      if (identical(replaced, record)) continue;
      final current = replacedBy[replaced];
      if (current == null || (record.number ?? 0) > (current.number ?? 0)) {
        replacedBy[replaced] = record;
      }
    }
  }
  return replacedBy;
}
