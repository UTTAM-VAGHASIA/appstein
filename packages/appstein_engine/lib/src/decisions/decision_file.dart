import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:yaml/yaml.dart';

import '../knowledge/plain_text.dart';

/// The most characters a decision's title may have.
const decisionTitleLength = 120;

/// One file in `.appstein/decisions/` as it was read (spec §6.7): a
/// [ReadDecision] or an [UnreadableDecision].
sealed class DecisionFile {
  const DecisionFile(this.file);

  /// Its file name, such as `0002-state.md`.
  final String file;

  /// The number its file name starts with; null when it starts with none.
  int? get number => decisionFileNumber(file);
}

/// A decision file whose record was read.
final class ReadDecision extends DecisionFile {
  /// Wraps [record].
  ReadDecision(this.record) : super(record.file);

  /// The record.
  final DecisionRecord record;
}

/// A decision file that can't be read, and why.
final class UnreadableDecision extends DecisionFile {
  /// The file named [file] can't be read because of [problem].
  const UnreadableDecision(super.file, this.problem);

  /// Why, in words that follow "unreadable (": `it has no front matter`.
  final String problem;
}

/// The number a decision file's name starts with, such as 2 for
/// `0002-state.md`; null when it doesn't start with digits and `-`.
int? decisionFileNumber(String file) =>
    switch (RegExp(r'^(\d+)-').firstMatch(file)?.group(1)) {
      final digits? => int.tryParse(digits),
      null => null,
    };

/// Reads the decision file [file] whose text is [text] (spec §6.7). It
/// never throws: anything that keeps the record from being read gives an
/// [UnreadableDecision] that says why.
DecisionFile parseDecisionFile(String file, String text) {
  DecisionFile unreadable(String problem) => UnreadableDecision(file, problem);

  final lines = const LineSplitter().convert(withoutBom(text));
  if (lines.isEmpty || lines.first.trimRight() != '---') {
    return unreadable('it has no front matter');
  }
  final end = lines.indexWhere((line) => line.trimRight() == '---', 1);
  if (end < 0) return unreadable('its front matter has no closing ---');
  final Object? yaml;
  try {
    yaml = loadYaml(lines.sublist(1, end).join('\n'));
  } on FormatException {
    return unreadable('its front matter is not valid YAML');
  }
  if (yaml is! Map) return unreadable('its front matter is not a map');

  final title = yaml['title'];
  if (title == null || '$title'.trim().isEmpty) {
    return unreadable('it has no title');
  }
  final status = switch (yaml['status']) {
    final String word => DecisionStatus.tryParse(word),
    _ => null,
  };
  if (status == null) {
    return unreadable('its status is not accepted, proposed or superseded');
  }
  final int? supersedes;
  switch (yaml['supersedes']) {
    case null:
      supersedes = null;
    case final int number when number > 0:
      supersedes = number;
    case final String digits when RegExp(r'^\d+$').hasMatch(digits):
      supersedes = int.parse(digits);
    default:
      return unreadable('its supersedes is not a decision number');
  }
  final paths = _strings(yaml['paths']);
  if (paths == null) return unreadable('its paths are not a list');
  final checks = _strings(yaml['checks']);
  if (checks == null) return unreadable('its checks are not a list');

  var why = lines.sublist(end + 1).join('\n').trim();
  final marker = RegExp('^why:', caseSensitive: false).firstMatch(why);
  if (marker != null) why = why.substring(marker.end).trimLeft();

  return ReadDecision(
    DecisionRecord(
      file: file,
      number: decisionFileNumber(file),
      title: capText(oneLine('$title'), decisionTitleLength),
      status: status,
      date: switch (yaml['date']) {
        null => null,
        final date => '$date',
      },
      supersedes: supersedes,
      paths: paths,
      checks: checks,
      why: why,
    ),
  );
}

/// A YAML value as a list of strings: nothing is none, one scalar is one
/// item. Null when it is anything else, such as a map.
List<String>? _strings(Object? value) => switch (value) {
  null => const [],
  final String one => [one],
  final num one => ['$one'],
  final List<Object?> many
      when many.every((item) => item is String || item is num) =>
    [for (final item in many) '$item'],
  _ => null,
};

/// The text of a new decision file (spec §6.7), ending in a line break:
/// the front matter with its keys in the spec's order, then the reason
/// after `Why:`. [title] is written on one line; a value YAML would read as
/// anything but the same text is quoted.
String renderDecision({
  required int number,
  required String title,
  required DecisionStatus status,
  required String date,
  int? supersedes,
  List<String> paths = const [],
  List<String> checks = const [],
  required String why,
}) {
  final marker = RegExp('^why:', caseSensitive: false).firstMatch(why.trim());
  final reason = marker == null
      ? why.trim()
      : why.trim().substring(marker.end).trimLeft();
  return '---\n'
      'id: ${decisionNumberText(number)}\n'
      'title: ${_scalar(oneLine(title))}\n'
      'status: ${status.jsonName}\n'
      'date: $date\n'
      'supersedes: '
      '${supersedes == null ? 'null' : decisionNumberText(supersedes)}\n'
      'paths: ${_flowList(paths)}\n'
      'checks: ${_flowList(checks)}\n'
      '---\n'
      'Why: $reason\n';
}

String _flowList(List<String> items) =>
    '[${[for (final item in items) _scalar(item, inList: true)].join(', ')}]';

/// [value] as a YAML scalar: as it is when YAML reads it back as the same
/// text, and as a double-quoted string (JSON's form) otherwise.
String _scalar(String value, {bool inList = false}) {
  try {
    final read = loadYaml(inList ? 'k: [$value]' : 'k: $value');
    final back = read is Map ? read['k'] : null;
    if (inList
        ? back is List && back.length == 1 && back.single == value
        : back == value) {
      return value;
    }
  } on FormatException {
    // Not plain YAML: quote it.
  }
  return jsonEncode(value);
}

/// [text], a decision file, with the status in its front matter changed to
/// [status] and every other character kept: line breaks, comments and a
/// byte order mark included.
///
/// Null when the front matter has no plain `status: word` line, such as a
/// quoted status, when the file can't be read, or when changing that line
/// would change anything but the status YAML reads. Such a file is for a
/// person to edit.
String? withDecisionStatus(String text, DecisionStatus status) {
  final lines = RegExp(
    r'[^\n]*\n|[^\n]+$',
  ).allMatches(text).map((match) => match.group(0)!).toList();
  if (lines.isEmpty || withoutBom(lines.first).trimRight() != '---') {
    return null;
  }
  final end = lines.indexWhere((line) => line.trimRight() == '---', 1);
  if (end < 0) return null;
  final statusLine = RegExp(
    r'^(status:[ \t]+)([A-Za-z]+)((?:[ \t]+#[^\r\n]*)?[ \t]*\r?\n?)$',
  );
  for (var i = 1; i < end; i++) {
    final match = statusLine.firstMatch(lines[i]);
    if (match == null) continue;
    lines[i] = '${match.group(1)}${status.jsonName}${match.group(3)}';
    final changed = lines.join();
    // The line was found by its look, not by YAML's structure, and it can
    // look like the status without being it: a key of a map left open, a
    // line of a quoted title that wraps. So the change counts only when
    // YAML reads the new status and everything else as before.
    final before = parseDecisionFile('', text);
    final after = parseDecisionFile('', changed);
    if (before is! ReadDecision || after is! ReadDecision) return null;
    final was = before.record;
    final now = after.record;
    final same =
        now.status == status &&
        now.title == was.title &&
        now.why == was.why &&
        now.date == was.date &&
        now.supersedes == was.supersedes &&
        now.paths.join('\n') == was.paths.join('\n') &&
        now.checks.join('\n') == was.checks.join('\n');
    return same ? changed : null;
  }
  return null;
}

/// A file-name slug for [title]: lowercase `a`–`z`, digits and hyphens, at
/// most 50 characters and cut at a word when it has one, or `decision` when
/// nothing is left.
String decisionSlug(String title) {
  const max = 50;
  var slug = title
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > max) {
    // The cut is clean when it lands on the end of a word.
    final cut = slug[max] == '-' ? max : slug.lastIndexOf('-', max);
    slug = slug.substring(0, cut > 0 ? cut : max);
  }
  return slug.isEmpty ? 'decision' : slug;
}
