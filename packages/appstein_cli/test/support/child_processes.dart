import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

/// When each of the running processes among [ids] started, as text that is
/// the same each time it is asked for one process. A process that isn't
/// running, or whose start can't be read (another user's), is left out.
///
/// It asks as the product does (`lookUpProcess`), which on Windows starts
/// no process: a test that waits for its turn asks this too, and a process
/// it started would be counted by the test that holds the turn.
Future<Map<int, String>> _processStarts(Iterable<int> ids) async => {
  for (final id in ids.toSet()) id: ?_startOf(id),
};

/// When the process [id] started; null when it isn't running or that
/// can't be told. It starts no process on Windows (the product's
/// `lookUpProcess`, through `kernel32`) and on Linux (`/proc`). On macOS
/// it runs `ps`, which [childProcesses] leaves out by name.
String? _startOf(int id) {
  if (!Platform.isWindows && Directory('/proc').existsSync()) {
    try {
      // The 22nd field is the start, in clock ticks since boot. The name in
      // the second field is in parentheses and may hold spaces.
      final stat = File('/proc/$id/stat').readAsStringSync();
      final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      return fields[19];
    } on Object {
      return null;
    }
  }
  return switch (lookUpProcess(id)) {
    ProcessRunning(:final identity) => identity.start,
    _ => null,
  };
}

/// The start of each process a test has seen running, by ID. An operating
/// system gives the ID of an ended process to a new one, on Windows often
/// within seconds (a test here once took an unrelated program for a server
/// it had started), so the ID alone does not say that the process the test
/// recorded is running: the start tells them apart.
///
/// It is emptied when the test that filled it ends: a later test's process
/// may be given an ID an earlier test recorded.
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

/// Notes the processes [ids] as they run now, so a later [processAlive]
/// means these and not a newer process with one of their IDs. A test calls
/// it when it learns the IDs, while the processes run. An ID recorded
/// before is recorded anew.
Future<void> recordProcesses(Iterable<int> ids) async {
  _note(await _processStarts(ids), anew: true);
}

/// Whether the process a test recorded under [id] is running. An ID that
/// was never recorded ([recordProcesses], or an earlier call that found it
/// running) is recorded now.
Future<bool> processAlive(int id) async {
  final start = (await _processStarts([id]))[id];
  if (start == null) return false;
  _note({id: start}, anew: false);
  return _seenStarts[id] == start;
}

/// The running processes under the process [root], which the test itself
/// started: its children, their children and so on, by ID. [root] itself
/// and the tool that lists them are left out.
Future<Set<int>> processesUnder(int root) async {
  final parents = <int, int>{};
  final ProcessResult list;
  if (Platform.isWindows) {
    list = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Get-CimInstance Win32_Process | '
          r'ForEach-Object { "$($_.ProcessId) $($_.ParentProcessId)" }',
    ]);
  } else {
    list = await Process.run('ps', ['-A', '-o', 'pid=,ppid=']);
  }
  for (final line in const LineSplitter().convert('${list.stdout}')) {
    final numbers = line.trim().split(RegExp(r'\s+')).map(int.tryParse);
    if (numbers.toList() case [final id?, final parent?]) {
      if (id != list.pid) parents[id] = parent;
    }
  }
  final under = <int>{root};
  var grew = true;
  while (grew) {
    grew = false;
    for (final MapEntry(key: id, value: parent) in parents.entries) {
      if (under.contains(parent) && under.add(id)) grew = true;
    }
  }
  return under..remove(root);
}

/// Those of the processes a test recorded under [ids] that are still
/// running after [limit], each with its program, its start and its command
/// line; empty when all had ended. For a failure message that names what
/// outlived what.
Future<List<String>> survivorsAfter(Iterable<int> ids, Duration limit) async {
  if (await goneWithin(ids, limit) != null) return const [];
  final running = await _processStarts(ids);
  final left = [
    for (final MapEntry(key: id, value: start) in running.entries)
      if (_seenStarts[id] == start) id,
  ];
  final lines = <String>[];
  for (final id in left) {
    final image = switch (lookUpProcess(id)) {
      ProcessRunning(:final identity) => identity.image,
      _ => '?',
    };
    final ProcessResult command;
    if (Platform.isWindows) {
      command = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        '(Get-CimInstance Win32_Process -Filter "ProcessId=$id").CommandLine; '
            '(Get-CimInstance Win32_Process -Filter "ProcessId=$id")'
            '.ParentProcessId',
      ]);
    } else {
      command = await Process.run('ps', ['-o', 'ppid=,args=', '-p', '$id']);
    }
    lines.add(
      'process $id: $image, started ${running[id]}; '
      '${'${command.stdout}'.trim().replaceAll(RegExp(r'\s*\n\s*'), '; parent ')}',
    );
  }
  return lines;
}

/// How long until none of the processes a test recorded under [ids] is
/// running, or null when one still is after [limit]. A process that has
/// one of the IDs but another start than the recorded one does not count.
Future<Duration?> goneWithin(Iterable<int> ids, Duration limit) async {
  final watch = Stopwatch()..start();
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

/// Runs [body] while no other test of this test run is inside such a call.
///
/// The test files of a package run at the same time in one process, so the
/// children of that process are every file's children: a test that counts
/// them ([childProcesses]) would count the analysis server another file's
/// test has just started. A test that starts processes and one that counts
/// them both run their body in here. The turn is a file ([turnFile]):
/// creating a file that must not exist yet is something two isolates can't
/// both do.
///
/// - The wait has a limit, [wait]: a test that hangs while it holds the
///   turn makes the others fail with a message that says so.
/// - The file names its holder by process ID and start. One left behind by
///   a run that was killed, or by an earlier process that had this one's
///   ID, is taken away.
Future<T> withChildProcessesToItself<T>(
  Future<T> Function() body, {
  Duration wait = turnWait,
  File? file,
}) async {
  // Another file only in the tests of this function itself.
  final turn = file ?? turnFile();
  // Who holds the turn is written into the file: this process, by its ID
  // and its start, since an ID alone may be a later process's.
  final self = '$pid ${(await _processStarts([pid]))[pid] ?? 'unknown'}';
  final watch = Stopwatch()..start();
  while (true) {
    try {
      turn.createSync(exclusive: true);
      turn.writeAsStringSync(self);
      break;
    } on FileSystemException {
      if (await _turnWasLeft(turn)) {
        // By a run that was killed, or a process that had this one's ID.
        try {
          turn.deleteSync();
        } on FileSystemException {
          // Another isolate removed it first.
        }
        continue;
      }
      if (watch.elapsed > wait) {
        fail(
          'No turn among the tests that start processes in '
          '${wait.inSeconds} s: another test holds it '
          '(${turn.path}). A test that hangs while it holds the turn keeps '
          'the others waiting; look for the first test that timed out.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  try {
    return await body();
  } finally {
    try {
      turn.deleteSync();
    } on FileSystemException {
      // Taken away as left behind: nothing to give back.
    }
  }
}

/// The file that is the turn of [withChildProcessesToItself], in the
/// system's temporary folder, named after this process.
File turnFile() => File(
  '${Directory.systemTemp.path}${Platform.pathSeparator}'
  'appstein cli tests $pid turn',
);

/// How long a test waits for its turn before it fails, saying so. It is
/// less than the tests' own time limit of ten minutes, so the message is
/// this one and not a bare timeout.
const turnWait = Duration(minutes: 8);

/// Whether the turn file was left behind: the process it names isn't
/// running, or the process with that ID has another start. A file without
/// a holder's name counts as left when it is a minute old (the name is
/// written right after the file is made).
Future<bool> _turnWasLeft(File turn) async {
  final String held;
  final DateTime written;
  try {
    held = turn.readAsStringSync();
    written = turn.lastModifiedSync();
  } on FileSystemException {
    // Given back in this moment.
    return false;
  }
  final parts = held.split(' ');
  final holder = int.tryParse(parts.first);
  if (holder == null || parts.length < 2) {
    return DateTime.now().difference(written) > const Duration(minutes: 1);
  }
  final start = (await _processStarts([holder]))[holder];
  return start != parts.skip(1).join(' ');
}

/// The processes this process started that are still running, by ID with
/// their names: what a test compares before and after a run to see that
/// nothing was left behind. The tool that lists them is left out.
Future<Map<int, String>> childProcesses() async {
  final children = <int, String>{};
  if (Platform.isWindows) {
    final list = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Get-CimInstance Win32_Process -Filter "ParentProcessId=$pid" | '
          r'ForEach-Object { "$($_.ProcessId) $($_.Name)" }',
    ]);
    for (final line in const LineSplitter().convert('${list.stdout}')) {
      final [id, ...name] = line.trim().split(' ');
      final process = int.tryParse(id);
      if (process == null || process == list.pid) continue;
      children[process] = name.join(' ');
    }
    children.removeWhere((_, name) => name.toLowerCase() == 'conhost.exe');
  } else {
    final list = await Process.run('ps', ['-A', '-o', 'pid=,ppid=,comm=']);
    for (final line in const LineSplitter().convert('${list.stdout}')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 3 || parts[1] != '$pid') continue;
      final process = int.parse(parts[0]);
      if (process == list.pid) continue;
      children[process] = parts.sublist(2).join(' ');
    }
    // A `ps` another test's helper is running in this moment, to ask for
    // a process's start: it lists, and is gone at once.
    children.removeWhere((_, name) => name.split('/').last == 'ps');
  }
  return children;
}
