import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../knowledge/knowledge_lock.dart';
import '../knowledge/knowledge_store.dart';
import '../knowledge/knowledge_write_exception.dart';
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

  /// The decision that names this one in `supersedes`, whatever its own
  /// status; null when none does.
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
        // `.MD` too: on Windows and macOS it names the same file as `.md`.
        if (entity is File && entity.path.toLowerCase().endsWith('.md')) entity,
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

/// What `record_decision` is asked to do (spec §6.7, Writing): an
/// [AddDecision] or an [AcceptDecision].
sealed class DecisionRequest {
  const DecisionRequest();
}

/// A new decision, which replaces decision [supersedes] when that is set.
final class AddDecision extends DecisionRequest {
  /// Creates the request. [title] is one line, [paths] are POSIX patterns
  /// from the project folder, and [checks] are built-in checks.
  const AddDecision({
    required this.title,
    required this.why,
    this.status = DecisionStatus.proposed,
    this.paths = const [],
    this.checks = const [],
    this.supersedes,
  });

  /// What was decided, on one line.
  final String title;

  /// The reason.
  final String why;

  /// `proposed`, or `accepted` when the user agreed.
  final DecisionStatus status;

  /// The path patterns it applies to.
  final List<String> paths;

  /// The verifier checks that confirm it.
  final List<String> checks;

  /// The number of the decision it replaces; null when it replaces none.
  final int? supersedes;
}

/// The proposed decision [number] becomes accepted.
final class AcceptDecision extends DecisionRequest {
  /// Creates the request.
  const AcceptDecision(this.number);

  /// The decision's number.
  final int number;
}

/// Thrown by [writeDecision] for a request the project's decisions don't
/// allow, before anything is written.
final class DecisionRefused implements Exception {
  /// Creates the refusal.
  const DecisionRefused(this.message);

  /// Why, for the agent.
  final String message;

  @override
  String toString() => message;
}

/// What [writeDecision] did.
final class DecisionWritten {
  /// Creates the result.
  const DecisionWritten({
    required this.action,
    required this.decision,
    this.superseded,
    this.warning,
  });

  /// `added`, `replaced` or `accepted`.
  final String action;

  /// The decision that was added or accepted, as readers see it now.
  final DecisionEntry decision;

  /// The decision that was replaced, as readers see it now.
  final DecisionEntry? superseded;

  /// What couldn't be done after the decision was written: the replaced
  /// file's status line was left as it is, and why.
  final String? warning;
}

/// Carries out [request] in the project at [projectRoot] (spec §6.7,
/// Writing), holding the `.appstein/` write lock (spec §15) so two writers
/// never take the same number. [today] is the date a new decision gets.
///
/// An existing decision's text is never rewritten: only the word on its
/// `status:` line changes. Throws [DecisionRefused] before writing when the
/// decisions don't allow the request, a [KnowledgeLockTimeout] when another
/// writer holds the lock for [lockTimeout], and a
/// [KnowledgeWriteException] when the file can't be written.
Future<DecisionWritten> writeDecision(
  String projectRoot,
  DecisionRequest request, {
  required String today,
  Duration lockTimeout = const Duration(seconds: 10),
}) async {
  final lock = await KnowledgeLock.acquire(
    p.join(projectRoot, '.appstein'),
    timeout: lockTimeout,
  );
  try {
    final decisions = readDecisions(projectRoot);
    if (decisions.folderProblem case final problem?) {
      throw DecisionRefused(
        '`.appstein/decisions/` could not be read ($problem).',
      );
    }
    return switch (request) {
      AddDecision() => await _add(projectRoot, decisions, request, today),
      AcceptDecision() => await _accept(projectRoot, decisions, request),
    };
  } finally {
    lock.release();
  }
}

Future<DecisionWritten> _add(
  String projectRoot,
  DecisionSet decisions,
  AddDecision request,
  String today,
) async {
  DecisionEntry? replaced;
  if (request.supersedes case final target?) {
    replaced = _numbered(decisions, target);
    if (!replaced.active) {
      throw DecisionRefused(
        'Decision ${decisionNumberText(target)} is already superseded'
        '${switch (replaced.supersededBy?.numberText) {
          final by? => ', by $by',
          null => '',
        }}.',
      );
    }
  }
  final number = decisions.nextNumber;
  final name =
      '${decisionNumberText(number)}-${decisionSlug(request.title)}.md';
  final text = renderDecision(
    number: number,
    title: request.title,
    status: request.status,
    date: today,
    supersedes: request.supersedes,
    paths: request.paths,
    checks: request.checks,
    why: request.why,
  );
  // Read it back before writing: a file the reader can't read, or reads
  // differently, must never be written.
  final back = parseDecisionFile(name, text);
  if (back is! ReadDecision ||
      back.record.title != request.title ||
      !_same(back.record.paths, request.paths) ||
      !_same(back.record.checks, request.checks) ||
      back.record.supersedes != request.supersedes ||
      back.record.status != request.status) {
    throw const DecisionRefused(
      'The title or a path holds characters a decision file cannot store. '
      'Reword it with plain text.',
    );
  }
  final path = p.join(decisionsFolder(projectRoot), name);
  if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
    throw DecisionRefused(
      '${decisionPath(name)} already exists, and decisions are never '
      'overwritten. Rename that file, then try again.',
    );
  }
  await replaceFile(path, text);

  String? warning;
  if (replaced != null) {
    final file = replaced.record.file;
    final changed = _withStatus(
      decisions.bytes[file]!,
      DecisionStatus.superseded,
    );
    if (changed == null) {
      warning =
          "The status line of ${decisionPath(file)} isn't a plain "
          '`status: word` line, so it was left as it is. Change it to '
          '`superseded` by hand.';
    } else {
      try {
        await replaceFileBytes(
          p.join(decisionsFolder(projectRoot), file),
          changed,
        );
      } on KnowledgeWriteException catch (error) {
        // The store's advice to run `appstein sync` is for generated files.
        final reason = error.reason
            .replaceAll(' and run `appstein sync` again', '')
            .replaceFirst(RegExp(r'\.$'), '');
        warning =
            "The status line of ${decisionPath(file)} couldn't be changed "
            'to `superseded` ($reason). Change it by hand.';
      }
    }
  }

  final after = readDecisions(projectRoot);
  return DecisionWritten(
    action: replaced == null ? 'added' : 'replaced',
    decision: _written(after, number),
    superseded: replaced == null
        ? null
        : _written(after, replaced.record.number!),
    warning: warning,
  );
}

Future<DecisionWritten> _accept(
  String projectRoot,
  DecisionSet decisions,
  AcceptDecision request,
) async {
  final entry = _numbered(decisions, request.number);
  final number = decisionNumberText(request.number);
  switch (entry.status) {
    case DecisionStatus.accepted:
      throw DecisionRefused('Decision $number is accepted already.');
    case DecisionStatus.superseded:
      throw DecisionRefused(
        'Decision $number is superseded'
        '${switch (entry.supersededBy?.numberText) {
          final by? => ' by $by',
          null => '',
        }}, '
        "so it can't be accepted.",
      );
    case DecisionStatus.proposed:
  }
  final file = entry.record.file;
  final changed = _withStatus(decisions.bytes[file]!, DecisionStatus.accepted);
  if (changed == null) {
    throw DecisionRefused(
      "The status line of ${decisionPath(file)} isn't a plain "
      '`status: proposed` line; change it to `accepted` by hand.',
    );
  }
  await replaceFileBytes(p.join(decisionsFolder(projectRoot), file), changed);
  return DecisionWritten(
    action: 'accepted',
    decision: _written(readDecisions(projectRoot), request.number),
  );
}

/// Decision [number] as [decisions], read after a write, holds it. The
/// write was checked before it was made, so not finding it means the file
/// changed under the lock: a [KnowledgeWriteException] says so.
DecisionEntry _written(DecisionSet decisions, int number) =>
    decisions.numbered(number) ??
    (throw KnowledgeWriteException(
      decisionsFolder('.'),
      'decision ${decisionNumberText(number)} was written but could not be '
      'read back; look at the files in `.appstein/decisions/`',
    ));

bool _same(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The one readable decision numbered [number], or a [DecisionRefused]
/// that says why there is none.
DecisionEntry _numbered(DecisionSet decisions, int number) {
  final text = decisionNumberText(number);
  if (decisions.duplicates[number] case final files?) {
    throw DecisionRefused(
      'Number $text is used by ${files.length} files (${files.join(', ')}); '
      'rename one first.',
    );
  }
  for (final file in decisions.unreadable) {
    if (file.number == number) {
      throw DecisionRefused(
        "Decision $text can't be read (${decisionPath(file.file)}: "
        '${file.problem}); fix the file first.',
      );
    }
  }
  final entry = decisions.numbered(number);
  if (entry == null) throw DecisionRefused('No decision is numbered $text.');
  return entry;
}

/// The [bytes] of a decision file with its status changed to [status],
/// keeping a byte order mark and every other byte; null when the file
/// isn't valid UTF-8 or has no plain status line ([withDecisionStatus]).
List<int>? _withStatus(List<int> bytes, DecisionStatus status) {
  const bom = [0xEF, 0xBB, 0xBF];
  final marked =
      bytes.length >= 3 &&
      bytes[0] == bom[0] &&
      bytes[1] == bom[1] &&
      bytes[2] == bom[2];
  final String text;
  try {
    text = utf8.decode(marked ? bytes.sublist(3) : bytes);
  } on FormatException {
    return null;
  }
  final changed = withDecisionStatus(text, status);
  if (changed == null) return null;
  return [if (marked) ...bom, ...utf8.encode(changed)];
}

/// Which decision replaces which (spec §6.7): a record is replaced by the
/// record that names its number in `supersedes`, whatever either file's
/// status line says, so a decision that was replaced never comes back into
/// force. When several name it, the highest number counts.
///
/// Records that supersede each other in a circle would leave none in
/// force, so the one with the highest number stays; [problems] gets a
/// sentence about each circle.
Map<DecisionRecord, DecisionRecord> _replacements(
  List<DecisionRecord> records,
  List<String> problems,
) {
  // Whatever the record's own status: a decision that was replaced stays
  // replaced when its replacement is replaced in turn. Naming itself
  // replaces nothing.
  bool replaces(DecisionRecord record) =>
      record.supersedes != null && record.supersedes != record.number;
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
