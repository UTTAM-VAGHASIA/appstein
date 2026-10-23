/// How a CI job ended, and whether a job lost with its runner runs again
/// (ticket 15 of slice 1d.7). Pure: no `dart:io`, no network.
///
/// [classifyJob] sorts one job's end from what GitHub's API says about it;
/// [judgeAttempt] decides, for one attempt of a run, which lost jobs run
/// again, which were lost a second time, and what the run says about each.
library;

import 'unit_test_trace.dart';

/// Which jobs of [jobs], one attempt's list, ran in that attempt. A job of
/// [earlier] attempts that was not run again is copied into the next
/// attempt with a new ID but the same name and start time, so a job whose
/// name and start time equal an earlier job's is a copy and left out.
List<JobRecord> newInAttempt(List<JobRecord> jobs, List<JobRecord> earlier) {
  final seen = {for (final job in earlier) _identity(job)};
  return [
    for (final job in jobs)
      if (!seen.contains(_identity(job))) job,
  ];
}

String _identity(JobRecord job) =>
    '${job.name}\u0000${job.startedAt?.toIso8601String()}';

/// What the rerun workflow asks GitHub to run again.
sealed class RerunPlan {
  const RerunPlan();
}

/// Run one job again (`POST …/actions/jobs/{id}/rerun`). GitHub also reruns
/// the jobs that depend on it.
final class RerunJob extends RerunPlan {
  /// Reruns the job [jobId].
  const RerunJob(this.jobId);

  /// The job to run again.
  final int jobId;

  @override
  bool operator ==(Object other) => other is RerunJob && other.jobId == jobId;

  @override
  int get hashCode => jobId.hashCode;

  @override
  String toString() => 'RerunJob($jobId)';
}

/// Run every failed job of the run again
/// (`POST …/runs/{id}/rerun-failed-jobs`): chosen only when every job that
/// failed is a job lost for the first time.
final class RerunFailedJobs extends RerunPlan {
  /// Reruns the failed jobs of [runId].
  const RerunFailedJobs(this.runId);

  /// The run whose failed jobs run again.
  final int runId;

  @override
  bool operator ==(Object other) =>
      other is RerunFailedJobs && other.runId == runId;

  @override
  int get hashCode => runId.hashCode;

  @override
  String toString() => 'RerunFailedJobs($runId)';
}

/// Run nothing again.
final class NoRerun extends RerunPlan {
  /// Reruns nothing.
  const NoRerun();

  @override
  bool operator ==(Object other) => other is NoRerun;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'NoRerun()';
}

/// How loud a [Notice] is on the run's page.
enum NoticeLevel {
  /// A plain note.
  notice,

  /// A warning: a job was lost and runs again.
  warning,

  /// An error: a job was lost a second time.
  error,
}

/// One line the run's page shows about a job's end.
final class Notice {
  /// A line of [level] saying [text].
  const Notice(this.level, this.text);

  /// How loud it is.
  final NoticeLevel level;

  /// What it says, in plain English.
  final String text;

  /// The line as a GitHub workflow command (`::warning::…`), with `%`, CR
  /// and LF escaped as the runner requires.
  String get command {
    final data = text
        .replaceAll('%', '%25')
        .replaceAll('\r', '%0D')
        .replaceAll('\n', '%0A');
    return '::${level.name}::$data';
  }

  @override
  String toString() => command;
}

/// A trace status `lost-jobs` sets as the last word of a job's trace, when
/// the trace still said the job was running.
final class TraceClosing {
  /// The closing of [jobName]'s trace with [report], as GitHub [state].
  const TraceClosing(this.jobName, this.state, this.report);

  /// The job whose trace it closes.
  final String jobName;

  /// The status's state: `success` for a job that passed, `failure` for a
  /// lost job, `error` for any other end.
  final String state;

  /// The report it posts: [TraceState.finished], [TraceState.lost] or
  /// [TraceState.ended].
  final TraceReport report;
}

/// What [judgeAttempt] decided for one attempt.
final class LostJobsVerdict {
  /// A verdict with every field given.
  const LostJobsVerdict({
    required this.firstLosses,
    required this.secondLosses,
    required this.rerun,
    required this.notices,
    required this.closings,
  });

  /// Jobs of the attempt lost for the first time in the run.
  final List<JobRecord> firstLosses;

  /// Jobs of the attempt lost again: a job of the same name was lost in an
  /// earlier attempt.
  final List<JobRecord> secondLosses;

  /// What the rerun workflow asks GitHub to run again.
  final RerunPlan rerun;

  /// The lines for the run's page, in the order of the attempt's jobs.
  final List<Notice> notices;

  /// The trace statuses to close.
  final List<TraceClosing> closings;

  /// Whether `lost-jobs` fails: a job was lost a second time.
  bool get fails => secondLosses.isNotEmpty;
}

/// Judges attempt [attempt] of run [runId]: [jobs] are that attempt's jobs,
/// [earlierJobs] those of every earlier attempt, and [traces] the trace
/// entries found on the commit, by job name (empty when they were not
/// read).
///
/// Only a job that ran in this attempt ([newInAttempt]) and has ended is
/// judged, so `lost-jobs` itself, still running, is left out. A lost job
/// whose name was never lost before in the run is rerun once; one whose
/// name was lost before fails the verdict. One lost job is rerun alone;
/// two or more are rerun with every failed job only when every job that
/// failed is one of them, since GitHub can rerun one job or all failed
/// jobs, not two chosen ones; otherwise nothing is rerun and each one's
/// command is given.
LostJobsVerdict judgeAttempt({
  required int runId,
  required int attempt,
  required List<JobRecord> jobs,
  required List<JobRecord> earlierJobs,
  Map<String, List<TraceEntry>> traces = const {},
}) {
  final ended = [
    for (final job in jobs)
      if (job.status == 'completed') job,
  ];
  final fresh = newInAttempt(ended, earlierJobs);
  final earlierLosses = _lossHistory(earlierJobs);
  final firstLosses = <JobRecord>[];
  final secondLosses = <JobRecord>[];
  for (final job in fresh) {
    if (!classifyJob(job).isLost) continue;
    (earlierLosses.containsKey(job.name) ? secondLosses : firstLosses).add(job);
  }
  final rerun = _rerunPlan(runId, firstLosses, ended);
  TraceEntry? traceOf(JobRecord job) =>
      _lastTrace(traces, job.name, runId, job.runAttempt);

  final notices = [
    for (final job in fresh)
      ?_notice(
        job,
        traceOf: traceOf,
        rerun: rerun,
        runId: runId,
        attempt: attempt,
        firstLosses: firstLosses,
        earlierLosses: earlierLosses[job.name],
      ),
    if (firstLosses.isEmpty && secondLosses.isEmpty)
      Notice(
        NoticeLevel.notice,
        'No job of attempt $attempt was lost with its runner.',
      ),
  ];
  return LostJobsVerdict(
    firstLosses: firstLosses,
    secondLosses: secondLosses,
    rerun: rerun,
    notices: notices,
    closings: [for (final job in fresh) ?_closing(job, traceOf(job))],
  );
}

/// The jobs lost in earlier attempts, by name, oldest first. A lost job
/// that was not run again is copied into the next attempt with the same
/// name and start time, so it counts once.
Map<String, List<JobRecord>> _lossHistory(List<JobRecord> earlierJobs) {
  final losses = <String, List<JobRecord>>{};
  final counted = <String>{};
  final byAttempt = [...earlierJobs]
    ..sort((a, b) => a.runAttempt.compareTo(b.runAttempt));
  for (final job in byAttempt) {
    if (job.status != 'completed' || !classifyJob(job).isLost) continue;
    if (!counted.add(_identity(job))) continue;
    (losses[job.name] ??= []).add(job);
  }
  return losses;
}

/// What to rerun for [firstLosses], the jobs of an attempt lost for the
/// first time, given every job of the attempt that has [ended].
RerunPlan _rerunPlan(
  int runId,
  List<JobRecord> firstLosses,
  List<JobRecord> ended,
) {
  if (firstLosses.isEmpty) return const NoRerun();
  if (firstLosses.length == 1) return RerunJob(firstLosses.single.id);
  final lostIds = {for (final job in firstLosses) job.id};
  final failing = [
    for (final job in ended)
      if (classifyJob(job) != JobEnd.passed) job,
  ];
  return failing.every((job) => lostIds.contains(job.id))
      ? RerunFailedJobs(runId)
      : const NoRerun();
}

/// The newest trace entry of job [name] in attempt [attempt] of run
/// [runId]. Entries come newest first from the API; their `created_at`
/// decides when both have one.
TraceEntry? _lastTrace(
  Map<String, List<TraceEntry>> traces,
  String name,
  int runId,
  int attempt,
) {
  TraceEntry? best;
  for (final entry in traces[name] ?? const <TraceEntry>[]) {
    if (entry.runId != runId || entry.attempt != attempt) continue;
    final newer =
        best == null ||
        (entry.createdAt != null &&
            best.createdAt != null &&
            entry.createdAt!.isAfter(best.createdAt!));
    if (newer) best = entry;
  }
  return best;
}

/// The status that closes [job]'s trace when its [last] report still says
/// the tests are running, or null when there is nothing to close: `success`
/// and `finished` for a job that passed (the wrapper's own last post did
/// not arrive), `failure` and `lost` for a lost job, `error` and `ended`
/// for any other end.
TraceClosing? _closing(JobRecord job, TraceEntry? last) {
  if (last == null || last.report.state.isFinal) return null;
  final end = classifyJob(job);
  final clock = traceClock(job.completedAt ?? DateTime.now());
  if (end == JobEnd.passed) {
    return TraceClosing(
      job.name,
      'success',
      TraceReport(
        attempt: job.runAttempt,
        clock: clock,
        state: TraceState.finished,
      ),
    );
  }
  return TraceClosing(
    job.name,
    end.isLost ? 'failure' : 'error',
    TraceReport(
      attempt: job.runAttempt,
      clock: clock,
      state: end.isLost ? TraceState.lost : TraceState.ended,
      lastClock: last.report.clock,
      path: last.report.path,
    ),
  );
}

/// The line the run shows about [job]'s end, or null when its end is
/// ordinary (it passed, or failed with a log). [earlierLosses] are the
/// losses of the same name in earlier attempts, if any.
Notice? _notice(
  JobRecord job, {
  required TraceEntry? Function(JobRecord) traceOf,
  required RerunPlan rerun,
  required int runId,
  required int attempt,
  required List<JobRecord> firstLosses,
  required List<JobRecord>? earlierLosses,
}) {
  final end = classifyJob(job);
  if (end.isLost && earlierLosses != null) {
    return Notice(
      NoticeLevel.error,
      _secondLoss([...earlierLosses, job], traceOf),
    );
  }
  return switch (end) {
    JobEnd.lostContact || JobEnd.lostAtLimit => Notice(
      NoticeLevel.warning,
      '${job.name} was lost (${_reason(job)}, with no log). '
      '${_traceSentence(traceOf(job))} '
      '${_after(job, rerun, runId, attempt, firstLosses.length)}',
    ),
    JobEnd.hungWithLog => Notice(
      NoticeLevel.warning,
      '${job.name} ran into its time limit with the runner alive: its log '
      'shows where. It is not rerun.',
    ),
    JobEnd.cancelledByPerson => Notice(
      NoticeLevel.notice,
      '${job.name} was cancelled by a person. It is not rerun.',
    ),
    JobEnd.other => Notice(
      NoticeLevel.notice,
      '${job.name} ended ${job.conclusion ?? 'with no conclusion'}, not as a '
      'job lost with its runner. It is not rerun.',
    ),
    JobEnd.passed || JobEnd.failedWithLog => null,
  };
}

const _noTrace =
    "(only the test jobs write one, and a pull request from a fork can't)";

/// GitHub's annotation for [job]'s loss, as words inside a sentence: its
/// first sentence, with a small first letter and no final stop.
String _reason(JobRecord job) {
  final start = classifyJob(job) == JobEnd.lostContact
      ? lostContactText
      : timeLimitText;
  final text = job.annotations.firstWhere((a) => a.startsWith(start));
  final stop = text.indexOf('. ');
  var sentence = stop < 0 ? text : text.substring(0, stop);
  if (sentence.endsWith('.')) {
    sentence = sentence.substring(0, sentence.length - 1);
  }
  return sentence[0].toLowerCase() + sentence.substring(1);
}

String _traceSentence(TraceEntry? last) {
  if (last == null) return 'No trace was found for it $_noTrace.';
  return "Its trace's last report: "
      '${traceDescription(last.report, withAttempt: false)}.';
}

String _after(
  JobRecord job,
  RerunPlan rerun,
  int runId,
  int attempt,
  int lostCount,
) {
  final wait = 'if no attempt ${attempt + 1} starts within 10 minutes, run:';
  return switch (rerun) {
    RerunJob() =>
      "CI's rerun workflow runs it once more; $wait "
          'gh run rerun $runId --job ${job.id}',
    RerunFailedJobs() =>
      "CI's rerun workflow reruns the run's failed jobs, which are all lost "
          'ones, once more; $wait gh run rerun $runId --failed',
    NoRerun() =>
      "CI's rerun workflow reruns nothing here: $lostCount jobs were lost "
          'while another job failed, and GitHub can rerun one job or every '
          'failed job, not two chosen ones. To run it again: '
          'gh run rerun $runId --job ${job.id}',
  };
}

/// Where a lost job's trace stopped: the clock and path of its last report
/// before the loss.
({String clock, String? path})? _stop(TraceEntry? entry) {
  if (entry == null) return null;
  final report = entry.report;
  return (
    clock: report.state.isClosing
        ? report.lastClock ?? report.clock
        : report.clock,
    path: report.path,
  );
}

String _secondLoss(
  List<JobRecord> losses,
  TraceEntry? Function(JobRecord) traceOf,
) {
  final job = losses.last;
  final times = losses.length == 2 ? 'twice' : '${losses.length} times';
  final each = losses.length == 2 ? 'either' : 'any';
  final how = [
    for (final loss in losses)
      'attempt ${loss.runAttempt}: '
          '${classifyJob(loss) == JobEnd.lostContact ? 'lost communication' : 'the time limit'}',
  ].join('; ');
  final text = StringBuffer(
    '${job.name} was lost $times ($how), with no log $each time.',
  );
  final before = losses[losses.length - 2];
  final stops = [_stop(traceOf(before)), _stop(traceOf(job))];
  final missing = [
    for (final (i, loss) in [before, job].indexed)
      if (stops[i] == null) 'attempt ${loss.runAttempt}',
  ];
  if (missing.isNotEmpty) {
    text.write(' No trace was found for ${missing.join(' or ')} $_noTrace.');
  } else if (stops[0]!.path != null && stops[0]!.path == stops[1]!.path) {
    final whose = losses.length == 2
        ? "Both attempts' traces"
        : "Attempt ${before.runAttempt}'s and attempt ${job.runAttempt}'s "
              'traces';
    text.write(
      ' $whose stopped at ${stops[1]!.path}, which points to a hang in '
      "Appstein's own tests rather than the runner.",
    );
  } else {
    String at(({String clock, String? path}) stop) =>
        '${stop.path ?? 'no test file'} (${stop.clock} UTC)';
    text.write(
      " Attempt ${before.runAttempt}'s trace stopped at ${at(stops[0]!)}, "
      "attempt ${job.runAttempt}'s at ${at(stops[1]!)}: not one test file, "
      'so most likely the runner.',
    );
  }
  return text.toString();
}

/// One step of a job, as `GET …/attempts/{n}/jobs` lists it.
final class StepRecord {
  /// A step with its [name], [status] and [conclusion].
  const StepRecord(this.name, this.status, this.conclusion);

  /// Reads one entry of a job's `steps` list.
  factory StepRecord.fromApi(Map<String, Object?> step) => StepRecord(
    step['name'] as String? ?? '',
    step['status'] as String? ?? '',
    step['conclusion'] as String?,
  );

  /// The step's name, for example `Unit tests` or `Complete job`.
  final String name;

  /// `completed`, `in_progress`, `pending` or `queued`.
  final String status;

  /// The step's conclusion, null while it has none.
  final String? conclusion;
}

/// One job of one attempt of a run, from `GET …/attempts/{n}/jobs`, with the
/// messages of its check-run annotations.
final class JobRecord {
  /// A job with every field given.
  const JobRecord({
    required this.id,
    required this.name,
    required this.runId,
    required this.runAttempt,
    required this.status,
    required this.conclusion,
    required this.startedAt,
    required this.completedAt,
    required this.steps,
    required this.annotations,
  });

  /// Reads one job of the API's `jobs` list, and the [annotations] of its
  /// check run (`GET /repos/{o}/{r}/check-runs/{job id}/annotations`; the
  /// job's ID is its check run's ID). Each annotation is a map with a
  /// `message`; anything else in the list is ignored.
  factory JobRecord.fromApi(
    Map<String, Object?> job,
    List<Object?> annotations,
  ) => JobRecord(
    id: (job['id'] as num).toInt(),
    name: job['name'] as String? ?? '',
    runId: (job['run_id'] as num?)?.toInt() ?? 0,
    runAttempt: (job['run_attempt'] as num?)?.toInt() ?? 1,
    status: job['status'] as String? ?? '',
    conclusion: job['conclusion'] as String?,
    startedAt: _time(job['started_at']),
    completedAt: _time(job['completed_at']),
    steps: [
      for (final step in (job['steps'] as List<Object?>?) ?? const [])
        if (step is Map<String, Object?>) StepRecord.fromApi(step),
    ],
    annotations: [
      for (final annotation in annotations)
        if (annotation is Map<String, Object?> &&
            annotation['message'] is String)
          annotation['message']! as String,
    ],
  );

  /// The job's ID, which is also its check run's ID.
  final int id;

  /// The job's name, for example `test (windows-latest)`.
  final String name;

  /// The ID of the run the job belongs to.
  final int runId;

  /// The attempt of the run this job is listed in.
  final int runAttempt;

  /// `completed` once the job has ended.
  final String status;

  /// `success`, `failure`, `cancelled`, `skipped`, `neutral` and so on;
  /// null while the job runs.
  final String? conclusion;

  /// When the job started. A job copied into a later attempt without being
  /// run again keeps this time.
  final DateTime? startedAt;

  /// When the job ended.
  final DateTime? completedAt;

  /// The job's steps, in the API's order.
  final List<StepRecord> steps;

  /// The `message` of each annotation of the job's check run, in the API's
  /// order.
  final List<String> annotations;
}

DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

/// How a job ended, as [classifyJob] sorts it.
enum JobEnd {
  /// It succeeded, was skipped, or ended neutral.
  passed,

  /// A person cancelled the run. Never rerun.
  cancelledByPerson,

  /// Lost: its steps never finished and GitHub says the runner lost
  /// communication with the server.
  lostContact,

  /// Lost: its steps never finished and GitHub cancelled it at its time
  /// limit.
  lostAtLimit,

  /// It reached its time limit with the runner alive: its steps finished and
  /// its log shows where it hung. Not rerun.
  hungWithLog,

  /// It failed with a log: an ordinary failure. Not rerun.
  failedWithLog,

  /// Any other end, for example cancelled before it started. Not rerun.
  other;

  /// Whether this end is a job lost with its runner, the only end that is
  /// rerun.
  bool get isLost => this == lostContact || this == lostAtLimit;
}

/// The conclusions of a job that passed: [JobEnd.passed]. Such a job needs
/// no annotation to be judged.
const passedConclusions = {'success', 'skipped', 'neutral'};

/// The start of the annotation GitHub writes when a person cancels a run.
const cancelledByPersonText = 'The run was canceled by @';

/// The start of the annotation GitHub writes when a hosted runner stops
/// answering.
const lostContactText = 'The hosted runner lost communication with the server';

/// The start of the annotation GitHub writes when a job reaches its time
/// limit.
const timeLimitText = 'The job has exceeded the maximum execution time';

/// Sorts how [job] ended. The first rule that matches wins:
///
/// 1. `success`, `skipped` or `neutral` is [JobEnd.passed];
/// 2. an annotation saying a person cancelled the run is
///    [JobEnd.cancelledByPerson], before any rule below, so a person who
///    cancels a frozen job is never rerun;
/// 3. the job is *unfinished* when it has steps, one of them is not
///    `completed`, and none is named `Complete job`;
/// 4. unfinished, with the annotation about lost communication, is
///    [JobEnd.lostContact];
/// 5. unfinished, with the annotation about the time limit, is
///    [JobEnd.lostAtLimit];
/// 6. finished, with the annotation about the time limit, is
///    [JobEnd.hungWithLog];
/// 7. a finished `failure` is [JobEnd.failedWithLog];
/// 8. anything else is [JobEnd.other], for example an unfinished job with
///    an annotation this rule doesn't know: it has no log to show, and it
///    is not rerun.
///
/// A lost end needs both signals, the unfinished steps and GitHub's
/// annotation, so an odd combination is never rerun by mistake.
JobEnd classifyJob(JobRecord job) {
  if (passedConclusions.contains(job.conclusion)) return JobEnd.passed;
  bool says(String start) => job.annotations.any((a) => a.startsWith(start));
  if (says(cancelledByPersonText)) return JobEnd.cancelledByPerson;
  final unfinished =
      job.steps.isNotEmpty &&
      job.steps.any((step) => step.status != 'completed') &&
      !job.steps.any((step) => step.name == 'Complete job');
  if (unfinished && says(lostContactText)) return JobEnd.lostContact;
  if (unfinished && says(timeLimitText)) return JobEnd.lostAtLimit;
  if (!unfinished && says(timeLimitText)) return JobEnd.hungWithLog;
  if (!unfinished && job.conclusion == 'failure') return JobEnd.failedWithLog;
  return JobEnd.other;
}
