import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart'
    show analysisHostFolderVariable;

import 'terminal_verify.dart' show analysisCacheVariable;

/// Starts a process the way `Process.start` does; a test gives its own.
typedef ProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

/// What every `appstein` process that a measurement of `tool/measure_sync.dart`
/// starts has in common: the compiled binary, the app it runs on, the Flutter
/// SDK that runs the tool, and the folder of the analysis hosts' address files
/// (a folder in the tool's work folder, so a developer's own hosts take no
/// part and the hosts the tool starts can be found and ended).
final class MeasureContext {
  /// Creates the context. [start] starts a process; tests give their own.
  const MeasureContext({
    required this.executable,
    required this.project,
    required this.flutterRoot,
    required this.hostFolder,
    this.start = Process.start,
  });

  /// The compiled `appstein` binary.
  final String executable;

  /// The folder of the app the processes run on.
  final String project;

  /// The Flutter SDK whose Dart runs the tool (`FLUTTER_ROOT`).
  final String flutterRoot;

  /// The folder of the analysis hosts' address files
  /// ([analysisHostFolderVariable]).
  final String hostFolder;

  /// Starts a process.
  final ProcessStarter start;

  /// The environment of every `appstein` process: the Flutter SDK, the folder
  /// of the hosts' address files and, when [cache] is given, the analysis
  /// server's disk cache in that folder ([analysisCacheVariable]).
  Map<String, String> environment([String? cache]) => {
    'FLUTTER_ROOT': flutterRoot,
    analysisHostFolderVariable: hostFolder,
    analysisCacheVariable: ?cache,
  };
}
