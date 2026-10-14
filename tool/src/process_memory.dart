import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// One running process, as the measuring tools see it.
final class ProcessRow {
  /// Creates a row.
  const ProcessRow(this.id, this.parent, this.bytes, [this.start]);

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
}

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
/// `<id> <parent id> <working set bytes> <start>` lines ([listProcesses]);
/// the start is in milliseconds since the epoch, or `-` when it is not
/// known. A line without the start is read too. A line that isn't numbers
/// (a process whose working set isn't known) is left out.
List<ProcessRow> parseWindowsProcessList(String output) {
  final rows = <ProcessRow>[];
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final words = line.trim().split(RegExp(r'\s+'));
    if (words.length < 3 || words.length > 4) continue;
    final numbers = words.take(3).map(int.tryParse).toList();
    if (numbers.contains(null)) continue;
    rows.add(
      ProcessRow(
        numbers[0]!,
        numbers[1]!,
        numbers[2]!,
        words.length == 4 ? int.tryParse(words[3]) : null,
      ),
    );
  }
  return rows;
}

/// The rows of `ps -A -o pid=,ppid=,rss=,etime=`, whose memory is in
/// kilobytes. [now] is the time of the listing, in milliseconds since the
/// epoch: a row's start is [now] less its elapsed time. A line that isn't
/// three numbers and an elapsed time is left out; one with only the three
/// numbers has no start.
List<ProcessRow> parsePsProcessList(String output, {required int now}) {
  final rows = <ProcessRow>[];
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final words = line.trim().split(RegExp(r'\s+'));
    if (words.length < 3 || words.length > 4) continue;
    final numbers = words.take(3).map(int.tryParse).toList();
    if (numbers.contains(null)) continue;
    final elapsed = words.length == 4 ? elapsedSeconds(words[3]) : null;
    rows.add(
      ProcessRow(
        numbers[0]!,
        numbers[1]!,
        numbers[2]! * 1024,
        elapsed == null ? null : now - elapsed * 1000,
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
          r'$([int64]$_.WorkingSetSize) $start" }',
    ]);
  } else {
    list = await Process.run('ps', ['-A', '-o', 'pid=,ppid=,rss=,etime=']);
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

/// Waits for a run's [exit] code and for [peak], the sampling of its memory
/// that was started beside it, and returns both. Both are listened to at
/// once: a sampling that fails while the run goes on (the process list can
/// fail) is a [StateError] at once, not an error nobody listens to. A
/// failure of either is a [StateError].
Future<(int, int)> exitAndPeak(Future<int> exit, Future<int> peak) async {
  try {
    final [code, most] = await Future.wait([exit, peak], eagerError: true);
    return (code, most);
  } on Object catch (error) {
    final reason = error is StateError ? error.message : '$error';
    throw StateError('the run or the sampling of its memory failed: $reason');
  }
}

/// The most memory the process [root] and the processes under it held,
/// looked at repeatedly (a look takes up to a second on Windows) until
/// [until] completes. It looks at least once.
Future<int> peakTreeMemory(int root, Future<void> until) async {
  var ended = false;
  unawaited(until.whenComplete(() => ended = true));
  var peak = 0;
  do {
    peak = math.max(peak, treeMemory(await listProcesses(), root));
    await Future<void>.delayed(const Duration(milliseconds: 200));
  } while (!ended);
  return peak;
}
