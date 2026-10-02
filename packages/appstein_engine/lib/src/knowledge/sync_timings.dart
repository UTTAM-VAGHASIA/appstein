/// How long each step of one sync took (`SyncReport.timings`), for
/// measuring where a sync's time goes (`tool/measure_sync.dart`,
/// `appstein sync --timings`).
///
/// A step that runs more than once adds up. A name that starts with two
/// spaces is part of the step before it (the renames inside the knowledge
/// write, say), so only the other names add up to the whole sync.
final class SyncTimings {
  final Map<String, Duration> _steps = {};

  /// Each step's total time, in the order the steps first started, so a step
  /// comes before the parts timed inside it.
  Map<String, Duration> get steps => Map.unmodifiable(_steps);

  /// Adds [elapsed] to [step].
  void add(String step, Duration elapsed) =>
      _steps.update(step, (total) => total + elapsed, ifAbsent: () => elapsed);

  /// Runs [run] as [step] and returns its result. The time counts even when
  /// it throws.
  T time<T>(String step, T Function() run) {
    _steps.putIfAbsent(step, () => Duration.zero);
    final watch = Stopwatch()..start();
    try {
      return run();
    } finally {
      add(step, watch.elapsed);
    }
  }

  /// Runs [run] as [step], as [time] does, waiting for it to finish.
  Future<T> timeAsync<T>(String step, Future<T> Function() run) async {
    _steps.putIfAbsent(step, () => Duration.zero);
    final watch = Stopwatch()..start();
    try {
      return await run();
    } finally {
      add(step, watch.elapsed);
    }
  }
}
