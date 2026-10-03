import 'dart:io';

import 'package:path/path.dart' as p;

import 'coverage.dart';
import 'generated_docs.dart';
import 'generated_sections.dart';
import 'git_repo.dart';
import 'guide_checker.dart';
import 'progress.dart';
import 'progress_check.dart';
import 'progress_html.dart';
import 'stale_check.dart';

/// Runs every developer guide check (spec §19.6) on the repo at [repoRoot]:
/// - links and repo paths in the guide and package READMEs;
/// - every guide page linked from the start page;
/// - the coverage map;
/// - generated sections up to date;
/// - `docs/superpowers/progress.yaml` valid, consistent with the plans and
///   spec §18, and naming only merge commits that are in the repo;
/// - the progress sections of the spec's visual page up to date;
/// - with [since], the stale-page check against the merge base of [since]
///   and HEAD. A guide page counts as changed only when its hand-written
///   text changed: a page whose only change is inside generated sections
///   doesn't explain anything new.
///
/// Throws [GitException] when [repoRoot] isn't a git repo.
Future<List<GuideProblem>> checkGuide(String repoRoot, {String? since}) async {
  final git = GitRepo(repoRoot);
  final pages = guidePages(repoRoot);
  final problems = <GuideProblem>[
    for (final file in guideFiles(repoRoot)) ...checkMarkdown(repoRoot, file),
    ...checkLinked(repoRoot, pages),
  ];
  final covers = readCoverMap(repoRoot, pages);
  problems
    ..addAll(covers.problems)
    ..addAll(checkCoverage(covers.map, git.files()));
  if (since != null) {
    if (git.hasCommit(since)) {
      problems.addAll(
        checkStale(
          map: covers.map,
          changed: [
            for (final file in git.changedSince(since))
              if (!_onlyGeneratedChanged(
                repoRoot,
                git,
                since,
                file,
                covers.map,
              ))
                file,
          ],
          messages: git.messagesSince(since),
        ),
      );
    } else {
      problems.add(GuideProblem('--since', null, '$since is not a commit.'));
    }
  }
  final generated = await regenerateGuide(repoRoot, pages, write: false);
  problems
    ..addAll(generated.problems)
    ..addAll([
      for (final page in generated.changedPages)
        GuideProblem(
          page,
          null,
          'Generated sections are out of date. Run: '
          'fvm dart run tool/gen_docs.dart',
        ),
    ]);
  final progress = readProgress(repoRoot);
  problems.addAll(progress.problems);
  final record = progress.progress;
  if (record != null) {
    problems
      ..addAll(checkProgress(repoRoot, record))
      ..addAll(checkMerges(record, git.hasCommit));
    final visual = regenerateVisualPage(
      repoRoot,
      write: false,
      bodies: renderProgressSections(record),
    );
    problems
      ..addAll(visual.problems)
      ..addAll([
        for (final page in visual.changedPages)
          GuideProblem(
            page,
            null,
            'The progress sections are out of date. Run: '
            'fvm dart run tool/gen_docs.dart',
          ),
      ]);
  }
  return problems;
}

/// Whether [file] is a guide page whose text is the same as at the merge
/// base of [since], once generated section bodies are left out and line
/// endings are made LF. Such a page changed only where `gen_docs` writes.
/// A page that is new, deleted, unreadable or has broken markers counts as
/// changed.
bool _onlyGeneratedChanged(
  String repoRoot,
  GitRepo git,
  String since,
  String file,
  CoverMap map,
) {
  if (!map.pages.containsKey(file)) return false;
  final current = File(p.joinAll([repoRoot, ...file.split('/')]));
  if (!current.existsSync()) return false;
  final base = git.fileAt(since, file);
  if (base == null) return false;
  final String text;
  try {
    text = current.readAsStringSync();
  } on FileSystemException {
    return false;
  }
  final stripped = stripGeneratedBodies(text);
  return stripped != null && stripped == stripGeneratedBodies(base);
}
