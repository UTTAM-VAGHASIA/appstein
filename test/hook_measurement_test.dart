import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/command_run.dart';
import '../tool/src/hook_measurement.dart';
import '../tool/src/warm_verify.dart' show limitMiss;
import 'support/temp_repo.dart';

// The hook rows with a scripted hook: a function that answers the way the
// compiled `appstein verify --fast --hook claude` does for the file on disk,
// or is made to answer wrongly. No process is started.
void main() {
  const relative = 'lib/a.dart';
  const original = '/// A.\nclass A {}\n';
  late Directory project;
  late File edited;

  setUp(() {
    project = tempFolder();
    edited = File(p.join(project.path, 'lib', 'a.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync(original);
  });

  /// The text of the finding the real hook writes to stderr for an error.
  String errorText(int line) =>
      '$relative\n  error dart.error (line $line): A value of type '
      "'String' can't be returned.\n";

  /// A hook that reads the file as it is on disk, the way the real one
  /// does: exit 2 and the error on stderr when the file holds one, else
  /// silence.
  Future<CommandRun> Function(String) hook({
    List<Duration> times = const [],
    int Function(int exit)? changeExit,
    List<String>? sessions,
    String Function(int line, String text)? changeText,
  }) {
    var call = 0;
    return (sessionId) async {
      sessions?.add(sessionId);
      final lines = edited.readAsLinesSync();
      final at = lines.indexWhere((line) => line.startsWith('int wrong'));
      final elapsed = call < times.length
          ? times[call]
          : const Duration(milliseconds: 2000);
      call++;
      if (at < 0) {
        return (exitCode: 0, stdout: '', stderr: '', elapsed: elapsed);
      }
      final text = errorText(at + 1);
      return (
        exitCode: changeExit?.call(2) ?? 2,
        stdout: '',
        stderr: changeText?.call(at + 1, text) ?? text,
        elapsed: elapsed,
      );
    };
  }

  Future<WarmHookRow> row(
    Future<CommandRun> Function(String) run, {
    int count = 3,
  }) => measureWarmHook(
    run: run,
    project: project.path,
    file: relative,
    count: count,
  );

  group('hookInput', () {
    test('is Claude Code\'s PostToolUse input: the session, the event, the '
        'project and the edited file', () {
      final json =
          jsonDecode(hookInput('s-1', project: project.path, file: relative))
              as Map<String, Object?>;
      expect(json['session_id'], 's-1');
      expect(json['hook_event_name'], 'PostToolUse');
      expect(json['cwd'], project.path);
      expect(json['tool_name'], 'Edit');
      expect(
        (json['tool_input'] as Map)['file_path'],
        p.join(project.path, 'lib', 'a.dart'),
      );
    });
  });

  group('hookRunProblem', () {
    CommandRun run({
      int exitCode = 2,
      String? stderr,
      String stdout = '',
      int line = 7,
    }) => (
      exitCode: exitCode,
      stdout: stdout,
      stderr: stderr ?? errorText(line),
      elapsed: Duration.zero,
    );

    test('passes a run that exited 2 and named the error on its line', () {
      expect(hookRunProblem(run(), file: relative, line: 7), isNull);
    });

    test('fails an exit code other than 2, whatever it printed', () {
      for (final exit in [0, 1, 3]) {
        final problem = hookRunProblem(
          run(exitCode: exit),
          file: relative,
          line: 7,
        );
        expect(problem, contains('exit code $exit'), reason: 'exit $exit');
        expect(problem, contains('expected 2'));
      }
    });

    test('fails an exit 2 that does not name the file', () {
      expect(
        hookRunProblem(
          run(stderr: '  error dart.error (line 7): x\n'),
          file: relative,
          line: 7,
        ),
        allOf(contains('does not name'), contains(relative)),
      );
    });

    test('fails an exit 2 that names the error on another line: a reply '
        'left from an earlier edit', () {
      expect(
        hookRunProblem(run(line: 6), file: relative, line: 7),
        contains('line 7'),
      );
    });

    test('fails an exit 2 for another check than dart.error', () {
      expect(
        hookRunProblem(
          run(stderr: '$relative\n  error lint.layer (line 7): x\n'),
          file: relative,
          line: 7,
        ),
        contains('dart.error'),
      );
    });
  });

  group('hookCutByCap', () {
    CommandRun run({String stdout = '', String stderr = ''}) =>
        (exitCode: 0, stdout: stdout, stderr: stderr, elapsed: Duration.zero);

    test('is true when the context or the stderr says the code checks are '
        'still pending', () {
      expect(
        hookCutByCap(
          run(
            stdout:
                '... the code checks of this change are '
                'still pending ...',
          ),
        ),
        isTrue,
      );
      expect(hookCutByCap(run(stderr: 'checks still pending')), isTrue);
    });

    test('is false for silence and for an error', () {
      expect(hookCutByCap(run()), isFalse);
      expect(hookCutByCap(run(stderr: errorText(7))), isFalse);
    });
  });

  group('hookNotReady', () {
    CommandRun run(int exitCode, {String stdout = '', String stderr = ''}) => (
      exitCode: exitCode,
      stdout: stdout,
      stderr: stderr,
      elapsed: Duration.zero,
    );

    test('is null for a silent run and for warnings', () {
      expect(hookNotReady(run(0)), isNull);
      expect(
        hookNotReady(run(0, stdout: '{"hookSpecificOutput": "2 warnings"}')),
        isNull,
      );
    });

    test('names a run cut by the cap, Appstein failing, and a run with '
        'errors', () {
      expect(
        hookNotReady(run(0, stdout: 'checks are still pending')),
        contains('not ready'),
      );
      expect(
        hookNotReady(
          run(0, stdout: 'Appstein verify could not run, so your change'),
        ),
        contains('could not run'),
      );
      expect(
        hookNotReady(run(2, stderr: errorText(3))),
        contains('exit code 2'),
      );
      expect(hookNotReady(run(3)), contains('exit code 3'));
    });
  });

  group('the limit of the hook', () {
    // limitMiss is tested in warm_verify_test.dart; the hook uses it with its
    // own label and the same 5 s.
    test('a median of 5.000 s fails and 4.999 s passes, naming the hook', () {
      expect(limitMiss('hook', const Duration(milliseconds: 4999)), isNull);
      expect(
        limitMiss('hook', const Duration(milliseconds: 5000)),
        allOf(startsWith('The hook took 5000 ms'), contains('not changed')),
      );
    });
  });

  group('measureWarmHook', () {
    test('three runs, each after its own edit and with its own session: '
        'the times in order, the median, the file put back', () async {
      final sessions = <String>[];
      final result = await row(
        hook(
          times: const [
            Duration(milliseconds: 2500),
            Duration(milliseconds: 1500),
            Duration(milliseconds: 2000),
          ],
          sessions: sessions,
        ),
      );
      expect(result.problem, isNull);
      expect(result.times, const [
        Duration(milliseconds: 2500),
        Duration(milliseconds: 1500),
        Duration(milliseconds: 2000),
      ]);
      expect(result.median, const Duration(milliseconds: 2000));
      expect(sessions.toSet(), hasLength(3));
      expect(edited.readAsStringSync(), original);
    });

    test('every run is after an edit of its own: the error is on a line of '
        'its own, so a reply left from an earlier edit fails', () async {
      final seen = <String>[];
      final result = await row((sessionId) async {
        seen.add(edited.readAsStringSync());
        return hook()(sessionId);
      });
      expect(result.problem, isNull);
      expect(seen.toSet(), hasLength(3));
      for (final text in seen) {
        expect(text, contains('int wrong'));
      }
    });

    test(
      'a run that exited 0 fails the row at once, whatever its time',
      () async {
        final result = await row(
          hook(
            changeExit: (_) => 0,
            times: const [Duration(milliseconds: 100)],
          ),
        );
        expect(
          result.problem,
          allOf(contains('run 1'), contains('exit code 0')),
        );
        expect(result.times, hasLength(1));
        expect(edited.readAsStringSync(), original);
      },
    );

    test('a run that did not name the error fails the row', () async {
      final result = await row(
        hook(changeText: (line, _) => 'something else\n'),
      );
      expect(
        result.problem,
        allOf(contains('run 1'), contains('does not name')),
      );
    });

    test('a run that names the error of the edit before fails the second '
        'run', () async {
      var call = 0;
      final result = await row((sessionId) async {
        call++;
        final run = await hook()(sessionId);
        // From the second run on the hook repeats the first one's line.
        return call < 2
            ? run
            : (
                exitCode: 2,
                stdout: '',
                stderr: errorText(7),
                elapsed: run.elapsed,
              );
      });
      expect(result.problem, contains('run 2'));
      expect(result.times, hasLength(2));
    });

    test('the file is put back when the hook throws', () async {
      await expectLater(
        row((_) async => throw StateError('the hook did not start')),
        throwsA(isA<StateError>()),
      );
      expect(edited.readAsStringSync(), original);
    });
  });

  group('measureNoHostHook', () {
    Future<NoHostHookRow> cold(Future<CommandRun> Function(String) run) =>
        measureNoHostHook(run: run, project: project.path, file: relative);

    test('a host that came in time: exit 2 naming the error, the cap not '
        'reached, the file put back', () async {
      final result = await cold(
        hook(times: const [Duration(milliseconds: 9000)]),
      );
      expect(result.problem, isNull);
      expect(result.reachedCap, isFalse);
      expect(result.run!.elapsed, const Duration(milliseconds: 9000));
      expect(edited.readAsStringSync(), original);
    });

    test('a run cut by the cap is not a failure: it says it reached the '
        'cap and keeps the time', () async {
      final result = await cold(
        (_) async => (
          exitCode: 0,
          stdout:
              '{"additionalContext": "the code checks of this change are '
              'still pending"}',
          stderr: '',
          elapsed: const Duration(milliseconds: 20400),
        ),
      );
      expect(result.problem, isNull);
      expect(result.reachedCap, isTrue);
      expect(result.run!.elapsed, const Duration(milliseconds: 20400));
    });

    test('a run that neither named the error nor was cut fails', () async {
      final result = await cold(hook(changeExit: (_) => 0));
      expect(result.problem, contains('exit code 0'));
      expect(result.reachedCap, isFalse);
      expect(result.run, isNotNull);
    });
  });

  group('waitUntilHostReady', () {
    test('ready at the first clean run: one run', () async {
      var runs = 0;
      final problem = await waitUntilHostReady(
        run: (_) async {
          runs++;
          return (exitCode: 0, stdout: '', stderr: '', elapsed: Duration.zero);
        },
      );
      expect(problem, isNull);
      expect(runs, 1);
    });

    test('runs again, with a session of its own each time, until a run is '
        'not cut', () async {
      final sessions = <String>[];
      final problem = await waitUntilHostReady(
        pause: Duration.zero,
        run: (sessionId) async {
          sessions.add(sessionId);
          return (
            exitCode: 0,
            stdout: sessions.length < 3 ? 'checks are still pending' : '',
            stderr: '',
            elapsed: Duration.zero,
          );
        },
      );
      expect(problem, isNull);
      expect(sessions.toSet(), hasLength(3));
    });

    test('gives up after its attempts, and says why the last run was not '
        'ready', () async {
      var runs = 0;
      final problem = await waitUntilHostReady(
        attempts: 4,
        pause: Duration.zero,
        run: (_) async {
          runs++;
          return (
            exitCode: 0,
            stdout: 'Appstein verify could not run: no host',
            stderr: '',
            elapsed: Duration.zero,
          );
        },
      );
      expect(runs, 4);
      expect(problem, allOf(contains('4'), contains('could not run')));
    });
  });
}
