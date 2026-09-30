import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;

import 'src/hooks.dart';

/// Installs the repo's git hooks (spec §19.6). Run it from the repo root
/// once per clone, and again when `tool/src/hooks.dart` changes:
///   fvm dart run tool/install_hooks.dart           install or update
///   fvm dart run tool/install_hooks.dart --remove  remove Appstein's blocks
/// graphify's own hooks are removed with `graphify hook uninstall`.
Future<void> main(List<String> arguments) async {
  final remove = arguments.contains('--remove');
  if (arguments.any((argument) => argument != '--remove')) {
    stderr.writeln('Usage: fvm dart run tool/install_hooks.dart [--remove]');
    exitCode = 3;
    return;
  }
  final root = Directory.current.path;
  final gitPath = Process.runSync('git', [
    'rev-parse',
    '--git-path',
    'hooks',
  ], workingDirectory: root);
  if (gitPath.exitCode != 0) {
    stderr.writeln('Run this from the Appstein repo: ${gitPath.stderr}');
    exitCode = 3;
    return;
  }
  final hooksDir = p.normalize(p.join(root, (gitPath.stdout as String).trim()));
  if (!remove) {
    final graphify = findExecutable('graphify', HostEnvironment.current());
    if (graphify == null) {
      stdout.writeln(
        'graphify is not installed, so its graph hooks are skipped. Install '
        'it with `uv tool install graphifyy`, then run this again.',
      );
    } else {
      final result = await const SystemProcessRunner().run(graphify, [
        'hook',
        'install',
      ], timeout: const Duration(minutes: 2));
      stdout.write(result.stdout);
      if (!result.ok) {
        stderr.writeln('graphify hook install failed: ${result.stderr}');
      }
    }
  }
  try {
    for (final line in installHookBlocks(hooksDir, remove: remove)) {
      stdout.writeln(line);
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 3;
  }
}
