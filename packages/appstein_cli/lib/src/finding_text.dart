import 'package:appstein_protocol/appstein_protocol.dart';

/// [findings] in the order every text output shows them: the findings about
/// no file first (`(project)`), then those of each file; a file with an error
/// comes before a file without one, and inside each half the order of
/// [findings] is kept (`sortFindings`' order: files by path, then severity).
///
/// The findings of one file are next to each other in the result, which is
/// what [findingLines] relies on.
List<Finding> orderedFindings(List<Finding> findings) {
  final groups = <String?, List<Finding>>{};
  for (final finding in findings) {
    (groups[finding.file] ??= []).add(finding);
  }
  bool hasError(List<Finding> group) =>
      group.any((finding) => finding.severity == Severity.error);
  return [
    for (final group in groups.values)
      if (hasError(group)) ...group,
    for (final group in groups.values)
      if (!hasError(group)) ...group,
  ];
}

/// The lines that show [ordered], which must be in [orderedFindings]' order:
/// a heading for each file (`(project)` for those about no file), then a line
/// for each finding with its severity, ID, line number when it has one and
/// message, then a `fix:` line when it has a fix hint and, with [knowledge],
/// a `knowledge:` line when it rests on a knowledge file. A blank line ends
/// each group.
List<String> findingLines(List<Finding> ordered, {bool knowledge = false}) {
  final lines = <String>[];
  var started = false;
  String? file;
  for (final finding in ordered) {
    if (!started || finding.file != file) {
      if (started) lines.add('');
      started = true;
      file = finding.file;
      lines.add(file ?? '(project)');
    }
    final line = switch (finding.line) {
      final line? => ' (line $line)',
      null => '',
    };
    lines.add(
      '  ${finding.severity.name} ${finding.id}$line: ${finding.message}',
    );
    if (finding.fixHint case final fix?) lines.add('    fix: $fix');
    final ref = finding.knowledgeRef;
    if (knowledge && ref != null) lines.add('    knowledge: $ref');
  }
  if (started) lines.add('');
  return lines;
}
