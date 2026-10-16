import 'package:test/test.dart';

import '../tool/src/held_detect.dart';

// The decision of tool/measure_sync.dart about a held `sync --detect` row: the
// median of three runs, measured once more when it is 2 s or more (owner,
// 2026-10-16), and a miss only when the second median misses too.
void main() {
  /// Measures a row whose runs are [script], in the order they are asked
  /// for, and returns the row with the indices the measurement asked for.
  Future<(HeldDetect<Duration>?, List<int>)> measure(
    List<int> script, {
    bool retry = true,
    List<Duration>? retried,
  }) async {
    final asked = <int>[];
    final row = await measureHeldDetect<Duration>(
      run: (index) async {
        asked.add(index);
        return Duration(milliseconds: script[index]);
      },
      timeOf: (time) => time,
      retry: retry,
      onRetry: retried?.add,
    );
    return (row, asked);
  }

  test('a first median under the limit is not measured again', () async {
    final (row, asked) = await measure([1100, 1900, 1500]);
    expect(asked, [0, 1, 2]);
    expect(row!.retried, isFalse);
    expect(row.counted, const Duration(milliseconds: 1500));
    expect(row.miss('a detect'), isNull);
    expect(row.cell(), '1500 ms (1100, 1900, 1500)');
  });

  test('one slow run does not move the median, so it is no retry', () async {
    final (row, asked) = await measure([1100, 9000, 1500]);
    expect(asked, [0, 1, 2]);
    expect(row!.retried, isFalse);
    expect(row.miss('a detect'), isNull);
  });

  test('a first miss with a second median under the limit passes, and both '
      'are recorded', () async {
    final seen = <Duration>[];
    final (row, asked) = await measure([
      2694,
      2429,
      1850,
      1205,
      1042,
      1078,
    ], retried: seen);
    // The second measurement asks for different runs: indices 3, 4 and 5.
    expect(asked, [0, 1, 2, 3, 4, 5]);
    expect(seen, [const Duration(milliseconds: 2429)]);
    expect(row!.retried, isTrue);
    expect(row.firstMedian, const Duration(milliseconds: 2429));
    expect(row.secondMedian, const Duration(milliseconds: 1078));
    expect(row.counted, const Duration(milliseconds: 1078));
    expect(row.miss('a detect'), isNull);
    expect(
      row.cell(),
      '2429 ms (2694, 2429, 1850); '
      'again: 1078 ms (1205, 1042, 1078), counted',
    );
  });

  test('a miss twice is a miss naming both medians', () async {
    final (row, asked) = await measure([2694, 2429, 1850, 2300, 2100, 2900]);
    expect(asked, [0, 1, 2, 3, 4, 5]);
    expect(row!.retried, isTrue);
    expect(row.counted, const Duration(milliseconds: 2300));
    expect(
      row.miss('a detect after one edit'),
      'a detect after one edit took 2429 ms, the median of three, and '
      '2300 ms again (under 2 s)',
    );
  });

  test('exactly 2 s is a miss', () async {
    expect(detectMissed(const Duration(seconds: 2)), isTrue);
    expect(
      detectMissed(
        const Duration(seconds: 2) - const Duration(microseconds: 1),
      ),
      isFalse,
    );
    // Exactly 2 s at first starts the second measurement; exactly 2 s again
    // is the miss.
    final (row, asked) = await measure([2000, 2000, 2000, 2000, 2000, 2000]);
    expect(asked, [0, 1, 2, 3, 4, 5]);
    expect(row!.miss('a detect'), isNotNull);
    // And a second median just under it passes.
    final (passed, _) = await measure([2000, 2000, 2000, 1999, 1999, 1999]);
    expect(passed!.miss('a detect'), isNull);
  });

  test('without retry (a row that is not held) a slow median is measured '
      'once and is not a retry', () async {
    final (row, asked) = await measure([3000, 3100, 3200], retry: false);
    expect(asked, [0, 1, 2]);
    expect(row!.retried, isFalse);
    expect(row.cell(), '3100 ms (3000, 3100, 3200)');
  });

  test('a run that is not valid ends the measurement', () async {
    final asked = <int>[];
    final row = await measureHeldDetect<Duration>(
      run: (index) async {
        asked.add(index);
        return index == 4 ? null : const Duration(seconds: 3);
      },
      timeOf: (time) => time,
      retry: true,
    );
    expect(row, isNull);
    expect(asked, [0, 1, 2, 3, 4]);
  });

  test('the median run of each attempt is kept', () async {
    final row = HeldDetect<String>(
      ['a', 'b', 'c'],
      ['d', 'e', 'f'],
      (name) => Duration(
        milliseconds: {
          'a': 3000,
          'b': 2500,
          'c': 2000,
          'd': 1500,
          'e': 1000,
          'f': 1200,
        }[name]!,
      ),
    );
    expect(row.firstMedianRun, 'b');
    expect(row.secondMedianRun, 'f');
    expect(row.counted, const Duration(milliseconds: 1200));
  });
}
