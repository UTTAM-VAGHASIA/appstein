import 'dart:io';

/// The summary line a terminal `appstein verify --fast` must end with on the
/// measured app: the fast checks find nothing there.
const fastSummary = '0 errors, 0 warnings, 0 info. No findings suppressed.';

/// The summary line of a terminal full `appstein verify` on the measured
/// app: no error, only warnings (each feature without a test, the page
/// edited by hand, the router's formatting), no info and nothing suppressed.
final fullSummary = RegExp(
  r'^0 errors, \d+ warnings?, 0 info\. No findings suppressed\.$',
);

/// The flag of a fast run.
const fastFlag = '--fast';

/// The flag of a full run.
const fullFlag = '--full';

/// The environment variable that moves the Dart analysis server's disk
/// cache (its "state location", `~/.dartServer` by default) to another
/// folder. The server reads it on every system; `appstein verify` and
/// `appstein mcp` pass their environment on to the guard, and the guard to
/// the server.
const analysisCacheVariable = 'ANALYZER_STATE_LOCATION_OVERRIDE';

/// What the analysis server's cache folder holds: its cache entries and its
/// half-written files.
typedef CacheCount = ({int entries, int halfWritten});

/// The files of the analysis server's cache folder [path] and the folders
/// under it, in two counts:
/// - **half-written:** the `-temp-` files (the name of the entry, `-temp-`
///   and a process ID) a server writes before it renames them into place.
///   A server that is killed while it writes one leaves it behind (a
///   terminal run kills its server: 3 to 16 such files a run on Windows,
///   2026-10-15). They are no cache, and counted as entries, the cache would
///   never stop growing;
/// - **entries:** every other file.
///
/// Both are 0 when the folder does not exist.
CacheCount countCache(String path) {
  final folder = Directory(path);
  if (!folder.existsSync()) return (entries: 0, halfWritten: 0);
  var entries = 0;
  var halfWritten = 0;
  for (final file in folder.listSync(recursive: true).whereType<File>()) {
    if (_halfWritten.hasMatch(file.path)) {
      halfWritten++;
    } else {
      entries++;
    }
  }
  return (entries: entries, halfWritten: halfWritten);
}

final _halfWritten = RegExp(r'-temp-\d+$');

/// Deletes the cold cache folder [path] after its run. On Windows a folder
/// can't be deleted while a process still holds a file in it (a server that
/// has not quite ended): then [warn] is told, and the folder is left for the
/// cleanup of the tool's work folder, so the run's own result, or its
/// error, is what the caller sees. [delete] deletes a folder; tests replace
/// it.
void discardCache(
  String path, {
  required void Function(String warning) warn,
  void Function(String path) delete = _deleteFolder,
}) {
  try {
    delete(path);
  } on FileSystemException catch (error) {
    warn(
      'warning: could not delete the cache folder $path now '
      '(${error.osError?.message ?? error.message}); it goes with the work '
      'folder',
    );
  }
}

void _deleteFolder(String path) => Directory(path).deleteSync(recursive: true);

/// The most untimed runs that warm the analysis server's disk cache before
/// the warm rows are timed ([measureTerminalRows]).
const terminalWarmUpMost = 15;

/// Why a terminal `appstein verify` run on the measured app does not count,
/// or null when it does. A run counts when
/// - it exited 0;
/// - it named no check as not run (`Not run:`) and printed no notice
///   (`Note:`): a run that skipped a check, or left a process behind, would
///   be cheaper or other than a real one, and still exits 0;
/// - its last line is the summary: [fastSummary] exactly for a [fast] run,
///   [fullSummary] for a full one;
/// - a full run also reported the page edited by hand: a `docs.stale`
///   warning in the group of `docs/app/routes.md`, which only a full run
///   checks. So it ran the full checks, not the fast ones.
String? terminalVerifyProblem(
  int exitCode,
  String stdout,
  String stderr, {
  required bool fast,
}) {
  final lines = stdout.trimRight().split(RegExp(r'\r?\n'));
  final summary = lines.last;
  final why = <String>[
    if (exitCode != 0) 'exit code $exitCode, expected 0',
    if (lines.contains('Not run:')) 'it named checks as not run',
    if (lines.contains('Note:')) 'it printed a notice',
    if (fast ? summary != fastSummary : !fullSummary.hasMatch(summary))
      'its last line is "$summary", expected '
          '${fast ? '"$fastSummary"' : 'the summary of warnings only'}',
    if (!fast && !_reportsStaleRoutes(lines))
      'it did not report docs.stale on docs/app/routes.md, which only a '
          'full run checks',
  ];
  return why.isEmpty ? null : '${why.join('; ')}:\n$stdout$stderr';
}

/// Whether the group of `docs/app/routes.md` in a run's [lines] (the file's
/// line, then its findings up to a blank line) holds a `docs.stale`
/// warning, wherever it is among them.
bool _reportsStaleRoutes(List<String> lines) {
  var inGroup = false;
  for (final line in lines) {
    if (line == 'docs/app/routes.md') {
      inGroup = true;
    } else if (line.trim().isEmpty) {
      inGroup = false;
    } else if (inGroup && line.startsWith('  warning docs.stale')) {
      return true;
    }
  }
  return false;
}

/// One terminal `appstein verify` run: its exit code, output and time.
typedef TerminalRun = ({
  int exitCode,
  String stdout,
  String stderr,
  Duration elapsed,
});

/// The flags of round [round] of timed runs, in the order they run: fast
/// first in even rounds, full first in odd ones, so neither row always
/// follows the other.
List<String> roundOrder(int round) =>
    round.isEven ? const [fastFlag, fullFlag] : const [fullFlag, fastFlag];

/// The terminal `verify` rows: three runs each, fast and full, on a cold and
/// on a warm analysis-server cache, and the warm-up between them.
final class TerminalRows {
  /// The times of the runs with a new, empty cache each, in the order they
  /// ran.
  final coldFast = <Duration>[];

  /// See [coldFast].
  final coldFull = <Duration>[];

  /// The times of the runs on the warm cache, in the order they ran.
  final warmFast = <Duration>[];

  /// See [warmFast].
  final warmFull = <Duration>[];

  /// The times of the untimed warm-up runs.
  final warmUp = <Duration>[];

  /// How many cache entries each warm-up run added to the cache folder.
  final warmUpAdded = <int>[];

  /// How many half-written files each warm-up run left in the cache folder.
  final warmUpHalfWritten = <int>[];

  /// Whether the warm-up stopped at its cap with the cache still growing.
  var capped = false;
}

/// Measures the terminal `verify` rows with [run], which runs `appstein
/// verify` with the flag it is given and the analysis server's cache in the
/// folder it is given. In order:
///
/// 1. **One full run first**, untimed, on [warmCache]. The app's files are
///    all unverified after its first sync, and its router is not formatted,
///    so a fast run before any full run reports `dart.unformatted`; a full
///    run checks every file and clears them, so every fast run after it has
///    no finding. It is a run on the warm cache, so it starts the warm-up
///    too.
/// 2. **Cold:** three rounds of a fast and a full run, each with a new,
///    empty cache folder from [newCache], which [discardCache] removes after
///    the run (the tool's `discardCache` warns, and never throws, when it
///    can't).
/// 3. **Warm-up:** full runs on [warmCache], at most [warmUpMost], until one
///    added no cache entry to it **and** left no new half-written file
///    ([cacheCount] before and after: `countCache` in the tool). A run whose
///    server was killed before it renamed any file into place adds no entry
///    but leaves half-written ones, and is no sign of a warm cache. A
///    warm-up that reaches the cap is [TerminalRows.capped].
/// 4. **Warm:** three rounds of a fast and a full run on [warmCache].
///
/// The rounds alternate their order ([roundOrder]). Every run is checked
/// ([terminalVerifyProblem]), and every cache folder a run used must hold
/// entries afterwards: an empty one means the cache variable did not reach
/// the analysis server, and the rows would measure another cache. Throws a
/// [StateError] that says why when either check fails.
Future<TerminalRows> measureTerminalRows({
  required Future<TerminalRun> Function(String flag, String cache) run,
  required String warmCache,
  required String Function() newCache,
  required void Function(String cache) discardCache,
  required CacheCount Function(String cache) cacheCount,
  int warmUpMost = terminalWarmUpMost,
}) async {
  final rows = TerminalRows();
  Future<TerminalRun> checked(String flag, String cache, String what) async {
    final result = await run(flag, cache);
    if (terminalVerifyProblem(
          result.exitCode,
          result.stdout,
          result.stderr,
          fast: flag == fastFlag,
        )
        case final problem?) {
      throw StateError('appstein verify $flag ($what): $problem');
    }
    if (cacheCount(cache).entries == 0) {
      throw StateError(
        'appstein verify $flag ($what) left no file in the analysis '
        "server's cache folder $cache: $analysisCacheVariable did not reach "
        'the server, so the rows would not measure the cache they name.',
      );
    }
    return result;
  }

  await checked(fullFlag, warmCache, 'the first run, which clears the files');
  for (var round = 0; round < 3; round++) {
    for (final flag in roundOrder(round)) {
      final cache = newCache();
      try {
        final result = await checked(flag, cache, 'a cold run');
        (flag == fastFlag ? rows.coldFast : rows.coldFull).add(result.elapsed);
      } finally {
        discardCache(cache);
      }
    }
  }
  rows.capped = true;
  for (var i = 0; i < warmUpMost; i++) {
    final before = cacheCount(warmCache);
    final result = await checked(fullFlag, warmCache, 'a warm-up run');
    final after = cacheCount(warmCache);
    final added = after.entries - before.entries;
    final halfWritten = after.halfWritten - before.halfWritten;
    rows.warmUp.add(result.elapsed);
    rows.warmUpAdded.add(added);
    rows.warmUpHalfWritten.add(halfWritten);
    if (added <= 0 && halfWritten <= 0) {
      rows.capped = false;
      break;
    }
  }
  for (var round = 0; round < 3; round++) {
    for (final flag in roundOrder(round)) {
      final result = await checked(flag, warmCache, 'a warm run');
      (flag == fastFlag ? rows.warmFast : rows.warmFull).add(result.elapsed);
    }
  }
  return rows;
}

/// One sampled terminal run: its exit code, output, and the most memory its
/// process tree held, null when the sampling never saw the guard and the
/// analysis server (`peakTreeMemory`).
typedef SampledRun = ({int exitCode, String stdout, String stderr, int? peak});

/// The most memory a terminal `appstein verify <flag>` run held, from
/// [sample], which runs it once with its memory sampled. Each run is checked
/// ([terminalVerifyProblem]). A run whose guard and server the sampling
/// never saw is run once more; when the second is not seen either, the
/// measurement fails, rather than print a row that measured only part of
/// the tree. Throws a [StateError] that says why.
Future<int> sampledPeak(
  Future<SampledRun> Function() sample, {
  required String flag,
}) async {
  for (var attempt = 1; attempt <= 2; attempt++) {
    final result = await sample();
    if (terminalVerifyProblem(
          result.exitCode,
          result.stdout,
          result.stderr,
          fast: flag == fastFlag,
        )
        case final problem?) {
      throw StateError('appstein verify $flag (a sampled run): $problem');
    }
    if (result.peak case final peak?) return peak;
  }
  throw StateError(
    'the sampling of appstein verify $flag never saw its guard and analysis '
    'server, in two runs: each run ended, or its server, before a look at '
    'the process list found them. Its memory was not measured.',
  );
}
