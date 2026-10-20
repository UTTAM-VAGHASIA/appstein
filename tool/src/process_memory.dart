import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// Gives the running processes ([listProcesses]); a test gives its own.
typedef ProcessLister = Future<List<ProcessRow>> Function();

/// One running process, as the measuring tools see it.
final class ProcessRow {
  /// Creates a row.
  const ProcessRow(this.id, this.parent, this.bytes, [this.start, this.name]);

  /// The process's ID.
  final int id;

  /// Its parent's ID. The system never clears it: when a parent ends, its
  /// children keep its ID, and a new process may be given that ID.
  final int parent;

  /// The memory it has in use, in bytes: the working set on Windows, the
  /// resident set elsewhere.
  final int bytes;

  /// When it started, in milliseconds since the Unix epoch; null when the
  /// system did not say. On Linux and macOS it is the listing's time minus
  /// `ps`'s elapsed time, so it is good to about a second.
  final int? start;

  /// The program it runs, as the system names it: `Win32_Process.Name` on
  /// Windows (`dart.exe`), `ps`'s `comm` elsewhere (a name on Linux, the
  /// program's path on macOS); null when the listing did not say.
  final String? name;
}

/// The program of [row] without its folder and its `.exe`, in lower case:
/// `dartvm` for `/Users/x/flutter/bin/cache/dart-sdk/bin/dartvm` and for
/// `dartvm.exe`; null when the row has no name. On Linux the Dart VM names
/// its process `dart:<script>`, cut to 15 characters (`dart:silent_gua`
/// in CI), so a name that starts with `dart:` is `dart`.
String? programOf(ProcessRow row) {
  final name = row.name;
  if (name == null) return null;
  if (name.toLowerCase().startsWith('dart:')) return 'dart';
  final base = name.split(RegExp(r'[\\/]')).last.toLowerCase();
  return base.endsWith('.exe') ? base.substring(0, base.length - 4) : base;
}

/// The programs an analysis server runs as: the SDK's `dart`, the VM it may
/// hand a script to (`dartvm`), and the AOT runtime.
const dartPrograms = {'dart', 'dartvm', 'dartaotruntime'};

/// The program the compiled Appstein binary runs as ([programOf]): the
/// `appstein` commands, the analysis host and the guard in front of the
/// server. Where the Dart VM names its processes after the script instead
/// (`dart:<script>`), these read as [dartPrograms], so nothing that must work
/// on every system may tell a server from a guard by this name.
const appsteinProgram = 'appstein';

/// The seconds in `ps`'s `etime` text (`mm:ss`, `hh:mm:ss` or
/// `dd-hh:mm:ss`), or null when it is none of those.
int? elapsedSeconds(String text) {
  final days = text.split('-');
  if (days.length > 2) return null;
  final clock = days.last.split(':').map(int.tryParse).toList();
  if (clock.length < 2 || clock.length > 3 || clock.contains(null)) return null;
  final day = days.length == 2 ? int.tryParse(days.first) : 0;
  if (day == null) return null;
  var seconds = 0;
  for (final part in clock) {
    seconds = seconds * 60 + part!;
  }
  return day * 86400 + seconds;
}

/// The rows of PowerShell's `Get-CimInstance Win32_Process` printed as
/// `<id> <parent id> <working set bytes> <start> <name>` lines
/// ([listProcesses]); the start is in milliseconds since the epoch, or `-`
/// when it is not known, and the name is the rest of the line (it may hold
/// spaces). A line without the name, or without the start and the name, is
/// read too. A line that doesn't start with three numbers (a process whose
/// working set isn't known) is left out.
List<ProcessRow> parseWindowsProcessList(String output) {
  final rows = <ProcessRow>[];
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final words = line.trim().split(RegExp(r'\s+'));
    if (words.length < 3) continue;
    final numbers = words.take(3).map(int.tryParse).toList();
    if (numbers.contains(null)) continue;
    rows.add(
      ProcessRow(
        numbers[0]!,
        numbers[1]!,
        numbers[2]!,
        words.length > 3 ? int.tryParse(words[3]) : null,
        words.length > 4 ? words.skip(4).join(' ') : null,
      ),
    );
  }
  return rows;
}

/// The rows of `ps -A -o pid=,ppid=,rss=,etime=,comm=`, whose memory is in
/// kilobytes. [now] is the time of the listing, in milliseconds since the
/// epoch: a row's start is [now] less its elapsed time. The name is the rest
/// of the line (on macOS the program's path, which may hold spaces). A line
/// that doesn't start with three numbers is left out; one with only the
/// three numbers has no start, and one without the rest has no name.
List<ProcessRow> parsePsProcessList(String output, {required int now}) {
  final rows = <ProcessRow>[];
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final words = line.trim().split(RegExp(r'\s+'));
    if (words.length < 3) continue;
    final numbers = words.take(3).map(int.tryParse).toList();
    if (numbers.contains(null)) continue;
    final elapsed = words.length > 3 ? elapsedSeconds(words[3]) : null;
    rows.add(
      ProcessRow(
        numbers[0]!,
        numbers[1]!,
        numbers[2]! * 1024,
        elapsed == null ? null : now - elapsed * 1000,
        words.length > 4 ? words.skip(4).join(' ') : null,
      ),
    );
  }
  return rows;
}

/// The rows of a listing that exited with [exitCode] and printed [stdout],
/// read as [windows] or `ps` prints them. Throws a [StateError] when the
/// listing failed, or does not hold the process [ownPid] that asked for it:
/// an empty or partial list would show as no memory and no leftover.
List<ProcessRow> checkedProcessList(
  int exitCode,
  String stdout, {
  required bool windows,
  required int now,
  required int ownPid,
}) {
  if (exitCode != 0) {
    throw StateError(
      'the process list could not be read: exit code $exitCode:\n$stdout',
    );
  }
  final rows = windows
      ? parseWindowsProcessList(stdout)
      : parsePsProcessList(stdout, now: now);
  if (!rows.any((row) => row.id == ownPid)) {
    throw StateError(
      'the process list could not be read: it has ${rows.length} processes '
      'and not this one ($ownPid)',
    );
  }
  return rows;
}

/// Every process that is running now. Throws a [StateError] when the system
/// does not give a list that holds this process.
Future<List<ProcessRow>> listProcesses() async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final ProcessResult list;
  if (Platform.isWindows) {
    list = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      r'Get-CimInstance Win32_Process | ForEach-Object { '
          r'$start = if ($_.CreationDate) { '
          r'[int64](($_.CreationDate.ToFileTimeUtc() - 116444736000000000) '
          r'/ 10000) } else { "-" }; '
          r'"$($_.ProcessId) $($_.ParentProcessId) '
          r'$([int64]$_.WorkingSetSize) $start $($_.Name)" }',
    ]);
  } else {
    list = await Process.run('ps', [
      '-A',
      '-o',
      'pid=,ppid=,rss=,etime=,comm=',
    ]);
  }
  return checkedProcessList(
    list.exitCode,
    '${list.stdout}',
    windows: Platform.isWindows,
    now: now,
    ownPid: pid,
  );
}

/// The IDs of the process [root] and every process under it in [rows].
///
/// A process counts as a child only when it did not start before its
/// parent: the system names a parent by ID and never clears it, so the
/// children of a parent that ended keep its ID, and a new, unrelated process
/// given that ID would look like their parent. A child cannot be older than
/// its parent. The rule applies at every level. When either start is not
/// known the process counts.
Set<int> processTree(List<ProcessRow> rows, int root) {
  final starts = {for (final row in rows) row.id: row.start};
  final tree = {root};
  var grew = true;
  while (grew) {
    grew = false;
    for (final row in rows) {
      if (!tree.contains(row.parent) || tree.contains(row.id)) continue;
      final parentStart = starts[row.parent];
      final start = row.start;
      if (parentStart != null && start != null && start < parentStart) {
        continue;
      }
      tree.add(row.id);
      grew = true;
    }
  }
  return tree;
}

/// The memory, in bytes, of the process [root] and every process under it.
int treeMemory(List<ProcessRow> rows, int root) {
  final tree = processTree(rows, root);
  return rows
      .where((row) => tree.contains(row.id))
      .fold<int>(0, (sum, row) => sum + row.bytes);
}

/// The memory, in bytes, of the processes [roots] and everything under any
/// of them, each process counted once: a root that lies inside another's
/// tree adds nothing.
int treesMemory(List<ProcessRow> rows, Iterable<int> roots) {
  final inTrees = <int>{for (final root in roots) ...processTree(rows, root)};
  return rows
      .where((row) => inTrees.contains(row.id))
      .fold<int>(0, (sum, row) => sum + row.bytes);
}

/// [treeStarts] of every root in [roots], merged: each process once, with the
/// start the listing gave it.
Map<int, int?> treesStarts(List<ProcessRow> rows, Iterable<int> roots) {
  final merged = <int, int?>{};
  for (final root in roots) {
    for (final MapEntry(:key, :value) in treeStarts(rows, root).entries) {
      merged.putIfAbsent(key, () => value);
    }
  }
  return merged;
}

/// How far two starts of one process may lie apart, listing to listing:
/// `ps` gives seconds, and a listing's time is not exact.
const _startTolerance = Duration(seconds: 2);

/// The IDs of the process [root] and everything under it in [rows] ([processTree]),
/// each with the start the listing gave it (null when unknown): what
/// [survivors] compares a later listing with.
Map<int, int?> treeStarts(List<ProcessRow> rows, int root) {
  final starts = {for (final row in rows) row.id: row.start};
  // A root that is not in the listing has ended: it has no start to
  // compare, and its ID must not make a later program look like it.
  return {
    for (final id in processTree(rows, root))
      if (starts.containsKey(id)) id: starts[id],
  };
}

/// The processes of [before] (an ID with its start, [treeStarts]) that are
/// still running in [now]. A process with the ID of one of them counts only
/// when its start is the recorded one, within two seconds: the ID of a
/// process that ended may be given to another program, one that started
/// after the listing or one that was already running, and that program is
/// not a leftover. When either start is not known the process counts: a
/// survivor must never be missed for want of a time.
Set<int> survivors(Map<int, int?> before, List<ProcessRow> now) {
  final tolerance = _startTolerance.inMilliseconds;
  return {
    for (final row in now)
      if (before.containsKey(row.id) &&
          (before[row.id] == null ||
              row.start == null ||
              (row.start! - before[row.id]!).abs() <= tolerance))
        row.id,
  };
}

/// Looks at the process list with [lister] up to [attempts] times, [delay]
/// apart, until none of the processes of [tree] (an ID with its start,
/// [treeStarts]) is running any more ([survivors]), and returns the ones that
/// are, which is empty when they ended. A listing that fails ends the wait
/// with [listingProblem], which says so, and the processes are then unknown:
/// [left] is what was last seen. Nothing is looked for when [tree] is empty.
Future<({Set<int> left, String? listingProblem})> waitUntilGone(
  Map<int, int?> tree,
  ProcessLister lister, {
  int attempts = 20,
  Duration delay = const Duration(milliseconds: 500),
}) async {
  var left = tree.keys.toSet();
  for (var i = 0; i < attempts && left.isNotEmpty; i++) {
    try {
      left = survivors(tree, await lister());
    } on StateError catch (error) {
      return (
        left: left,
        listingProblem:
            'could not check that the processes ended: ${error.message}',
      );
    }
    if (left.isNotEmpty) await Future<void>.delayed(delay);
  }
  return (left: left, listingProblem: null);
}

/// The problem to report when the processes [left] of [what] (such as
/// `appstein mcp` or the analysis host) are still running after it ended,
/// with the command to end them by hand.
String stillRunningProblem(String what, Set<int> left) {
  final ids = left.toList()..sort();
  return 'processes of $what are still running after it ended: '
      '${ids.join(', ')} (end them with '
      '${Platform.isWindows ? 'taskkill -PID <id> -F' : 'kill <id>'})';
}

/// Waits for a run's [exit] code and for [peak], the sampling of its memory
/// that was started beside it, and returns both; the peak is null when the
/// sampling never saw the run ([peakTreeMemory]). Both are listened to at
/// once: a sampling that fails while the run goes on (the process list can
/// fail) is a [StateError] at once, not an error nobody listens to. A
/// failure of either is a [StateError].
Future<(int, int?)> exitAndPeak(Future<int> exit, Future<int?> peak) async {
  try {
    final [code, most] = await Future.wait<int?>([
      exit,
      peak,
    ], eagerError: true);
    return (code!, most);
  } on Object catch (error) {
    final reason = error is StateError ? error.message : '$error';
    throw StateError('the run or the sampling of its memory failed: $reason');
  }
}

/// Whether [rows] hold the process [root] running, with a Dart program
/// ([dartPrograms]) under one of its children: for a terminal `appstein
/// verify`, the analysis server under the guard ([processTree] decides who
/// is under whom). Anything else under the guard does not count: on Windows
/// each console program gets a `conhost.exe` child, so the guard alone has
/// a child of its own. A process whose name the listing did not give is not
/// shown to be a server.
bool reachesServer(List<ProcessRow> rows, int root) {
  if (!rows.any((row) => row.id == root)) return false;
  final tree = processTree(rows, root);
  final children = {
    for (final row in rows)
      if (row.parent == root && tree.contains(row.id)) row.id,
  };
  // Everything under a child, at any depth.
  final under = <int>{};
  var grew = true;
  while (grew) {
    grew = false;
    for (final row in rows) {
      if (!tree.contains(row.id) || under.contains(row.id)) continue;
      if (children.contains(row.parent) || under.contains(row.parent)) {
        under.add(row.id);
        grew = true;
      }
    }
  }
  return rows.any(
    (row) => under.contains(row.id) && dartPrograms.contains(programOf(row)),
  );
}

/// The most memory the process [root] and the processes under it held,
/// looked at repeatedly until [until] completes. It looks at least once.
///
/// Returns null when no look found [root] running with its guard and the
/// analysis server under it ([reachesServer]): a run that ended before the
/// first look was taken (a look takes about half a second on Windows, and
/// the first one on a new machine can take many seconds), or a look that
/// caught the run before it started its server, saw a part of its memory or
/// none, which is not its peak. The peak is the most of the looks that
/// found [root] running. [lister] gives the process list; tests replace it.
Future<int?> peakTreeMemory(
  int root,
  Future<void> until, {
  Future<List<ProcessRow>> Function() lister = listProcesses,
}) async {
  var ended = false;
  unawaited(until.whenComplete(() => ended = true));
  var peak = 0;
  var seen = false;
  do {
    final rows = await lister();
    if (rows.any((row) => row.id == root)) {
      seen = seen || reachesServer(rows, root);
      peak = math.max(peak, treeMemory(rows, root));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  } while (!ended);
  return seen ? peak : null;
}
