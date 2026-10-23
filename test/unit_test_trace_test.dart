import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/unit_test_trace.dart';

const _url =
    'https://github.com/UTTAM-VAGHASIA/appstein/actions/runs/39763006737/attempts/2';

TraceEntry? _parse(
  String description, {
  String job = 'test (windows-latest)',
}) => parseTrace(
  context: traceContext(job),
  description: description,
  targetUrl: _url,
);

/// The events of a real `dart test --file-reporter json:<file>` run on
/// Windows (test 1.32.0), of two files run at once: `a_test.dart` with one
/// 15 s test, `b_test.dart` with a quick test and an 8 s one. Only the
/// absolute folder in the `url` fields was replaced with `C:/probe/`.
List<String> recordedEvents() =>
    File('test/support/ci_jobs/dart_test_events.jsonl').readAsLinesSync();

void main() {
  group('event fold', () {
    final now = DateTime.utc(2026, 10, 22, 10, 58, 12);
    TraceReport fold(int lines, int elapsedMs) {
      final run = TestRunFold(
        prefix: 'packages/appstein_engine/',
        label: 'packages/appstein_engine',
      );
      recordedEvents().take(lines).forEach(run.addLine);
      return run.report(attempt: 1, now: now, elapsedMs: elapsedMs);
    }

    test('before any test starts it names the folder', () {
      expect(
        traceDescription(fold(0, 0)),
        'a1 10:58:12 UTC, starting packages/appstein_engine',
      );
    });

    test('while files load it names the file loading longest', () {
      expect(
        traceDescription(fold(5, 6)),
        'a1 10:58:12 UTC, loading packages/appstein_engine/test/a_test.dart',
      );
    });

    test('two files at once: the test that has run longest', () {
      // After 14 events "slow a" (started at 394 ms) and "slow b" (at
      // 407 ms) are both running.
      expect(
        traceDescription(fold(14, 394 + 2 * 60000 + 1000)),
        'a1 10:58:12 UTC, 2 running, longest 2m: '
        'packages/appstein_engine/test/a_test.dart',
      );
    });

    test('a test that never finishes stays the one named', () {
      // "slow b" finished at 8,412 ms; "slow a" has no testDone yet.
      expect(
        traceDescription(fold(15, 9000)),
        'a1 10:58:12 UTC, 1 running, longest 0m: '
        'packages/appstein_engine/test/a_test.dart',
      );
    });

    test('with nothing running it names the last file that finished', () {
      expect(
        traceDescription(fold(17, 15500)),
        'a1 10:58:12 UTC, idle after packages/appstein_engine/test/a_test.dart',
      );
    });

    test('lines that are not events are ignored', () {
      final run = TestRunFold(prefix: '', label: 'test')
        ..addLine('not json')
        ..addLine('[1, 2]')
        ..addLine('{"type":"testStart"}')
        ..addLine('{"type":"testDone","testID":99}');
      expect(
        traceDescription(run.report(attempt: 2, now: now, elapsedMs: 0)),
        'a2 10:58:12 UTC, starting test',
      );
    });

    test('a half-written last line waits for the rest', () {
      final bytes = utf8.encode(recordedEvents().take(3).join('\n'));
      final lines = JsonLines();
      expect(lines.add(bytes.sublist(0, 10)), isEmpty);
      final firstTwo = lines.add(bytes.sublist(10));
      expect(firstTwo, recordedEvents().take(2).toList());
      expect(lines.add(utf8.encode('\n')), [recordedEvents()[2]]);
    });

    test('a character split between two reads is kept whole', () {
      final bytes = utf8.encode('{"a":"caf\u00e9"}\r\n');
      final lines = JsonLines();
      final split = bytes.indexOf(0xC3) + 1;
      expect(lines.add(bytes.sublist(0, split)), isEmpty);
      expect(lines.add(bytes.sublist(split)), ['{"a":"caf\u00e9"}']);
    });

    test('paths are repo-relative with forward slashes', () {
      expect(
        repoPath('packages/appstein_cli/', r'test\a\b_test.dart'),
        'packages/appstein_cli/test/a/b_test.dart',
      );
      expect(repoPath('', 'test/x_test.dart'), 'test/x_test.dart');
    });

    test('the tests never get the token', () {
      final env = childEnvironment({
        'PATH': '/bin',
        'APPSTEIN_TRACE_TOKEN': 'secret',
        'appstein_trace_token': 'secret too',
        'GITHUB_ACTIONS': 'true',
      });
      expect(env, {'PATH': '/bin', 'GITHUB_ACTIONS': 'true'});
    });
  });

  group('trace text', () {
    const engineFile = 'packages/appstein_engine/test/analysis_host_test.dart';
    final every = <TraceReport>[
      const TraceReport(
        attempt: 1,
        clock: '10:51:02',
        state: TraceState.starting,
        path: 'packages/appstein_engine',
      ),
      const TraceReport(
        attempt: 1,
        clock: '10:28:40',
        state: TraceState.loading,
        path: 'packages/appstein_cli/test/foo_test.dart',
      ),
      const TraceReport(
        attempt: 1,
        clock: '10:58:12',
        state: TraceState.running,
        running: 3,
        longestMinutes: 38,
        path: engineFile,
      ),
      const TraceReport(
        attempt: 2,
        clock: '10:59:00',
        state: TraceState.idle,
        path: 'test/lost_jobs_test.dart',
      ),
      const TraceReport(
        attempt: 1,
        clock: '11:02:13',
        state: TraceState.finished,
      ),
      const TraceReport(
        attempt: 1,
        clock: '11:02:13',
        state: TraceState.failed,
      ),
      const TraceReport(
        attempt: 1,
        clock: '11:30:44',
        state: TraceState.lost,
        lastClock: '10:58:12',
        path: engineFile,
      ),
      const TraceReport(
        attempt: 1,
        clock: '11:30:44',
        state: TraceState.lost,
        lastClock: '10:58:12',
      ),
      const TraceReport(
        attempt: 3,
        clock: '11:30:44',
        state: TraceState.ended,
        lastClock: '10:58:12',
        path: engineFile,
      ),
    ];

    test('reads the forms of the brief exactly', () {
      expect(
        traceDescription(every[2]),
        'a1 10:58:12 UTC, 3 running, longest 38m: $engineFile',
      );
      expect(
        traceDescription(every[1]),
        'a1 10:28:40 UTC, loading packages/appstein_cli/test/foo_test.dart',
      );
      expect(
        traceDescription(every[0]),
        'a1 10:51:02 UTC, starting packages/appstein_engine',
      );
      expect(traceDescription(every[4]), 'a1 11:02:13 UTC, finished');
      expect(traceDescription(every[5]), 'a1 11:02:13 UTC, unit tests failed');
      expect(
        traceDescription(every[6]),
        'a1 lost 11:30:44 UTC, last 10:58:12 UTC: $engineFile',
      );
      expect(
        traceDescription(every[7]),
        'a1 lost 11:30:44 UTC, last 10:58:12 UTC',
      );
    });

    for (final report in every) {
      test('round-trips ${report.state.name}', () {
        final entry = _parse(traceDescription(report))!;
        expect(entry.report, report);
        expect(entry.jobName, 'test (windows-latest)');
        expect(entry.runId, 39763006737);
        expect(entry.attempt, 2);
      });
    }

    test(
      'a long path keeps its file name and fits in 140 ASCII characters',
      () {
        final deep = [
          'packages',
          'appstein_engine',
          'test',
          for (var i = 0; i < 12; i++) 'folder_number_$i',
          'a_test_file_with_a_long_name_test.dart',
        ].join('/');
        final text = traceDescription(
          TraceReport(
            attempt: 12,
            clock: '23:59:59',
            state: TraceState.running,
            running: 123,
            longestMinutes: 359,
            path: deep,
          ),
        );
        expect(text.length, lessThanOrEqualTo(traceDescriptionLimit));
        expect(text, endsWith('/a_test_file_with_a_long_name_test.dart'));
        expect(text, contains('packages/.../'));
        expect(_parse(text)!.report.path, endsWith('_test.dart'));
      },
    );

    test('a file name longer than the limit keeps its end', () {
      final text = traceDescription(
        TraceReport(
          attempt: 1,
          clock: '00:00:00',
          state: TraceState.loading,
          path: 'test/${'x' * 200}_test.dart',
        ),
      );
      expect(text.length, traceDescriptionLimit);
      expect(text, endsWith('x_test.dart'));
    });

    test('the text is ASCII only', () {
      final text = traceDescription(
        const TraceReport(
          attempt: 1,
          clock: '00:00:00',
          state: TraceState.idle,
          path: 'test/caf\u00e9_\u{1F600}_test.dart',
        ),
      );
      expect(text.codeUnits.every((c) => c >= 32 && c < 127), isTrue);
      expect(text, 'a1 00:00:00 UTC, idle after test/caf?_??_test.dart');
    });

    test('the text holds only the report fields', () {
      // Every character of a description comes from a fixed word of a form,
      // a number, a clock or the path: the description of a report whose
      // path is empty is one of these exact shapes, with nothing else.
      final shapes = RegExp(
        r'^a\d+ (\d\d:\d\d:\d\d UTC, ((starting|loading|idle after) |'
        r'\d+ running, longest \d+m: |finished|unit tests failed)|'
        r'(lost|ended) \d\d:\d\d:\d\d UTC, last \d\d:\d\d:\d\d UTC(: )?)$',
      );
      for (final report in every) {
        final withoutPath = TraceReport(
          attempt: report.attempt,
          clock: report.clock,
          state: report.state,
          running: report.running,
          longestMinutes: report.longestMinutes,
          lastClock: report.lastClock,
          path: report.path == null ? null : '',
        );
        expect(traceDescription(withoutPath), matches(shapes));
      }
    });

    test('only final states are final', () {
      expect(
        [
          for (final s in TraceState.values)
            if (s.isFinal) s,
        ],
        [
          TraceState.finished,
          TraceState.failed,
          TraceState.lost,
          TraceState.ended,
        ],
      );
    });

    test('statuses that are not traces read as null', () {
      expect(
        parseTrace(
          context: 'ci/other',
          description: 'a1 11:02:13 UTC, finished',
          targetUrl: _url,
        ),
        isNull,
      );
      expect(
        parseTrace(
          context: traceContext('test (ubuntu-latest)'),
          description: 'a1 11:02:13 UTC, finished',
          targetUrl: 'https://github.com/o/r/actions/runs/1',
        ),
        isNull,
      );
      expect(_parse('a1 11:02:13 UTC, something else'), isNull);
    });

    test('the context, the attempt page and the clock', () {
      expect(
        traceContext('test (windows-latest)'),
        'CI trace / test (windows-latest)',
      );
      expect(
        attemptUrl('https://github.com', 'o/r', 5, 2),
        'https://github.com/o/r/actions/runs/5/attempts/2',
      );
      expect(traceClock(DateTime.utc(2026, 10, 22, 9, 5, 7)), '09:05:07');
    });
  });
}
