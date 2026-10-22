import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';

/// One choice of the analysis host's folder as a hook process makes it: the
/// kind of place chosen (`AnalysisHostFolderChoice.kind`, not the path) and
/// how many processes it started.
typedef HostFolderChooser =
    ({AnalysisHostPlaceKind kind, int processes}) Function();

/// What [measureHostFolderChoice] found.
final class HostFolderChoiceResult {
  /// Creates the result.
  HostFolderChoiceResult({
    required this.os,
    required this.kind,
    required this.first,
    required this.others,
    required this.processes,
  });

  /// The system it ran on.
  final HostOs os;

  /// The kind of place the choices gave (every choice gives the same one);
  /// null when they did not.
  final AnalysisHostPlaceKind? kind;

  /// The first choice's time: the one a hook process pays, with the
  /// libraries the system calls need loaded.
  final Duration first;

  /// The times of the other choices.
  final List<Duration> others;

  /// The processes each choice started, in order.
  final List<int> processes;

  /// The median of [others].
  Duration get median {
    final sorted = [...others]..sort();
    return sorted.isEmpty ? Duration.zero : sorted[sorted.length ~/ 2];
  }

  /// Why the run fails, or null: on Windows a choice may start no process,
  /// and on macOS none when the system named the user's temporary folder.
  /// Linux is reported only (at most one `stat` is expected).
  String? get problem {
    final most = processes.fold(0, (a, b) => a > b ? a : b);
    if (os == HostOs.windows && most > 0) {
      return 'a choice of the host folder on Windows started $most '
          'process(es); it must start none';
    }
    if (os == HostOs.macos &&
        kind == AnalysisHostPlaceKind.userTemp &&
        most > 0) {
      return "a choice of the host folder in macOS's temporary folder "
          'started $most process(es); it must start none';
    }
    return null;
  }

  /// The table for the log.
  String table() {
    String ms(Duration time) =>
        '${(time.inMicroseconds / 1000).toStringAsFixed(1)} ms';
    final most = processes.fold(0, (a, b) => a > b ? a : b);
    return '''
| Host folder choice (${os.name}, a fresh environment each, no APPSTEIN_ANALYSIS_HOST_FOLDER) | |
|---|---|
| Place chosen | ${kind?.name ?? 'mixed'} |
| First choice (what a hook pays, libraries loaded) | ${ms(first)} |
| Median of the other ${others.length} | ${ms(median)} |
| Processes started per choice (target: none on Windows, none on macOS in its temporary folder) | $most at most (${processes.join(', ')}) |
''';
  }
}

/// Measures the choice of the analysis host's folder as a hook process makes
/// it, [choices] times: each with a fresh environment and fresh facts of the
/// machine, as a new process has, and without
/// `APPSTEIN_ANALYSIS_HOST_FOLDER`, so the machine's own place is chosen.
/// It writes nothing: a choice makes no folder. [choose] replaces the real
/// choice (for the project at [projectRoot]), for tests.
HostFolderChoiceResult measureHostFolderChoice({
  required String projectRoot,
  HostOs? os,
  int choices = 21,
  HostFolderChooser? choose,
}) {
  final chooser = choose ?? () => _realChoice(projectRoot);
  final times = <Duration>[];
  final kinds = <AnalysisHostPlaceKind>{};
  final processes = <int>[];
  for (var i = 0; i < choices; i++) {
    final watch = Stopwatch()..start();
    final (:kind, processes: started) = chooser();
    watch.stop();
    times.add(watch.elapsed);
    kinds.add(kind);
    processes.add(started);
  }
  return HostFolderChoiceResult(
    os: os ?? HostOs.current,
    kind: kinds.length == 1 ? kinds.single : null,
    first: times.first,
    others: times.skip(1).toList(),
    processes: processes,
  );
}

/// The real choice, with a fresh environment and facts, its processes
/// counted.
({AnalysisHostPlaceKind kind, int processes}) _realChoice(String projectRoot) {
  var started = 0;
  final environment = HostEnvironment(
    os: HostOs.current,
    variables: {
      for (final MapEntry(:key, :value) in Platform.environment.entries)
        if (key.toUpperCase() != analysisHostFolderVariable) key: value,
    },
    workingDirectory: Directory.current.path,
    facts: MachineFacts(),
  );
  final chosen = chooseAnalysisHostFolder(
    environment,
    projectRoot: projectRoot,
    runSync: (executable, arguments) {
      started++;
      return Process.runSync(executable, arguments);
    },
  );
  return (kind: chosen.kind, processes: started);
}
