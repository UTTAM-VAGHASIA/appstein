import 'coverage.dart';
import 'guide_checker.dart';

/// A `Docs-Checked:` commit trailer: someone confirmed that a page is still
/// right after a code change (spec §19.6).
final class DocsChecked {
  /// Creates a trailer for [page].
  const DocsChecked(this.page, this.reason);

  /// The page, repo-relative with forward slashes.
  final String page;

  /// Why the page is still right.
  final String reason;
}

final _trailer = RegExp(r'^\s*docs-checked:(.*)$', caseSensitive: false);

/// Reads every `Docs-Checked: <page> - <reason>` line in [messages]. The key
/// is matched in any case. The page may be written relative to `docs/guide/`
/// (`doctor.md`) or to the repo root. A line without a page or a reason is a
/// problem.
({List<DocsChecked> checked, List<GuideProblem> problems}) parseDocsChecked(
  List<String> messages,
) {
  final checked = <DocsChecked>[];
  final problems = <GuideProblem>[];
  for (final message in messages) {
    for (final raw in message.split('\n')) {
      final line = raw.trimRight();
      final match = _trailer.firstMatch(line);
      if (match == null) continue;
      final value = match.group(1)!.trim();
      final dash = value.indexOf(' - ');
      final page = (dash < 0 ? value : value.substring(0, dash)).trim();
      final reason = dash < 0 ? '' : value.substring(dash + 3).trim();
      if (page.isEmpty || reason.isEmpty) {
        problems.add(
          GuideProblem(
            'commit message',
            null,
            'Write the trailer as `Docs-Checked: <page> - <reason>`: '
                '${line.trim()}',
          ),
        );
        continue;
      }
      checked.add(
        DocsChecked(
          page.startsWith('docs/guide/') ? page : 'docs/guide/$page',
          reason,
        ),
      );
    }
  }
  return (checked: checked, problems: problems);
}

/// The stale-page check (spec §19.6). Every file in [changed] that a page
/// covers needs one of its covering pages in [changed] too, or named by a
/// `Docs-Checked` trailer in [messages].
List<GuideProblem> checkStale({
  required CoverMap map,
  required List<String> changed,
  required List<String> messages,
}) {
  final trailers = parseDocsChecked(messages);
  final problems = [...trailers.problems];
  final confirmed = <String>{};
  for (final trailer in trailers.checked) {
    if (map.pages.containsKey(trailer.page)) {
      confirmed.add(trailer.page);
    } else {
      problems.add(
        GuideProblem(
          'commit message',
          null,
          'Docs-Checked names ${trailer.page}, which is not a guide page.',
        ),
      );
    }
  }
  final changedFiles = changed.toSet();
  for (final file in changed) {
    final pages = map.pagesCovering(file);
    if (pages.isEmpty ||
        pages.any(changedFiles.contains) ||
        pages.any(confirmed.contains)) {
      continue;
    }
    final short = pages.first.substring('docs/guide/'.length);
    problems.add(
      GuideProblem(
        file,
        null,
        'Changed, but the page that explains it did not: '
        '${pages.join(', ')}. Update the page, or if it is still right, add '
        'a commit trailer: Docs-Checked: $short - <why it is still right>',
      ),
    );
  }
  return problems;
}
