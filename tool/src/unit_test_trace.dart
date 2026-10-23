/// The trace of CI's unit tests (ticket 15 of slice 1d.7): the text of the
/// `CI trace / <job>` commit status, and how the JSON events of
/// `dart test --file-reporter json:<file>` fold into it. Pure: no `dart:io`.
///
/// The status lives on GitHub, not on the runner, so its last text survives
/// a runner that is lost: it says when the runner was last alive and which
/// test file had run longest without finishing.
library;

import 'dart:convert';

/// The environment variable that carries the token the trace is written
/// with. The tests never see it: [childEnvironment] removes it.
const traceTokenVariable = 'APPSTEIN_TRACE_TOKEN';

/// [environment] without [traceTokenVariable], in any letter case (Windows
/// treats variable names without case), for the `dart test` processes.
/// They must be started with this whole map and without their parent's
/// environment, or the token comes back with it.
Map<String, String> childEnvironment(Map<String, String> environment) => {
  for (final MapEntry(:key, :value) in environment.entries)
    if (key.toUpperCase() != traceTokenVariable) key: value,
};

/// The repo-relative path of a test file that `dart test`, run in the
/// folder [prefix] names (`''` for the repo root, `packages/x/` for a
/// package), reports as [path]: with [prefix] in front and forward slashes.
String repoPath(String prefix, String path) =>
    '$prefix${path.replaceAll(r'\', '/')}';

/// Splits bytes read from a growing file into whole lines: a line is
/// returned only once its line feed has arrived, so a half-written last
/// line waits for the next read.
final class JsonLines {
  final _carry = <int>[];

  /// The whole lines that [bytes], read after the bytes before, complete.
  List<String> add(List<int> bytes) {
    _carry.addAll(bytes);
    final end = _carry.lastIndexOf(0x0A);
    if (end < 0) return const [];
    final text = utf8.decode(_carry.sublist(0, end), allowMalformed: true);
    _carry.removeRange(0, end + 1);
    return [
      for (final line in text.split('\n'))
        line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
    ];
  }
}

/// The state of one `dart test` command, folded from the events of its
/// JSON file reporter, and the trace report it gives.
final class TestRunFold {
  /// A fold for a command run in the folder [prefix] names (`''` for the
  /// repo root, `packages/x/` for a package); [label] is the folder the
  /// trace names before any test starts.
  TestRunFold({required this.prefix, required this.label});

  /// What goes in front of the paths the reporter gives.
  final String prefix;

  /// The folder the trace names before any test starts.
  final String label;

  /// Folds one line of the JSON reporter in. A line that is not an event
  /// this fold reads is ignored.
  void addLine(String line) {
    final Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (event is! Map<String, Object?>) return;
    final time = event['time'];
    switch (event['type']) {
      case 'suite':
        final suite = event['suite'];
        if (suite is Map<String, Object?> &&
            suite['id'] is int &&
            suite['path'] is String) {
          _suites[suite['id']! as int] = repoPath(
            prefix,
            suite['path']! as String,
          );
        }
      case 'testStart':
        final test = event['test'];
        if (test is! Map<String, Object?> || test['id'] is! int) return;
        final path = _suites[test['suiteID']];
        if (path == null || time is! int) return;
        final name = test['name'];
        _running[test['id']! as int] = (
          path: path,
          start: time,
          loading: name is String && name.startsWith('loading '),
        );
        _started = true;
      case 'testDone':
        final done = _running.remove(event['testID']);
        if (done != null) _lastDone = done.path;
    }
  }

  final _suites = <int, String>{};
  final _running = <int, ({String path, int start, bool loading})>{};
  var _started = false;
  String? _lastDone;

  /// The report for attempt [attempt] at [now], when the command has run
  /// for [elapsedMs] (the reporter's `time` counts from about then).
  TraceReport report({
    required int attempt,
    required DateTime now,
    required int elapsedMs,
  }) {
    final clock = traceClock(now);
    if (_running.isEmpty) {
      return _started && _lastDone != null
          ? TraceReport(
              attempt: attempt,
              clock: clock,
              state: TraceState.idle,
              path: _lastDone,
            )
          : TraceReport(
              attempt: attempt,
              clock: clock,
              state: TraceState.starting,
              path: label,
            );
    }
    final longest = _running.values.reduce((a, b) => b.start < a.start ? b : a);
    if (longest.loading) {
      return TraceReport(
        attempt: attempt,
        clock: clock,
        state: TraceState.loading,
        path: longest.path,
      );
    }
    final ms = elapsedMs - longest.start;
    return TraceReport(
      attempt: attempt,
      clock: clock,
      state: TraceState.running,
      running: _running.length,
      longestMinutes: ms < 0 ? 0 : ms ~/ 60000,
      path: longest.path,
    );
  }
}

/// The most characters a commit status's description holds in practice.
const traceDescriptionLimit = 140;

/// The commit status context of [jobName]'s trace, for example
/// `CI trace / test (windows-latest)`.
String traceContext(String jobName) => '$_contextPrefix$jobName';

const _contextPrefix = 'CI trace / ';

/// The page of one attempt of a run, the `target_url` of its trace. It is
/// how a reader tells runs and attempts apart on one commit.
String attemptUrl(String serverUrl, String repo, int runId, int attempt) =>
    '$serverUrl/$repo/actions/runs/$runId/attempts/$attempt';

/// The time of day of [time] in UTC, as `HH:MM:SS`.
String traceClock(DateTime time) {
  final utc = time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}';
}

/// What one report of the trace says.
enum TraceState {
  /// A `dart test` command started and no test has started yet:
  /// [TraceReport.path] is the folder it runs in.
  starting,

  /// The test that has run longest is the hidden one that loads a file:
  /// [TraceReport.path] is that file.
  loading,

  /// Tests are running: [TraceReport.running] of them, the longest for
  /// [TraceReport.longestMinutes], in [TraceReport.path].
  running,

  /// No test is running between two: [TraceReport.path] is the file of the
  /// last test that finished.
  idle,

  /// Every command passed. Final.
  finished,

  /// A command failed. Final.
  failed,

  /// `lost-jobs` found the job lost: [TraceReport.clock] is when it ended,
  /// [TraceReport.lastClock] the trace's last report. Final.
  lost,

  /// `lost-jobs` found the job ended some other way while its trace still
  /// said it was running. Final.
  ended;

  /// Whether a report in this state is the trace's last word.
  bool get isFinal => index >= finished.index;

  /// Whether `lost-jobs` wrote it to close a trace: [lost] or [ended].
  bool get isClosing => this == lost || this == ended;
}

/// One report of the trace: what its description says.
final class TraceReport {
  /// A report with its fields; which ones are set depends on [state].
  const TraceReport({
    required this.attempt,
    required this.clock,
    required this.state,
    this.running,
    this.longestMinutes,
    this.path,
    this.lastClock,
  });

  /// The run's attempt the report belongs to.
  final int attempt;

  /// When the report was made (`HH:MM:SS`, UTC). For [TraceState.lost] and
  /// [TraceState.ended], when the job ended.
  final String clock;

  /// What the report says.
  final TraceState state;

  /// How many tests were running, for [TraceState.running].
  final int? running;

  /// For how many whole minutes the longest of them had run, for
  /// [TraceState.running].
  final int? longestMinutes;

  /// A repo-relative path with forward slashes: the file or folder the
  /// [state] names. Its middle folders may be shortened to `...`.
  final String? path;

  /// The clock of the trace's last report before the job ended, for
  /// [TraceState.lost] and [TraceState.ended].
  final String? lastClock;

  @override
  bool operator ==(Object other) =>
      other is TraceReport &&
      other.attempt == attempt &&
      other.clock == clock &&
      other.state == state &&
      other.running == running &&
      other.longestMinutes == longestMinutes &&
      other.path == path &&
      other.lastClock == lastClock;

  @override
  int get hashCode => Object.hash(
    attempt,
    clock,
    state,
    running,
    longestMinutes,
    path,
    lastClock,
  );

  @override
  String toString() => 'TraceReport(${traceDescription(this)})';
}

/// The description of [report]: ASCII only, at most
/// [traceDescriptionLimit] characters, and nothing but the report's fields:
///
/// ```text
/// a1 10:51:02 UTC, starting packages/appstein_engine
/// a1 10:28:40 UTC, loading packages/appstein_cli/test/foo_test.dart
/// a1 10:58:12 UTC, 3 running, longest 38m: packages/a/test/b_test.dart
/// a1 10:59:00 UTC, idle after packages/a/test/b_test.dart
/// a1 11:02:13 UTC, finished
/// a1 11:02:13 UTC, unit tests failed
/// a1 lost 11:30:44 UTC, last 10:58:12 UTC: packages/a/test/b_test.dart
/// a1 ended 11:30:44 UTC, last 10:58:12 UTC: packages/a/test/b_test.dart
/// ```
///
/// A path that doesn't fit has its middle folders shortened to `...`; the
/// file name is kept. With [withAttempt] false the leading `a1 ` is left
/// out, for quoting a report inside a sentence about that attempt.
String traceDescription(TraceReport report, {bool withAttempt = true}) {
  final a = withAttempt ? 'a${report.attempt} ' : '';
  final at = '$a${report.clock} UTC, ';
  final (head, withPath) = switch (report.state) {
    TraceState.starting => ('${at}starting ', true),
    TraceState.loading => ('${at}loading ', true),
    TraceState.running => (
      '$at${report.running ?? 0} running, '
          'longest ${report.longestMinutes ?? 0}m: ',
      true,
    ),
    TraceState.idle => ('${at}idle after ', true),
    TraceState.finished => ('${at}finished', false),
    TraceState.failed => ('${at}unit tests failed', false),
    TraceState.lost || TraceState.ended => (
      '$a${report.state.name} ${report.clock} UTC, '
          'last ${report.lastClock} UTC',
      report.path != null,
    ),
  };
  if (!withPath) return _ascii(head);
  final separator = report.state.isClosing ? ': ' : '';
  final start = _ascii('$head$separator');
  return '$start${shortenPath(_ascii(report.path ?? ''), traceDescriptionLimit - start.length)}';
}

String _ascii(String text) => String.fromCharCodes([
  for (final unit in text.codeUnits) unit >= 32 && unit < 127 ? unit : 0x3F,
]);

/// [path] in at most [limit] characters: whole when it fits, otherwise its
/// first folder, `...` and as many of its last parts as fit, and as a last
/// resort `...` and the end of its file name.
String shortenPath(String path, int limit) {
  if (path.length <= limit) return path;
  final parts = path.split('/');
  final file = parts.last;
  if (parts.length > 2) {
    var tail = file;
    for (var i = parts.length - 2; i > 0; i--) {
      final longer = '${parts[i]}/$tail';
      if ('${parts.first}/.../$longer'.length > limit) break;
      tail = longer;
    }
    final shortened = '${parts.first}/.../$tail';
    if (shortened.length <= limit) return shortened;
  }
  final bare = '.../$file';
  if (bare.length <= limit) return bare;
  return '...${file.substring(file.length - (limit - 3))}';
}

/// One trace report as GitHub keeps it: a commit status of a
/// `CI trace / <job>` context.
final class TraceEntry {
  /// An entry with its fields.
  const TraceEntry({
    required this.jobName,
    required this.runId,
    required this.attempt,
    required this.report,
    this.createdAt,
  });

  /// The job the trace belongs to, from the status's context.
  final String jobName;

  /// The run, from the status's `target_url`.
  final int runId;

  /// The run's attempt, from the status's `target_url`.
  final int attempt;

  /// What the description says.
  final TraceReport report;

  /// When GitHub received the status: when the runner was last alive.
  final DateTime? createdAt;
}

final _attemptUrl = RegExp(r'/actions/runs/(\d+)/attempts/(\d+)$');
final _timed = RegExp(
  r'^a(\d+) (\d\d:\d\d:\d\d) UTC, (?:'
  r'starting (?<starting>.+)|'
  r'loading (?<loading>.+)|'
  r'(?<running>\d+) running, longest (?<minutes>\d+)m: (?<runPath>.+)|'
  r'idle after (?<idle>.+)|'
  r'(?<finished>finished)|'
  r'(?<failed>unit tests failed))$',
);
final _closed = RegExp(
  r'^a(\d+) (lost|ended) (\d\d:\d\d:\d\d) UTC, last (\d\d:\d\d:\d\d) UTC'
  r'(?:: (.+))?$',
);

/// Reads one commit status as a trace report, or returns null when it is
/// not one: its [context] is not `CI trace / …`, its [targetUrl] names no
/// run attempt, or its [description] is in none of [traceDescription]'s
/// forms. [createdAt] is the status's `created_at`.
TraceEntry? parseTrace({
  required String context,
  required String description,
  required String targetUrl,
  DateTime? createdAt,
}) {
  if (!context.startsWith(_contextPrefix)) return null;
  final url = _attemptUrl.firstMatch(targetUrl);
  if (url == null) return null;
  final report = _parseReport(description);
  if (report == null) return null;
  return TraceEntry(
    jobName: context.substring(_contextPrefix.length),
    runId: int.parse(url[1]!),
    attempt: int.parse(url[2]!),
    report: report,
    createdAt: createdAt,
  );
}

TraceReport? _parseReport(String description) {
  final closed = _closed.firstMatch(description);
  if (closed != null) {
    return TraceReport(
      attempt: int.parse(closed[1]!),
      clock: closed[3]!,
      state: closed[2] == 'lost' ? TraceState.lost : TraceState.ended,
      lastClock: closed[4],
      path: closed[5],
    );
  }
  final m = _timed.firstMatch(description);
  if (m == null) return null;
  final attempt = int.parse(m[1]!);
  final clock = m[2]!;
  TraceReport make(TraceState state, {String? path, int? n, int? min}) =>
      TraceReport(
        attempt: attempt,
        clock: clock,
        state: state,
        path: path,
        running: n,
        longestMinutes: min,
      );
  if (m.namedGroup('starting') case final path?) {
    return make(TraceState.starting, path: path);
  }
  if (m.namedGroup('loading') case final path?) {
    return make(TraceState.loading, path: path);
  }
  if (m.namedGroup('running') case final n?) {
    return make(
      TraceState.running,
      path: m.namedGroup('runPath'),
      n: int.parse(n),
      min: int.parse(m.namedGroup('minutes')!),
    );
  }
  if (m.namedGroup('idle') case final path?) {
    return make(TraceState.idle, path: path);
  }
  if (m.namedGroup('finished') != null) return make(TraceState.finished);
  return make(TraceState.failed);
}
