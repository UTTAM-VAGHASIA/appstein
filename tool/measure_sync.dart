import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Measures `appstein sync` against spec §15, on generated official_mvvm apps
/// with a new app's `android/` and `ios/` files:
/// - a full sync of a 200-file app, with fresh packages and no analyzer
///   cache: under 30 s;
/// - `sync --detect` on that app when nothing changed, after one edit of a
///   view model, and after one edit of the router: each under 2 s, as the
///   median of three runs (three different edits), because a CI machine's
///   speed varies by about 2x from run to run. The table shows the three
///   times beside the median;
/// - each MCP tool's answer on that app, from fresh knowledge, in one
///   `appstein mcp` process: under 1 s, as the median of three;
/// - `appstein docs` on that app, from fresh knowledge: writing every page,
///   then with nothing to write, and `docs --check`, each under 2 s (the
///   last two as the median of three). It also checks what the real command
///   does: the pages are written, a second run changes nothing, and
///   `--check` after a hand edit exits 1, names the page and writes nothing.
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
/// network). Prints a Markdown table, then a second one with where the time
/// of each full sync and edit went, step by step (`appstein sync --timings`),
/// and exits 1 when a held row misses its target or a check fails.
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
  try {
    final exe = await _compile(work.path);
    if (exe == null) {
      exitCode = 1;
      return;
    }
    final columns = <int, Map<String, Duration>>{};
    // The three runs behind each median row, in the order they ran.
    final spreads = <int, Map<String, List<Duration>>>{};
    // The runs whose steps the second table breaks down.
    final broken = <String, _Run>{};
    var missed = <String>[];
    final mcp = <String, List<Duration>>{};
    for (final (files, held) in const [(200, true), (1000, false)]) {
      final app = p.join(work.path, 'app $files');
      _generateApp(app, features: (files - 2) ~/ 2);
      Future<_Run> sync([List<String> flags = const []]) =>
          _run(exe, app, flutterRoot, flags);
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
      // real slowdown still moves the median.
      final runs = spreads[files] = {};
      void record(String row, List<_Run> three) {
        final median = _median(three);
        times[row] = median.elapsed;
        runs[row] = [for (final run in three) run.elapsed];
      }

      // The first detect empties the change list the full sync recorded;
      // the next ones are what a hook sees after a command that changed
      // nothing.
      await sync(const ['--detect']);
      final unchanged = <_Run>[];
      for (var i = 0; i < 3; i++) {
        final run = await sync(const ['--detect']);
        if (!run.stdout.startsWith('Knowledge is current')) {
          stderr.writeln(
            'A detect with nothing changed rebuilt:\n${run.stdout}',
          );
          exitCode = 1;
          return;
        }
        unchanged.add(run);
      }
      record('unchanged', unchanged);

      // Three different edits of one view model, each followed by a detect.
      const viewModel =
          'lib/ui/feature_5/view_models/feature_5_view_model.dart';
      final edited = <_Run>[];
      for (var i = 0; i < 3; i++) {
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
          return;
        }
        edited.add(run);
      }
      record('viewModel', edited);
      broken['view model edit (median), $files'] = _median(edited);

      final router = <_Run>[];
      for (var i = 0; i < 3; i++) {
        _edit(
          p.join(app, 'lib', 'routing', 'router.dart'),
          "'/feature-$i'",
          "'/feature-$i-renamed'",
        );
        final run = await sync(const ['--detect']);
        if (run.problem() case final problem?) {
          stderr.writeln('A detect after the router edit: $problem');
          exitCode = 1;
          return;
        }
        router.add(run);
      }
      record('router', router);
      broken['router edit (median), $files'] = _median(router);

      if (held) {
        // The knowledge is fresh after the last detect, so these measure
        // spec §15's "MCP tool responses < 1 s from fresh knowledge". The
        // first call starts the server; it is not counted.
        final session = await _McpSession.start(exe, app, flutterRoot);
        try {
          await session.call('overview', const {});
          for (final (tool, arguments) in _mcpCalls) {
            final three = <Duration>[];
            for (var i = 0; i < 3; i++) {
              three.add(await session.call(tool, arguments));
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
            _run(exe, app, flutterRoot, flags, command: 'docs');
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
          if (full.elapsed >= const Duration(seconds: 30))
            'a full sync took ${full.elapsed.inMilliseconds} ms (under 30 s)',
          if (times['unchanged']! >= const Duration(seconds: 2))
            'a detect with nothing changed took ${took('unchanged')}, the '
                'median of three (under 2 s)',
          if (times['viewModel']! >= const Duration(seconds: 2))
            'a detect after one edit took ${took('viewModel')}, the median '
                'of three (under 2 s)',
          if (times['router']! >= const Duration(seconds: 2))
            'a detect after a router edit took ${took('router')}, the '
                'median of three (under 2 s)',
          for (final MapEntry(key: tool, value: three) in mcp.entries)
            if ((three.toList()..sort())[1] >= const Duration(seconds: 1))
              'the MCP tool $tool took ${(three.toList()..sort())[1].inMilliseconds} ms, '
                  'the median of three (under 1 s)',
        ];
      }
    }
    String cell(int files, String row) {
      // The docs rows are measured on the 200-file app only.
      if (!columns[files]!.containsKey(row)) return 'not measured';
      final median = '${columns[files]![row]!.inMilliseconds} ms';
      final three = spreads[files]![row];
      return three == null
          ? median
          : '$median (${three.map((time) => time.inMilliseconds).join(', ')})';
    }

    String line(String label, String row) =>
        '| $label | ${cell(200, row)} | ${cell(1000, row)} |';
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
''');
    stdout.writeln(_breakdown(broken));
    stdout.writeln('''
| MCP answer on the 200-file app (one `appstein mcp` process) | median of 3 (target under 1 s) |
|---|---|
${[for (final MapEntry(key: tool, value: three) in mcp.entries) '| `$tool` | ${(three.toList()..sort())[1].inMilliseconds} ms (${three.map((d) => d.inMilliseconds).join(', ')}) |'].join('\n')}
''');
    if (missed.isNotEmpty) {
      stderr.writeln('Spec §15 targets missed on the 200-file app:');
      for (final miss in missed) {
        stderr.writeln('  $miss');
      }
      exitCode = 1;
    }
  } finally {
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

/// One `appstein mcp` process and a minimal JSON-RPC client over its stdin
/// and stdout: enough to time tool calls as an agent makes them.
final class _McpSession {
  _McpSession._(this._process, this._lines);

  final Process _process;
  final StreamIterator<String> _lines;
  var _id = 0;

  static Future<_McpSession> start(
    String exe,
    String app,
    String flutterRoot,
  ) async {
    final process = await Process.start(
      exe,
      ['--project', app, 'mcp'],
      environment: {'FLUTTER_ROOT': flutterRoot},
    );
    unawaited(process.stderr.drain<void>());
    final session = _McpSession._(
      process,
      StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
    );
    await session._request('initialize', {
      'protocolVersion': '2025-11-25',
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'measure_sync', 'version': '1'},
    });
    session._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    return session;
  }

  void _send(Map<String, Object?> message) =>
      _process.stdin.writeln(jsonEncode(message));

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) async {
    final id = ++_id;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    while (await _lines.moveNext()) {
      final message = jsonDecode(_lines.current) as Map<String, Object?>;
      if (message['id'] != id) continue;
      if (message['error'] case final error?) {
        throw StateError('$method failed: $error');
      }
      return message['result']! as Map<String, Object?>;
    }
    throw StateError('appstein mcp exited before answering $method');
  }

  /// How long [tool] took to answer; throws when it answered with an error.
  Future<Duration> call(String tool, Map<String, Object?> arguments) async {
    final watch = Stopwatch()..start();
    final result = await _request('tools/call', {
      'name': tool,
      'arguments': arguments,
    });
    watch.stop();
    if (result['isError'] == true) {
      throw StateError(
        '$tool answered with an error: ${jsonEncode(result['content'])}',
      );
    }
    return watch.elapsed;
  }

  /// Ends the server by closing its stdin, as an agent does.
  ///
  /// The iterator is cancelled too: between reads it holds its subscription
  /// to the server's stdout paused, and a paused subscription keeps this
  /// process alive after `main` returns.
  Future<void> close() async {
    await _process.stdin.close();
    await _process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _process.kill();
        return _process.exitCode;
      },
    );
    await _lines.cancel();
  }
}

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

Future<_Run> _run(
  String exe,
  String app,
  String flutterRoot,
  List<String> flags, {
  String command = 'sync',
}) async {
  final watch = Stopwatch()..start();
  final result = await Process.run(
    exe,
    ['--project', app, command, if (command == 'sync') '--timings', ...flags],
    environment: {'FLUTTER_ROOT': flutterRoot},
  );
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
