import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

/// Resolves the global `--project` option.
///
/// An explicit path, relative to the working folder, must contain
/// `pubspec.yaml`. Without the option, the nearest folder at or above the
/// working folder that contains one is used (null when there is none).
String? resolveProjectRoot(
  ArgResults? globalResults,
  HostEnvironment environment,
) {
  final explicit = globalResults?.option('project');
  if (explicit == null) return findProjectRoot(environment.workingDirectory);
  final root = p.normalize(p.join(environment.workingDirectory, explicit));
  if (!File(p.join(root, 'pubspec.yaml')).existsSync()) {
    throw UsageException(
      'No pubspec.yaml in $root.',
      'Pass --project the folder of a Dart or Flutter project.',
    );
  }
  return root;
}
