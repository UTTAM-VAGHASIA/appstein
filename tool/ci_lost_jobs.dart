import 'dart:io';

import 'package:args/args.dart';

import 'src/github_api.dart';
import 'src/lost_jobs_modes.dart';

/// Finds CI jobs lost with their runner (ticket 15 of slice 1d.7).
///
/// `report` is the `lost-jobs` job of `ci.yml`: it judges its own attempt,
/// prints a warning for a job lost the first time and an error for one
/// lost again, closes the jobs' traces, and exits 1 on a second loss.
/// `rerun` is the job of `ci-rerun.yml`, after a CI run ended: it judges
/// that attempt from the API alone and asks GitHub to rerun a job lost for
/// the first time.
///
/// The token comes from `APPSTEIN_GITHUB_TOKEN` and is never printed;
/// everything else comes from flags that the workflow fills from `github.*`.
///
/// Usage:
///   dart run tool/ci_lost_jobs.dart report --repo OWNER/NAME --run ID
///       --attempt N --sha SHA [--server-url URL]
///   dart run tool/ci_lost_jobs.dart rerun --repo OWNER/NAME --run ID
///       --attempt N
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('repo', help: 'The repository, OWNER/NAME.')
    ..addOption('run', help: "The run's ID.")
    ..addOption('attempt', help: "The run's attempt.")
    ..addOption('sha', help: 'report: the commit the traces are on.')
    ..addOption(
      'server-url',
      defaultsTo: 'https://github.com',
      help: "report: GitHub's address, for the traces' links.",
    );
  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (error) {
    _usage(parser, error.message);
    return;
  }
  final mode = options.rest.length == 1 ? options.rest.single : '';
  final repo = options.option('repo');
  final runId = int.tryParse(options.option('run') ?? '');
  final attempt = int.tryParse(options.option('attempt') ?? '');
  final sha = options.option('sha');
  if (!{'report', 'rerun'}.contains(mode) ||
      repo == null ||
      runId == null ||
      attempt == null ||
      (mode == 'report' && sha == null)) {
    _usage(
      parser,
      'Give report or rerun, --repo, --run and --attempt, and '
      '--sha for report.',
    );
    return;
  }
  final token = Platform.environment['APPSTEIN_GITHUB_TOKEN'] ?? '';
  if (token.isEmpty) {
    stdout.writeln('::error::APPSTEIN_GITHUB_TOKEN is not set.');
    exitCode = 1;
    return;
  }
  final api = HttpGitHubApi(repo: repo, token: token);
  try {
    exitCode = mode == 'report'
        ? await reportLostJobs(
            api: api,
            repo: repo,
            serverUrl: options.option('server-url')!,
            runId: runId,
            attempt: attempt,
            sha: sha!,
            out: stdout,
          )
        : await rerunLostJobs(
            api: api,
            runId: runId,
            attempt: attempt,
            out: stdout,
          );
  } on GitHubApiException catch (error) {
    // Both modes handle GitHub's errors themselves; this is a last guard,
    // and like them it never turns the run red for GitHub's outage.
    stdout.writeln('::warning::GitHub could not be read: $error');
    exitCode = 0;
  } finally {
    api.close();
  }
}

void _usage(ArgParser parser, String problem) {
  stderr
    ..writeln(problem)
    ..writeln(
      'Usage: dart run tool/ci_lost_jobs.dart report|rerun --repo OWNER/NAME '
      '--run ID --attempt N [--sha SHA] [--server-url URL]',
    )
    ..writeln(parser.usage);
  exitCode = 2;
}
