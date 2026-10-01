import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../host/host_environment.dart';
import '../host/process_runner.dart';

/// Whether a project's packages can be used as they are (spec §6.5).
final class PackagesStatus {
  /// Creates the status.
  const PackagesStatus({
    required this.fresh,
    required this.reason,
    required this.workspaceRoot,
  });

  /// Whether `flutter pub get` can be skipped, by Flutter's own rule.
  final bool fresh;

  /// Why the packages are fresh or not, in words that follow "because",
  /// such as "pubspec.yaml changed after they were fetched".
  final String reason;

  /// The folder that holds `.dart_tool/package_config.json` and
  /// `pubspec.lock`: the project itself, or the root of its pub workspace.
  final String workspaceRoot;
}

/// Decides whether the project at [projectRoot] needs `flutter pub get`
/// before it can be analyzed. It uses the rule that `flutter run`,
/// `flutter analyze` and `flutter test` use (flutter_tools'
/// `pub.dart`, `get` with `checkUpToDate`), for the Flutter framework
/// version [flutterVersion].
///
/// In a pub workspace, the package config and lock file are read from the
/// workspace root that `.dart_tool/pub/workspace_ref.json` names. Flutter's
/// code joins that folder as if it were the file, so it always re-fetches
/// there; Appstein reads what the reference means (see the developer
/// guide's project-map page).
PackagesStatus checkPackages(
  String projectRoot, {
  required String flutterVersion,
}) {
  final workspaceRoot = _workspaceRoot(projectRoot);
  PackagesStatus status(bool fresh, String reason) => PackagesStatus(
    fresh: fresh,
    reason: reason,
    workspaceRoot: workspaceRoot,
  );
  try {
    final config = File(
      p.join(workspaceRoot, '.dart_tool', 'package_config.json'),
    );
    if (!config.existsSync()) {
      return status(
        false,
        'they had not been fetched (there was no '
        '.dart_tool/package_config.json)',
      );
    }
    final generator = _generator(config);
    if (generator != null && generator != 'pub') {
      return status(
        true,
        'the package config was written by $generator, so it is used as '
        'it is',
      );
    }
    final lock = File(p.join(workspaceRoot, 'pubspec.lock'));
    if (!lock.existsSync()) return status(false, 'there was no pubspec.lock');
    final pubspecTime = File(
      p.join(projectRoot, 'pubspec.yaml'),
    ).lastModifiedSync();
    if (!pubspecTime.isBefore(lock.lastModifiedSync()) ||
        !pubspecTime.isBefore(config.lastModifiedSync())) {
      return status(false, 'pubspec.yaml changed after they were fetched');
    }
    final version = File(p.join(workspaceRoot, '.dart_tool', 'version'));
    if (!version.existsSync()) {
      return status(
        false,
        'they were not fetched by Flutter (there was no .dart_tool/version)',
      );
    }
    // Compared exactly, as Flutter does: it writes the file without a
    // newline.
    final fetchedWith = version.readAsStringSync();
    if (fetchedWith != flutterVersion) {
      return status(
        false,
        'they were fetched with Flutter ${fetchedWith.trim()}, not '
        '$flutterVersion',
      );
    }
    return status(true, 'they are up to date');
  } on FileSystemException catch (error) {
    return status(
      false,
      'they could not be checked (${fileErrorReason(error)})',
    );
  }
}

/// Runs `flutter pub get` in [projectRoot] with the Flutter SDK at
/// [flutterRoot], as `flutter run` does when the packages are stale.
///
/// Returns null when it worked. Otherwise it returns why it didn't, ending
/// with the last lines Flutter printed.
Future<String?> fetchPackages(
  String projectRoot, {
  required String flutterRoot,
  required HostOs os,
  required ProcessRunner runner,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final flutter = p.join(
    flutterRoot,
    'bin',
    os == HostOs.windows ? 'flutter.bat' : 'flutter',
  );
  final result = await runner.run(
    flutter,
    const ['pub', 'get'],
    timeout: timeout,
    workingDirectory: projectRoot,
  );
  if (!result.started) {
    return 'Flutter could not be started (${result.stderr.trim()})';
  }
  if (result.timedOut) {
    return '`flutter pub get` did not finish within ${_duration(timeout)}';
  }
  if (result.exitCode != 0) {
    final output = result.stderr.trim().isEmpty
        ? result.stdout.trim()
        : result.stderr.trim();
    return '`flutter pub get` failed with exit code ${result.exitCode}'
        '${output.isEmpty ? '' : ':\n${_lastLines(output, 10)}'}';
  }
  final config = File(
    p.join(_workspaceRoot(projectRoot), '.dart_tool', 'package_config.json'),
  );
  if (!config.existsSync()) {
    return '`flutter pub get` finished but did not create '
        '.dart_tool/package_config.json';
  }
  return null;
}

/// [duration] in words: whole minutes when it divides evenly, else seconds.
String _duration(Duration duration) {
  final seconds = duration.inSeconds;
  final (count, unit) = seconds > 0 && seconds % 60 == 0
      ? (seconds ~/ 60, 'minute')
      : (seconds, 'second');
  return '$count $unit${count == 1 ? '' : 's'}';
}

String _workspaceRoot(String projectRoot) {
  final reference = File(
    p.join(projectRoot, '.dart_tool', 'pub', 'workspace_ref.json'),
  );
  if (!reference.existsSync()) return projectRoot;
  try {
    if (jsonDecode(reference.readAsStringSync()) case {
      'workspaceRoot': final String root,
    }) {
      return p.normalize(p.join(reference.parent.path, root));
    }
  } on FormatException {
    // Invalid JSON: unlike Flutter, whose pub.dart crashes on it, fall back
    // to the project's own files. (Valid JSON of another shape is ignored by
    // Flutter too.)
  } on FileSystemException {
    // Unreadable: the same.
  }
  return projectRoot;
}

String? _generator(File config) {
  try {
    if (jsonDecode(config.readAsStringSync()) case {
      'generator': final String generator,
    }) {
      return generator;
    }
  } on FormatException {
    // Flutter treats a damaged config as one that pub wrote.
  }
  return null;
}

String _lastLines(String text, int count) {
  final lines = const LineSplitter().convert(text);
  return lines.skip(lines.length > count ? lines.length - count : 0).join('\n');
}
