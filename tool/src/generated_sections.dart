import 'package:path/path.dart' as p;

import 'guide_checker.dart';
import 'markdown.dart';

final _start = RegExp(r'^<!-- generated:([a-z0-9-]+) -->$');
final _end = RegExp(r'^<!-- /generated:([a-z0-9-]+) -->$');

/// A page after its generated sections were rendered again.
final class RegeneratedPage {
  /// Creates the result.
  const RegeneratedPage(this.text, this.sections, this.problems);

  /// The page with every section's body replaced. It is the unchanged input
  /// when there are [problems].
  final String text;

  /// The names of the sections the page has, in order.
  final List<String> sections;

  /// Malformed markers, unknown names, or sections in a page they can't be
  /// in.
  final List<GuideProblem> problems;
}

/// Replaces the body of each generated section in [markdown], the text of
/// [page], with its entry in [bodies] (spec §19.6).
///
/// A section is a `<!-- generated:<name> -->` line, then anything, then a
/// `<!-- /generated:<name> -->` line. The body is written with a blank line
/// after the start marker and before the end marker. Markers inside code
/// fences are examples and are left alone. The page's line endings (LF or
/// CRLF) are kept. Generated links are relative to `docs/guide/`, so a page
/// in a subfolder may not have sections.
RegeneratedPage regenerate(
  String page,
  String markdown,
  Map<String, String> bodies,
) {
  final crlf = markdown.contains('\r\n');
  final lines = markdown.replaceAll('\r\n', '\n').split('\n');
  final out = <String>[];
  final sections = <String>[];
  final problems = <GuideProblem>[];
  String? open;
  var openLine = 0;
  // Fences are tracked only outside sections: a section's body is replaced
  // whole, so a fence inside it opens nothing.
  final fences = FenceTracker();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();
    if (open == null) {
      out.add(line);
      if (fences.next(line) != FenceLine.prose) continue;
      final start = _start.firstMatch(trimmed);
      if (start != null) {
        open = start.group(1)!;
        openLine = i + 1;
        sections.add(open);
      } else if (_end.hasMatch(trimmed)) {
        problems.add(
          GuideProblem(page, i + 1, 'An end marker without a start marker.'),
        );
      }
      continue;
    }
    final end = _end.firstMatch(trimmed);
    if (end == null) {
      if (_start.hasMatch(trimmed)) {
        problems.add(
          GuideProblem(page, i + 1, "Generated sections can't be nested."),
        );
      }
      continue;
    }
    if (end.group(1) != open) {
      problems.add(
        GuideProblem(
          page,
          i + 1,
          'This ends section ${end.group(1)}, but $open is open '
          '(line $openLine).',
        ),
      );
    }
    final body = bodies[open];
    if (body == null) {
      final known = bodies.keys.toList()..sort();
      problems.add(
        GuideProblem(
          page,
          openLine,
          'Unknown generated section: $open. Known: ${known.join(', ')}.',
        ),
      );
    }
    out
      ..add('')
      ..add((body ?? '').trimRight())
      ..add('')
      ..add(line);
    open = null;
  }
  if (open != null) {
    problems.add(
      GuideProblem(
        page,
        openLine,
        'Section $open is never closed with <!-- /generated:$open -->.',
      ),
    );
  }
  if (sections.isNotEmpty && p.posix.dirname(page) != 'docs/guide') {
    problems.add(
      GuideProblem(
        page,
        null,
        'Generated sections link relative to docs/guide/, so they belong in '
        'pages directly in that folder.',
      ),
    );
  }
  if (problems.isNotEmpty) return RegeneratedPage(markdown, sections, problems);
  final text = out.join('\n');
  return RegeneratedPage(
    crlf ? text.replaceAll('\n', '\r\n') : text,
    sections,
    const [],
  );
}

/// [markdown] with the body of every generated section removed and LF line
/// endings, to compare two versions of a page for the stale-page check
/// (spec §19.6): a page whose only change is inside its sections strips to
/// the same text. The markers stay, and markers inside code fences are left
/// alone, as in [regenerate]. Any section name is accepted. Null when the
/// markers are malformed, because the sections can't be told apart from
/// the hand-written text then.
String? stripGeneratedBodies(String markdown) {
  final out = <String>[];
  final fences = FenceTracker();
  String? open;
  for (final line in markdown.replaceAll('\r\n', '\n').split('\n')) {
    final trimmed = line.trim();
    if (open == null) {
      out.add(line);
      if (fences.next(line) != FenceLine.prose) continue;
      final start = _start.firstMatch(trimmed);
      if (start != null) {
        open = start.group(1);
      } else if (_end.hasMatch(trimmed)) {
        return null;
      }
      continue;
    }
    final end = _end.firstMatch(trimmed);
    if (end == null) {
      if (_start.hasMatch(trimmed)) return null;
      continue;
    }
    if (end.group(1) != open) return null;
    out.add(line);
    open = null;
  }
  return open == null ? out.join('\n') : null;
}
