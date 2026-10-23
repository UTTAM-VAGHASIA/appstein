/// The two modes of `tool/ci_lost_jobs.dart` (ticket 15 of slice 1d.7):
/// `report`, the `lost-jobs` job inside a CI run, and `rerun`, the job of
/// `ci-rerun.yml` that runs after a CI run ends. Both read the run through a
/// [GitHubApi] and judge it with [judgeAttempt].
library;

import 'github_api.dart';
import 'lost_jobs.dart';
import 'unit_test_trace.dart';

/// The most pages of commit statuses [readTraces] reads: 3,000 statuses,
/// more than a few runs of one commit write.
const tracePagesLimit = 30;

/// Every job of attempt [attempt] of run [runId], with the annotations of
/// each job that did not pass (a passed job needs none to be judged).
Future<List<JobRecord>> readAttempt(
  GitHubApi api,
  int runId,
  int attempt,
) async {
  return [
    for (final job in await api.jobsOfAttempt(runId, attempt))
      JobRecord.fromApi(
        job,
        passedConclusions.contains(job['conclusion'])
            ? const []
            : await api.annotations((job['id']! as num).toInt()),
      ),
  ];
}

/// The jobs of every attempt of run [runId] before [attempt].
Future<List<JobRecord>> _earlier(GitHubApi api, int runId, int attempt) async =>
    [for (var n = 1; n < attempt; n++) ...await readAttempt(api, runId, n)];

/// The trace entries of run [runId] on commit [sha], by job name, read from
/// every page of its statuses up to [tracePagesLimit].
Future<Map<String, List<TraceEntry>>> readTraces(
  GitHubApi api,
  String sha,
  int runId,
) async {
  final traces = <String, List<TraceEntry>>{};
  for (var page = 1; page <= tracePagesLimit; page++) {
    final statuses = await api.statusesPage(sha, page);
    for (final status in statuses) {
      final entry = parseTrace(
        context: status['context'] as String? ?? '',
        description: status['description'] as String? ?? '',
        targetUrl: status['target_url'] as String? ?? '',
        createdAt: DateTime.tryParse(status['created_at'] as String? ?? ''),
      );
      if (entry != null && entry.runId == runId) {
        (traces[entry.jobName] ??= []).add(entry);
      }
    }
    if (statuses.length < 100) break;
  }
  return traces;
}

/// The jobs of attempt [attempt] of run [runId] and of every earlier
/// attempt, or null when GitHub can't give them even after its retries.
/// Then a warning goes to [out]: a job that really failed or was lost makes
/// the run red by itself, so judging nothing is no reason to fail.
Future<(List<JobRecord>, List<JobRecord>)?> _readRun(
  GitHubApi api,
  int runId,
  int attempt,
  StringSink out,
) async {
  try {
    return (
      await readAttempt(api, runId, attempt),
      await _earlier(api, runId, attempt),
    );
  } on GitHubApiException catch (error) {
    out.writeln(
      Notice(
        NoticeLevel.warning,
        'The jobs of attempt $attempt of run $runId could not be read, so '
        'lost jobs were not judged this time: $error. See the jobs with: '
        'gh run view $runId --attempt $attempt. A job lost with its runner '
        'can be rerun with: gh run rerun $runId --job <job id>',
      ).command,
    );
    return null;
  }
}

/// The `lost-jobs` job: judges attempt [attempt] of run [runId], prints
/// each notice to [out] as a workflow command, closes the traces that
/// still say a job is running, and returns 1 when a job was lost a second
/// time, else 0. A run that can't be read, or a trace that can't be read
/// or closed, never fails it.
Future<int> reportLostJobs({
  required GitHubApi api,
  required String repo,
  required String serverUrl,
  required int runId,
  required int attempt,
  required String sha,
  required StringSink out,
}) async {
  final read = await _readRun(api, runId, attempt, out);
  if (read == null) return 0;
  final (jobs, earlier) = read;
  var traces = <String, List<TraceEntry>>{};
  try {
    traces = await readTraces(api, sha, runId);
  } on GitHubApiException catch (error) {
    out.writeln(
      Notice(
        NoticeLevel.warning,
        'The traces could not be read: $error',
      ).command,
    );
  }
  final verdict = judgeAttempt(
    runId: runId,
    attempt: attempt,
    jobs: jobs,
    earlierJobs: earlier,
    traces: traces,
  );
  for (final notice in verdict.notices) {
    out.writeln(notice.command);
  }
  for (final closing in verdict.closings) {
    try {
      await api.postStatus(
        sha,
        state: closing.state,
        context: traceContext(closing.jobName),
        description: traceDescription(closing.report),
        targetUrl: attemptUrl(serverUrl, repo, runId, closing.report.attempt),
      );
    } on GitHubApiException catch (error) {
      out.writeln(
        Notice(
          NoticeLevel.warning,
          'The trace of ${closing.jobName} could not be closed: $error',
        ).command,
      );
    }
  }
  return verdict.fails ? 1 : 0;
}

/// The job of `ci-rerun.yml`: judges attempt [attempt] of run [runId] from
/// the API alone (nothing the run wrote is trusted), prints what it found,
/// and asks GitHub to rerun what the verdict says. Returns 1 when GitHub
/// refused the rerun, else 0: a run that can't be read is a warning.
Future<int> rerunLostJobs({
  required GitHubApi api,
  required int runId,
  required int attempt,
  required StringSink out,
}) async {
  final read = await _readRun(api, runId, attempt, out);
  if (read == null) return 0;
  final (jobs, earlier) = read;
  final verdict = judgeAttempt(
    runId: runId,
    attempt: attempt,
    jobs: jobs,
    earlierJobs: earlier,
  );
  for (final notice in verdict.notices) {
    out.writeln(notice.command);
  }
  try {
    switch (verdict.rerun) {
      case RerunJob(:final jobId):
        await api.rerunJob(jobId);
        final name = jobs.firstWhere((job) => job.id == jobId).name;
        out.writeln('Asked GitHub to rerun $name (job $jobId) of run $runId.');
      case RerunFailedJobs():
        await api.rerunFailedJobs(runId);
        out.writeln(
          'Asked GitHub to rerun the failed jobs of run $runId: '
          '${[for (final job in verdict.firstLosses) job.name].join(', ')}.',
        );
      case NoRerun():
        out.writeln('Nothing to rerun.');
    }
  } on GitHubApiException catch (error) {
    out.writeln(
      Notice(NoticeLevel.error, 'GitHub refused the rerun: $error').command,
    );
    return 1;
  }
  return 0;
}
