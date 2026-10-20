import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/hook_process.dart';
import '../tool/src/measure_context.dart';
import 'support/fake_process.dart';

// The hook's process with a scripted process: nothing is started. The time is
// the later of the exit and the close of the output (owner decision,
// 2026-10-21), and a hook that never ends or whose output stays open fails.
void main() {
  late List<(String, List<String>, String?, Map<String, String>?)> started;

  MeasureContext contextOf(FakeProcess process) {
    started = [];
    return MeasureContext(
      executable: '/work/appstein',
      project: '/work/app',
      flutterRoot: '/sdk',
      hostFolder: '/work/hosts',
      start: (executable, arguments, {workingDirectory, environment}) async {
        started.add((executable, arguments, workingDirectory, environment));
        return process;
      },
    );
  }

  Duration ms(int n) => Duration(milliseconds: n);

  test('starts the compiled hook the way Claude Code does: in the project, '
      'with the hook arguments, the input on stdin and the environment of the '
      'context with the analysis cache', () async {
    final process = FakeProcess(stdoutText: 'out', stderrText: 'err');
    final run = await runHook(
      contextOf(process),
      cache: '/work/cache',
      input: '{"session_id":"s"}',
    );
    expect(started, hasLength(1));
    final (executable, arguments, directory, environment) = started.single;
    expect(executable, '/work/appstein');
    expect(arguments, ['verify', '--fast', '--hook', 'claude']);
    expect(directory, '/work/app');
    expect(environment!['FLUTTER_ROOT'], '/sdk');
    expect(environment['APPSTEIN_ANALYSIS_HOST_FOLDER'], '/work/hosts');
    expect(environment['ANALYZER_STATE_LOCATION_OVERRIDE'], '/work/cache');
    expect(process.written.toString(), '{"session_id":"s"}');
    expect(run.exitCode, 0);
    expect(run.stdout, 'out');
    expect(run.stderr, 'err');
  });

  test('the time is to the exit when the output closed first', () async {
    final process = FakeProcess(
      exitCodeValue: 2,
      exitAfter: ms(300),
      stdoutClosesAfter: ms(20),
      stderrClosesAfter: ms(20),
    );
    final run = await runHook(contextOf(process), cache: 'c', input: '{}');
    expect(run.exitCode, 2);
    expect(run.elapsed, greaterThanOrEqualTo(ms(300)));
    expect(run.elapsed, lessThan(ms(1500)));
  });

  test(
    'the time is to the close of the output when that comes after the '
    'exit: a hook is not done for Claude Code before its output is',
    () async {
      final process = FakeProcess(
        exitAfter: ms(20),
        stdoutClosesAfter: ms(20),
        stderrClosesAfter: ms(500),
      );
      final run = await runHook(contextOf(process), cache: 'c', input: '{}');
      expect(run.elapsed, greaterThanOrEqualTo(ms(500)));
      expect(run.elapsed, lessThan(ms(1500)));
    },
  );

  test('the later close of the two streams counts', () async {
    final process = FakeProcess(
      exitAfter: ms(10),
      stdoutClosesAfter: ms(450),
      stderrClosesAfter: ms(10),
    );
    final run = await runHook(contextOf(process), cache: 'c', input: '{}');
    expect(run.elapsed, greaterThanOrEqualTo(ms(450)));
  });

  test('output still open long after the exit fails, with the time of the '
      'exit and the patience', () async {
    final process = FakeProcess(exitAfter: ms(20), stdoutClosesAfter: null);
    await expectLater(
      runHook(
        contextOf(process),
        cache: 'c',
        input: '{}',
        outputPatience: ms(300),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('output stayed open'),
            contains('Claude Code would wait'),
            contains('ms, but'),
          ),
        ),
      ),
    );
  });

  test('a hook that never ends is killed after the limit, and fails', () async {
    final process = FakeProcess(exitAfter: null);
    await expectLater(
      runHook(contextOf(process), cache: 'c', input: '{}', limit: ms(200)),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('had not ended'), contains('killed')),
        ),
      ),
    );
    expect(process.killed, isTrue);
  });

  test('a process that cannot be started is a failed row with its message, '
      'not an exception of another kind', () async {
    final context = MeasureContext(
      executable: '/work/appstein',
      project: '/work/app',
      flutterRoot: '/sdk',
      hostFolder: '/work/hosts',
      start: (executable, arguments, {workingDirectory, environment}) async =>
          throw const ProcessException('/work/appstein', [], 'not found', 2),
    );
    await expectLater(
      runHook(context, cache: 'c', input: '{}'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('could not start'), contains('not found')),
        ),
      ),
    );
  });

  test('a stream error after the kill does not escape: the failure is the '
      'hook that never ended', () async {
    final uncaught = <Object>[];
    final process = FakeProcess(
      exitAfter: null,
      errorOnKill: true,
      stdoutClosesAfter: null,
      stderrClosesAfter: null,
    );
    Object? failure;
    await runZonedGuarded(() async {
      try {
        await runHook(
          contextOf(process),
          cache: 'c',
          input: '{}',
          limit: ms(200),
        );
      } on Object catch (error) {
        failure = error;
      }
      // The error of the broken pipe arrives after the throw.
      await Future<void>.delayed(ms(150));
    }, (error, stack) => uncaught.add(error));
    expect(failure, isA<StateError>());
    expect((failure! as StateError).message, contains('had not ended'));
    expect(uncaught, isEmpty);
  });

  test('an output that fails after a normal exit is a failed row with the '
      'reason', () async {
    final process = FakeProcess(exitAfter: ms(10), stdoutFails: true);
    await expectLater(
      runHook(contextOf(process), cache: 'c', input: '{}'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('output'), contains('the pipe broke')),
        ),
      ),
    );
  });

  test('a hook that ended without reading its input still gives its '
      'exit code', () async {
    final process = FakeProcess(exitCodeValue: 3);
    // The sink of a fake that is closed early: the write may fail.
    await process.stdin.close();
    final run = await runHook(contextOf(process), cache: 'c', input: '{}');
    expect(run.exitCode, 3);
  });

  test('the default bounds are 120 s for the run and 10 s for the output', () {
    expect(hookRunLimit, const Duration(seconds: 120));
    expect(hookOutputPatience, const Duration(seconds: 10));
  });
}
