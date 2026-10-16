/// The limit of a held `sync --detect` row: spec §15's 2 s. A median of
/// exactly 2 s misses.
const detectLimit = Duration(seconds: 2);

/// Whether a [median] of a held `sync --detect` row misses the limit
/// ([detectLimit], exactly 2 s included).
bool detectMissed(Duration median) => median >= detectLimit;

/// One held `sync --detect` row of `tool/measure_sync.dart`: the median of
/// three runs and, when that median missed the limit, a second measurement
/// of three fresh runs (owner decision, 2026-10-16: on a slow CI runner
/// one median can miss while the rerun passes, so a row misses only when the
/// second median misses too). The second median is the one that counts.
///
/// [T] is what one run is: the tool keeps its whole result, [timeOf] gives
/// its time.
final class HeldDetect<T> {
  /// A row with the three runs of the first measurement, and the three of
  /// the second when there was one.
  HeldDetect(this.first, this.second, this._timeOf);

  /// The runs of the first measurement.
  final List<T> first;

  /// The runs of the second measurement, or null when the first median was
  /// under the limit.
  final List<T>? second;

  final Duration Function(T) _timeOf;

  /// Whether the first median missed and the row was measured again.
  bool get retried => second != null;

  /// The run with the middle time of [runs].
  T _medianRun(List<T> runs) =>
      (runs.toList()
        ..sort((a, b) => _timeOf(a).compareTo(_timeOf(b))))[runs.length ~/ 2];

  /// The run with the middle time of the first measurement.
  T get firstMedianRun => _medianRun(first);

  /// The run with the middle time of the second measurement, or null when
  /// there was none.
  T? get secondMedianRun => second == null ? null : _medianRun(second!);

  /// The median of the first measurement.
  Duration get firstMedian => _timeOf(firstMedianRun);

  /// The median of the second measurement, or null when there was none.
  Duration? get secondMedian =>
      second == null ? null : _timeOf(_medianRun(second!));

  /// The median that counts: the second one when the row was measured
  /// again, otherwise the first.
  Duration get counted => secondMedian ?? firstMedian;

  /// The three times of [runs] in the order they ran, in milliseconds.
  String _spread(List<T> runs) =>
      runs.map((run) => _timeOf(run).inMilliseconds).join(', ');

  /// The cell of the main table: the median and the three runs, and for a
  /// row measured again also the second median and its three runs, marked as
  /// the one that counted, e.g.
  /// `2429 ms (2694, 2429, 1850); again: 1078 ms (1205, 1042, 1078), counted`.
  String cell() {
    final once = '${firstMedian.inMilliseconds} ms (${_spread(first)})';
    return second == null
        ? once
        : '$once; again: ${secondMedian!.inMilliseconds} ms '
              '(${_spread(second!)}), counted';
  }

  /// Why the row misses the limit, naming [what] was measured, or null when
  /// the median that counts is under it. A row measured again that misses
  /// names both medians.
  String? miss(String what) {
    if (!detectMissed(counted)) return null;
    final took =
        '$what took ${firstMedian.inMilliseconds} ms, the median of '
        'three';
    return second == null
        ? '$took (under 2 s)'
        : '$took, and ${secondMedian!.inMilliseconds} ms again (under 2 s)';
  }
}

/// Measures a held `sync --detect` row: three runs, `run(0)` to `run(2)`,
/// then, when [retry] is true and their median is [detectMissed], three more,
/// `run(3)` to `run(5)`. The index is for the caller to make a different edit
/// for each run, so every detect has a change to rebuild. [onRetry] is told
/// the first median when the second measurement starts.
///
/// [run] returns null for a run that is not valid (the caller has reported
/// why), and the measurement ends there with null.
Future<HeldDetect<T>?> measureHeldDetect<T>({
  required Future<T?> Function(int index) run,
  required Duration Function(T) timeOf,
  required bool retry,
  void Function(Duration firstMedian)? onRetry,
}) async {
  Future<List<T>?> three(int from) async {
    final runs = <T>[];
    for (var index = from; index < from + 3; index++) {
      final result = await run(index);
      if (result == null) return null;
      runs.add(result);
    }
    return runs;
  }

  final first = await three(0);
  if (first == null) return null;
  final row = HeldDetect<T>(first, null, timeOf);
  if (!retry || !detectMissed(row.firstMedian)) return row;
  onRetry?.call(row.firstMedian);
  final second = await three(3);
  return second == null ? null : HeldDetect<T>(first, second, timeOf);
}
