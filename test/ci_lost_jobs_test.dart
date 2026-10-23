import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/github_api.dart';
import '../tool/src/lost_jobs_modes.dart';
import '../tool/src/unit_test_trace.dart';

const fixtures = 'test/support/ci_jobs';
const sha = '0123456789abcdef0123456789abcdef01234567';
const windows = 'test (windows-latest)';
const hostTest = 'packages/appstein_engine/test/analysis_host_test.dart';

Map<String, Object?> _read(String file) =>
    jsonDecode(File('$fixtures/$file').readAsStringSync())
        as Map<String, Object?>;

/// A GitHub that answers from recorded jobs and annotations, keeps
/// statuses in memory, and records every write.
final class FakeGitHub implements GitHubApi {
  /// Jobs by attempt, as the API lists them.
  final jobs = <int, List<Map<String, Object?>>>{};

  /// Annotations by job ID.
  final notes = <int, List<Object?>>{};

  /// Statuses, newest first.
  final statuses = <Map<String, Object?>>[];

  /// Pages of statuses read.
  var pagesRead = 0;

  /// What every write call was asked.
  final writes = <String>[];

  /// The error a status post throws, if any.
  GitHubApiException? postError;

  /// The error a status read throws, if any.
  GitHubApiException? readError;

  /// The error a rerun throws, if any.
  GitHubApiException? rerunError;

  /// The error a read of jobs throws, if any.
  GitHubApiException? jobsError;

  @override
  Future<List<Map<String, Object?>>> jobsOfAttempt(
    int runId,
    int attempt,
  ) async {
    if (jobsError case final error?) throw error;
    return jobs[attempt] ?? const [];
  }

  @override
  Future<List<Object?>> annotations(int jobId) async =>
      notes[jobId] ?? const [];

  @override
  Future<List<Map<String, Object?>>> statusesPage(String sha, int page) async {
    if (readError case final error?) throw error;
    pagesRead++;
    final start = (page - 1) * 100;
    if (start >= statuses.length) return const [];
    return statuses.sublist(
      start,
      start + 100 > statuses.length ? statuses.length : start + 100,
    );
  }

  @override
  Future<void> postStatus(
    String sha, {
    required String state,
    required String context,
    required String description,
    required String targetUrl,
  }) async {
    if (postError case final error?) throw error;
    writes.add('status $sha $state $context | $description | $targetUrl');
  }

  @override
  Future<void> rerunJob(int jobId) async {
    if (rerunError case final error?) throw error;
    writes.add('rerun job $jobId');
  }

  @override
  Future<void> rerunFailedJobs(int runId) async {
    if (rerunError case final error?) throw error;
    writes.add('rerun failed jobs of $runId');
  }
}

/// Run 39551693885 as recorded: attempt 1 lost `test (windows-latest)`
/// (lost communication), and attempt 2 reran it and it passed.
FakeGitHub run39551693885() {
  final api = FakeGitHub();
  final all = _read('run_39551693885_all_jobs.json')['jobs']! as List<Object?>;
  for (final job in all.cast<Map<String, Object?>>()) {
    (api.jobs[(job['run_attempt']! as num).toInt()] ??= []).add(job);
  }
  for (final name in ['lost_communication', 'failed_with_log']) {
    final data = _read('$name.json');
    api.notes[((data['job']! as Map<String, Object?>)['id']! as num).toInt()] =
        data['annotations']! as List<Object?>;
  }
  return api;
}

/// A status as the API lists it.
Map<String, Object?> status(
  String context,
  String description,
  int runId,
  int attempt,
  DateTime createdAt, {
  String state = 'pending',
}) => {
  'context': context,
  'description': description,
  'state': state,
  'target_url': attemptUrl('https://github.com', 'o/r', runId, attempt),
  'created_at': createdAt.toIso8601String(),
};

void main() {
  const runId = 39551693885;

  group('report', () {
    test(
      'a first loss warns with the trace found past the first page',
      () async {
        final api = run39551693885();
        final t0 = DateTime.utc(2026, 10, 21, 6);
        // Newest first: 150 statuses of the other jobs, then the windows
        // job's last reports, so they are on the second page.
        for (var i = 0; i < 150; i++) {
          api.statuses.add(
            status(
              traceContext('test (ubuntu-latest)'),
              'a1 06:10:00 UTC, finished',
              runId,
              1,
              t0.add(Duration(minutes: 30, seconds: -i)),
            ),
          );
        }
        api.statuses
          ..add(status('ci/other', 'something', runId, 1, t0))
          ..add(
            status(
              traceContext(windows),
              'a1 06:45:12 UTC, 3 running, longest 38m: $hostTest',
              runId,
              1,
              t0.add(const Duration(minutes: 20)),
            ),
          )
          ..add(
            status(
              traceContext(windows),
              'a1 06:44:42 UTC, 1 running, longest 1m: test/x_test.dart',
              runId,
              1,
              t0.add(const Duration(minutes: 19)),
            ),
          );
        final out = StringBuffer();
        final code = await reportLostJobs(
          api: api,
          repo: 'o/r',
          serverUrl: 'https://github.com',
          runId: runId,
          attempt: 1,
          sha: sha,
          out: out,
        );
        expect(code, 0);
        expect(api.pagesRead, greaterThanOrEqualTo(2));
        expect(
          out.toString(),
          contains(
            '::warning::test (windows-latest) was lost (the hosted runner lost '
            "communication with the server, with no log). Its trace's last "
            'report: 06:45:12 UTC, 3 running, longest 38m: $hostTest. ',
          ),
        );
        expect(api.writes, [
          'status $sha failure CI trace / test (windows-latest) | '
              'a1 lost 06:48:04 UTC, last 06:45:12 UTC: $hostTest | '
              'https://github.com/o/r/actions/runs/$runId/attempts/1',
        ]);
      },
    );

    test('attempt 2 found nothing and exits 0', () async {
      final api = run39551693885();
      final out = StringBuffer();
      final code = await reportLostJobs(
        api: api,
        repo: 'o/r',
        serverUrl: 'https://github.com',
        runId: runId,
        attempt: 2,
        sha: sha,
        out: out,
      );
      expect(code, 0);
      expect(
        out.toString(),
        contains('::notice::No job of attempt 2 was lost with its runner.'),
      );
      expect(api.writes, isEmpty);
    });

    // Built from the recordings: there is no recorded second loss yet.
    FakeGitHub lostTwice() {
      final api = FakeGitHub();
      final first = _read('lost_communication.json');
      final second = _read('lost_at_limit.json');
      final a1 = first['job']! as Map<String, Object?>;
      final a2 = {
        ...second['job']! as Map<String, Object?>,
        'id': 900000000002,
        'run_id': a1['run_id'],
        'run_attempt': 2,
        'name': windows,
      };
      api.jobs[1] = [a1];
      api.jobs[2] = [a2];
      api.notes[(a1['id']! as num).toInt()] =
          first['annotations']! as List<Object?>;
      api.notes[900000000002] = second['annotations']! as List<Object?>;
      return api;
    }

    test('a second loss is an error and exits 1', () async {
      final api = lostTwice();
      final out = StringBuffer();
      final code = await reportLostJobs(
        api: api,
        repo: 'o/r',
        serverUrl: 'https://github.com',
        runId: runId,
        attempt: 2,
        sha: sha,
        out: out,
      );
      expect(code, 1);
      expect(
        out.toString(),
        contains('::error::test (windows-latest) was lost twice'),
      );
      expect(api.writes.where((w) => w.startsWith('rerun')), isEmpty);
    });

    test('a status that cannot be written never fails the job', () async {
      final api = run39551693885()
        ..postError = const GitHubApiException(403, 'Resource not accessible')
        ..statuses.add(
          status(
            traceContext(windows),
            'a1 06:45:12 UTC, loading $hostTest',
            runId,
            1,
            DateTime.utc(2026, 10, 21, 6, 45),
          ),
        );
      final out = StringBuffer();
      final code = await reportLostJobs(
        api: api,
        repo: 'o/r',
        serverUrl: 'https://github.com',
        runId: runId,
        attempt: 1,
        sha: sha,
        out: out,
      );
      expect(code, 0);
      expect(
        out.toString(),
        contains(
          '::warning::The trace of test (windows-latest) could not be '
          'closed: HTTP 403 Resource not accessible',
        ),
      );
    });

    test('statuses that cannot be read leave only the trace out', () async {
      final api = run39551693885()
        ..readError = const GitHubApiException(404, 'Not Found');
      final out = StringBuffer();
      final code = await reportLostJobs(
        api: api,
        repo: 'o/r',
        serverUrl: 'https://github.com',
        runId: runId,
        attempt: 1,
        sha: sha,
        out: out,
      );
      expect(code, 0);
      expect(
        out.toString(),
        contains('The traces could not be read: HTTP 404 Not Found'),
      );
      expect(out.toString(), contains('No trace was found for it'));
    });
  });

  group('GitHub cannot be read', () {
    // A job that really failed or was lost makes the run red by itself, so
    // lost-jobs adds nothing by failing on GitHub's outage.
    const outage = GitHubApiException(503, 'Service Unavailable');

    test('report warns and exits 0', () async {
      final api = run39551693885()..jobsError = outage;
      final out = StringBuffer();
      final code = await reportLostJobs(
        api: api,
        repo: 'o/r',
        serverUrl: 'https://github.com',
        runId: runId,
        attempt: 1,
        sha: sha,
        out: out,
      );
      expect(code, 0);
      expect(
        out.toString(),
        '::warning::The jobs of attempt 1 of run $runId could not be read, '
        'so lost jobs were not judged this time: HTTP 503 Service '
        'Unavailable. See the jobs with: gh run view $runId --attempt 1. '
        'A job lost with its runner can be rerun with: gh run rerun $runId '
        '--job <job id>\n',
      );
      expect(api.writes, isEmpty);
    });

    test('rerun warns, reruns nothing and exits 0', () async {
      final api = run39551693885()..jobsError = outage;
      final out = StringBuffer();
      final code = await rerunLostJobs(
        api: api,
        runId: runId,
        attempt: 1,
        out: out,
      );
      expect(code, 0);
      expect(
        out.toString(),
        startsWith(
          '::warning::The jobs of attempt 1 of run $runId could not be read, '
          'so lost jobs were not judged this time: HTTP 503',
        ),
      );
      expect(api.writes, isEmpty);
    });
  });

  group('rerun', () {
    test('attempt 1 reruns exactly its one lost job', () async {
      final api = run39551693885();
      final out = StringBuffer();
      final code = await rerunLostJobs(
        api: api,
        runId: runId,
        attempt: 1,
        out: out,
      );
      expect(code, 0);
      expect(api.writes, ['rerun job 119062121322']);
      expect(api.pagesRead, 0, reason: 'the rerunner reads no statuses');
      expect(
        out.toString(),
        contains(
          'Asked GitHub to rerun test (windows-latest) (job 119062121322) '
          'of run $runId.',
        ),
      );
    });

    test('attempt 2 reruns nothing', () async {
      final api = run39551693885();
      final out = StringBuffer();
      final code = await rerunLostJobs(
        api: api,
        runId: runId,
        attempt: 2,
        out: out,
      );
      expect(code, 0);
      expect(api.writes, isEmpty);
      expect(out.toString(), contains('Nothing to rerun.'));
    });

    test('two lost jobs and no other failure: every failed job', () async {
      final api = FakeGitHub();
      final first = _read('lost_communication.json');
      final second = _read('lost_at_limit.json');
      api.jobs[1] = [
        first['job']! as Map<String, Object?>,
        {
          ...second['job']! as Map<String, Object?>,
          'run_id': runId,
          'name': 'build (windows-latest)',
        },
      ];
      api.notes[119062121322] = first['annotations']! as List<Object?>;
      api.notes[119771537338] = second['annotations']! as List<Object?>;
      final out = StringBuffer();
      final code = await rerunLostJobs(
        api: api,
        runId: runId,
        attempt: 1,
        out: out,
      );
      expect(code, 0);
      expect(api.writes, ['rerun failed jobs of $runId']);
    });

    test('a rerun GitHub refuses fails the rerun job', () async {
      final api = run39551693885()
        ..rerunError = const GitHubApiException(
          403,
          'This workflow is already running',
        );
      final out = StringBuffer();
      final code = await rerunLostJobs(
        api: api,
        runId: runId,
        attempt: 1,
        out: out,
      );
      expect(code, 1);
      expect(
        out.toString(),
        contains(
          '::error::GitHub refused the rerun: HTTP 403 This workflow is '
          'already running',
        ),
      );
    });
  });
}
