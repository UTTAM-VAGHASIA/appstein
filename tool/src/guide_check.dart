import 'coverage.dart';
import 'generated_docs.dart';
import 'git_repo.dart';
import 'guide_checker.dart';
import 'stale_check.dart';

/// Runs every developer guide check (spec §19.6) on the repo at [repoRoot]:
/// - links and repo paths in the guide and package READMEs;
/// - every guide page linked from the start page;
/// - the coverage map;
/// - generated sections up to date;
/// - with [since], the stale-page check against the merge base of [since]
///   and HEAD.
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
          changed: git.changedSince(since),
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
  return problems;
}
