/// The run of CI's unit tests with their trace (ticket 15 of slice 1d.7):
/// the same `dart test` commands as before, in the same order, while the
/// trace is posted every 30 s. `tool/ci_unit_tests.dart` starts it.
library;

import 'dart:async';
import 'dart:io';

import 'github_api.dart';
import 'unit_test_trace.dart';

/// One `dart test` command of the step.
typedef UnitTestCommand = ({
  String folder,
  List<String> paths,
  String prefix,
  String label,
});

/// The step's commands, in CI's order: `dart test test` at the repo root,
/// then `dart test` in each of [packageFolders] (repo-relative, like
/// `packages/appstein_engine`), sorted by name.
List<UnitTestCommand> unitTestCommands(List<String> packageFolders) => [
  (folder: '.', paths: const ['test'], prefix: '', label: 'test'),
  for (final folder in [...packageFolders]..sort())
    (folder: folder, paths: const [], prefix: '$folder/', label: folder),
];

/// The package folders of [packages], repo-relative and sorted: each
/// folder that holds a `pubspec.yaml` and whose name does not start with a
/// dot. Shell glob `packages/*/` passes the same folders, since every folder
/// there is a package.
List<String> packageFolders(Directory packages) => [
  for (final entry in packages.listSync())
    if (entry is Directory &&
        !_name(entry).startsWith('.') &&
        File('${entry.path}${Platform.pathSeparator}pubspec.yaml').existsSync())
      'packages/${_name(entry)}',
]..sort();

String _name(Directory folder) =>
    folder.uri.pathSegments.where((s) => s.isNotEmpty).last;

/// How to start one `dart test` command: [dart] runs `test` with the JSON
/// reporter writing to [reportFile], in the command's folder. The child
/// gets [parentEnvironment] without the trace's token, and nothing else: with
/// the parent's environment included the token would come back.
({
  String executable,
  List<String> arguments,
  String workingDirectory,
  Map<String, String> environment,
  bool includeParentEnvironment,
})
dartTestStart({
  required String dart,
  required UnitTestCommand command,
  required String reportFile,
  required Map<String, String> parentEnvironment,
}) => (
  executable: dart,
  arguments: ['test', '--file-reporter', 'json:$reportFile', ...command.paths],
  workingDirectory: command.folder,
  environment: childEnvironment(parentEnvironment),
  includeParentEnvironment: false,
);

/// Starts one `dart test` command the way CI does ([dartTestStart]: no
/// token, no parent environment). With [mode] `inheritStdio`, as in CI,
/// its output is the step's output; with `normal` it is read and dropped
/// (for tests, so a child never blocks on a full pipe).
Future<StartedCommand> startDartTest({
  required String dart,
  required UnitTestCommand command,
  required String reportFile,
  required Map<String, String> parentEnvironment,
  ProcessStartMode mode = ProcessStartMode.inheritStdio,
}) async {
  final start = dartTestStart(
    dart: dart,
    command: command,
    reportFile: reportFile,
    parentEnvironment: parentEnvironment,
  );
  final process = await Process.start(
    start.executable,
    start.arguments,
    workingDirectory: start.workingDirectory,
    environment: start.environment,
    includeParentEnvironment: start.includeParentEnvironment,
    mode: mode,
  );
  if (mode == ProcessStartMode.normal) {
    process.stdout.drain<void>().ignore();
    process.stderr.drain<void>().ignore();
  }
  return _StartedProcess(process);
}

final class _StartedProcess implements StartedCommand {
  _StartedProcess(this._process);

  final Process _process;

  @override
  Future<int> get exitCode => _process.exitCode;
}

/// A started `dart test` command.
abstract interface class StartedCommand {
  /// Its exit code, once it has ended.
  Future<int> get exitCode;
}

/// Starts [command] with the JSON reporter writing to [reportFile].
typedef CommandStarter =
    Future<StartedCommand> Function(UnitTestCommand command, String reportFile);

/// The HTTP statuses after which posting the trace stops: the token may not
/// write statuses (a pull request from a fork), or the commit has reached
/// GitHub's limit of statuses per context. Trying again would not help. A
/// 403 that is GitHub's rate limit ([GitHubApiException.rateLimited]) is not
/// one of them: it passes.
const tracePermanentErrors = {401, 403, 404, 422};

/// Posts the trace's commit status. A post must never fail the tests or
/// hold them up. After one of [tracePermanentErrors] it prints one line and
/// stops posting. Any other error (no answer within [timeout], a server
/// error, a lost connection) is printed once for its kind, and the next
/// report is posted as usual, so one bad moment never leaves an old trace
/// behind.
final class TraceWriter {
  /// A writer that posts with [post] and prints its error lines to [out];
  /// a post that takes longer than [timeout] counts as an error.
  TraceWriter(
    this._post, {
    required this.out,
    this.timeout = const Duration(seconds: 10),
  });

  final Future<void> Function(String state, String description) _post;

  /// Where the error lines go.
  final StringSink out;

  /// How long one post may take.
  final Duration timeout;

  var _stopped = false;
  final _kindsSeen = <String>{};

  /// Posts [description] as [state] (`pending`, `success` or `failure`),
  /// unless posting has stopped. Never throws.
  Future<void> send(String state, String description) async {
    if (_stopped) return;
    try {
      await _post(state, description).timeout(timeout);
    } on TimeoutException {
      _failed(
        GitHubApiException(
          0,
          'GitHub gave no answer within ${_seconds(timeout)} s',
        ),
        kind: 'timeout',
      );
    } on GitHubApiException catch (error) {
      if (tracePermanentErrors.contains(error.statusCode) &&
          !error.rateLimited) {
        _stopped = true;
        out.writeln(traceWriteError(error));
      } else {
        _failed(error, kind: 'HTTP ${error.statusCode}');
      }
    } catch (error) {
      // Any error at all: a post must never fail the tests.
      _failed(error, kind: '${error.runtimeType}');
    }
  }

  void _failed(Object error, {required String kind}) {
    if (!_kindsSeen.add(kind)) return;
    final what = error is GitHubApiException
        ? '$error'
        : '${error.runtimeType}';
    out.writeln(
      'The trace could not be written this time: '
      '${what.endsWith('.') ? what : '$what.'} Posting goes on.',
    );
  }
}

String _seconds(Duration duration) {
  final ms = duration.inMilliseconds;
  return ms % 1000 == 0 ? '${ms ~/ 1000}' : '${ms / 1000}';
}

/// Runs [commands] one after another, stopping at the first that fails,
/// and returns 1 when one failed, else 0: what the step's shell script did.
/// Each command's JSON report goes to `<reportFolder>/<n>.json`; while it
/// runs, its new whole lines are read every [interval] and the report is
/// posted with [trace]. With no [trace] the tests just run, untraced.
Future<int> runUnitTests({
  required List<UnitTestCommand> commands,
  required CommandStarter start,
  required String reportFolder,
  required int attempt,
  required StringSink out,
  TraceWriter? trace,
  Duration interval = const Duration(seconds: 30),
  DateTime Function() now = DateTime.now,
}) async {
  if (trace == null) {
    out.writeln(
      'The trace is off (no $traceTokenVariable): the unit tests run '
      'untraced.',
    );
  }
  // One post at a time. A periodic tick while a post is under way is
  // skipped; a command's start post waits for it and then posts, and the
  // last word waits for every post before it, so a late `pending` never
  // follows it.
  Future<void>? posting;
  void progress(TraceReport report, {required bool skippable}) {
    if (trace == null || (skippable && posting != null)) return;
    late final Future<void> mine;
    mine = (posting ?? Future<void>.value())
        .then((_) => trace.send('pending', traceDescription(report)))
        .whenComplete(() {
          if (identical(posting, mine)) posting = null;
        });
    posting = mine;
  }

  Future<void> last(String state, TraceState end) async {
    if (trace == null) return;
    await posting;
    await trace.send(
      state,
      traceDescription(
        TraceReport(attempt: attempt, clock: traceClock(now()), state: end),
      ),
    );
  }

  for (final (index, command) in commands.indexed) {
    final reportFile = File(
      '$reportFolder${Platform.pathSeparator}${index + 1}.json',
    );
    final fold = TestRunFold(prefix: command.prefix, label: command.label);
    final lines = JsonLines();
    var offset = 0;
    final clock = Stopwatch()..start();
    void tick({required bool skippable}) {
      final bytes = readNewBytes(reportFile, offset);
      offset += bytes.length;
      lines.add(bytes).forEach(fold.addLine);
      progress(
        fold.report(
          attempt: attempt,
          now: now(),
          elapsedMs: clock.elapsedMilliseconds,
        ),
        skippable: skippable,
      );
    }

    final started = await start(command, reportFile.path);
    tick(skippable: false);
    final timer = Timer.periodic(interval, (_) => tick(skippable: true));
    final code = await started.exitCode;
    timer.cancel();
    if (code != 0) {
      await last('failure', TraceState.failed);
      return 1;
    }
  }
  await last('success', TraceState.finished);
  return 0;
}

/// The error line a failed post prints, from [error].
String traceWriteError(Object error) => error is GitHubApiException
    ? 'The trace could not be written: $error. The tests go on untraced.'
    : 'The trace could not be written: ${error.runtimeType}. The tests go on '
          'untraced.';

/// Reads the bytes [file] gained after [offset], or none when it does not
/// exist yet.
List<int> readNewBytes(File file, int offset) {
  if (!file.existsSync()) return const [];
  final handle = file.openSync();
  try {
    final length = handle.lengthSync();
    if (length <= offset) return const [];
    handle.setPositionSync(offset);
    return handle.readSync(length - offset);
  } finally {
    handle.closeSync();
  }
}
