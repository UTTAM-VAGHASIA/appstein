import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Measures the Dart analysis server that `appstein verify`'s code checks
/// ask (slice 1d.2, decision record 0001), in three arrangements: over LSP,
/// over the legacy analyzer protocol, and over the legacy protocol behind a
/// guard process.
///
/// The guard is this tool's `--guard` mode: a process that starts the
/// server, passes its stdin and stdout through, and ends the server when its
/// own stdin closes. It exists because a legacy server doesn't end when its
/// stdin closes or its parent is killed. It is measured compiled
/// (`dart compile exe`) and run by `dart`.
///
/// The tool generates the 200-file app of `measure_sync.dart`, with
/// `flutter_lints` and a few files that have findings, fetches its packages,
/// and then:
/// - starts the server three times in each arrangement, without and with the
///   `appstein_lints` plugin, and prints the median time until it is ready
///   and the memory of its process tree at that moment. "Ready" is the
///   moment the server said its analysis was done and, with the plugin, the
///   plugin's diagnostic had arrived for each of the three canary files. The
///   time at which the server said it was done is printed beside it, because
///   over LSP that comes before the plugin has finished;
/// - asks the four questions of the code analysis on a ready server: the
///   diagnostics after an edit on disk (plugin rules included), whether one
///   diagnostic can be fixed automatically, the pending fixes per file and
///   code, and whether a file's formatting would change;
/// - runs `dart fix --dry-run`, compares its fixes with the legacy
///   protocol's, and records the most memory its processes held;
/// - stops the server in several ways (the protocol's own request, closing
///   its stdin, killing its parent, killing only the guard) and says whether
///   its process ended, at once or after the next edit of a project file.
///
/// The first start with the plugin builds the plugin for the new app, and is
/// printed in its own row.
///
/// Usage, from the repo root:
///   fvm dart run tool/measure_analysis_server.dart [--work `folder`]
///
/// The app is made in a new folder inside `--work` (the system's temporary
/// folder by default). `flutter pub get` needs the network. It prints
/// Markdown tables and exits 1 when a measurement is broken: the plugin
/// didn't report, a server never became ready or ended early, or the pending
/// fixes differ from `dart fix --dry-run`. A whole run takes about seventeen
/// minutes. Every process it starts is recorded and ended before it exits,
/// also when it is interrupted with Ctrl+C.
Future<void> main(List<String> args) async {
  if (args case ['--guard', final dart]) {
    await _guard(dart);
    return;
  }
  if (args case ['--hold', final kind, final app, final guard]) {
    _guardExe = guard;
    await _hold(app, _Kind.values.byName(kind));
    return;
  }
  final Directory parent;
  switch (args) {
    case []:
      parent = Directory.systemTemp;
    case ['--work', final folder] when Directory(folder).existsSync():
      parent = Directory(folder);
    default:
      stderr.writeln(
        'Usage: fvm dart run tool/measure_analysis_server.dart '
        '[--work <folder>], where the folder exists.',
      );
      exitCode = 1;
      return;
  }
  final dart = Platform.resolvedExecutable;
  final flutterRoot = _flutterRoot();
  if (flutterRoot == null) {
    stderr.writeln(
      'Run this with the Dart of a Flutter SDK (fvm dart run '
      'tool/measure_analysis_server.dart): $dart is not inside one.',
    );
    exitCode = 1;
    return;
  }
  final work = parent.createTempSync('appstein measure server ');
  stderr.writeln('Measuring in ${work.path}');

  Future<void> cleanUp() async {
    await _endStarted();
    // A process that was just ended may hold a file for a moment longer.
    for (var attempt = 1; ; attempt++) {
      try {
        work.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 10) {
          stderr.writeln(
            'warning: could not delete ${work.path}; remove it by hand',
          );
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  // Ctrl+C: end every process this run started before leaving.
  final interrupt = ProcessSignal.sigint.watch().listen((_) async {
    stderr.writeln('Interrupted: ending the servers this run started.');
    await cleanUp();
    exit(130);
  });
  try {
    final app = p.join(work.path, 'app 200');
    _generateApp(app, lints: p.join(Directory.current.path, 'packages'));
    final get = await Process.run(
      p.join(
        flutterRoot,
        'bin',
        Platform.isWindows ? 'flutter.bat' : 'flutter',
      ),
      ['pub', 'get'],
      workingDirectory: app,
    );
    if (get.exitCode != 0) {
      throw _Broken('flutter pub get failed:\n${get.stdout}${get.stderr}');
    }
    _guardExe = p.join(work.path, Platform.isWindows ? 'guard.exe' : 'guard');
    final compile = await Process.run(dart, [
      'compile',
      'exe',
      Platform.script.toFilePath(),
      '-o',
      _guardExe,
    ]);
    if (compile.exitCode != 0) {
      throw _Broken(
        'could not compile the guard:\n${compile.stdout}${compile.stderr}',
      );
    }

    // Starts: three per arrangement, without and then with the plugin. The
    // guard is started with the plugin only. The last server of each
    // arrangement with the plugin, but the guard run by `dart`, is kept for
    // the questions.
    final starts = <(_Kind, bool), List<_Start>>{};
    final stops = <String, String>{};
    final kept = <_Kind, _Server>{};
    final first = <bool, _Start>{};
    for (final plugin in [false, true]) {
      _writeOptions(app, plugin: plugin);
      {
        // The first start of all fills the server's cache for this app,
        // and the first with the plugin builds the plugin for it. Neither
        // is one of the three.
        final (server, start) = await _start(
          dart,
          app,
          _Kind.legacy,
          plugin: plugin,
        );
        first[plugin] = start;
        stderr.writeln(
          'Legacy, plugin ${plugin ? 'on' : 'off'}, first start: '
          '${_seconds(start.ready)}, ${_gigabytes(start.memory)}',
        );
        await server.shutdown();
      }
      for (final kind in _Kind.values) {
        if (kind.guarded && !plugin) continue;
        final runs = starts[(kind, plugin)] = [];
        for (var i = 0; i < 3; i++) {
          final (server, start) = await _start(dart, app, kind, plugin: plugin);
          runs.add(start);
          stderr.writeln(
            '${kind.label}, plugin ${plugin ? 'on' : 'off'}, start ${i + 1}: '
            '${_seconds(start.ready)}, ${_gigabytes(start.memory)}',
          );
          if (plugin && i == 0 && kind != _Kind.guardVm) {
            stops['${kind.label}: its stdin is closed'] = await _closeStdin(
              server,
            );
          } else if (plugin && i == 2 && kind != _Kind.guardVm) {
            kept[kind] = server;
          } else {
            await server.shutdown();
          }
        }
      }
    }

    // The four questions, on a ready server with the plugin on.
    final answers = <_Kind, _Answers>{};
    for (final MapEntry(key: kind, value: server) in kept.entries) {
      answers[kind] = await _ask(server, app);
      final watch = Stopwatch()..start();
      final code = await server.shutdown();
      stops['${kind.label}: asked to stop '
              '(${kind.isLsp ? '`shutdown`, then `exit`' : '`server.shutdown`'})'] =
          code == null
          ? 'STILL RUNNING after 10 s (the tool ended it)'
          : 'ended with exit code $code after '
                '${watch.elapsedMilliseconds} ms';
    }

    // A killed parent, three times for each arrangement, and a killed guard.
    for (final kind in kept.keys) {
      final results = <String>[];
      for (var i = 0; i < 3; i++) {
        results.add(await _killParent(dart, app, kind));
        stderr.writeln(
          '${kind.label}, parent killed ${i + 1}: ${results.last}',
        );
      }
      stops['${kind.label}: its parent process is killed (3 runs)'] = results
          .join('; ');
    }
    {
      final results = <String>[];
      for (var i = 0; i < 3; i++) {
        results.add(await _killGuard(dart, app));
        stderr.writeln('Guard killed ${i + 1}: ${results.last}');
      }
      stops['${_Kind.guardExe.label}: only the guard is killed (3 runs)'] =
          results.join('; ');
    }

    // What `dart fix --dry-run` prints for the same project, and the most
    // memory its processes held.
    final cliWatch = Stopwatch()..start();
    final cli = await Process.start(dart, [
      'fix',
      '--dry-run',
    ], workingDirectory: app);
    _started.add(cli.pid);
    unawaited(cli.stderr.drain<void>());
    final cliOutput = cli.stdout.transform(utf8.decoder).join();
    final cliPeak = await _peakMemory(cli.pid, cli.exitCode);
    final cliCode = await cli.exitCode;
    cliWatch.stop();
    final cliTotals = _cliFixes(await cliOutput);

    String startRow(_Kind kind, bool plugin) {
      final runs = starts[(kind, plugin)]!;
      int median(int Function(_Start) of) => _median(runs.map(of).toList());
      Duration time(Duration Function(_Start) of) =>
          Duration(milliseconds: median((run) => of(run).inMilliseconds));
      return '| ${kind.label}, plugin ${plugin ? 'on' : 'off'} '
          '| ${_seconds(time((run) => run.ready))} '
          '(${runs.map((run) => _seconds(run.ready)).join(', ')}) '
          '| ${_seconds(time((run) => run.saidDone))} '
          '| ${_gigabytes(median((run) => run.memory))} '
          '| ${kind.guarded ? _megabytes(median((run) => run.guardMemory)) : ''} |';
    }

    String firstRow(String what, _Start start) =>
        '| $what | ${_seconds(start.ready)} | ${_seconds(start.saidDone)} '
        '| ${_gigabytes(start.memory)} | |';

    stdout.writeln('''
| Analysis server start (${Platform.operatingSystem}, 200-file app), median of 3 | Ready | Said its analysis was done | Memory when ready | Of which the guard |
|---|---|---|---|---|
${[
      for (final plugin in [false, true])
        for (final kind in _Kind.values)
          if (starts.containsKey((kind, plugin))) startRow(kind, plugin),
    ].join('\n')}
${firstRow('Legacy, plugin off, the first start for this app (one run)', first[false]!)}
${firstRow('Legacy, plugin on, the first start with the plugin, which builds it (one run)', first[true]!)}
''');

    final columns = answers.keys.toList();
    String row(String what, String Function(_Answers) of) =>
        '| $what | ${columns.map((kind) => of(answers[kind]!)).join(' | ')} |';
    stdout.writeln('''
| Question, on a ready server with the plugin on | ${columns.map((kind) => kind.label).join(' | ')} |
|---|${columns.map((_) => '---|').join()}
${row('Edit on disk until the file\'s and its importer\'s diagnostics arrive, median of 3', (x) => '${x.errorEdit} ms')}
${row('Edit on disk until the plugin\'s diagnostic arrives, median of 10', (x) => '${x.pluginEdit} ms')}
${row('After those 10 edits, the server said it was done after the plugin\'s diagnostic, and sent no diagnostics later', (x) => x.doneCoversPlugin)}
${row('One file\'s list holds the analyzer\'s and the plugin\'s diagnostics together', (x) => x.merged ? 'yes' : 'NO')}
${row('Can this diagnostic be fixed: a deprecated use with a migration', (x) => x.fixable)}
${row('Can this diagnostic be fixed: a deprecated use without one', (x) => x.notFixable)}
${row('Pending fixes, one request', (x) => x.onePass)}
${row('Pending fixes, complete', (x) => x.complete)}
${row('Most memory held while the pending fixes were asked', (x) => _gigabytes(x.fixPeak))}
${row('Would formatting change: an unformatted file / a formatted file, median of 3 each', (x) => x.format)}
${row('Project files changed by these questions', (x) => x.wrote ? 'YES' : 'none')}
''');
    final legacy = answers[_Kind.legacy]!;
    stdout.writeln(legacy.notes.map((note) => '- $note').join('\n'));
    stdout.writeln('''

| Pending fixes (file and code) | Legacy, complete | `dart fix --dry-run` |
|---|---|---|
${{...legacy.totals.keys, ...cliTotals.keys}.map((key) => '| $key | ${legacy.totals[key] ?? 0} | ${cliTotals[key] ?? 0} |').join('\n')}

A cold `dart fix --dry-run` took ${_seconds(cliWatch.elapsed)}, and its processes held at most ${_gigabytes(cliPeak)} (one run, the plugin on).

| Stopping the server | What happened |
|---|---|
${stops.entries.map((stop) => '| ${stop.key} | ${stop.value} |').join('\n')}
''');

    final problems = [
      if (cliCode != 0) '`dart fix --dry-run` exited $cliCode',
      if (!_same(legacy.totals, cliTotals))
        'the complete pending fixes differ from `dart fix --dry-run`',
      if (legacy.totals.isEmpty) 'no pending fixes were found',
      if (answers.values.any((answer) => answer.wrote))
        'a question changed a project file',
    ];
    if (problems.isNotEmpty) {
      stderr.writeln('Broken measurement: ${problems.join('; ')}.');
      exitCode = 1;
    }
  } on _Broken catch (broken) {
    stderr.writeln('Broken measurement: ${broken.message}');
    exitCode = 1;
  } finally {
    await interrupt.cancel();
    await cleanUp();
  }
  // The servers' output streams would keep this process alive.
  exit(exitCode);
}

/// The arrangements measured.
enum _Kind {
  lsp('LSP'),
  legacy('Legacy'),
  guardExe('Legacy behind a compiled guard'),
  guardVm('Legacy behind a guard run by `dart`');

  const _Kind(this.label);

  /// Its name in the tables.
  final String label;

  bool get isLsp => this == lsp;

  bool get guarded => this == guardExe || this == guardVm;
}

/// How long the tool itself waits for a server before it gives up. It is far
/// above the limit the measurement is meant to help choose.
const _patience = Duration(minutes: 10);

/// The files with a deliberate layer violation. In the runs so far the
/// plugin reported the first two early and the third late. With the plugin
/// on, a server is ready only when `layer_imports` has arrived for each:
/// over LSP nothing else says the plugin has finished.
const _canaries = [
  'lib/data/canary.dart',
  'lib/domain/canary.dart',
  'lib/zz/canary.dart',
];

/// The file with pending fixes that is also unformatted.
const _legacyFile = 'lib/ui/legacy/legacy.dart';

/// The file with a deprecated use `dart fix` has no migration for.
const _ownUse = 'lib/ui/legacy/own_use.dart';

/// The compiled guard.
late final String _guardExe;

/// The process IDs of every process this run started (servers, guards,
/// holders, `dart fix`) or found under one it started, so none is left
/// behind whatever happens. Nothing else is ever ended.
final _started = <int>{};

/// Ends every process in [_started] that is still running.
Future<void> _endStarted() => _end(_started.toList());

/// Ends those of the processes [ids] that are still running. Every ID
/// given here is one this run started.
Future<void> _end(Iterable<int> ids) async {
  for (final id in ids) {
    if (await _alive(id)) Process.killPid(id, ProcessSignal.sigkill);
  }
}

String _seconds(Duration time) =>
    '${(time.inMilliseconds / 1000).toStringAsFixed(1)} s';

String _gigabytes(int bytes) =>
    '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';

String _megabytes(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

bool _same(Map<String, int> a, Map<String, int> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

int _median(List<int> values) => (values.toList()..sort())[values.length ~/ 2];

/// A measurement that can't be trusted, with the reason.
final class _Broken implements Exception {
  _Broken(this.message);

  final String message;
}

/// One start of the server: when it was ready, when it said its analysis
/// was done, the memory of its process tree when ready, and how much of
/// that was the guard's.
final class _Start {
  _Start(this.ready, this.saidDone, this.memory, this.guardMemory);

  final Duration ready;
  final Duration saidDone;
  final int memory;
  final int guardMemory;
}

/// Starts a server on [app] and waits until it is ready.
Future<(_Server, _Start)> _start(
  String dart,
  String app,
  _Kind kind, {
  required bool plugin,
}) async {
  final server = await _Server.start(dart, app, kind);
  await server.until(() => server.saidDone != null, 'its first analysis');
  if (plugin) {
    await server.until(
      () => _canaries.every(
        (canary) => server.count(p.join(app, canary), 'layer_imports') > 0,
      ),
      'the plugin\'s diagnostics (did the plugin run?)',
    );
  }
  final ready = server.elapsed;
  final rows = await _processes();
  final all = _memory(rows, server.process.pid);
  return (
    server,
    _Start(
      ready,
      server.saidDone!,
      all,
      kind.guarded ? all - _memory(rows, server.serverPid) : 0,
    ),
  );
}

/// What one arrangement answered to the four questions.
final class _Answers {
  late int errorEdit;
  late int pluginEdit;
  late String doneCoversPlugin;
  late bool merged;
  late String fixable;
  late String notFixable;
  late String onePass;
  late String complete;
  late int fixPeak;
  late String format;
  late bool wrote;

  /// The complete pending fixes, `file code` to count. Legacy only.
  var totals = <String, int>{};

  /// Facts that fit no column.
  final notes = <String>[];
}

/// Asks a ready [server] the four questions of the code analysis.
Future<_Answers> _ask(_Server server, String app) async {
  final answers = _Answers();
  final before = _snapshot(app);
  String file(String relative) => p.joinAll([app, ...relative.split('/')]);

  // 1. Diagnostics after an edit on disk. The server is told nothing: its
  // own file watcher must notice.
  final viewModel = file(
    'lib/ui/feature_5/view_models/feature_5_view_model.dart',
  );
  final screen = file('lib/ui/feature_5/widgets/feature_5_screen.dart');
  final canary = file(_canaries[1]);
  final viewModelText = File(viewModel).readAsStringSync();
  final canaryText = File(canary).readAsStringSync();
  final errorEdits = <int>[];
  for (var i = 0; i < 3; i++) {
    final edit = await _edit(
      server,
      viewModel,
      viewModelText.replaceFirst('int taps = 0;', 'String taps$i = 0;'),
      () => server.of(viewModel).isNotEmpty && server.of(screen).isNotEmpty,
    );
    errorEdits.add(edit.seen);
    await _edit(
      server,
      viewModel,
      viewModelText,
      () => server.of(viewModel).isEmpty && server.of(screen).isEmpty,
    );
  }
  // Ten edits that each add a second layer violation to a canary.
  final pluginEdits = <int>[];
  var covered = 0;
  for (var i = 0; i < 10; i++) {
    final edit = await _edit(
      server,
      canary,
      "import '../ui/feature_${i + 1}/view_models/"
      "feature_${i + 1}_view_model.dart';\n$canaryText\n"
      '/// More.\nFeature${i + 1}ViewModel more() => '
      'Feature${i + 1}ViewModel();\n',
      () => server.count(canary, 'layer_imports') == 2,
    );
    pluginEdits.add(edit.seen);
    if (edit.done != null &&
        edit.done! >= edit.seen &&
        !edit.laterDiagnostics) {
      covered++;
    }
    await _edit(
      server,
      canary,
      canaryText,
      () => server.count(canary, 'layer_imports') == 1,
    );
  }
  answers
    ..errorEdit = _median(errorEdits)
    ..pluginEdit = _median(pluginEdits)
    ..doneCoversPlugin = 'in $covered of 10';
  final both = file(_canaries[0]);
  answers.merged =
      server.count(both, 'layer_imports') == 1 &&
      server.count(both, 'unused_import') == 1;

  // 2. Can one diagnostic be fixed automatically.
  Future<String> fixes(String path, String code) async {
    final diagnostic = server
        .of(path)
        .where((d) => '${d['code']}' == code)
        .firstOrNull;
    if (diagnostic == null) {
      throw _Broken(
        '${server.kind.label}: no $code in $path, which has '
        '${server.of(path).map((d) => d['code']).toList()}.',
      );
    }
    final watch = Stopwatch()..start();
    final found = await server.fixes(path, diagnostic);
    return '${found.isEmpty ? 'no fix named' : found.map((f) => '`$f`').join(', ')} '
        '(${watch.elapsedMilliseconds} ms)';
  }

  final legacy = file(_legacyFile);
  answers
    ..fixable = await fixes(legacy, 'deprecated_member_use')
    ..notFixable = await fixes(
      file(_ownUse),
      'deprecated_member_use_from_same_package',
    );

  // 3. Pending fixes, with the most memory the server held meanwhile.
  final asked = Completer<void>();
  final peak = _peakMemory(server.process.pid, asked.future);
  if (server.lsp) {
    final times = <int>[];
    var edits = <String, String>{};
    var named = false;
    var count = 0;
    for (var i = 0; i < 3; i++) {
      server.applyEdits.clear();
      final watch = Stopwatch()..start();
      await server.request('workspace/executeCommand', {
        'command': 'dart.edit.fixAllInWorkspace.preview',
      });
      times.add(watch.elapsedMilliseconds);
      named = jsonEncode(server.applyEdits).contains('deprecated_member_use');
      (edits, count) = _applyLspEdits(server.applyEdits);
    }
    _lspPreview = edits;
    answers
      ..onePass =
          '$count edits in ${edits.length} file(s), with line ranges and '
          '${named ? 'the fix codes' : 'no fix codes or counts'} '
          '(${_median(times)} ms, median of 3)'
      ..complete = 'not available: one request is one pass, and no codes';
  } else {
    final times = <int>[];
    late _LegacyFixes result;
    for (var i = 0; i < 3; i++) {
      final watch = Stopwatch()..start();
      result = await _legacyFixes(server, app);
      times.add(watch.elapsedMilliseconds);
    }
    final first = result.firstPass.values.fold(0, (sum, n) => sum + n);
    final all = result.totals.values.fold(0, (sum, n) => sum + n);
    answers
      ..totals = result.totals
      ..onePass =
          '$first fixes per file and code with counts, no line numbers '
          '(${result.firstPassTime} ms)'
      ..complete =
          '$all fixes in ${result.passes} passes with edits and one that '
          'finds none (${_median(times)} ms, median of 3)';
    if (server.kind == _Kind.legacy) {
      final preview = _lspPreview;
      if (preview != null) {
        answers.notes.add(
          'The text after LSP\'s one preview '
          '${_sameText(preview, result.afterFirstPass) ? 'equals' : 'differs from'} '
          'the text after the legacy protocol\'s first pass, and '
          '${_sameText(preview, result.afterLastPass) ? 'equals' : 'differs from'} '
          'the text after its last pass.',
        );
      }
      final errors = await server.request('analysis.getErrors', {
        'file': canary,
      });
      final codes = [
        for (final error in (errors! as Map)['errors'] as List)
          '${(error as Map)['code']}',
      ];
      answers.notes.add(
        'Legacy `analysis.getErrors` on a file with one plugin diagnostic '
        'returned ${codes.isEmpty ? 'nothing' : codes.join(', ')}: the '
        'plugin\'s diagnostics come only in the `analysis.errors` '
        'notifications.',
      );
      final carried = await server.request('lsp.handle', {
        'lspMessage': {
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'textDocument/formatting',
          'params': {
            'textDocument': {'uri': Uri.file(legacy).toString()},
            'options': {'tabSize': 2, 'insertSpaces': true},
          },
        },
      });
      final response = ((carried! as Map)['lspResponse'] as Map?)?['result'];
      answers.notes.add(
        'Legacy `lsp.handle` carried an LSP `textDocument/formatting` '
        'request and '
        '${response is List ? 'got ${response.length} edit(s) back' : 'got no result'}: '
        'an LSP request can be sent over the legacy protocol.',
      );
    }
  }
  asked.complete();
  answers.fixPeak = await peak;

  // 4. Would a file's formatting change. Three requests for each file.
  final changes = <bool>[];
  final medians = <int>[];
  for (final path in [legacy, screen]) {
    final times = <int>[];
    for (var i = 0; i < 3; i++) {
      final watch = Stopwatch()..start();
      final would = await server.wouldFormat(path);
      times.add(watch.elapsedMilliseconds);
      if (i == 0) changes.add(would);
    }
    medians.add(_median(times));
  }
  answers
    ..format =
        '${changes[0] ? 'would change' : 'WOULD NOT CHANGE'} '
        '(${medians[0]} ms) / '
        '${changes[1] ? 'WOULD CHANGE' : 'would not change'} '
        '(${medians[1]} ms)'
    ..wrote = !_sameText(before, _snapshot(app));
  return answers;
}

/// The text after LSP's fix preview, kept to compare with the legacy
/// protocol's passes (the LSP server is asked first).
Map<String, String>? _lspPreview;

/// Every Dart file under `lib/` of [app] with its text.
Map<String, String> _snapshot(String app) => {
  for (final file in Directory(p.join(app, 'lib')).listSync(recursive: true))
    if (file is File && file.path.endsWith('.dart'))
      p.canonicalize(file.path): file.readAsStringSync(),
};

bool _sameText(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

/// What followed one edit on disk: the milliseconds until the diagnostics
/// waited for had arrived ([seen]), the milliseconds until the server last
/// said it was done analyzing ([done], null when it never said so), and
/// whether any diagnostics arrived after that ([laterDiagnostics]).
typedef _Edit = ({int seen, int? done, bool laterDiagnostics});

/// Writes [content] to [path], waits until [arrived] holds for what the
/// server sent, and then until it has been quiet for a second.
Future<_Edit> _edit(
  _Server server,
  String path,
  String content,
  bool Function() arrived,
) async {
  await server.settle();
  final from = server.elapsed;
  File(path).writeAsStringSync(content);
  await server.until(arrived, 'the diagnostics after an edit of $path');
  final seen = server.elapsed - from;
  await server.settle(quiet: const Duration(seconds: 1));
  final done = server.statuses
      .where((status) => status.$1 > from && !status.$2)
      .lastOrNull
      ?.$1;
  return (
    seen: seen.inMilliseconds,
    done: done == null ? null : (done - from).inMilliseconds,
    laterDiagnostics: done != null && server.lastDiagnostics > done,
  );
}

/// The legacy protocol's pending fixes, as `dart fix --dry-run` gets them.
final class _LegacyFixes {
  var passes = 0;
  var firstPassTime = 0;
  final firstPass = <String, int>{};
  final totals = <String, int>{};
  var afterFirstPass = <String, String>{};
  var afterLastPass = <String, String>{};
}

/// Asks `edit.bulkFixes` until a pass returns no edits. Each pass's edits
/// are applied to an overlay the server analyzes in place of the file, so
/// nothing is written to disk. The overlays are removed at the end.
Future<_LegacyFixes> _legacyFixes(_Server server, String app) async {
  final result = _LegacyFixes();
  final overlays = <String, String>{};
  while (true) {
    final watch = Stopwatch()..start();
    final answer =
        (await server.request('edit.bulkFixes', {
              'included': [app],
              'inTestMode': false,
              'updatePubspec': false,
            }))!
            as Map<String, Object?>;
    final edits = (answer['edits']! as List).cast<Map<String, Object?>>();
    if (edits.isEmpty) break;
    if (result.passes == 0) result.firstPassTime = watch.elapsedMilliseconds;
    for (final detail
        in (answer['details']! as List).cast<Map<Object?, Object?>>()) {
      for (final fix
          in (detail['fixes']! as List).cast<Map<Object?, Object?>>()) {
        final key =
            '${p.relative(detail['path']! as String, from: app)} '
            '${fix['code']}';
        final count = fix['occurrences']! as int;
        result.totals[key] = (result.totals[key] ?? 0) + count;
        if (result.passes == 0) result.firstPass[key] = count;
      }
    }
    for (final fileEdit in edits) {
      final path = fileEdit['file']! as String;
      var text = overlays[path] ?? File(path).readAsStringSync();
      // The server lists a file's edits last offset first.
      for (final edit
          in (fileEdit['edits']! as List).cast<Map<Object?, Object?>>()) {
        final offset = edit['offset']! as int;
        text = text.replaceRange(
          offset,
          offset + (edit['length']! as int),
          edit['replacement']! as String,
        );
      }
      overlays[path] = text;
    }
    await server.request('analysis.updateContent', {
      'files': {
        for (final overlay in overlays.entries)
          overlay.key: {'type': 'add', 'content': overlay.value},
      },
    });
    final texts = {
      for (final overlay in overlays.entries)
        p.canonicalize(overlay.key): overlay.value,
    };
    if (result.passes == 0) result.afterFirstPass = texts;
    result.afterLastPass = texts;
    result.passes++;
    if (result.passes > 10) throw _Broken('the fix passes never ended');
  }
  await server.request('analysis.updateContent', {
    'files': {
      for (final path in overlays.keys) path: {'type': 'remove'},
    },
  });
  await server.settle();
  return result;
}

/// The text of each file after the `workspace/applyEdit` requests in [asked]
/// (which the tool refused, so nothing was written), and the number of
/// edits.
(Map<String, String>, int) _applyLspEdits(List<Map<String, Object?>> asked) {
  final texts = <String, String>{};
  var count = 0;
  for (final request in asked) {
    final changes =
        ((request['edit'] as Map?)?['documentChanges'] as List?) ?? const [];
    for (final change in changes.cast<Map<Object?, Object?>>()) {
      final path = Uri.parse(
        (change['textDocument']! as Map)['uri'] as String,
      ).toFilePath();
      var text = File(path).readAsStringSync();
      final starts = [0];
      for (var i = 0; i < text.length; i++) {
        if (text.codeUnitAt(i) == 10) starts.add(i + 1);
      }
      int offset(Object? position) {
        final at = position! as Map<Object?, Object?>;
        return starts[at['line']! as int] + (at['character']! as int);
      }

      final edits = (change['edits']! as List).cast<Map<Object?, Object?>>();
      count += edits.length;
      // Every range is in the original text: apply the last one first.
      final ordered = [for (var i = 0; i < edits.length; i++) (i, edits[i])]
        ..sort((a, b) {
          final byStart = offset(
            (b.$2['range']! as Map)['start'],
          ).compareTo(offset((a.$2['range']! as Map)['start']));
          return byStart != 0 ? byStart : b.$1.compareTo(a.$1);
        });
      for (final (_, edit) in ordered) {
        final range = edit['range']! as Map;
        text = text.replaceRange(
          offset(range['start']),
          offset(range['end']),
          edit['newText']! as String,
        );
      }
      texts[p.canonicalize(path)] = text;
    }
  }
  return (texts, count);
}

/// The `file code` to count pairs `dart fix --dry-run` printed.
Map<String, int> _cliFixes(String output) {
  final totals = <String, int>{};
  String? file;
  for (final line in const LineSplitter().convert(output)) {
    final fix = RegExp(r'^  (\S+) [^\w\s] (\d+) fix(es)?$').firstMatch(line);
    if (fix != null && file != null) {
      totals['$file ${fix[1]}'] = int.parse(fix[2]!);
    } else if (line.endsWith('.dart') && !line.startsWith(' ')) {
      file = p.normalize(line);
    }
  }
  return totals;
}

/// Closes [server]'s stdin (the guard's, when there is one) and says
/// whether its processes ended.
Future<String> _closeStdin(_Server server) async {
  final watch = Stopwatch()..start();
  await server.process.stdin.close();
  final code = await server.process.exitCode
      .then<int?>((code) => code)
      .timeout(const Duration(seconds: 15), onTimeout: () => null);
  if (code == null) {
    await _end([server.process.pid, server.serverPid]);
    return 'STILL RUNNING after 15 s (the tool ended it)';
  }
  final time = watch.elapsedMilliseconds;
  if (server.kind.guarded) {
    final gone = await _goneWithin([
      server.serverPid,
    ], const Duration(seconds: 15));
    if (gone == null) {
      await _end([server.serverPid]);
      return 'the guard ended after $time ms, the server was STILL RUNNING '
          '15 s later (the tool ended it)';
    }
    return 'the guard ended with exit code $code after $time ms, and the '
        'server was gone within ${_seconds(gone)} more';
  }
  return 'ended with exit code $code after $time ms';
}

/// How long until none of the processes [ids] is running, or null when one
/// still is after [limit]. A check takes about 0.2 s.
Future<Duration?> _goneWithin(List<int> ids, Duration limit) async {
  final watch = Stopwatch()..start();
  while (true) {
    var any = false;
    for (final id in ids) {
      if (await _alive(id)) any = true;
    }
    if (!any) return watch.elapsed;
    if (watch.elapsed > limit) return null;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Edits a project file of [app] (an error in `main.dart`) and says how long
/// until the processes [ids] are gone, then puts the file back.
Future<String> _afterAnEdit(String app, List<int> ids) async {
  final main = File(p.join(app, 'lib', 'main.dart'));
  final text = main.readAsStringSync();
  main.writeAsStringSync('$text\nint wrong() => "x";\n');
  try {
    final gone = await _goneWithin(ids, const Duration(seconds: 30));
    return gone == null
        ? 'STILL RUNNING 30 s after the next edit of a project file (the '
              'tool ended it)'
        : 'gone within ${_seconds(gone)} of the next edit of a project file';
  } finally {
    main.writeAsStringSync(text);
  }
}

/// Starts this tool again as a parent that holds a ready server, kills that
/// parent, and says whether the server's processes ended: at once, or after
/// the next edit of a project file.
Future<String> _killParent(String dart, String app, _Kind kind) async {
  final holder = await Process.start(dart, [
    Platform.script.toFilePath(),
    '--hold',
    kind.name,
    app,
    _guardExe,
  ]);
  // The holder and, once known, every process under it: what this function
  // must leave ended whatever happens.
  final mine = {holder.pid};
  _started.add(holder.pid);
  try {
    unawaited(holder.stderr.drain<void>());
    String? line;
    try {
      line = await holder.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((line) => line.startsWith('holding '))
          .timeout(_patience);
    } on Object {
      // It failed, or the wait ran out.
    }
    mine.addAll(_tree(await _processes(), holder.pid));
    _started.addAll(mine);
    if (line == null) {
      throw _Broken('${kind.label}: the holding process never held a server.');
    }
    // `dart` may run the script in a child process, so the parent to kill is
    // the process that said it holds the server. The line names it, then
    // the guard (or the server again) and the server.
    final [parent, guard, server] = line
        .split(' ')
        .skip(1)
        .map(int.parse)
        .toList();
    Process.killPid(parent, ProcessSignal.sigkill);
    holder.kill(ProcessSignal.sigkill);
    await holder.exitCode;
    final gone = await _goneWithin(
      {guard, server}.toList(),
      const Duration(seconds: 30),
    );
    if (gone != null) return 'gone within ${_seconds(gone)}';
    return 'still running after 30 s, then ${await _afterAnEdit(app, [guard, server])}';
  } finally {
    await _end(mine);
  }
}

/// Starts a server behind the compiled guard, kills only the guard, and
/// says whether the server ended: while idle, or after the next edit of a
/// project file.
Future<String> _killGuard(String dart, String app) async {
  final (server, _) = await _start(dart, app, _Kind.guardExe, plugin: true);
  try {
    await server.settle();
    Process.killPid(server.process.pid, ProcessSignal.sigkill);
    await server.process.exitCode;
    final gone = await _goneWithin([
      server.serverPid,
    ], const Duration(seconds: 20));
    if (gone != null) return 'the server was gone within ${_seconds(gone)}';
    return 'the server was still running after 20 s with nothing to do, then '
        '${await _afterAnEdit(app, [server.serverPid])}';
  } finally {
    await _end([server.process.pid, server.serverPid]);
  }
}

/// The `--hold` mode: starts a server, waits for its first analysis, prints
/// `holding <this process> <the guard or the server> <the server>` and waits
/// to be killed. If it fails instead, it ends the server it started.
Future<void> _hold(String app, _Kind kind) async {
  try {
    final server = await _Server.start(Platform.resolvedExecutable, app, kind);
    await server.until(() => server.saidDone != null, 'its first analysis');
    stdout.writeln('holding $pid ${server.process.pid} ${server.serverPid}');
    await Future<void>.delayed(const Duration(hours: 1));
  } finally {
    await _endStarted();
  }
}

/// The `--guard` mode: starts a legacy server with [dart], names its
/// process on stderr (`guarding <process ID>`), passes stdin and stdout
/// through, and kills the server when its own stdin closes, which is what
/// happens when the process that started the guard ends in any way.
Future<void> _guard(String dart) async {
  final server = await Process.start(dart, [
    'language-server',
    '--protocol=analyzer',
    '--suppress-analytics',
  ]);
  stderr.writeln('guarding ${server.pid}');
  server.stderr.listen(stderr.add);
  stdin.listen(
    server.stdin.add,
    onDone: () {
      server.kill(ProcessSignal.sigkill);
      exit(0);
    },
    onError: (Object _) {
      server.kill(ProcessSignal.sigkill);
      exit(0);
    },
  );
  // The server ended by itself (it was asked to stop): pass on what it
  // still said, then end with its exit code.
  await stdout.addStream(server.stdout);
  await stdout.flush();
  exit(await server.exitCode);
}

/// Whether a process with this ID is running.
Future<bool> _alive(int id) async {
  if (Platform.isWindows) {
    final list = await Process.run('tasklist', [
      '/FI',
      'PID eq $id',
      '/FO',
      'CSV',
      '/NH',
    ]);
    return '${list.stdout}'.contains('"$id"');
  }
  return (await Process.run('ps', ['-p', '$id'])).exitCode == 0;
}

/// Every running process: its ID, its parent's ID, and the memory it has in
/// use in bytes (working set on Windows, resident set elsewhere).
Future<List<(int, int, int)>> _processes() async {
  final rows = <(int, int, int)>[];
  if (Platform.isWindows) {
    final list = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Get-CimInstance Win32_Process | ForEach-Object { '
          r'"$($_.ProcessId) $($_.ParentProcessId) $($_.WorkingSetSize)" }',
    ]);
    for (final line in const LineSplitter().convert('${list.stdout}')) {
      final numbers = line.trim().split(' ').map(int.tryParse).toList();
      if (numbers case [final id?, final parent?, final bytes?]) {
        rows.add((id, parent, bytes));
      }
    }
  } else {
    final list = await Process.run('ps', ['-A', '-o', 'pid=,ppid=,rss=']);
    for (final line in const LineSplitter().convert('${list.stdout}')) {
      final numbers = line
          .trim()
          .split(RegExp(r'\s+'))
          .map(int.tryParse)
          .toList();
      if (numbers case [final id?, final parent?, final kilobytes?]) {
        rows.add((id, parent, kilobytes * 1024));
      }
    }
  }
  return rows;
}

/// The process [root] and every process under it, from [rows].
Set<int> _tree(List<(int, int, int)> rows, int root) {
  final tree = {root};
  var grew = true;
  while (grew) {
    grew = false;
    for (final (id, parent, _) in rows) {
      if (tree.contains(parent) && tree.add(id)) grew = true;
    }
  }
  return tree;
}

/// The memory of the process [root] and every process under it.
int _memory(List<(int, int, int)> rows, int root) {
  final tree = _tree(rows, root);
  return rows
      .where((row) => tree.contains(row.$1))
      .fold<int>(0, (sum, row) => sum + row.$3);
}

/// The most memory the process [root] and the processes under it held,
/// looked at about once a second until [until] completes.
Future<int> _peakMemory(int root, Future<void> until) async {
  var ended = false;
  unawaited(until.whenComplete(() => ended = true));
  var peak = 0;
  while (!ended) {
    peak = math.max(peak, _memory(await _processes(), root));
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  return peak;
}

/// One analysis server process and a small client for either protocol:
/// enough to wait for its diagnostics and ask the four questions.
final class _Server {
  _Server._(this.process, this.kind);

  /// The process this tool talks to: the server, or the guard in front of
  /// it.
  final Process process;

  /// The arrangement it was started in.
  final _Kind kind;

  /// Whether it speaks LSP; otherwise the legacy analyzer protocol.
  bool get lsp => kind.isLsp;

  /// The server's own process: [process], or the one the guard started.
  late final int serverPid;

  final _watch = Stopwatch()..start();
  final _pending = <String, Completer<Object?>>{};
  final _waiters = <void Function()>[];
  final _bytes = BytesBuilder();
  var _nextId = 0;
  var _lastMessage = Duration.zero;
  var _ended = false;

  /// The latest diagnostics the server sent for each file, as it sent them.
  final diagnostics = <String, List<Map<String, Object?>>>{};

  /// When the server last sent a file's diagnostics.
  Duration lastDiagnostics = Duration.zero;

  /// Each time the server said whether it is analyzing.
  final statuses = <(Duration, bool)>[];

  /// When the server first said its analysis was done.
  Duration? saidDone;

  /// The `workspace/applyEdit` requests the server made (LSP). Each was
  /// answered "not applied".
  final applyEdits = <Map<String, Object?>>[];

  /// The time since the process was started.
  Duration get elapsed => _watch.elapsed;

  /// Starts the server of [dart] on [app], directly or behind a guard, and
  /// tells it the project: over LSP with `initialize`, over the legacy
  /// protocol with `analysis.setAnalysisRoots`.
  ///
  /// `initialize` names this process as the client. That isn't what makes
  /// an LSP server end with its parent: it ends when its stdin closes, also
  /// when `processId` is null (checked in the review of slice 1d.2's ticket
  /// 02).
  static Future<_Server> start(String dart, String app, _Kind kind) async {
    final server = [
      dart,
      'language-server',
      '--protocol=${kind.isLsp ? 'lsp' : 'analyzer'}',
      // A measurement must not report usage to Google.
      '--suppress-analytics',
    ];
    final command = switch (kind) {
      _Kind.lsp || _Kind.legacy => server,
      _Kind.guardExe => [_guardExe, '--guard', dart],
      _Kind.guardVm => [dart, Platform.script.toFilePath(), '--guard', dart],
    };
    final process = await Process.start(command.first, command.sublist(1));
    _started.add(process.pid);
    final self = _Server._(process, kind);
    unawaited(process.exitCode.then((_) => self._end()));
    final guarding = Completer<int>();
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (kind.guarded && line.startsWith('guarding ')) {
            guarding.complete(int.parse(line.substring(9)));
          } else {
            stderr.writeln(line);
          }
        });
    if (kind.guarded) {
      self.serverPid = await guarding.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () =>
            throw _Broken('${kind.label}: the guard did not start.'),
      );
      _started.add(self.serverPid);
    } else {
      self.serverPid = process.pid;
    }
    if (kind.isLsp) {
      process.stdout.listen(self._onBytes);
      await self.request('initialize', {
        'processId': pid,
        'rootUri': Uri.file(app).toString(),
        'capabilities': {
          'workspace': {
            'applyEdit': true,
            // The fix preview is refused without change annotations.
            'workspaceEdit': {
              'documentChanges': true,
              'changeAnnotationSupport': {'groupsOnLabel': true},
            },
          },
          'textDocument': {
            'publishDiagnostics': <String, Object?>{},
            'codeAction': {
              'codeActionLiteralSupport': {
                'codeActionKind': {
                  'valueSet': ['quickfix'],
                },
              },
            },
          },
        },
      });
      self._send({
        'jsonrpc': '2.0',
        'method': 'initialized',
        'params': <String, Object?>{},
      });
    } else {
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            try {
              self._onMessage(jsonDecode(line) as Map<String, Object?>);
            } on FormatException {
              // Not a message.
            }
          });
      await self.request('server.setSubscriptions', {
        'subscriptions': ['STATUS'],
      });
      await self.request('analysis.setAnalysisRoots', {
        'included': [app],
        'excluded': <String>[],
      });
    }
    return self;
  }

  /// The latest diagnostics for [path].
  List<Map<String, Object?>> of(String path) =>
      diagnostics[p.canonicalize(path)] ?? const [];

  /// How many of [path]'s latest diagnostics have [code].
  int count(String path, String code) =>
      of(path).where((d) => '${d['code']}'.endsWith(code)).length;

  /// Sends a request and returns its result; throws when the server
  /// answers with an error, and [_Broken] when its process has ended.
  Future<Object?> request(String method, Object? params) {
    if (_ended) {
      throw _Broken('${kind.label}: the server ended before $method.');
    }
    final id = ++_nextId;
    final completer = _pending['$id'] = Completer();
    _send(
      lsp
          ? {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}
          : {'id': '$id', 'method': method, 'params': ?params},
    );
    return completer.future;
  }

  /// Completes when [test] holds, checked each time a message arrives.
  /// Throws [_Broken] naming [what] after [_patience], or when the server's
  /// process ends first.
  Future<void> until(bool Function() test, String what) {
    if (test()) return Future.value();
    if (_ended) {
      throw _Broken('${kind.label}: the server ended while waiting for $what.');
    }
    final completer = Completer<void>();
    late void Function() waiter;
    final timer = Timer(_patience, () {
      _waiters.remove(waiter);
      if (!completer.isCompleted) {
        completer.completeError(
          _Broken('${kind.label}: no sign in 10 minutes of $what.'),
        );
      }
    });
    waiter = () {
      if (completer.isCompleted) return;
      if (test()) {
        _waiters.remove(waiter);
        completer.complete();
      } else if (_ended) {
        _waiters.remove(waiter);
        completer.completeError(
          _Broken('${kind.label}: the server ended while waiting for $what.'),
        );
      }
    };
    _waiters.add(waiter);
    return completer.future.whenComplete(timer.cancel);
  }

  /// Waits until the server isn't analyzing and has sent nothing for
  /// [quiet]. Throws [_Broken] when that takes more than a minute or the
  /// server's process ends.
  Future<void> settle({
    Duration quiet = const Duration(milliseconds: 300),
  }) async {
    final watch = Stopwatch()..start();
    while (true) {
      if (_ended) {
        throw _Broken('${kind.label}: the server ended while it was awaited.');
      }
      if (watch.elapsed > const Duration(minutes: 1)) {
        throw _Broken(
          '${kind.label}: the server was never quiet for a minute.',
        );
      }
      final analyzing = statuses.isNotEmpty && statuses.last.$2;
      if (!analyzing && elapsed - _lastMessage >= quiet) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  /// The fixes the server offers for [diagnostic] in [path], by the names
  /// it gives them, without those that only add an `ignore`.
  Future<List<String>> fixes(
    String path,
    Map<String, Object?> diagnostic,
  ) async {
    final List<String> names;
    if (lsp) {
      final actions =
          (await request('textDocument/codeAction', {
                'textDocument': {'uri': Uri.file(path).toString()},
                'range': diagnostic['range'],
                'context': {
                  'diagnostics': [diagnostic],
                  'only': ['quickfix'],
                },
              })
              as List?) ??
          const [];
      names = [
        for (final action in actions.cast<Map<Object?, Object?>>())
          if ((action['diagnostics'] as List? ?? const []).any(
            (d) =>
                jsonEncode((d as Map)['range']) ==
                jsonEncode(diagnostic['range']),
          ))
            '${action['kind']}',
      ];
    } else {
      final location = diagnostic['location']! as Map;
      final answer =
          (await request('edit.getFixes', {
                'file': path,
                'offset': location['offset'],
              }))!
              as Map;
      names = [
        for (final entry
            in (answer['fixes'] as List).cast<Map<Object?, Object?>>())
          if (((entry['error']! as Map)['location'] as Map)['offset'] ==
                  location['offset'] &&
              (entry['error']! as Map)['code'] == diagnostic['code'])
            for (final fix
                in (entry['fixes']! as List).cast<Map<Object?, Object?>>())
              '${fix['id']}',
      ];
    }
    return names.where((name) => !name.contains('.ignore.')).toList();
  }

  /// Whether formatting [path] would change it. Nothing is written.
  Future<bool> wouldFormat(String path) async {
    if (lsp) {
      final edits = await request('textDocument/formatting', {
        'textDocument': {'uri': Uri.file(path).toString()},
        'options': {'tabSize': 2, 'insertSpaces': true},
      });
      return edits is List && edits.isNotEmpty;
    }
    final answer =
        (await request('edit.format', {
              'file': path,
              'selectionOffset': 0,
              'selectionLength': 0,
            }))!
            as Map;
    return (answer['edits'] as List).isNotEmpty;
  }

  /// Asks the server to stop, the way its protocol says, and returns the
  /// exit code of [process]. Ends it and returns null when it is still
  /// running 10 s later.
  Future<int?> shutdown() async {
    try {
      await request(
        lsp ? 'shutdown' : 'server.shutdown',
        null,
      ).timeout(const Duration(seconds: 10));
      if (lsp) _send({'jsonrpc': '2.0', 'method': 'exit'});
    } on Object {
      // The exit code below says what happened.
    }
    final code = await process.exitCode
        .then<int?>((code) => code)
        .timeout(const Duration(seconds: 10), onTimeout: () => null);
    if (code == null) {
      for (final id in {process.pid, serverPid}) {
        if (await _alive(id)) Process.killPid(id, ProcessSignal.sigkill);
      }
    }
    return code;
  }

  /// The process ended: nothing more will arrive.
  void _end() {
    _ended = true;
    for (final completer in _pending.values.toList()) {
      if (!completer.isCompleted) {
        completer.completeError(
          _Broken('${kind.label}: the server ended before it answered.'),
        );
      }
    }
    _pending.clear();
    for (final waiter in _waiters.toList()) {
      waiter();
    }
  }

  void _send(Map<String, Object?> message) {
    if (lsp) {
      final body = utf8.encode(jsonEncode(message));
      process.stdin
        ..add(ascii.encode('Content-Length: ${body.length}\r\n\r\n'))
        ..add(body);
    } else {
      process.stdin.writeln(jsonEncode(message));
    }
  }

  /// Splits LSP's stream into messages: a `Content-Length` header, a blank
  /// line, then that many bytes of JSON.
  void _onBytes(List<int> chunk) {
    _bytes.add(chunk);
    while (true) {
      final bytes = _bytes.toBytes();
      var header = -1;
      for (var i = 0; i + 3 < bytes.length; i++) {
        if (bytes[i] == 13 &&
            bytes[i + 1] == 10 &&
            bytes[i + 2] == 13 &&
            bytes[i + 3] == 10) {
          header = i;
          break;
        }
      }
      if (header < 0) return;
      final length = int.parse(
        RegExp(
          r'Content-Length: (\d+)',
        ).firstMatch(ascii.decode(bytes.sublist(0, header)))![1]!,
      );
      final end = header + 4 + length;
      if (bytes.length < end) return;
      _bytes
        ..clear()
        ..add(bytes.sublist(end));
      _onMessage(
        jsonDecode(utf8.decode(bytes.sublist(header + 4, end)))
            as Map<String, Object?>,
      );
    }
  }

  void _onMessage(Map<String, Object?> message) {
    _lastMessage = elapsed;
    final method = (message['method'] ?? message['event']) as String?;
    if (method == null) {
      final completer = _pending.remove('${message['id']}');
      if (message['error'] case final error?) {
        completer?.completeError(StateError(jsonEncode(error)));
      } else {
        completer?.complete(message['result']);
      }
    } else {
      final params = (message['params'] as Map<String, Object?>?) ?? {};
      bool? analyzing;
      switch (method) {
        case 'workspace/applyEdit':
          applyEdits.add(params);
        case r'$/analyzerStatus':
          analyzing = params['isAnalyzing'] == true;
        case 'server.status':
          final analysis = params['analysis'] as Map?;
          if (analysis != null) analyzing = analysis['isAnalyzing'] == true;
        case 'server.error':
          stderr.writeln('server.error: ${params['message']}');
        case 'textDocument/publishDiagnostics':
          lastDiagnostics = elapsed;
          diagnostics[p.canonicalize(
            Uri.parse(params['uri']! as String).toFilePath(),
          )] = (params['diagnostics']! as List)
              .cast<Map<String, Object?>>();
        case 'analysis.errors':
          lastDiagnostics = elapsed;
          diagnostics[p.canonicalize(params['file']! as String)] =
              (params['errors']! as List).cast<Map<String, Object?>>();
      }
      if (analyzing != null) {
        if (!analyzing && statuses.any((status) => status.$2)) {
          saidDone ??= elapsed;
        }
        statuses.add((elapsed, analyzing));
      }
      if (lsp && message.containsKey('id')) {
        // A request from the server. An edit is refused, so nothing is
        // written; anything else is accepted.
        _send({
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': method == 'workspace/applyEdit' ? {'applied': false} : null,
        });
      }
    }
    for (final waiter in _waiters.toList()) {
      waiter();
    }
  }
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

/// Writes [app]'s `analysis_options.yaml`: `flutter_lints`, one more lint
/// (the deprecated use without a migration is in the app's own code), and
/// with [plugin] the `appstein_lints` plugin with four layers.
void _writeOptions(String app, {required bool plugin}) {
  final lints = File(p.join(app, 'lints path.txt')).readAsStringSync();
  const base = '''
include: package:flutter_lints/flutter.yaml

linter:
  rules:
    - deprecated_member_use_from_same_package
''';
  File(p.join(app, 'analysis_options.yaml')).writeAsStringSync(
    plugin
        ? '''
$base
plugins:
  appstein_lints:
    path: $lints
    diagnostics:
      layer_imports: true

appstein_lints:
  layers:
    ui: [lib/ui/**]
    data: [lib/data/**]
    domain: [lib/domain/**]
    last: [lib/zz/**]
  allow:
    ui: [data, domain]
    data: [domain]
    domain: []
    last: []
'''
        : base,
  );
}

/// Writes the 200-file official_mvvm app of `measure_sync.dart` (99
/// features with a view model and a screen each, a router and `main.dart`),
/// and beside it the files the measurement needs: three canaries with a
/// layer violation (the first also has an unused import), a file with
/// pending fixes that is also unformatted, and a deprecated use that has no
/// migration. [lints] is the folder that holds the `appstein_lints` package.
void _generateApp(String app, {required String lints}) {
  void write(String relative, String content) => File(p.join(app, relative))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  write(
    'lints path.txt',
    p.join(lints, 'appstein_lints').replaceAll(r'\', '/'),
  );
  write(
    'pubspec.yaml',
    'name: measure_app\npublish_to: none\n\nenvironment:\n  sdk: ^3.12.0\n\n'
        'dependencies:\n  flutter:\n    sdk: flutter\n  go_router: ^18.0.0\n\n'
        'dev_dependencies:\n  flutter_lints: ^6.0.0\n',
  );
  final imports = StringBuffer();
  final routes = StringBuffer();
  for (var i = 0; i < 99; i++) {
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
  // The canaries: no layer but `ui` may import `ui`.
  write(
    _canaries[0],
    "import 'dart:math';\n\n"
    "import '../ui/feature_0/view_models/feature_0_view_model.dart';\n\n"
    '/// The first canary.\n'
    'Feature0ViewModel first() => Feature0ViewModel();\n',
  );
  write(
    _canaries[1],
    "import '../ui/feature_0/view_models/feature_0_view_model.dart';\n\n"
    '/// The canary.\nFeature0ViewModel canary() => Feature0ViewModel();\n',
  );
  write(
    _canaries[2],
    "import '../ui/feature_98/view_models/feature_98_view_model.dart';\n\n"
    '/// The last canary.\n'
    'Feature98ViewModel last() => Feature98ViewModel();\n',
  );
  // Six deprecated uses `dart fix` can migrate (one inside another, which
  // takes a second pass), an unused import, and a line `dart format` would
  // split.
  write(_legacyFile, '''
import 'dart:math';

import 'package:flutter/material.dart';

/// A tint, written against old APIs.
Color tint(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return scheme.background.withOpacity(0.5);
}

/// A second use on one line, and a lint with a fix.
Widget box(ColorScheme scheme) {
  final a = scheme.onBackground; final b = scheme.surfaceVariant;
  return ColoredBox(color: a.withOpacity(b.opacity), child: SizedBox());
}
''');
  write('lib/ui/legacy/own.dart', '''
/// The old way.
@Deprecated('Use something else')
int stale() => 1;
''');
  // A use in the same file would not be reported.
  write(_ownUse, '''
import 'own.dart';

/// Built on the old way, for now.
int fresh() => stale();
''');
}
