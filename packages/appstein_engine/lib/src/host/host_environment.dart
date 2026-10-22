import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The operating system Appstein runs on.
enum HostOs {
  /// Microsoft Windows.
  windows,

  /// Apple macOS.
  macos,

  /// Linux.
  linux;

  /// The OS of the running process.
  static HostOs get current => Platform.isWindows
      ? windows
      : Platform.isMacOS
      ? macos
      : linux;
}

/// The parts of the machine Appstein reads: the OS, environment variables and
/// the working folder, and the facts of the machine and its user that every
/// process of one user shares ([machineName], [machineId], [userId],
/// [userHome], [privateGroupId], [runUserRoot]).
///
/// The engine reads these only through this class, so tests can describe any
/// machine without changing the real one: each fact is read from the real
/// machine unless the environment was described with it.
final class HostEnvironment {
  /// Describes a machine.
  const HostEnvironment({
    required this.os,
    required this.variables,
    required this.workingDirectory,
    this._machineName,
    this._machineId,
    this._userId,
    this._userHome,
    this._privateGroupId,
    this._runUserRoot,
    this._facts,
  });

  /// The machine this process runs on.
  factory HostEnvironment.current() => HostEnvironment(
    os: HostOs.current,
    variables: Platform.environment,
    workingDirectory: Directory.current.path,
  );

  /// The operating system.
  final HostOs os;

  /// Environment variables.
  final Map<String, String> variables;

  /// The folder commands run from.
  final String workingDirectory;

  final String? _machineName;
  final String? _machineId;
  final int? _userId;
  final String? _userHome;
  final int? _privateGroupId;
  final String? _runUserRoot;
  final MachineFacts? _facts;

  MachineFacts get _real => _facts ?? MachineFacts.system;

  /// The name of the machine (`analysisHostFolder`): the one the environment
  /// was described with, else the name of the machine this process runs on
  /// (`Platform.localHostname`, asked each time: a name changed while the
  /// process runs is seen).
  String get machineName => _machineName ?? Platform.localHostname;

  /// The machine's ID: the first line of `/etc/machine-id`, else of
  /// `/var/lib/dbus/machine-id`, when it is 32 hex characters; empty when
  /// there is none (containers often have none). Read once for the process.
  String get machineId => _machineId ?? _real.machineId;

  /// The ID of the user this process runs as, the effective one (the second
  /// number of the `Uid:` line of `/proc/self/status` on Linux, no process
  /// started; else `id -u`); null when neither tells. Read once for the
  /// process, also when it could not be read. An environment described with a
  /// negative ID has none that can be read.
  int? get userId => switch (_userId) {
    final id? when id < 0 => null,
    final id? => id,
    _ => _real.userId,
  };

  /// The user's home folder as the user database has it (the line of
  /// `/etc/passwd` for [userId], else `getent passwd`), not `$HOME`, which
  /// differs between the processes of one user; null when there is none, or
  /// when what the database says is not an absolute path. An environment
  /// described with an empty home has none. Read once for the process, also
  /// when there is none.
  String? get userHome => switch (_userHome) {
    '' => null,
    final home? => home,
    _ => _real.userHome(userId),
  };

  /// [userHome] when it can be had without starting a process (described, or
  /// in `/etc/passwd`); null when there is none or only `getent` could tell
  /// ([userHomeNeedsProcess]).
  String? get userHomeWithoutProcess => switch (_userHome) {
    '' => null,
    final home? => home,
    _ => _real.userHomeFromFiles(userId),
  };

  /// Whether the home of the user can only be had by starting `getent` (the
  /// user is not in `/etc/passwd`, as with LDAP or NIS).
  bool get userHomeNeedsProcess =>
      _userHome == null && userHomeWithoutProcess == null && userId != null;

  /// The ID of the user's private group, or null when the user's own group is
  /// shared: the primary group of the user in `/etc/passwd`, when no other
  /// user lists it as primary and `/etc/group` lists no member of it other
  /// than the user (the rule Debian's OpenSSH uses for a home that the group may write;
  /// upstream OpenSSH refuses any group write).
  /// Files only, no process. An environment described with a negative ID has
  /// none.
  int? get privateGroupId => switch (_privateGroupId) {
    final id? when id < 0 => null,
    final id? => id,
    _ => _real.privateGroupId(userId),
  };

  /// Where the system makes a folder for each user that is logged in
  /// (`/run/user`); a test gives one that is not there.
  String get runUserRoot => _runUserRoot ?? '/run/user';

  /// The value of the environment variable [name], or null when it is unset
  /// or empty.
  ///
  /// On Windows, names are case-insensitive (`Path` and `PATH` are the same).
  String? variable(String name) {
    var value = variables[name];
    if (value == null && os == HostOs.windows) {
      final wanted = name.toLowerCase();
      for (final entry in variables.entries) {
        if (entry.key.toLowerCase() == wanted) {
          value = entry.value;
          break;
        }
      }
    }
    return (value == null || value.isEmpty) ? null : value;
  }

  /// The user's home folder: `USERPROFILE` on Windows, `HOME` elsewhere.
  String? get homeDir =>
      variable(os == HostOs.windows ? 'USERPROFILE' : 'HOME');

  /// The folders on PATH, in order, without empty entries or the quotes
  /// Windows allows around an entry.
  List<String> get pathEntries {
    final separator = os == HostOs.windows ? ';' : ':';
    final entries = <String>[];
    for (final raw in (variable('PATH') ?? '').split(separator)) {
      var entry = raw.trim();
      if (entry.length >= 2 && entry.startsWith('"') && entry.endsWith('"')) {
        entry = entry.substring(1, entry.length - 1);
      }
      if (entry.isNotEmpty) entries.add(entry);
    }
    return entries;
  }
}

/// The facts of the machine and its user that are read from the system:
/// each is read the first time it is asked for and kept for the life of the
/// object, **also when it could not be read**, so a process that has no such
/// file (Windows, macOS) never reads the files or starts `id` or `getent`
/// again. [system] is the one every [HostEnvironment] uses unless it is
/// given another; tests give one with their own [readFile] and [run] to see
/// what is read.
final class MachineFacts {
  /// Facts read with [readFile] (the text of a file, null when there is none
  /// or it can't be read) and [run] (the result of a program, null when it
  /// can't be started); the system's own unless given.
  MachineFacts({
    String? Function(String path)? readFile,
    ProcessResult? Function(String program, List<String> arguments)? run,
  }) : _readFile = readFile ?? _readFromDisk,
       _run = run ?? _runProgram;

  /// The facts of the machine this process runs on.
  static final system = MachineFacts();

  final String? Function(String path) _readFile;
  final ProcessResult? Function(String program, List<String> arguments) _run;

  String? _machineId;
  var _userIdRead = false;
  int? _userId;
  final _homes = <int?, String?>{};
  final _filesHomes = <int?, String?>{};
  final _groups = <int?, int?>{};

  /// The machine ID, empty when there is none.
  String get machineId => _machineId ??= _readMachineId();

  String _readMachineId() {
    for (final file in ['/etc/machine-id', '/var/lib/dbus/machine-id']) {
      final line = (_readFile(file) ?? '').split('\n').first.trim();
      if (RegExp(r'^[0-9a-f]{32}$').hasMatch(line)) return line;
    }
    return '';
  }

  /// The effective user ID; null when it can't be read.
  int? get userId {
    if (_userIdRead) return _userId;
    _userIdRead = true;
    // `Uid:  real  effective  saved  filesystem`
    for (final line in (_readFile('/proc/self/status') ?? '').split('\n')) {
      if (line.startsWith('Uid:')) {
        final fields = line.substring(4).trim().split(RegExp(r'\s+'));
        if (fields.length >= 2 && int.tryParse(fields[1]) != null) {
          return _userId = int.parse(fields[1]);
        }
      }
    }
    final result = _run('id', ['-u']);
    if (result != null && result.exitCode == 0) {
      return _userId = int.tryParse('${result.stdout}'.trim());
    }
    return null;
  }

  /// The passwd lines of `/etc/passwd`, as fields; empty when it can't be
  /// read.
  List<List<String>> _passwd() => [
    for (final line in (_readFile('/etc/passwd') ?? '').split('\n'))
      if (!line.startsWith('#') && line.split(':').length >= 6) line.split(':'),
  ];

  /// The home of [id] from `/etc/passwd`, without starting a process.
  String? userHomeFromFiles(int? id) => _filesHomes.putIfAbsent(
    id,
    () => id == null ? null : _homeIn(_passwd(), id),
  );

  /// The home of [id]: `/etc/passwd`, else `getent passwd`.
  String? userHome(int? id) => _homes.putIfAbsent(id, () {
    if (id == null) return null;
    if (userHomeFromFiles(id) case final home?) return home;
    final result = _run('getent', ['passwd', '$id']);
    if (result == null || result.exitCode != 0) return null;
    return _homeIn([
      for (final line in const LineSplitter().convert('${result.stdout}'))
        line.split(':'),
    ], id);
  });

  /// The home in the passwd [lines] for [id]; null when there is none or it
  /// is not an absolute path.
  static String? _homeIn(List<List<String>> lines, int id) {
    for (final fields in lines) {
      if (fields.length >= 6 && fields[2] == '$id') {
        final home = fields[5];
        return p.posix.isAbsolute(home) ? home : null;
      }
    }
    return null;
  }

  /// The private group of [id], null when there is none (below).
  int? privateGroupId(int? id) => _groups.putIfAbsent(id, () {
    if (id == null) return null;
    final lines = _passwd();
    final mine = [
      for (final fields in lines)
        if (fields[2] == '$id') fields,
    ];
    if (mine.isEmpty) return null;
    final name = mine.first[0];
    final group = int.tryParse(mine.first[3]);
    if (group == null) return null;
    // No other user has it as the primary group.
    for (final fields in lines) {
      if (fields[2] != '$id' && fields[3] == '$group') return null;
    }
    // And the group lists no member but the user.
    for (final line in (_readFile('/etc/group') ?? '').split('\n')) {
      final fields = line.split(':');
      if (fields.length >= 4 && fields[2] == '$group') {
        final members = [
          for (final member in fields[3].split(','))
            if (member.trim().isNotEmpty) member.trim(),
        ];
        if (members.any((member) => member != name)) return null;
      }
    }
    return group;
  });

  static String? _readFromDisk(String path) {
    try {
      return File(path).readAsStringSync();
    } on Object {
      return null;
    }
  }

  static ProcessResult? _runProgram(String program, List<String> arguments) {
    try {
      return Process.runSync(program, arguments);
    } on Object {
      return null;
    }
  }
}
