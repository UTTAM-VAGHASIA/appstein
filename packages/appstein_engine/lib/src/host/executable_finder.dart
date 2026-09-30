import 'dart:io';

import 'package:path/path.dart' as p;

import 'host_environment.dart';

/// Finds the command [name] on the PATH of [environment], the way a shell
/// would, and returns its full path, or null when it isn't installed.
///
/// On Windows it tries each PATHEXT extension in order (`.COM;.EXE;.BAT;.CMD`
/// by default). Elsewhere, the file must have an executable bit.
String? findExecutable(String name, HostEnvironment environment) =>
    _matches(name, environment).firstOrNull;

/// Every match for the command [name] on the PATH of [environment], in the
/// order a shell tries them: PATH order, and on Windows PATHEXT order within
/// one folder. The first is what [findExecutable] returns.
///
/// Flutter lists matches like this, with `where` on Windows and `which -a`
/// elsewhere, to find `aapt` and `adb`. Unlike `where`, this never looks in
/// the current folder first.
List<String> findAllExecutables(String name, HostEnvironment environment) =>
    _matches(name, environment).toList();

Iterable<String> _matches(String name, HostEnvironment environment) sync* {
  final windows = environment.os == HostOs.windows;
  final extensions = windows
      ? (environment.variable('PATHEXT') ?? '.COM;.EXE;.BAT;.CMD')
            .split(';')
            .where((e) => e.isNotEmpty)
            .map((e) => e.toLowerCase())
            .toList()
      : const [''];
  final hasExtension =
      windows && extensions.contains(p.extension(name).toLowerCase());
  for (final dir in environment.pathEntries) {
    for (final extension in hasExtension ? const [''] : extensions) {
      final candidate = p.join(dir, '$name$extension');
      final file = File(candidate);
      if (!file.existsSync()) continue;
      if (!windows && (file.statSync().mode & 0x49) == 0) continue;
      yield candidate;
    }
  }
}
