import 'dart:async';
import 'dart:io';
import 'dart:isolate';

// The engine's `TestFailure` is a failed test of the project `verify` runs.
import 'package:appstein_engine/appstein_engine.dart' hide TestFailure;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/fixture_app.dart';

/// A file of `test/analysis/support/`, found from the package itself: other
/// test files change the working folder.
String analysisSupportFile(String name) {
  final library = Isolate.resolvePackageUriSync(
    Uri.parse('package:appstein_engine/appstein_engine.dart'),
  )!;
  return p.join(
    p.dirname(p.dirname(library.toFilePath())),
    'test',
    'analysis',
    'support',
    name,
  );
}

/// The command that starts the guard in the engine's tests: the `dart` that
/// runs the tests, and `guard_main.dart`.
List<String> get testGuardCommand => [
  Platform.resolvedExecutable,
  analysisSupportFile('guard_main.dart'),
];

/// The real `dart` executable of the SDK that runs the tests.
String get testDart => dartExecutableIn(testDartSdk);

/// The environment that gives a test's analysis server a cache folder of
/// its own ([analysisCacheVariable]), so the tests leave nothing in the
/// cache the machine shares. Every test that starts an analysis server, or
/// a guard (the real guard deletes its server's half-written files there),
/// passes it.
///
/// The folder is deleted after the test, or after the group when this is
/// called in `setUpAll`. A server that is still ending holds files in it on
/// Windows, so the delete is tried again for a while.
Map<String, String> testAnalysisEnvironment() {
  final cache = Directory.systemTemp.createTempSync('appstein cache tëst ');
  addTearDown(() => deleteWhenFree(cache));
  return {analysisCacheVariable: cache.path};
}

/// Deletes the folder [folder] and all in it, trying again for up to 10 s
/// while a process that is ending still holds a file in it (Windows).
Future<void> deleteWhenFree(Directory folder) async {
  for (var attempt = 0; ; attempt++) {
    try {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 200) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

/// A real analysis server for the project at [app], with the SDK that runs
/// the tests and a cache folder of its own ([testAnalysisEnvironment]). The
/// caller stops it; it is also stopped after the test (or the group, when
/// made in `setUpAll`), before its cache folder is deleted.
AnalysisServer realAnalysisServer(String app) {
  final server = AnalysisServer(
    projectRoot: app,
    guardCommand: testGuardCommand,
    dartExecutable: () => testDart,
    environment: testAnalysisEnvironment(),
  );
  // Registered after the folder's delete, so it runs before it.
  addTearDown(server.stop);
  return server;
}

/// Writes [content] to the file [relative] (with `/`) of the project [app].
void writeProjectFile(String app, String relative, String content) =>
    File(p.joinAll([app, ...relative.split('/')]))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);

/// Who runs under the process ID [id] now, as the product asks it
/// (`lookUpProcess`); null when nothing does or it can't be told.
ProcessIdentity? identityOf(int id) => switch (lookUpProcess(id)) {
  ProcessRunning(:final identity) => identity,
  _ => null,
};

/// Waits until [process], a `dart <script>` that writes on stderr first
/// thing (`silent_guard.dart`), has written its first line there, and
/// drains the rest. Fails the test, rather than hanging, when the process
/// ends without one or none comes [within].
///
/// A test takes a process's identity only after this. On Linux and macOS a
/// `dart <script>` process execs the SDK's `dartvm` in the same process,
/// keeping the ID and the start, and `ps` names it `dart` before the exec
/// and `dartvm` after it. An identity taken a moment after the start could
/// so differ from one taken later: that was the macOS failure of CI run
/// 38721583522. Once the script has written, its Dart code runs, so the
/// exec is behind it.
Future<void> untilItsDartRuns(
  Process process, {
  Duration within = const Duration(seconds: 30),
}) {
  final running = Completer<void>();
  process.stderr.listen(
    (_) {
      if (!running.isCompleted) running.complete();
    },
    onDone: () {
      if (running.isCompleted) return;
      running.completeError(
        TestFailure(
          'process ${process.pid} ended without writing on stderr, so its '
          'Dart code never ran',
        ),
      );
    },
  );
  return running.future.timeout(
    within,
    onTimeout: () => throw TestFailure(
      'process ${process.pid} wrote nothing on stderr within $within',
    ),
  );
}

/// Deletes the file [relative] (with `/`) of the project [app]. On Windows
/// a file can't be deleted in the moment another process reads it, and an
/// analysis server reads a file soon after it changed; the delete is tried
/// again until it works.
void deleteProjectFile(String app, String relative) {
  final file = File(p.joinAll([app, ...relative.split('/')]));
  for (var attempt = 0; ; attempt++) {
    try {
      file.deleteSync();
      return;
    } on FileSystemException {
      if (attempt == 400) rethrow;
      sleep(const Duration(milliseconds: 5));
    }
  }
}

/// When each of the running processes among [ids] started, as text that is
/// the same each time it is asked for one process. A process that isn't
/// running, or whose start can't be read (another user's), is left out.
Future<Map<int, String>> _processStarts(Iterable<int> ids) async {
  final wanted = ids.toSet();
  if (wanted.isEmpty) return {};
  final ProcessResult list;
  if (Platform.isWindows) {
    list = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Get-Process -Id ${wanted.join(',')} -ErrorAction SilentlyContinue | '
          r'ForEach-Object { "$($_.Id) $($_.StartTime.Ticks)" }',
    ]);
  } else {
    list = await Process.run('ps', [
      '-o',
      'pid=,lstart=',
      '-p',
      wanted.join(','),
    ]);
  }
  final starts = <int, String>{};
  for (final line in '${list.stdout}'.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    final id = int.tryParse(parts.first);
    final start = parts.skip(1).join(' ');
    if (id != null && wanted.contains(id) && start.isNotEmpty) {
      starts[id] = start;
    }
  }
  return starts;
}

/// The start of each process a test has seen running, by ID. An operating
/// system gives the ID of an ended process to a new one, on Windows often
/// within seconds, so "a process with this ID is running" does not mean
/// "the process the test recorded is running": the start tells them apart.
///
/// It is emptied when the test that filled it ends: a later test's process
/// may be given an ID an earlier test recorded. Within one test, a test
/// that expects a new process under a recorded ID records it anew
/// ([recordProcesses]).
final _seenStarts = <int, String>{};
var _emptiedAtTestEnd = false;

void _note(Map<int, String> starts, {required bool anew}) {
  if (starts.isEmpty) return;
  if (!_emptiedAtTestEnd) {
    _emptiedAtTestEnd = true;
    addTearDown(() {
      _seenStarts.clear();
      _emptiedAtTestEnd = false;
    });
  }
  for (final MapEntry(key: id, value: start) in starts.entries) {
    if (anew) {
      _seenStarts[id] = start;
    } else {
      _seenStarts.putIfAbsent(id, () => start);
    }
  }
}

/// Notes the processes [ids] as they run now, so a later [processAlive] or
/// [goneWithin] means these and not a newer process with one of their IDs.
/// A test calls it when it learns the IDs, while the processes run, if
/// anything may start a process before it looks at them again.
/// An ID recorded before is recorded anew: the test says its process is the
/// one running now.
Future<void> recordProcesses(Iterable<int> ids) async {
  _note(await _processStarts(ids), anew: true);
}

/// Whether the process a test recorded under [id] is running. The first
/// time an ID is asked about, the process that has it is taken for the
/// recorded one, so a test asks while its process is known to run.
Future<bool> processAlive(int id) async {
  final start = (await _processStarts([id]))[id];
  if (start == null) return false;
  _note({id: start}, anew: false);
  return _seenStarts[id] == start;
}

/// How long until none of the processes a test recorded under [ids] is
/// running, or null when one still is after [limit]. A process that has
/// one of the IDs but another start than the one seen before, or that
/// started after this was called, is a new process with a used ID, and
/// does not count.
Future<Duration?> goneWithin(Iterable<int> ids, Duration limit) async {
  final watch = Stopwatch()..start();
  // What runs under an ID never seen before, now: later it may be another.
  _note(await _processStarts(ids), anew: false);
  while (true) {
    final running = await _processStarts(ids);
    final any = running.entries.any(
      (process) => _seenStarts[process.key] == process.value,
    );
    if (!any) return watch.elapsed;
    if (watch.elapsed > limit) return null;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
