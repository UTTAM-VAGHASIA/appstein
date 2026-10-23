import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/lost_jobs.dart';
import '../tool/src/unit_test_trace.dart';

/// Recorded API answers for the rule of ticket 15 of slice 1d.7. Each
/// trimmed file is `{source, note, job, annotations, has_log}`, copied as it
/// was recorded from GitHub's API.
const fixtures = 'test/support/ci_jobs';

/// The recorded job of [name] (`lost_at_limit` and so on).
JobRecord recorded(String name) {
  final data =
      jsonDecode(File('$fixtures/$name.json').readAsStringSync())
          as Map<String, Object?>;
  return JobRecord.fromApi(
    data['job']! as Map<String, Object?>,
    data['annotations']! as List<Object?>,
  );
}

/// [job] with some fields changed, for cases built from the recordings.
JobRecord changed(
  JobRecord job, {
  int? id,
  int? runAttempt,
  String? name,
  String? conclusion,
  DateTime? startedAt,
  DateTime? completedAt,
  List<StepRecord>? steps,
  List<String>? annotations,
}) => JobRecord(
  id: id ?? job.id,
  name: name ?? job.name,
  runId: job.runId,
  runAttempt: runAttempt ?? job.runAttempt,
  status: job.status,
  conclusion: conclusion ?? job.conclusion,
  startedAt: startedAt ?? job.startedAt,
  completedAt: completedAt ?? job.completedAt,
  steps: steps ?? job.steps,
  annotations: annotations ?? job.annotations,
);

/// Every job of both attempts of run 39551693885, as recorded with
/// `…/jobs?filter=all`, with the annotations recorded for its lost and its
/// failed job (the other jobs' annotations were not recorded; none of them
/// needs one to be judged).
List<JobRecord> run39551693885() {
  final data =
      jsonDecode(
            File('$fixtures/run_39551693885_all_jobs.json').readAsStringSync(),
          )
          as Map<String, Object?>;
  final annotations = <int, List<Object?>>{
    for (final name in ['lost_communication', 'failed_with_log'])
      recorded(name).id:
          (jsonDecode(File('$fixtures/$name.json').readAsStringSync())
                  as Map<String, Object?>)['annotations']!
              as List<Object?>,
  };
  return [
    for (final job in data['jobs']! as List<Object?>)
      JobRecord.fromApi(
        job! as Map<String, Object?>,
        annotations[((job as Map<String, Object?>)['id']! as num).toInt()] ??
            const [],
      ),
  ];
}

/// A trace entry of [job] for run [runId], attempt [attempt].
TraceEntry trace(
  String job,
  int runId,
  int attempt,
  String description, {
  DateTime? createdAt,
}) => parseTrace(
  context: traceContext(job),
  description: description,
  targetUrl: attemptUrl('https://github.com', 'o/r', runId, attempt),
  createdAt: createdAt,
)!;

const windows = 'test (windows-latest)';
const hostTest = 'packages/appstein_engine/test/analysis_host_test.dart';

void main() {
  group('attempts', () {
    final all = run39551693885();
    final first = [
      for (final j in all)
        if (j.runAttempt == 1) j,
    ];
    final second = [
      for (final j in all)
        if (j.runAttempt == 2) j,
    ];

    test('attempt 2 ran exactly one new job, the lost one again', () {
      final fresh = newInAttempt(second, first);
      expect(
        [for (final j in fresh) '${j.id} ${j.name}'],
        ['119081927520 test (windows-latest)'],
      );
    });

    test('attempt 1 reruns its one lost job alone', () {
      final verdict = judgeAttempt(
        runId: 39551693885,
        attempt: 1,
        jobs: first,
        earlierJobs: const [],
      );
      expect([for (final j in verdict.firstLosses) j.id], [119062121322]);
      expect(verdict.secondLosses, isEmpty);
      expect(verdict.rerun, const RerunJob(119062121322));
      expect(verdict.fails, isFalse);
      final warnings = [
        for (final n in verdict.notices)
          if (n.level == NoticeLevel.warning) n.text,
      ];
      expect(warnings, [
        'test (windows-latest) was lost (the hosted runner lost '
            'communication with the server, with no log). No trace was found '
            "for it (only the test jobs write one, and a pull request from a "
            "fork can't). CI's rerun workflow runs it once more; if no "
            'attempt 2 starts within 10 minutes, run: '
            'gh run rerun 39551693885 --job 119062121322',
      ]);
    });

    test('attempt 2, where the lost job passed, has nothing to do', () {
      final verdict = judgeAttempt(
        runId: 39551693885,
        attempt: 2,
        jobs: second,
        earlierJobs: first,
      );
      expect(verdict.firstLosses, isEmpty);
      expect(verdict.secondLosses, isEmpty);
      expect(verdict.rerun, const NoRerun());
      expect(verdict.fails, isFalse);
      expect(
        [for (final n in verdict.notices) n.text],
        ['No job of attempt 2 was lost with its runner.'],
      );
    });

    // There is no recorded second loss yet: this attempt-2 job is built
    // from the recorded lost jobs, with a new ID, attempt 2 and a later
    // start. The proof run of ticket 15 adds a real one.
    JobRecord lostAgain(JobRecord lost, {int attempt = 2}) => changed(
      lost,
      id: 900000000000 + attempt,
      runAttempt: attempt,
      name: windows,
      startedAt: lost.startedAt!.add(Duration(hours: attempt)),
      completedAt: lost.completedAt!.add(Duration(hours: attempt)),
    );

    test('a second loss fails and is not rerun', () {
      final a1 = recorded('lost_communication');
      final a2 = lostAgain(recorded('lost_at_limit'));
      final verdict = judgeAttempt(
        runId: a1.runId,
        attempt: 2,
        jobs: [a2],
        earlierJobs: [a1],
      );
      expect(verdict.firstLosses, isEmpty);
      expect([for (final j in verdict.secondLosses) j.id], [a2.id]);
      expect(verdict.rerun, const NoRerun());
      expect(verdict.fails, isTrue);
      expect(verdict.notices.single.level, NoticeLevel.error);
      expect(
        verdict.notices.single.text,
        startsWith(
          'test (windows-latest) was lost twice (attempt 1: lost '
          'communication; attempt 2: the time limit), with no log either '
          'time.',
        ),
      );
    });

    test('a job copied from the lost attempt is not judged again', () {
      final a1 = recorded('lost_communication');
      final copy = changed(a1, id: 1, runAttempt: 2);
      final verdict = judgeAttempt(
        runId: a1.runId,
        attempt: 2,
        jobs: [copy],
        earlierJobs: [a1],
      );
      expect(verdict.secondLosses, isEmpty);
      expect(verdict.firstLosses, isEmpty);
      expect(verdict.fails, isFalse);
    });

    test('a first loss after a whole rerun for another failure is rerun', () {
      final failed = recorded('failed_with_log');
      final a2 = lostAgain(recorded('lost_communication'));
      final verdict = judgeAttempt(
        runId: failed.runId,
        attempt: 2,
        jobs: [a2],
        earlierJobs: [
          failed,
          changed(
            a2,
            id: 5,
            runAttempt: 1,
            conclusion: 'success',
            steps: failed.steps,
            annotations: [],
            startedAt: failed.startedAt,
          ),
        ],
      );
      expect(verdict.rerun, RerunJob(a2.id));
      expect(verdict.fails, isFalse);
    });

    test('two lost jobs and nothing else failed: every failed job', () {
      final lostA = recorded('lost_communication');
      final lostB = changed(
        recorded('lost_at_limit'),
        id: 77,
        runAttempt: 1,
        name: 'build (macos-latest)',
      );
      final passed = recorded('second_attempt_passed');
      final verdict = judgeAttempt(
        runId: lostA.runId,
        attempt: 1,
        jobs: [lostA, lostB, changed(passed, runAttempt: 1)],
        earlierJobs: const [],
      );
      expect(verdict.firstLosses, hasLength(2));
      expect(verdict.rerun, RerunFailedJobs(lostA.runId));
      expect(
        verdict.notices.first.text,
        endsWith(
          "CI's rerun workflow reruns the run's failed jobs, which are all "
          'lost ones, once more; if no attempt 2 starts within 10 minutes, '
          'run: gh run rerun ${lostA.runId} --failed',
        ),
      );
    });

    test('two lost jobs while another failed with a log: nothing', () {
      final lostA = recorded('lost_communication');
      final lostB = changed(
        recorded('lost_at_limit'),
        id: 77,
        name: 'build (macos-latest)',
      );
      final failed = recorded('failed_with_log');
      final verdict = judgeAttempt(
        runId: lostA.runId,
        attempt: 1,
        jobs: [lostA, lostB, failed],
        earlierJobs: const [],
      );
      expect(verdict.rerun, const NoRerun());
      expect(verdict.fails, isFalse);
      final warnings = [
        for (final n in verdict.notices)
          if (n.level == NoticeLevel.warning) n.text,
      ];
      expect(warnings, hasLength(2));
      expect(
        warnings[0],
        endsWith('gh run rerun ${lostA.runId} --job ${lostA.id}'),
      );
      expect(warnings[1], endsWith('gh run rerun ${lostA.runId} --job 77'));
      expect(
        warnings[0],
        contains(
          "CI's rerun workflow reruns nothing here: 2 jobs were lost while "
          'another job failed, and GitHub can rerun one job or every failed '
          'job, not two chosen ones.',
        ),
      );
    });

    test('a job still running, lost-jobs itself, is not judged', () {
      final running = JobRecord(
        id: 3,
        name: 'lost-jobs',
        runId: 1,
        runAttempt: 1,
        status: 'in_progress',
        conclusion: null,
        startedAt: DateTime.utc(2026),
        completedAt: null,
        steps: const [StepRecord('Set up job', 'in_progress', null)],
        annotations: const [],
      );
      final verdict = judgeAttempt(
        runId: 1,
        attempt: 1,
        jobs: [running],
        earlierJobs: const [],
      );
      expect(
        [for (final n in verdict.notices) n.text],
        ['No job of attempt 1 was lost with its runner.'],
      );
    });

    test('other ends say why nothing was rerun, one line each', () {
      final verdict = judgeAttempt(
        runId: 1,
        attempt: 1,
        jobs: [
          recorded('hung_with_log_at_limit'),
          recorded('cancelled_by_person'),
          recorded('cancelled_before_start'),
          recorded('failed_with_log'),
        ],
        earlierJobs: const [],
      );
      expect(
        [for (final n in verdict.notices) n.command],
        [
          '::warning::measure (ubuntu-latest) ran into its time limit with the '
              'runner alive: its log shows where. It is not rerun.',
          '::notice::windows was cancelled by a person. It is not rerun.',
          '::notice::acceptance (windows-latest) ended cancelled, not as a '
              'job lost with its runner. It is not rerun.',
          '::notice::No job of attempt 1 was lost with its runner.',
        ],
      );
    });
  });

  group('messages with traces', () {
    final a1 = recorded('lost_communication');
    final runId = a1.runId;
    final a2 = changed(
      recorded('lost_at_limit'),
      id: 900000000002,
      runAttempt: 2,
      name: windows,
      startedAt: DateTime.utc(2026, 10, 21, 12),
      completedAt: DateTime.utc(2026, 10, 21, 13, 0, 5),
    );

    test('a first loss quotes its trace and closes it as lost', () {
      final verdict = judgeAttempt(
        runId: runId,
        attempt: 1,
        jobs: [a1],
        earlierJobs: const [],
        traces: {
          windows: [
            // Newest first, as the API lists statuses.
            trace(
              windows,
              runId,
              1,
              'a1 06:45:12 UTC, 3 running, longest 38m: $hostTest',
              createdAt: DateTime.utc(2026, 10, 21, 6, 45, 13),
            ),
            trace(
              windows,
              runId,
              1,
              'a1 06:44:42 UTC, 2 running, longest 37m: $hostTest',
              createdAt: DateTime.utc(2026, 10, 21, 6, 44, 43),
            ),
            // Another run of the same commit: never this job's.
            trace(
              windows,
              123,
              1,
              'a1 09:00:00 UTC, finished',
              createdAt: DateTime.utc(2026, 10, 21, 9),
            ),
          ],
        },
      );
      expect(
        verdict.notices.single.text,
        contains(
          "Its trace's last report: 06:45:12 UTC, 3 running, longest 38m: "
          '$hostTest.',
        ),
      );
      final closing = verdict.closings.single;
      expect(closing.jobName, windows);
      expect(closing.state, 'failure');
      expect(
        traceDescription(closing.report),
        'a1 lost ${traceClock(a1.completedAt!)} UTC, last 06:45:12 UTC: '
        '$hostTest',
      );
    });

    Map<String, List<TraceEntry>> twoTraces(String first, String second) => {
      windows: [
        trace(
          windows,
          runId,
          2,
          'a2 12:31:40 UTC, 1 running, longest 30m: $second',
        ),
        trace(
          windows,
          runId,
          1,
          'a1 lost 06:48:00 UTC, last 06:45:12 UTC: $first',
        ),
        trace(
          windows,
          runId,
          1,
          'a1 06:45:12 UTC, 3 running, longest 38m: $first',
        ),
      ],
    };

    test('lost twice at the same file points to our own tests', () {
      final verdict = judgeAttempt(
        runId: runId,
        attempt: 2,
        jobs: [a2],
        earlierJobs: [a1],
        traces: twoTraces(hostTest, hostTest),
      );
      expect(
        verdict.notices.single.text,
        'test (windows-latest) was lost twice (attempt 1: lost '
        'communication; attempt 2: the time limit), with no log either '
        "time. Both attempts' traces stopped at $hostTest, which points to "
        "a hang in Appstein's own tests rather than the runner.",
      );
      expect(verdict.notices.single.level, NoticeLevel.error);
      expect(verdict.closings.single.report.state, TraceState.lost);
      expect(verdict.closings.single.report.path, hostTest);
    });

    test('lost twice at different files points to the runner', () {
      const other = 'packages/appstein_cli/test/verify_test.dart';
      final verdict = judgeAttempt(
        runId: runId,
        attempt: 2,
        jobs: [a2],
        earlierJobs: [a1],
        traces: twoTraces(hostTest, other),
      );
      expect(
        verdict.notices.single.text,
        endsWith(
          "Attempt 1's trace stopped at $hostTest (06:45:12 UTC), attempt "
          "2's at $other (12:31:40 UTC): not one test file, so most likely "
          'the runner.',
        ),
      );
    });

    test('lost twice with no trace says so', () {
      final verdict = judgeAttempt(
        runId: runId,
        attempt: 2,
        jobs: [a2],
        earlierJobs: [a1],
      );
      expect(
        verdict.notices.single.text,
        endsWith(
          'No trace was found for attempt 1 or attempt 2 (only the test '
          "jobs write one, and a pull request from a fork can't).",
        ),
      );
    });

    test('a trace already closed, or finished, is left alone', () {
      final finished = recorded('failed_with_log');
      final verdict = judgeAttempt(
        runId: finished.runId,
        attempt: 1,
        jobs: [finished],
        earlierJobs: const [],
        traces: {
          finished.name: [
            trace(
              finished.name,
              finished.runId,
              1,
              'a1 06:00:00 UTC, unit tests failed',
            ),
          ],
        },
      );
      expect(verdict.closings, isEmpty);
    });

    test(
      'a running trace of a job that ended otherwise is closed as ended',
      () {
        final cancelled = recorded('cancelled_by_person');
        final verdict = judgeAttempt(
          runId: cancelled.runId,
          attempt: 1,
          jobs: [cancelled],
          earlierJobs: const [],
          traces: {
            cancelled.name: [
              trace(
                cancelled.name,
                cancelled.runId,
                1,
                'a1 13:55:40 UTC, loading test/a_test.dart',
              ),
            ],
          },
        );
        final closing = verdict.closings.single;
        expect(closing.state, 'error');
        expect(
          traceDescription(closing.report),
          'a1 ended ${traceClock(cancelled.completedAt!)} UTC, last 13:55:40 '
          'UTC: test/a_test.dart',
        );
      },
    );

    test('a running trace of a job that passed is closed as finished', () {
      // The wrapper's last post failed, so the trace still said "running".
      final passed = changed(recorded('second_attempt_passed'), runAttempt: 1);
      final verdict = judgeAttempt(
        runId: passed.runId,
        attempt: 1,
        jobs: [passed],
        earlierJobs: const [],
        traces: {
          passed.name: [
            trace(
              passed.name,
              passed.runId,
              1,
              'a1 07:20:00 UTC, idle after test/x_test.dart',
            ),
          ],
        },
      );
      final closing = verdict.closings.single;
      expect(closing.state, 'success');
      expect(
        traceDescription(closing.report),
        'a1 ${traceClock(passed.completedAt!)} UTC, finished',
      );
    });

    test('the workflow command escapes what the runner reads', () {
      expect(
        const Notice(NoticeLevel.error, '100% lost\r\nx').command,
        '::error::100%25 lost%0D%0Ax',
      );
    });
  });

  group('classifyJob on recorded jobs', () {
    final expected = {
      'lost_communication': JobEnd.lostContact,
      'lost_at_limit': JobEnd.lostAtLimit,
      'failed_with_log': JobEnd.failedWithLog,
      'hung_with_log_at_limit': JobEnd.hungWithLog,
      'cancelled_by_person': JobEnd.cancelledByPerson,
      'failed_at_setup': JobEnd.failedWithLog,
      'cancelled_before_start': JobEnd.other,
      'second_attempt_passed': JobEnd.passed,
    };
    for (final MapEntry(key: name, value: end) in expected.entries) {
      test('$name is ${end.name}', () {
        expect(classifyJob(recorded(name)), end);
      });
    }
  });

  group('classifyJob edge cases', () {
    test('an unfinished job with an unknown annotation is other', () {
      final job = changed(
        recorded('lost_communication'),
        annotations: ['Something new GitHub says.'],
      );
      expect(classifyJob(job), JobEnd.other);
    });

    test('a person who cancels a frozen job is never rerun', () {
      final job = changed(
        recorded('lost_at_limit'),
        annotations: [
          'The run was canceled by @someone.',
          'The job has exceeded the maximum execution time of 1h0m0s',
        ],
      );
      expect(classifyJob(job), JobEnd.cancelledByPerson);
    });

    test('lost contact with every step finished is a failure with a log', () {
      final finished = recorded('failed_with_log');
      final job = changed(
        finished,
        annotations: [
          'The hosted runner lost communication with the server. Anything …',
        ],
      );
      expect(classifyJob(job), JobEnd.failedWithLog);
    });

    test('a step left pending in a job that completed is not lost', () {
      // Built from the recorded hang: GitHub wrote "Complete job", so the
      // runner was alive at the end even if one step is still listed as
      // pending.
      final hung = recorded('hung_with_log_at_limit');
      final job = changed(
        hung,
        steps: [
          ...hung.steps.take(2),
          const StepRecord('Some later step', 'pending', null),
          ...hung.steps.skip(2),
        ],
      );
      expect(classifyJob(job), JobEnd.hungWithLog);
    });

    test('unfinished steps with no annotation are not lost', () {
      final job = changed(recorded('lost_at_limit'), annotations: []);
      expect(classifyJob(job), JobEnd.other);
    });

    test('skipped and neutral jobs passed', () {
      final job = recorded('lost_at_limit');
      expect(classifyJob(changed(job, conclusion: 'skipped')), JobEnd.passed);
      expect(classifyJob(changed(job, conclusion: 'neutral')), JobEnd.passed);
    });

    test('only the two lost ends are lost', () {
      expect(
        [
          for (final end in JobEnd.values)
            if (end.isLost) end,
        ],
        [JobEnd.lostContact, JobEnd.lostAtLimit],
      );
    });
  });
}
