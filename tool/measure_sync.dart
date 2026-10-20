import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart' show readDartFileHashes;
// The analysis server's look at the disk is measured on its own, and the
// engine keeps it out of its public API.
// ignore: implementation_imports
import 'package:appstein_engine/src/analysis/disk_look.dart'
    show DiskLook, unchangingFolders;
import 'package:path/path.dart' as p;

import 'src/analysis_hosts.dart';
import 'src/held_detect.dart';
import 'src/hook_measurement.dart';
import 'src/hook_process.dart';
import 'src/hook_rows.dart';
import 'src/large_build.dart';
import 'src/mcp_session.dart';
import 'src/measure_context.dart';
import 'src/process_memory.dart';
import 'src/terminal_verify.dart';
import 'src/warm_measurement.dart';
import 'src/warm_verify.dart';

/// Measures `appstein sync` against spec §15, on generated official_mvvm apps
/// with a new app's `android/` and `ios/` files:
/// - a full sync of a 200-file app, with fresh packages and no analyzer
///   cache: under 30 s;
/// - `sync --detect` on that app when nothing changed, after one edit of a
///   view model, and after one edit of the router: each under 2 s, as the
///   median of three runs (three different edits), because a CI machine's
///   speed varies by about 2x from run to run. The table shows the three
///   times beside the median. A row whose median is 2 s or more is measured
///   once more, on every system: three fresh runs (three new edits for the
///   edit rows, each with a change to rebuild, under the same correctness
///   checks), and it misses only when the second median is also 2 s or more
///   (owner, 2026-10-16: a slow CI runner made one median miss that the
///   rerun passed). The table then shows both attempts, the second marked as
///   the one that counted, and a miss names both medians. The second table
///   keeps the first attempt's median run. The 1,000-file rows are never held
///   and never measured again (`measureHeldDetect`);
/// - each MCP tool's answer on that app, from fresh knowledge, in one
///   `appstein mcp` process: under 1 s, as the median of three;
/// - `appstein docs` on that app, from fresh knowledge: writing every page,
///   then with nothing to write, and `docs --check`, each under 2 s (the
///   last two as the median of three). It also checks what the real command
///   does: the pages are written, a second run changes nothing, and
///   `--check` after a hand edit exits 1, names the page and writes nothing;
/// - the `verify` tool of a running `appstein mcp` on that app, the way an
///   agent meets it (spec §9.1, §15): the project's analysis host is started
///   and warmed by a first call, then one file is edited to add a real error
///   and `verify` with the fast scope is called, three times. The median must
///   be under 5 s (spec §15: "< 5 s"; exactly 5 s fails), and every reply
///   must report the error, or the run fails whatever the time. The limit is
///   not changed to fit a result: a miss is printed with the measured time,
///   for the owner. Also printed: the first call (the host and its analysis
///   server starting), the memory of the process tree (`appstein mcp`, the
///   host, its guard and the server), and where the time of a call went. The
///   host outlives the session, so the tool ends it afterwards;
/// - the terminal `appstein verify --fast` and `appstein verify` on that app,
///   which start their own analysis server (no host runs, and a terminal run
///   never starts one), with the server's disk cache in
///   a folder of this tool (`measureTerminalRows`): three times each on a
///   cold cache (a new, empty folder each run) and three times each on a
///   warm one (after full runs until one adds no cache entry, at most 15,
///   printed), fast and full in alternating order, printed side by side with
///   the most memory a run held. The full run has no limit; the fast run is
///   capped by `verify.fast_timeout_seconds`, which the app keeps at its
///   default of 20 s, as a user's runs are: a fast run cut by the cap exits 3
///   and fails the row, with its time printed and the cap named
///   (`terminalCutProblem`); the cap is not raised to fit. It also checks
///   what the real command does: every run exits 0, names no check as not
///   run, prints no notice and ends with its summary line, a full run reports
///   the page edited by hand, and `--format json` reports that page as the
///   one `docs.stale` finding. The `appstein mcp` rows use the same warm
///   cache;
/// - the hook where an agent meets it (spec §9.1, §15, design §15), on the
///   same app: the compiled `appstein verify --fast --hook claude` with
///   Claude Code's PostToolUse input on stdin, timed from before its process
///   starts until the process has exited and its output has closed, the
///   later of the two, because that is what Claude Code waits for
///   (`runHook`). **With the project's analysis host ready**
///   (`measureWarmHook`), after an edit that adds an error, the median of
///   three (each run follows an edit of its own and has a session of its own,
///   so the hook's "nothing changed" rule never makes a run silent) must be
///   under 5 s (5.000 s fails), and every run must exit 2 and name the error
///   on its line. **With no host running and a warm analysis cache**
///   (`measureNoHostHook`; the everyday case of a new session, not a
///   cold-cache start) the hook starts a host and waits: one run, with no
///   limit but the cap, and whether it reached the cap is printed.
///   **Sharing** (`measureSharing`): two `appstein mcp` processes and a hook
///   on the project leave exactly one analysis host and one analysis server,
///   found by their place in the process tree and not by name, or the tool
///   fails; the memory of
///   one session and of two sessions with the host is printed side by side.
///   The tool gives every process it starts a host-folder of its own
///   (`APPSTEIN_ANALYSIS_HOST_FOLDER`), so a developer's own hosts never take
///   part, ends the hosts it started itself (they outlive their sessions by
///   design) and checks that nothing is left;
/// - what a reading of the project costs the warm call, in this process:
///   the analysis server's look at the disk and the scan of the Dart files,
///   on the 200-file app with and without a large `build/` folder. Printed
///   only.
///
/// The same rows are measured for a 1,000-file app. Their times are printed
/// for information only and never held to a target (owner decision, slice
/// 1b.7), but a broken run at either size (a failed sync, a skipped map,
/// unread native config, an edit not reported as changed) still exits 1.
///
/// It compiles the `appstein` command first and runs every sync as a new
/// process, the way an agent's hook runs it, with FLUTTER_ROOT set to the
/// Flutter SDK whose Dart runs this tool.
///
/// Usage, from the repo root:
///   fvm dart run tool/measure_sync.dart [--work <folder>]
///
/// The apps are made in a new folder inside `--work` (the system's temporary
/// folder by default). CI passes its own temporary folder, which is on the
/// disk that holds the checkout.
///
/// The first sync of each app fetches its packages (go_router needs the
/// network). Prints six Markdown tables: the main one; where the time of
/// each full sync and edit went, step by step (`appstein sync --timings`);
/// the `verify` rows (warm, terminal, memory); the hook rows (the hook with
/// the host ready, with no host, the sharing check and its memory); what a
/// reading costs; and the MCP answers. It exits 1 when a held row misses its
/// target or a check fails. When the warm, hook or terminal measurement's own
/// checks fail (a reply that missed the error, a process left running, a fast
/// run cut by the cap), the tables measured so far are printed before it
/// exits, so a CI log keeps the numbers.
Future<void> main(List<String> args) async {
  final Directory parent;
  switch (args) {
    case []:
      parent = Directory.systemTemp;
    case ['--work', final folder] when Directory(folder).existsSync():
      parent = Directory(folder);
    default:
      stderr.writeln(
        'Usage: fvm dart run tool/measure_sync.dart [--work <folder>], where '
        'the folder exists.',
      );
      exitCode = 1;
      return;
  }
  final flutterRoot = _flutterRoot();
  if (flutterRoot == null) {
    stderr.writeln(
      'Run this with the Dart of a Flutter SDK (fvm dart run '
      'tool/measure_sync.dart): ${Platform.resolvedExecutable} is not inside '
      'one.',
    );
    exitCode = 1;
    return;
  }
  final work = parent.createTempSync('appstein measure sync ');
  stderr.writeln('Measuring in ${work.path}');
  // The address files of the analysis hosts every process of this tool
  // meets: its own folder, so a developer's hosts take no part, and the hosts
  // this tool starts can be found and ended (`MeasureContext`).
  final hostFolder = p.join(work.path, 'analysis host');
  try {
    final exe = await _compile(work.path);
    if (exe == null) {
      exitCode = 1;
      return;
    }
    final columns = <int, Map<String, Duration>>{};
    // The three runs behind each median row, in the order they ran.
    final spreads = <int, Map<String, List<Duration>>>{};
    // The three detect rows, with their second measurement when they had one.
    final detectRows = <int, Map<String, HeldDetect<_Run>>>{};
    // The runs whose steps the second table breaks down.
    final broken = <String, _Run>{};
    var missed = <String>[];
    final mcp = <String, List<Duration>>{};
    // The most memory a terminal verify run held, by row.
    final terminalPeaks = <String, int>{};
    // The terminal verify rows, with the warm-up before the warm ones, and
    // the time of that whole step: every run of it, sampled and JSON runs
    // included.
    TerminalRows? terminal;
    Duration? terminalTime;
    // The analysis server's disk cache of every `appstein verify` and
    // `appstein mcp` this tool starts, except the cold runs, which each get
    // a new one: this tool's own, so what other steps of a CI job left in
    // the default cache (`~/.dartServer`) changes no row, on any system.
    final warmCache = (Directory(
      p.join(work.path, 'analysis server cache'),
    )..createSync()).path;
    WarmResult? warm;
    HookResults? hooks;
    List<_ReadingRow>? reading;

    // Prints every table that has something in it: when a check fails
    // early, the rows measured before it still reach the log.
    String cell(int files, String row) {
      // The docs and verify rows are measured on the 200-file app only.
      final column = columns[files];
      if (column == null || !column.containsKey(row)) return 'not measured';
      if (detectRows[files]?[row] case final detect?) return detect.cell();
      final median = '${column[row]!.inMilliseconds} ms';
      final three = spreads[files]?[row];
      return three == null
          ? median
          : '$median (${three.map((time) => time.inMilliseconds).join(', ')})';
    }

    String line(String label, String row) =>
        '| $label | ${cell(200, row)} | ${cell(1000, row)} |';
    void printTables() {
      stdout.writeln('''
| Measurement (${Platform.operatingSystem}, a new process each) | 200 files | 1,000 files (info) |
|---|---|---|
${line('First sync, with `flutter pub get`', 'first')}
${line('**Full sync, no analyzer cache** (target under 30 s)', 'full')}
${line('**`sync --detect`, nothing changed**, median of 3 (target under 2 s)', 'unchanged')}
${line('**`sync --detect` after editing a view model**, median of 3 (target under 2 s)', 'viewModel')}
${line('**`sync --detect` after editing the router**, median of 3 (target under 2 s)', 'router')}
${line('**`docs`, writing every page** (target under 2 s)', 'docsFirst')}
${line('**`docs`, nothing to write**, median of 3 (target under 2 s)', 'docs')}
${line('**`docs --check`**, median of 3 (target under 2 s)', 'docsCheck')}
| `verify --fast` in the terminal, median of 3 (capped at ${terminalFastCap.inSeconds} s by `verify.fast_timeout_seconds`; a run cut by it fails): cold analysis-server cache / warm | ${cell(200, 'verifyFastCold')} / ${cell(200, 'verifyFastWarm')} | not measured |
| `verify` (full) in the terminal, median of 3 (no limit): cold analysis-server cache / warm | ${cell(200, 'verifyFullCold')} / ${cell(200, 'verifyFullWarm')} | not measured |
''');
      if (broken.isNotEmpty) stdout.writeln(_breakdown(broken));
      if (warm case final measured?) {
        stdout.writeln(
          _warmTable(measured, terminalPeaks, terminal, terminalTime),
        );
      }
      if (hooks case final measured?) {
        stdout.writeln(_hookTable(measured));
      }
      if (reading case final read?) stdout.writeln(_readingTable(read));
      if (mcp.isNotEmpty) {
        stdout.writeln('''
| MCP answer on the 200-file app (one `appstein mcp` process) | median of 3 (target under 1 s) |
|---|---|
${[for (final MapEntry(key: tool, value: three) in mcp.entries) '| `$tool` | ${(three.toList()..sort())[1].inMilliseconds} ms (${three.map((d) => d.inMilliseconds).join(', ')}) |'].join('\n')}
''');
      }
    }

    for (final (files, held) in const [(200, true), (1000, false)]) {
      final app = p.join(work.path, 'app $files');
      _generateApp(app, features: (files - 2) ~/ 2);
      final context = MeasureContext(
        executable: exe,
        project: app,
        flutterRoot: flutterRoot,
        hostFolder: hostFolder,
      );
      Future<_Run> sync([List<String> flags = const []]) =>
          _run(context, flags);
      final times = columns[files] = {};

      final first = await sync();
      if (first.problem() case final problem?) {
        stderr.writeln('The first sync of the $files-file app: $problem');
        exitCode = 1;
        return;
      }
      times['first'] = first.elapsed;

      // Cold: no knowledge and no analyzer cache, the 30 s worst case.
      Directory(p.join(app, '.appstein')).deleteSync(recursive: true);
      final cache = Directory(p.join(app, '.dart_tool', 'appstein'));
      if (cache.existsSync()) cache.deleteSync(recursive: true);
      final full = await sync();
      if (full.problem() case final problem?) {
        stderr.writeln('The full sync of the $files-file app: $problem');
        exitCode = 1;
        return;
      }
      times['full'] = full.elapsed;
      broken['full, $files'] = full;

      // Each detect row is the median of three runs, as measure_analyze
      // takes the median of three: a CI machine's speed varies by about 2x
      // from run to run, and one slow run must not fail the target, while a
      // real slowdown still moves the median. A held row (the 200-file app)
      // whose median is 2 s or more is measured once more, with three fresh
      // runs and, for the edit rows, three new edits: it misses only when the
      // second median misses too (owner, 2026-10-16: a slow CI runner made a
      // median miss that the rerun passed). `measureHeldDetect` decides.
      final runs = spreads[files] = {};
      void record(String row, List<_Run> three) {
        final median = _median(three);
        times[row] = median.elapsed;
        runs[row] = [for (final run in three) run.elapsed];
      }

      final detects = detectRows[files] = {};
      // Measures one detect row; false when a run was not valid, which the
      // run has already reported (and set the exit code for).
      Future<bool> detectRow(
        String row,
        String what,
        Future<_Run?> Function(int index) one,
      ) async {
        final measured = await measureHeldDetect<_Run>(
          run: one,
          timeOf: (run) => run.elapsed,
          retry: held,
          onRetry: (first) => stderr.writeln(
            '$what took ${first.inMilliseconds} ms, the median of three '
            '(2 s or more): measuring it once more.',
          ),
        );
        if (measured == null) return false;
        times[row] = measured.counted;
        detects[row] = measured;
        return true;
      }

      // The first detect empties the change list the full sync recorded;
      // the next ones are what a hook sees after a command that changed
      // nothing.
      await sync(const ['--detect']);
      if (!await detectRow('unchanged', 'A detect with nothing changed', (
        _,
      ) async {
        final run = await sync(const ['--detect']);
        if (!run.stdout.startsWith('Knowledge is current')) {
          stderr.writeln(
            'A detect with nothing changed rebuilt:\n${run.stdout}',
          );
          exitCode = 1;
          return null;
        }
        return run;
      })) {
        return;
      }

      // A different edit of one view model for each run (the indices 0 to 2,
      // and 3 to 5 for a second measurement), each followed by a detect.
      const viewModel =
          'lib/ui/feature_5/view_models/feature_5_view_model.dart';
      if (!await detectRow('viewModel', 'A detect after one edit', (i) async {
        _edit(
          p.join(app, viewModel),
          'int taps = 0;',
          'int taps = 0;\n\n  /// Whether it was opened, $i.\n'
              '  bool opened$i = false;',
        );
        final run = await sync(const ['--detect']);
        if (run.problem() != null ||
            !run.stdout.contains('Changed since the last sync: $viewModel.')) {
          stderr.writeln(
            'A detect after the view model edit did not rebuild it:\n'
            '${run.stdout}${run.stderr}',
          );
          exitCode = 1;
          return null;
        }
        return run;
      })) {
        return;
      }
      // The first attempt's median run, which a miss is explained by.
      broken['view model edit (median), $files'] =
          detects['viewModel']!.firstMedianRun;

      // The router has a route '/feature-<i>' for each feature, 99 of them
      // here, so the edits 0 to 5 each find theirs.
      if (!await detectRow('router', 'A detect after a router edit', (i) async {
        _edit(
          p.join(app, 'lib', 'routing', 'router.dart'),
          "'/feature-$i'",
          "'/feature-$i-renamed'",
        );
        final run = await sync(const ['--detect']);
        if (run.problem() case final problem?) {
          stderr.writeln('A detect after the router edit: $problem');
          exitCode = 1;
          return null;
        }
        return run;
      })) {
        return;
      }
      broken['router edit (median), $files'] =
          detects['router']!.firstMedianRun;

      if (held) {
        // The knowledge is fresh after the last detect, so these measure
        // spec §15's "MCP tool responses < 1 s from fresh knowledge". The
        // first call starts the server; it is not counted.
        final session = await _startMcp(context, warmCache);
        try {
          await session.time('overview', const {});
          for (final (tool, arguments) in _mcpCalls) {
            final three = <Duration>[];
            for (var i = 0; i < 3; i++) {
              three.add(await session.time(tool, arguments));
            }
            mcp[tool] = three;
          }
        } on StateError catch (error) {
          stderr.writeln('appstein mcp: ${error.message}');
          exitCode = 1;
          return;
        } finally {
          await session.close();
        }
      }

      if (held) {
        // The knowledge is still fresh, so these measure spec §15's
        // "`appstein docs` from fresh knowledge < 2 s", and check what the
        // real command does on real files.
        Future<_Run> docs([List<String> flags = const []]) =>
            _run(context, flags, command: 'docs');
        String? wrong(_Run run, int exit, String start) =>
            run.exitCode == exit && run.stdout.startsWith(start)
            ? null
            : 'exit code ${run.exitCode}, expected $exit and output '
                  'starting "$start":\n${run.stdout}${run.stderr}';
        final written = await docs();
        if (wrong(written, 0, 'Rendered docs/app/: ') case final problem?) {
          stderr.writeln('The first appstein docs: $problem');
          exitCode = 1;
          return;
        }
        times['docsFirst'] = written.elapsed;
        final again = <_Run>[];
        final checks = <_Run>[];
        for (var i = 0; i < 3; i++) {
          for (final (into, flags) in [
            (again, const <String>[]),
            (checks, const ['--check']),
          ]) {
            final run = await docs(flags);
            if (wrong(run, 0, 'docs/app/ is up to date (')
                case final problem?) {
              stderr.writeln('appstein docs ${flags.join(' ')}: $problem');
              exitCode = 1;
              return;
            }
            into.add(run);
          }
        }
        record('docs', again);
        record('docsCheck', checks);
        // A page edited by hand: --check names it and exits 1, and writes
        // nothing.
        final page = File(p.join(app, 'docs', 'app', 'routes.md'));
        final edited = '${page.readAsStringSync()}Edited by hand.\n';
        page.writeAsStringSync(edited);
        final stale = await docs(const ['--check']);
        if (wrong(stale, 1, 'docs/app/ is not up to date: 1 of ') ??
                (stale.stdout.contains('  routes.md  hand-edited\n') &&
                        page.readAsStringSync() == edited
                    ? null
                    : 'it did not name routes.md as hand-edited, or it wrote '
                          'the page:\n${stale.stdout}')
            case final problem?) {
          stderr.writeln('appstein docs --check after a hand edit: $problem');
          exitCode = 1;
          return;
        }
      }

      if (held) {
        // The knowledge is still fresh, and `routes.md` is edited by hand:
        // these time the terminal fast and full runs, which start their own
        // analysis server, with no limit (spec §15: the 5 s limit is the
        // warm tool's, measured below), and check what the real command
        // prints (`terminalVerifyProblem`). Warnings alone (a feature without
        // a test, the edited page, the router's formatting) exit 0.
        //
        // The analysis server's disk cache is this tool's own folder
        // (`analysisCacheVariable`), so what earlier steps of the job left in
        // `~/.dartServer` changes nothing: a cold row starts each run with an
        // empty folder, and a warm row runs after the warm-up, which stops
        // when the folder stops growing or at its cap of 15 runs
        // (`measureTerminalRows`, which also runs a full run first so the
        // fast runs have no unverified file). The whole step is timed, so
        // its growth in a CI job can be watched.
        final stepWatch = Stopwatch()..start();
        // Printed also when the step fails, so a failing CI job still shows
        // how long the step ran.
        try {
          var coldCaches = 0;
          final TerminalRows measured;
          try {
            measured = terminal = await measureTerminalRows(
              run: (flag, cache) async {
                final run = await _run(
                  context,
                  [flag],
                  command: 'verify',
                  cache: cache,
                );
                return (
                  exitCode: run.exitCode,
                  stdout: run.stdout,
                  stderr: run.stderr,
                  elapsed: run.elapsed,
                );
              },
              warmCache: warmCache,
              newCache: () => (Directory(
                p.join(work.path, 'cold cache ${coldCaches++}'),
              )..createSync()).path,
              discardCache: (cache) =>
                  discardCache(cache, warn: stderr.writeln),
              cacheCount: countCache,
            );
          } on StateError catch (error) {
            // What was measured before it goes in the log, as for the warm
            // rows, and a run cut by the cap keeps its time in the message.
            printTables();
            stderr.writeln(error.message);
            exitCode = 1;
            return;
          }
          for (final (row, three) in [
            ('verifyFastCold', measured.coldFast),
            ('verifyFullCold', measured.coldFull),
            ('verifyFastWarm', measured.warmFast),
            ('verifyFullWarm', measured.warmFull),
          ]) {
            times[row] = medianOf(three);
            runs[row] = three;
          }
          // One more run of each, not timed, on the warm cache, with the
          // memory of its process tree sampled: the guard and the analysis
          // server it started.
          for (final (row, flag) in const [
            ('verifyFast', fastFlag),
            ('verifyFull', fullFlag),
          ]) {
            try {
              terminalPeaks[row] = await sampledPeak(
                () => _sampleVerify(context, flag, warmCache),
                flag: flag,
              );
            } on StateError catch (error) {
              stderr.writeln(error.message);
              exitCode = 1;
              return;
            }
          }
          final json = await _run(
            context,
            const ['--format', 'json'],
            command: 'verify',
            cache: warmCache,
          );
          final stalePages = json.exitCode != 0
              ? null
              : [
                  for (final finding
                      in (jsonDecode(json.stdout) as Map)['findings'] as List)
                    if ((finding as Map)['id'] == 'docs.stale') finding['file'],
                ];
          if (stalePages?.join(',') != 'docs/app/routes.md') {
            stderr.writeln(
              'appstein verify --format json after a hand edit of routes.md: '
              'exit code ${json.exitCode}, and docs.stale on $stalePages; '
              'expected exit code 0 and only docs/app/routes.md:\n'
              '${json.stderr}',
            );
            exitCode = 1;
            return;
          }
        } finally {
          final took = terminalTime = stepWatch.elapsed;
          stderr.writeln(
            'The terminal verify runs took ${_seconds(took)} in all.',
          );
        }
      }

      if (held) {
        // The limit of spec §15 where an agent meets it: the `verify` tool
        // of a running `appstein mcp`, after one file is edited. Its server
        // uses the warm cache of the terminal rows, after their warm-up,
        // which may stop at its cap of 15 runs with the cache still growing:
        // the same folder and steps on every system, though not always a
        // cache that stopped growing.
        warm = await _measureWarm(context, warmCache);
        if (warm.problem case final problem?) {
          // What was measured so far goes in the log before the failure.
          printTables();
          stderr.writeln('The warm verify measurement: $problem');
          exitCode = 1;
          return;
        }
        // The hook where an agent meets it, and the sharing of one analysis
        // server by the sessions of a project.
        hooks = await _measureHooks(context, warmCache);
        if (hooks.problem case final problem?) {
          printTables();
          stderr.writeln('The hook measurement: $problem');
          exitCode = 1;
          return;
        }
        reading = await _measureReading(app);
      }

      if (held) {
        String took(String row) => '${times[row]!.inMilliseconds} ms';
        missed = [
          for (final (row, what) in const [
            ('docs', 'appstein docs with nothing to write'),
            ('docsCheck', 'appstein docs --check'),
          ])
            if (times[row]! >= const Duration(seconds: 2))
              '$what took ${took(row)}, the median of three (under 2 s)',
          if (times['docsFirst']! >= const Duration(seconds: 2))
            'the first appstein docs took ${took('docsFirst')} (under 2 s)',
          ?limitMiss('warm fast verify', medianOf(warm!.fast)),
          ?limitMiss('hook', hooks!.hostReady!.median),
          if (full.elapsed >= const Duration(seconds: 30))
            'a full sync took ${full.elapsed.inMilliseconds} ms (under 30 s)',
          ?detects['unchanged']!.miss('a detect with nothing changed'),
          ?detects['viewModel']!.miss('a detect after one edit'),
          ?detects['router']!.miss('a detect after a router edit'),
          for (final MapEntry(key: tool, value: three) in mcp.entries)
            if ((three.toList()..sort())[1] >= const Duration(seconds: 1))
              'the MCP tool $tool took ${(three.toList()..sort())[1].inMilliseconds} ms, '
                  'the median of three (under 1 s)',
        ];
      }
    }
    printTables();
    if (missed.isNotEmpty) {
      stderr.writeln('Spec §15 targets missed on the 200-file app:');
      for (final miss in missed) {
        stderr.writeln('  $miss');
      }
      exitCode = 1;
    }
  } finally {
    // A host outlives the tool's own processes by design: whatever way this
    // run ended, the hosts it started are ended before its folder goes.
    try {
      if (await stopHosts(hostFolder) case final problem?) {
        stderr.writeln('warning: $problem');
      }
    } on Object catch (error) {
      stderr.writeln('warning: could not end the analysis hosts: $error');
    }
    try {
      work.deleteSync(recursive: true);
    } on FileSystemException {
      stderr.writeln(
        'warning: could not delete ${work.path}; remove it by hand',
      );
    }
  }
}

/// The tool calls timed on the 200-file app, each three times (spec §15:
/// MCP answers under 1 s from fresh knowledge).
const _mcpCalls = [
  ('overview', <String, Object?>{}),
  ('where_is', <String, Object?>{'query': 'feature 5 view model'}),
  ('feature', <String, Object?>{'name': 'feature_5'}),
  ('route', <String, Object?>{'path': '/feature-7'}),
  ('check_api', <String, Object?>{'name': 'withOpacity'}),
  ('what_changed', <String, Object?>{}),
  ('toolchain', <String, Object?>{}),
];

/// Starts `appstein mcp` for the app of [context], the way an agent's client
/// does, with the analysis server's cache in [cache].
Future<McpSession> _startMcp(MeasureContext context, String cache) =>
    McpSession.start(
      context.executable,
      ['--project', context.project, 'mcp'],
      environment: context.environment(cache),
      clientName: 'measure_sync',
    );

/// The view model that the warm measurement edits.
const _editedFile = 'lib/ui/feature_9/view_models/feature_9_view_model.dart';

/// Starts `appstein mcp` on the app of [context], with the analysis server's
/// cache in [cache], and runs the warm measurement on it (`measureWarm`),
/// which closes it, ends the analysis host it started and checks no process of
/// them is left.
Future<WarmResult> _measureWarm(MeasureContext context, String cache) async {
  final McpSession session;
  try {
    session = await _startMcp(context, cache);
  } on StateError catch (error) {
    return WarmResult()
      ..problem = 'appstein mcp did not start: ${error.message}';
  }
  return measureWarm(
    session,
    project: context.project,
    file: _editedFile,
    hostProcesses: () => hostProcessIds(context.hostFolder),
    endHosts: () => stopHosts(context.hostFolder),
  );
}

/// The hook where an agent meets it, on the app of [context] (spec §9.1,
/// §15), after the warm rows ended their host: the rows and their order are
/// `measureHookRows`; this gives it the compiled hook (`runHook`), the
/// sessions and the hosts of this tool's host folder. The analysis server of
/// every host and session uses the cache folder [cache].
Future<HookResults> _measureHooks(MeasureContext context, String cache) =>
    measureHookRows(
      run: (sessionId) => runHook(
        context,
        cache: cache,
        input: hookInput(
          sessionId,
          project: context.project,
          file: _editedFile,
        ),
      ),
      startSession: () => _startMcp(context, cache),
      hostIds: () => hostProcessIds(context.hostFolder),
      endHosts: () => stopHosts(context.hostFolder),
      project: context.project,
      file: _editedFile,
    );

/// Runs `appstein verify [flag]` once, without timing it, with the analysis
/// server's cache in [cache], and samples the memory of its process tree
/// (the guard and the analysis server it starts): its output, exit code and
/// peak, which is null when the sampling never saw the guard and the server
/// (`peakTreeMemory`). Throws a [StateError] when the process list can't be
/// read.
Future<SampledRun> _sampleVerify(
  MeasureContext context,
  String flag,
  String cache,
) async {
  // One look before the run, so the first look of the sampling does not
  // pay for starting the lister: on a new Windows machine the first
  // PowerShell process listing can take longer than a whole run.
  await listProcesses();
  final process = await context.start(context.executable, [
    '--project',
    context.project,
    'verify',
    flag,
  ], environment: context.environment(cache));
  final output = Future.wait([
    process.stdout.transform(utf8.decoder).join(),
    process.stderr.transform(utf8.decoder).join(),
  ]);
  // The sampling and the run are awaited together: a process list that
  // fails while the run goes on must not be an error nobody listens to.
  final (int code, int? most) =
      await exitAndPeak(
        process.exitCode,
        peakTreeMemory(process.pid, process.exitCode),
      ).onError<StateError>((error, _) async {
        // Only the process this function started is ended.
        process.kill();
        await process.exitCode;
        await output;
        throw error;
      });
  final [out, err] = await output;
  return (exitCode: code, stdout: out, stderr: err, peak: most);
}

/// One size of `build/`: what the reading of the project costs there.
final class _ReadingRow {
  _ReadingRow(this.buildFiles, this.dartFiles);

  /// Files in `build/`.
  final int buildFiles;

  /// Dart files the analysis sees in the whole project.
  final int dartFiles;

  /// The analysis server's look at the disk, once per call of `verify`.
  final look = <Duration>[];

  /// The scan of the Dart files, the first time (every file is hashed) and
  /// with the last scan to compare with (nothing changed).
  Duration scanFirst = Duration.zero;
  final scan = <Duration>[];
}

/// Times, in this process, the two readings of the project that a warm
/// `verify` call makes beside the analysis: the analysis server's look at
/// the disk (`DiskLook`) and the scan of the Dart files, each three times,
/// on [app] with no `build/` folder and with 6,000 and 26,000 files in it
/// (the sizes ticket 04 measured).
Future<List<_ReadingRow>> _measureReading(String app) async {
  final rows = <_ReadingRow>[];
  final unchanging = unchangingFolders(
    Platform.resolvedExecutable,
    Platform.environment,
  );
  for (final files in const [0, 6000, 26000]) {
    final dartInBuild = writeLargeBuild(app, files: files);
    // The scan trusts a file only when it is older than the last scan by
    // more than the clock's step (2 s): a build folder is not new.
    if (files > 0) await Future<void>.delayed(const Duration(seconds: 3));
    final look = await DiskLook.of(app, unchanging: unchanging);
    final row = _ReadingRow(files, look.dart.length);
    // The look above warmed the file system's cache; three more are timed.
    for (var i = 0; i < 3; i++) {
      final watch = Stopwatch()..start();
      await DiskLook.of(app, unchanging: unchanging);
      row.look.add(watch.elapsed);
    }
    final watch = Stopwatch()..start();
    final first = await readDartFileHashes(app);
    row.scanFirst = watch.elapsed;
    for (var i = 0; i < 3; i++) {
      final watch = Stopwatch()..start();
      await readDartFileHashes(app, previous: first);
      row.scan.add(watch.elapsed);
    }
    rows.add(row);
    stderr.writeln(
      'Read a project with $files files in build/ '
      '(${row.dartFiles} Dart files, $dartInBuild of them in build/).',
    );
  }
  return rows;
}

String _gigabytes(int bytes) =>
    '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';

String _spread(List<Duration> times) => times.isEmpty
    ? 'not measured'
    : '${medianOf(times).inMilliseconds} ms '
          '(${times.map((time) => time.inMilliseconds).join(', ')})';

/// The memory of a terminal run, or "not measured" before it was taken. A
/// sampling that never saw the run fails the measurement (`sampledPeak`), so
/// this is never a 0 that measured nothing.
String _peak(Map<String, int> peaks, String row) =>
    peaks.containsKey(row) ? _gigabytes(peaks[row]!) : 'not measured';

/// [time] in seconds, to a tenth.
String _seconds(Duration time) =>
    '${(time.inMilliseconds / 1000).toStringAsFixed(1)} s';

/// The warm-up before the warm terminal rows: how many runs, their times,
/// the cache entries each added and the half-written files each left
/// (`countCache`), and whether it stopped at its cap.
String _warmUp(TerminalRows? rows) {
  if (rows == null || rows.warmUp.isEmpty) return 'not measured';
  final runs = rows.warmUp.length;
  return '$runs ${runs == 1 ? 'run' : 'runs'}: '
      '${rows.warmUp.map((time) => time.inMilliseconds).join(', ')} ms, '
      'adding ${rows.warmUpAdded.join(', ')} cache entries and leaving '
      '${rows.warmUpHalfWritten.join(', ')} half-written files'
      '${rows.capped ? '. **Stopped at the cap of $terminalWarmUpMost with '
                'the cache still growing**: the warm rows may not be warm' : ''}';
}

/// The third table: the warm `verify` tool, with the 5 s limit, beside the
/// terminal runs' warm-up, memory and total time, and the cost of starting
/// the analysis server. After a failed measurement it holds what was
/// measured before the failure.
String _warmTable(
  WarmResult warm,
  Map<String, int> terminalPeaks,
  TerminalRows? terminal,
  Duration? terminalTime,
) =>
    '''
| `verify` where an agent meets it, 200-file app (${Platform.operatingSystem}) | Result |
|---|---|${warm.problem == null ? '' : '\n| **The measurement failed**, the rows below stop where it did | ${warm.problem!.replaceAll('|', '/').replaceAll('\n', ' ')} |'}
| **Warm fast `verify`** after an edit that adds an error, median of 3 (limit: under 5 s) | ${_spread(warm.fast)} |
| Warm fast `verify` after the error is fixed, median of 3 (no limit) | ${_spread(warm.fixed)} |
| Where that went: the knowledge refresh after the edit (an `overview` call), median of 3 | ${_spread(warm.refresh)} |
| Where that went: `verify` once the refresh is done, median of 3 | ${_spread(warm.afterRefresh)} |
| First `verify` call: the analysis host starts, its server starts and is ready, then reads | ${warm.startUp.inMilliseconds} ms |
| Memory of `appstein mcp`, the analysis host, its guard and the server, when ready / after the calls | ${_gigabytes(warm.memoryReady)} / ${_gigabytes(warm.memoryAfter)} |
| Warm-up of the analysis server's cache before the warm terminal rows: full runs until one adds no cache entry and leaves no half-written file (at most $terminalWarmUpMost) | ${_warmUp(terminal)} |
| The terminal `verify` step, every run of it (first, cold, warm-up, warm, sampled and JSON runs) | ${terminalTime == null ? 'not measured' : _seconds(terminalTime)} |
| Most memory of a terminal `verify --fast` run on the warm cache (its own guard and server) | ${_peak(terminalPeaks, 'verifyFast')} |
| Most memory of a terminal `verify` (full) run on the warm cache | ${_peak(terminalPeaks, 'verifyFull')} |
''';

/// The hook table: the 5 s limit where an agent meets it, the hook with no
/// host and a warm analysis cache, and what the sharing check found, with the
/// memory of one session beside that of two. After a failed measurement it
/// holds what was measured before the failure.
String _hookTable(HookResults results) {
  final ready = results.hostReady;
  final readyCell = ready == null
      ? 'not measured'
      : _spread(ready.times) +
            (ready.problem == null ? '' : ' (stopped at a failed run)');

  final noHost = results.noHost;
  final noHostRun = noHost?.run;
  final cap = '${terminalFastCap.inSeconds} s';
  final String noHostCell;
  if (noHost == null || noHostRun == null) {
    noHostCell = 'not measured';
  } else {
    final reached = noHost.reachedCap
        ? 'reached the cap ($cap): the code checks were named as pending'
        : 'did not reach the cap ($cap)';
    noHostCell =
        '${noHostRun.elapsed.inMilliseconds} ms, exit code '
        '${noHostRun.exitCode}; **$reached**';
  }

  final sharing = results.sharing;
  final sharedCell = sharing == null
      ? 'not measured'
      : '${sharing.hosts} / ${sharing.servers}';
  String memory(int? bytes) =>
      bytes == null || bytes == 0 ? 'not measured' : _gigabytes(bytes);
  final failure = results.problem == null
      ? ''
      : '\n| **The measurement failed** | '
            "${results.problem!.replaceAll('|', '/').replaceAll('\n', ' ')} |";
  return '''
| The hook `verify --fast --hook claude` (compiled), from its process start until it has exited and its output has closed, 200-file app (${Platform.operatingSystem}) | Result |
|---|---|$failure
| **Hook with the analysis host ready**, after an edit that adds an error, median of 3, every run exit 2 naming the error (limit: under 5 s) | $readyCell |
| Hook with **no host running and a warm analysis cache** (a new session, or after a host's idle stop; not a cold-cache start): it starts a host and waits, one run (no limit but the cap) | $noHostCell |
| Analysis hosts / analysis servers running after two `appstein mcp` sessions and a hook (exactly 1 / 1) | $sharedCell |
| Memory of one session: `appstein mcp`, the analysis host, its guard and the server | ${memory(sharing?.memoryOne)} |
| Memory of two sessions and the same host, after both called `verify` and a hook ran | ${memory(sharing?.memoryTwo)} |
''';
}

/// The fourth table: what the reading of the project costs a warm call.
String _readingTable(List<_ReadingRow> rows) =>
    '''
| Reading the 200-file app in this process, median of 3 | ${rows.map((row) => row.buildFiles == 0 ? 'no `build/`' : '`build/` with ${row.buildFiles} files').join(' | ')} |
|---|${rows.map((_) => '---|').join()}
| Dart files in the project | ${rows.map((row) => row.dartFiles).join(' | ')} |
| The analysis server's look at the disk, before each reading | ${rows.map((row) => _spread(row.look)).join(' | ')} |
| The scan of the Dart files, the first time (every file hashed) | ${rows.map((row) => '${row.scanFirst.inMilliseconds} ms').join(' | ')} |
| The scan of the Dart files, nothing changed | ${rows.map((row) => _spread(row.scan)).join(' | ')} |
''';

/// The second table: where each of [runs]' time went, one column per run
/// and one row per step `appstein sync --timings` reported (a part of the
/// step above it is indented), then the time outside every step (starting
/// and ending the process) and the whole run.
String _breakdown(Map<String, _Run> runs) {
  final steps = <String>{for (final run in runs.values) ...run.steps.keys};
  String cell(_Run run, String step) =>
      run.steps.containsKey(step) ? '${run.steps[step]} ms' : '';
  String outside(_Run run) {
    final inSteps = run.steps.entries
        .where((step) => !step.key.startsWith('  '))
        .fold(0, (sum, step) => sum + step.value);
    return '${run.elapsed.inMilliseconds - inSteps} ms';
  }

  final names = runs.keys.toList();
  return [
    '| Where the time went (${Platform.operatingSystem}) | '
        '${names.join(' | ')} |',
    '|---|${[for (final _ in names) '---|'].join()}',
    for (final step in steps)
      '| ${step.startsWith('  ') ? '&nbsp;&nbsp;' : ''}${step.trim()} | '
          '${[for (final run in runs.values) cell(run, step)].join(' | ')} |',
    '| outside every step (process start and exit) | '
        '${[for (final run in runs.values) outside(run)].join(' | ')} |',
    '| **the whole run** | '
        '${[for (final run in runs.values) '${run.elapsed.inMilliseconds} ms'].join(' | ')} |',
    '',
  ].join('\n');
}

/// The run with the middle time of [runs] (an odd number of them).
_Run _median(List<_Run> runs) =>
    (runs.toList()
      ..sort((a, b) => a.elapsed.compareTo(b.elapsed)))[runs.length ~/ 2];

/// One `appstein sync --timings` process: its exit code, output and time.
final class _Run {
  _Run(this.exitCode, this.stdout, this.stderr, this.elapsed);

  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration elapsed;

  /// Each step's time in milliseconds, from the `timing` lines the sync
  /// printed after its report.
  late final Map<String, int> steps = {
    for (final match in RegExp(
      r'^timing +(\d+) ms  (.+)$',
      multiLine: true,
    ).allMatches(stdout))
      match[2]!: int.parse(match[1]!),
  };

  /// Why this run doesn't count as a real sync, or null. A failed run, a
  /// skipped map or unread native config would be cheaper than a real sync.
  String? problem() {
    if (exitCode != 0) return 'exit code $exitCode:\n$stdout$stderr';
    if (stdout.contains('Project map skipped')) {
      return 'the project map was skipped:\n$stdout';
    }
    if (!stdout.contains('Native config: android read; ios read.')) {
      return 'native config was not read:\n$stdout';
    }
    return null;
  }
}

/// Runs `appstein <command> [flags]` on the app of [context] and times it;
/// with [cache],
/// the analysis server it starts keeps its disk cache there.
Future<_Run> _run(
  MeasureContext context,
  List<String> flags, {
  String command = 'sync',
  String? cache,
}) async {
  final watch = Stopwatch()..start();
  final result = await Process.run(context.executable, [
    '--project',
    context.project,
    command,
    if (command == 'sync') '--timings',
    ...flags,
  ], environment: context.environment(cache));
  watch.stop();
  return _Run(
    result.exitCode,
    '${result.stdout}',
    '${result.stderr}',
    watch.elapsed,
  );
}

/// The Flutter SDK whose Dart runs this tool
/// (`<flutter>/bin/cache/dart-sdk/bin/dart`), or null when this Dart isn't
/// inside one.
String? _flutterRoot() {
  var folder = p.dirname(Platform.resolvedExecutable);
  for (var i = 0; i < 4; i++) {
    folder = p.dirname(folder);
  }
  return File(
        p.join(folder, 'bin', 'cache', 'flutter.version.json'),
      ).existsSync()
      ? folder
      : null;
}

/// Compiles the `appstein` command into [work]; null, with the compiler's
/// output printed, when it fails.
Future<String?> _compile(String work) async {
  final exe = p.join(work, Platform.isWindows ? 'appstein.exe' : 'appstein');
  final result = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    p.join('packages', 'appstein_cli', 'bin', 'appstein.dart'),
    '-o',
    exe,
  ]);
  if (result.exitCode != 0) {
    stderr.writeln(
      'Could not compile appstein:\n${result.stdout}${result.stderr}',
    );
    return null;
  }
  return exe;
}

void _edit(String path, String from, String to) {
  final file = File(path);
  final text = file.readAsStringSync();
  if (!text.contains(from)) throw StateError('"$from" is not in $path');
  file.writeAsStringSync(text.replaceFirst(from, to));
}

/// Writes an official_mvvm app: [features] features with a view model and a
/// screen each, a router with one route per feature, and `main.dart`. The
/// app also has a new app's `android/` and `ios/` files.
void _generateApp(String app, {required int features}) {
  void write(String relative, String content) => File(p.join(app, relative))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  write(
    'pubspec.yaml',
    'name: measure_app\npublish_to: none\n\nenvironment:\n  sdk: ^3.12.0\n\n'
        'dependencies:\n  flutter:\n    sdk: flutter\n  go_router: ^18.0.0\n',
  );
  final imports = StringBuffer();
  final routes = StringBuffer();
  for (var i = 0; i < features; i++) {
    write(
      'lib/ui/feature_$i/view_models/feature_${i}_view_model.dart',
      "import 'package:flutter/foundation.dart';\n\n"
          "/// Feature $i's state.\n"
          'class Feature${i}ViewModel extends ChangeNotifier {\n'
          '  /// How many times it was tapped.\n'
          '  int taps = 0;\n'
          '}\n',
    );
    write(
      'lib/ui/feature_$i/widgets/feature_${i}_screen.dart',
      "import 'package:flutter/widgets.dart';\n\n"
          "import '../view_models/feature_${i}_view_model.dart';\n\n"
          "/// Feature $i's screen.\n"
          'class Feature${i}Screen extends StatelessWidget {\n'
          '  /// Creates the screen.\n'
          '  const Feature${i}Screen({super.key, required this.viewModel});\n\n'
          '  /// Its state.\n'
          '  final Feature${i}ViewModel viewModel;\n\n'
          '  @override\n'
          "  Widget build(BuildContext context) => Text('\${viewModel.taps}');\n"
          '}\n',
    );
    imports
      ..writeln(
        "import '../ui/feature_$i/view_models/feature_${i}_view_model.dart';",
      )
      ..writeln("import '../ui/feature_$i/widgets/feature_${i}_screen.dart';");
    routes.writeln(
      "    GoRoute(path: '/feature-$i', builder: (context, state) => "
      'Feature${i}Screen(viewModel: Feature${i}ViewModel())),',
    );
  }
  write(
    'lib/routing/router.dart',
    "import 'package:go_router/go_router.dart';\n\n$imports\n"
        '/// The router.\n'
        'GoRouter router() => GoRouter(\n  routes: [\n$routes  ],\n);\n',
  );
  write(
    'lib/main.dart',
    "import 'routing/router.dart';\n\n/// Starts the app.\n"
        'void main() => router();\n',
  );
  // The native files of a new Flutter app, from the engine's test fixture
  // (the tool runs from the repo root).
  final template = p.join(
    'packages',
    'appstein_engine',
    'test',
    'fixtures',
    'native',
    'template_app',
  );
  for (final file in Directory(template).listSync(recursive: true)) {
    if (file is! File || !file.path.endsWith('.fixture')) continue;
    final relative = p.relative(file.path, from: template);
    if (!relative.startsWith('android') && !relative.startsWith('ios')) {
      continue;
    }
    write(
      relative.substring(0, relative.length - '.fixture'.length),
      file.readAsStringSync(),
    );
  }
}
