import 'dart:io';

import 'package:path/path.dart' as p;

import 'generated_sections.dart';
import 'generators.dart';
import 'guide_checker.dart';
import 'progress.dart';
import 'progress_html.dart';

/// What regenerating the guide found.
final class GuideRegeneration {
  /// Creates the result.
  const GuideRegeneration(this.changedPages, this.problems);

  /// Pages whose generated sections were out of date. They were rewritten
  /// when regenerating with `write`.
  final List<String> changedPages;

  /// Problems that stopped a page or a section from being regenerated.
  final List<GuideProblem> problems;
}

/// Renders every generated section of the guide [pages] again (spec §19.6).
///
/// With [write], out-of-date pages are rewritten; without it, nothing is
/// written. [bodies] replaces the real generators, for tests. A section no
/// page shows is a problem, so no generated fact goes unshown. A generator
/// that fails is reported as a problem.
Future<GuideRegeneration> regenerateGuide(
  String repoRoot,
  List<String> pages, {
  required bool write,
  Map<String, String>? bodies,
}) async {
  final Map<String, String> rendered;
  try {
    rendered = bodies ?? await renderSections(repoRoot);
  } on Exception catch (error) {
    return GuideRegeneration(const [], [
      GuideProblem('tool/src/generators.dart', null, '$error'),
    ]);
  }
  final changed = <String>[];
  final problems = <GuideProblem>[];
  final used = <String>{};
  for (final page in pages) {
    final file = File(p.join(repoRoot, page));
    final before = file.readAsStringSync();
    final result = regenerate(page, before, rendered);
    problems.addAll(result.problems);
    used.addAll(result.sections);
    if (result.problems.isEmpty && result.text != before) {
      changed.add(page);
      if (write) file.writeAsStringSync(result.text);
    }
  }
  for (final name in rendered.keys) {
    if (!used.contains(name)) {
      problems.add(
        GuideProblem(
          'docs/guide',
          null,
          'No page shows the generated section $name. Add '
              '<!-- generated:$name --> and <!-- /generated:$name --> to the '
              'page that explains it.',
        ),
      );
    }
  }
  return GuideRegeneration(changed, problems);
}

/// The spec's visual page, which shows the progress sections (spec §19.6).
const visualPage = 'docs/superpowers/specs/2026-09-29-appstein-design.html';

/// Renders the progress sections of [visualPage] again (spec §19.6). With
/// [write], an out-of-date page is rewritten; without it, nothing is
/// written. [bodies] replaces the sections rendered from
/// `docs/superpowers/progress.yaml`, for tests; without it, a progress file
/// with problems is reported as those problems. A missing page, a section
/// the page doesn't show and a malformed or unknown marker are problems.
GuideRegeneration regenerateVisualPage(
  String repoRoot, {
  required bool write,
  Map<String, String>? bodies,
}) {
  var rendered = bodies;
  if (rendered == null) {
    final read = readProgress(repoRoot);
    final progress = read.progress;
    if (progress == null) return GuideRegeneration(const [], read.problems);
    rendered = renderProgressSections(progress);
  }
  final file = File(p.join(repoRoot, visualPage));
  if (!file.existsSync()) {
    return const GuideRegeneration([], [
      GuideProblem(
        visualPage,
        null,
        'Missing. It shows the progress sections.',
      ),
    ]);
  }
  final before = file.readAsStringSync();
  final result = regenerate(visualPage, before, rendered, guideLinks: false);
  final problems = [
    ...result.problems,
    for (final name in rendered.keys)
      if (!result.sections.contains(name))
        GuideProblem(
          visualPage,
          null,
          "The page doesn't show the generated section $name. Add "
          '<!-- generated:$name --> and <!-- /generated:$name --> where it '
          'belongs.',
        ),
  ];
  if (problems.isNotEmpty) return GuideRegeneration(const [], problems);
  if (result.text == before) return const GuideRegeneration([], []);
  if (write) file.writeAsStringSync(result.text);
  return const GuideRegeneration([visualPage], []);
}
