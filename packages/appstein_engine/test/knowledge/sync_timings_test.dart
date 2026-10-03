import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  test('add sums a step and keeps the order steps first ran in', () {
    final timings = SyncTimings()
      ..add('b', const Duration(milliseconds: 5))
      ..add('a', const Duration(milliseconds: 1))
      ..add('b', const Duration(milliseconds: 7));
    expect(timings.steps, {
      'b': const Duration(milliseconds: 12),
      'a': const Duration(milliseconds: 1),
    });
    expect(timings.steps.keys, ['b', 'a']);
  });

  test('a step comes before the parts added while it runs', () async {
    final timings = SyncTimings();
    await timings.timeAsync('write', () async {
      timings.add('  rename', const Duration(milliseconds: 1));
    });
    timings.time('save', () => timings.add('  encode', Duration.zero));
    expect(timings.steps.keys, ['write', '  rename', 'save', '  encode']);
  });

  test('time returns the result and records the step', () {
    final timings = SyncTimings();
    expect(timings.time('step', () => 42), 42);
    expect(timings.steps.keys, ['step']);
  });

  test('time records the step when it throws', () {
    final timings = SyncTimings();
    expect(
      () => timings.time<void>('step', () => throw StateError('x')),
      throwsStateError,
    );
    expect(timings.steps.keys, ['step']);
  });

  test(
    'timeAsync waits for the step and records it, even when it throws',
    () async {
      final timings = SyncTimings();
      final result = await timings.timeAsync('slow', () async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return 'done';
      });
      expect(result, 'done');
      expect(
        timings.steps['slow']! >= const Duration(milliseconds: 30),
        isTrue,
      );
      await expectLater(
        timings.timeAsync<void>('fails', () async => throw StateError('x')),
        throwsStateError,
      );
      expect(timings.steps.keys, ['slow', 'fails']);
    },
  );

  test('steps cannot be changed from outside', () {
    expect(
      () => SyncTimings().steps['x'] = Duration.zero,
      throwsUnsupportedError,
    );
  });
}
