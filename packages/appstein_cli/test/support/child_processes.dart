import 'dart:convert';
import 'dart:io';

/// Whether a process with this ID is running. For IDs the test itself
/// recorded.
Future<bool> processAlive(int id) async {
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
  }
  return children;
}
