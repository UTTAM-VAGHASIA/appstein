import 'dart:io';

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
/// the working folder.
///
/// The engine reads these only through this class, so tests can describe any
/// machine without changing the real one.
final class HostEnvironment {
  /// Describes a machine.
  const HostEnvironment({
    required this.os,
    required this.variables,
    required this.workingDirectory,
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
