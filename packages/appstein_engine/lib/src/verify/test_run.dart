import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../sdk/sdk_detector.dart';

/// One test that failed, or one test file that could not be loaded.
final class TestFailure {
  /// Creates the failure.
  const TestFailure({
    required this.file,
    this.line,
    this.test,
    required this.details,
  });

  /// The test file, from the project root, with `/` on every system.
  final String file;

  /// The 1-based line the test starts on in [file]; null for a file that
  /// could not be loaded, and where `flutter test` gives none.
  final int? line;

  /// The test's full name, with the names of its groups before it; null
  /// when [file] could not be loaded.
  final String? test;

  /// The first lines of the failure, on one line.
  final String details;
}

/// A test that was running, or a file that was being loaded, when a run
/// stopped.
typedef RunningTest = ({String file, String? test});

/// What one run of the project's tests gave.
///
/// Only [TestRun.finished] is a run whose [failures] are all of them. A run
/// that [timedOut], was [cutShort] or is [unexplained] never counts as one
/// in which every other test passed.
final class TestRun {
  /// A project with no test file: nothing was started.
  const TestRun.none() : this._(ran: false);

  /// A run that ended and said so, with the tests that failed.
  const TestRun.finished(List<TestFailure> failures)
    : this._(failures: failures);

  /// A run that was still going at its time limit and was stopped. [failures]
  /// are those it had told by then, and [running] what was open.
  const TestRun.timedOut({
    List<TestFailure> failures = const [],
    List<RunningTest> running = const [],
  }) : this._(timedOut: true, failures: failures, running: running);

  /// A run whose output ended, with [exitCode], without saying that the run
  /// was done, after it had started tests. [failures] are those it had told,
  /// and [running] what was open.
  const TestRun.cutShort({
    required List<TestFailure> failures,
    required List<RunningTest> running,
    required int exitCode,
  }) : this._(
         cutShort: true,
         failures: failures,
         running: running,
         exitCode: exitCode,
       );

  /// A run that ended with [exitCode] and named no failing test, and did not
  /// pass: for example a tool error before any test was loaded. [said] is
  /// Flutter's last words.
  const TestRun.unexplained({required int exitCode, required String said})
    : this._(unexplained: true, exitCode: exitCode, said: said);

  const TestRun._({
    this.ran = true,
    this.timedOut = false,
    this.cutShort = false,
    this.unexplained = false,
    this.failures = const [],
    this.running = const [],
    this.exitCode,
    this.said = '',
  });

  /// Whether `flutter test` was started.
  final bool ran;

  /// Whether the run was stopped at its time limit.
  final bool timedOut;

  /// Whether the output ended without the end of the run after tests had
  /// started.
  final bool cutShort;

  /// Whether the run ended with a failing exit code (or without the end of
  /// the run, with no test started) and named no failing test.
  final bool unexplained;

  /// The failing tests and the files that could not be loaded, in the order
  /// `flutter test` started them.
  final List<TestFailure> failures;

  /// For a run that [timedOut] or was [cutShort]: what was open when it
  /// stopped, in the order it was started. Several are open when suites run
  /// at the same time.
  final List<RunningTest> running;

  /// The exit code of a run that was [cutShort] or [unexplained].
  final int? exitCode;

  /// For an [unexplained] run: the last lines `flutter test` printed that
  /// say something, on one line.
  final String said;
}

/// The project's tests could not be run at all: there is no Flutter SDK to
/// run them with, or `flutter test` could not be started. That is Appstein
/// failing (exit `3`, spec §9.5), never a finding and never "no test
/// failed". A run that started and did not give a result is a [TestRun].
final class TestRunException implements Exception {
  /// Creates the error. [reason] completes "The project's tests could not
  /// be run: " and ends without a full stop.
  const TestRunException(this.reason);

  /// Why they could not be run.
  final String reason;

  @override
  String toString() => 'The project\'s tests could not be run: $reason.';
}

/// What a full `verify` passes to `flutter`:
/// - `--machine` makes it print one JSON event per line;
/// - `--no-pub` keeps it from fetching packages, which could rewrite
///   `pubspec.lock`: the knowledge refresh fetched them before.
const flutterTestCommand = ['test', '--machine', '--no-pub'];

/// Runs the tests of the project at [projectRoot] once, with `flutter test`
/// of the Flutter SDK the project uses, found as every other part of
/// Appstein finds it, and reads the events it prints (slice 1d.2).
///
/// - A project with no file under `test/` that ends in `_test.dart` has
///   nothing to run: `flutter test` is not started ([TestRun.none]).
/// - A run still going after [timeout] is stopped by [runner], with every
///   process it started ([TestRun.timedOut]). What it had printed by then is
///   kept: the failures it told, and the tests that were open.
/// - A run whose output ends without the end of the run, after tests
///   started, is [TestRun.cutShort], with the same.
/// - A run that ends with a failing exit code and names no failing test is
///   [TestRun.unexplained], with Flutter's last words.
/// - `flutter test` runs in [projectRoot]. It writes what a test run always
///   writes (`build/`, and `test/failures/` after a failed golden test), and
///   no file a project commits.
///
/// Throws a [TestRunException] when the project has no usable Flutter SDK,
/// and when `flutter test` can't be started.
Future<TestRun> runProjectTests({
  required String projectRoot,
  required HostEnvironment environment,
  required ProcessRunner runner,
  required Duration timeout,
}) async {
  if (!_hasTestFiles(projectRoot)) return const TestRun.none();
  final detection = SdkDetector(environment).detect(projectRoot: projectRoot);
  final location = detection.location;
  if (detection.info == null || location == null) {
    final problem = detection.problem ?? 'no Flutter SDK was found';
    throw TestRunException(
      'the project has no usable Flutter SDK (${_plain(problem)})',
    );
  }
  final flutter = p.join(
    location.root,
    'bin',
    environment.os == HostOs.windows ? 'flutter.bat' : 'flutter',
  );
  final result = await runner.run(
    flutter,
    flutterTestCommand,
    timeout: timeout,
    workingDirectory: projectRoot,
  );
  if (!result.started) {
    throw TestRunException(
      '`flutter test` could not be started with $flutter '
      '(${_plain(result.stderr)})',
    );
  }
  final output = _readEvents(
    result.stdout,
    projectRoot,
    stopped: result.timedOut,
  );
  // What it had printed when it was stopped is kept: a run that did not
  // finish is never told as one in which no other test failed.
  if (result.timedOut) {
    return TestRun.timedOut(failures: output.failures, running: output.running);
  }
  if (!output.done && output.started) {
    return TestRun.cutShort(
      failures: output.failures,
      running: output.running,
      exitCode: result.exitCode,
    );
  }
  if (output.failures.isEmpty && !(output.passed && result.exitCode == 0)) {
    // For example a tool error before any test was loaded. Its words are
    // on stderr, or on stdout among the events.
    final said = result.stderr.trim().isEmpty ? result.stdout : result.stderr;
    return TestRun.unexplained(
      exitCode: result.exitCode,
      said: _lastLines(said, 5),
    );
  }
  return TestRun.finished(output.failures);
}

/// Whether the project has a file `flutter test` would run: one under
/// `test/` whose name ends in `_test.dart`, which is Flutter's own rule.
bool _hasTestFiles(String projectRoot) {
  final folder = Directory(p.join(projectRoot, 'test'));
  try {
    for (final entity in folder.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('_test.dart')) return true;
    }
  } on FileSystemException {
    // No folder, or one that can't be listed: `flutter test` finds nothing
    // there either.
  }
  return false;
}

/// The failing tests among the events in [output], which is what
/// `flutter test --machine` printed: one JSON object per line (the JSON
/// reporter of `package:test`), between lines that are something else; a
/// last line cut short is passed over.
///
/// `done` is whether the end of the run was told, `started` whether any test
/// was, and `running` the tests started and not yet done.
///
/// `package:test` tells a test as done with `error`, and no error event
/// before it, in two cases: its test process ended while it ran (a crash, or
/// a test that calls `exit`), and it was still running when the run was
/// [stopped] by a signal `flutter test` handles (SIGTERM, on Linux and
/// macOS). The lines can't be told apart. In a [stopped] run, the last
/// events printed are the stop's block, however long before the stop they
/// were printed: every `testDone` with `error` (with or without an error
/// before it), `testDone` of hidden tests, the start and end of setUpAll
/// and tearDownAll tests (test_core runs a tearDownAll after the stop),
/// `print` events, and the end of the run. A test the block tells as done
/// with `error` is among `running`, and is a failure only if it told an
/// error; a setUpAll or tearDownAll in it is never among `running`. Every
/// other `testDone` with `error` and no error before it is a failure whose
/// process ended.
({
  List<TestFailure> failures,
  bool passed,
  bool done,
  bool started,
  List<RunningTest> running,
})
_readEvents(String output, String projectRoot, {required bool stopped}) {
  final events = <Map<String, Object?>>[];
  for (final line in const LineSplitter().convert(output)) {
    if (!line.startsWith('{')) continue;
    final Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (event is Map<String, Object?>) events.add(event);
  }
  // The setUpAll and tearDownAll tests, which `package:test` hides.
  final hidden = <int>{
    for (final event in events)
      if (event case {
        'type': 'testStart',
        'test': {'id': final int id, 'name': final String name},
      } when name.endsWith('(setUpAll)') || name.endsWith('(tearDownAll)'))
        id,
  };
  // Where what the stop printed starts: nothing, unless the run was stopped.
  var stop = events.length;
  while (stopped &&
      stop > 0 &&
      switch (events[stop - 1]) {
        {'type': 'testDone', 'result': 'error'} ||
        {'type': 'testDone', 'hidden': true} ||
        {'type': 'done'} ||
        {'type': 'print'} => true,
        // test_core runs a group's tearDownAll even after it has closed
        // the tests; a file has one when its author wrote one, or when
        // flutter_test's leak tracking is turned on.
        {'type': 'testStart', 'test': {'id': final int id}} ||
        {'type': 'testDone', 'testID': final int id} => hidden.contains(id),
        _ => false,
      }) {
    stop--;
  }

  final suites = <int, String>{};
  // In the order the tests were started.
  final tests = <int, Map<String, Object?>>{};
  // Started and not done, in the order they were started.
  final open = <int>{};
  var done = false;
  final errors = <int, String>{};
  final framework = <int, String>{};
  final failed = <int>{};
  // Done with `error` and no error: their test process ended.
  final ended = <int>{};
  var passed = false;
  for (final (index, event) in events.indexed) {
    switch (event) {
      case {
        'type': 'suite',
        'suite': {'id': final int id, 'path': final String path},
      }:
        suites[id] = path;
      case {
        'type': 'testStart',
        'test': final Map<String, Object?> test && {'id': final int id},
      }:
        tests[id] = test;
        open.add(id);
      case {
        'type': 'error',
        'testID': final int id,
        'error': final String error,
      }:
        // The first error is the failure; a later one follows from it.
        errors.putIfAbsent(id, () => error);
        failed.add(id);
      case {
            'type': 'print',
            'testID': final int id,
            'message': final String message,
          }
          when message.contains(_exceptionSign) && !errors.containsKey(id):
        // The first block the test printed before its error.
        framework.putIfAbsent(id, () => message);
      case {'type': 'testDone', 'testID': final int id, 'result': 'error'}
          when index >= stop && !hidden.contains(id):
        // Closed by the stop while it was running: it stays open. A test
        // that had told an error is a failure too.
        break;
      case {'type': 'testDone', 'testID': final int id} when index >= stop:
        // A setUpAll or tearDownAll the stop ran or closed, or a test it
        // told as hidden: done, and a failure only if it told an error.
        open.remove(id);
      case {'type': 'testDone', 'testID': final int id, 'result': 'error'}
          when !errors.containsKey(id):
        open.remove(id);
        failed.add(id);
        ended.add(id);
      case {
        'type': 'testDone',
        'testID': final int id,
        'result': final String result,
      }:
        open.remove(id);
        if (result != 'success') failed.add(id);
      case {'type': 'done', 'success': final bool success}:
        done = true;
        passed = success;
    }
  }

  final root = p.normalize(p.absolute(projectRoot));
  final failures = <TestFailure>[];
  final running = <RunningTest>[];
  for (final MapEntry(key: id, value: test) in tests.entries) {
    final suite = suites[test['suiteID']];
    final name = '${test['name']}';
    // `flutter test` loads each file as a test of its own, with this name.
    final loading = suite != null && name == 'loading $suite';
    if (open.contains(id)) {
      running.add((
        file: suite == null ? 'test' : _fromRoot(suite, root),
        test: loading ? null : name,
      ));
    }
    if (!failed.contains(id)) continue;
    var details =
        errors[id] ?? (ended.contains(id) ? _endedDetails : 'It did not pass.');
    if (details.startsWith(_seeAbove)) details = framework[id] ?? details;
    failures.add(
      TestFailure(
        file: suite == null ? 'test' : _fromRoot(suite, root),
        line: loading || suite == null ? null : _line(test, suite),
        test: loading ? null : name,
        details: _firstLines(details, root),
      ),
    );
  }
  return (
    failures: failures,
    passed: passed,
    done: done,
    started: tests.isNotEmpty,
    running: running,
  );
}

/// The start of the banner of what Flutter prints above the failure of a
/// widget test, whose error event then only says [_seeAbove]. The rest of the
/// banner names the library that caught the exception: `FLUTTER TEST
/// FRAMEWORK` for a failed expectation, `RENDERING LIBRARY` for a RenderFlex
/// overflow, and others.
const _exceptionSign = 'EXCEPTION CAUGHT BY ';
const _seeAbove = 'Test failed. See exception logs above.';

/// The details of a test whose test process ended before it finished.
const _endedDetails =
    'Its test process ended before the test finished (a crash or `exit`).';

/// [path] from the project at [root], with `/`; [path] itself when it is
/// outside.
String _fromRoot(String path, String root) {
  final absolute = p.normalize(p.absolute(root, path));
  return p.isWithin(root, absolute)
      ? p.split(p.relative(absolute, from: root)).join('/')
      : path;
}

/// The line of [test] in the file [suite]: where the test is, or for a test
/// a function of another file declares (as `testWidgets` does), where that
/// function is called. Null when `flutter test` names neither in [suite].
int? _line(Map<String, Object?> test, String suite) {
  for (final (url, line) in [
    (test['root_url'], test['root_line']),
    (test['url'], test['line']),
  ]) {
    if (url is! String || line is! int) continue;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('file')) continue;
    try {
      if (p.equals(uri.toFilePath(), p.normalize(suite))) return line;
    } on UnsupportedError {
      // A file URI this system can't read as a path.
    }
  }
  return null;
}

/// The first paragraph of [text] on one line, without the lines that only
/// draw (rules, and the `^^^` under a compile error) and without the
/// project's own path, which the finding's file already gives.
String _firstLines(String text, String root) {
  final lines = <String>[];
  for (final raw in const LineSplitter().convert(text)) {
    var line = raw.trim();
    if (line.isEmpty) {
      if (lines.isEmpty) continue;
      break;
    }
    // The path is the finding's file. For a compile error the reason is on
    // the lines after; for an exception while loading it follows the colon.
    final load = _failedToLoad.firstMatch(line);
    if (load != null) line = load.group(1)!;
    if (line.isEmpty || line.contains(_exceptionSign)) continue;
    if (_rule.hasMatch(line)) continue;
    lines.add(line);
    if (lines.length == _maxLines) break;
  }
  final slashed = root.replaceAll(r'\', '/');
  var joined = lines
      .join(' ')
      .replaceAll('${Uri.file(root)}/', '')
      .replaceAll('$slashed/', '');
  if (joined.length > _maxLength) {
    joined = '${joined.substring(0, _maxLength)}…';
  }
  return joined.isEmpty ? 'It did not pass.' : joined;
}

/// A line that only draws: a rule, the `^^^` under a compile error, or the
/// full stop the loader ends its message with.
final _rule = RegExp(r'^[\^.═=~_-]+$');

/// The first line of a load failure: `Failed to load "<path>":`, with the
/// reason after it when it is an exception the file threw.
final _failedToLoad = RegExp(r'^Failed to load ".*?":\s*(.*)$');

const _maxLines = 8;
const _maxLength = 600;

/// The last [count] lines of [text] that say something, on one line,
/// without a closing full stop.
String _lastLines(String text, int count) {
  final lines = [
    for (final line in const LineSplitter().convert(text))
      // Events, and the `[{"event":"test.startedProcess",…}]` line Flutter
      // prints for each test process, are not words.
      if (line.trim().isNotEmpty &&
          !line.startsWith('{') &&
          !line.startsWith('[{'))
        line.trim(),
  ];
  return _plain(
    lines.skip(lines.length > count ? lines.length - count : 0).join(' '),
  );
}

/// [text] as part of a reason: one line, without a closing full stop.
String _plain(String text) => text
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceFirst(RegExp(r'\.$'), '');
