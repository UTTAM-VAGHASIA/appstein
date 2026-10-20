import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/command_run.dart';
import '../tool/src/hook_rows.dart';
import '../tool/src/process_memory.dart';
import 'support/measure_fixtures.dart';
import 'support/temp_repo.dart';

// The order of the hook measurement (no host, wait, host ready, end the host,
// sharing) against a scripted world: a hook that reads the edited file from
// disk and starts a host, hosts that are a flag, and the real fake MCP server
// for the sessions of the sharing check. No host is started or ended.
void main() {
  const relative = 'lib/a.dart';
  late File edited;

  setUp(() {
    edited = File(p.join(tempFolder().path, 'lib', 'a.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('/// A.\nclass A {}\n');
  });

  const cut = (
    exitCode: 0,
    stdout: 'the code checks of this change are still pending',
    stderr: '',
    elapsed: Duration(milliseconds: 20000),
  );

  /// One scripted world: [events] are what happened in order.
  Future<(HookResults, List<String>)> measure({
    CommandRun? Function(String sessionId, int call)? script,
    bool hostBefore = false,
    List<String?> endProblems = const [],
    int readyAttempts = 6,
  }) async {
    final events = <String>[];
    var hostUp = hostBefore;
    var calls = 0;
    var ends = 0;
    final sessions = <int>[];
    final results = await measureHookRows(
      project: edited.parent.parent.path,
      file: relative,
      pause: Duration.zero,
      clock: () => 10000,
      run: (sessionId) async {
        events.add('run $sessionId');
        final scripted = script?.call(sessionId, calls++);
        // Any hook run starts a host when none runs.
        hostUp = true;
        if (scripted != null) return scripted;
        final lines = edited.readAsLinesSync();
        final at = lines.indexWhere((line) => line.startsWith('int wrong'));
        return at < 0
            ? (exitCode: 0, stdout: '', stderr: '', elapsed: Duration.zero)
            : (
                exitCode: 2,
                stdout: '',
                stderr:
                    '$relative\n  error dart.error (line ${at + 1}): '
                    "A value of type 'String' can't be returned.\n",
                elapsed: const Duration(milliseconds: 2000),
              );
      },
      startSession: () async {
        events.add('start session');
        final session = await startFakeMcp(file: edited, name: relative);
        sessions.add(session.pid);
        hostUp = true;
        return session;
      },
      hostIds: () => hostUp ? [100] : [],
      endHosts: () async {
        events.add('end hosts');
        hostUp = false;
        final problem = ends < endProblems.length ? endProblems[ends] : null;
        ends++;
        return problem;
      },
      lister: () async => [
        for (final pid in sessions) ProcessRow(pid, 1, 10000, 5000, 'appstein'),
        if (hostUp) ...hostTreeRows(parent: sessions.first),
      ],
    );
    return (results, events);
  }

  test('runs the rows in order: no host, the wait for the host, three runs '
      'with the host ready, the host ended, then the sharing check, which '
      'ends its own host', () async {
    final (results, events) = await measure();
    expect(results.problem, isNull);
    expect(events, [
      'run measure-hook-no-host',
      'run measure-hook-ready-0',
      'run measure-hook-0',
      'run measure-hook-1',
      'run measure-hook-2',
      'end hosts',
      'start session',
      'start session',
      'run measure-hook-sharing',
      'end hosts',
    ]);
    expect(results.noHost!.reachedCap, isFalse);
    expect(results.hostReady!.times, hasLength(3));
    expect(results.sharing!.problem, isNull);
    expect(results.sharing!.servers, 1);
    expect(edited.readAsStringSync(), '/// A.\nclass A {}\n');
  });

  test('a no-host run cut by the cap is recorded, and the wait for the '
      'host goes on until a run is not cut', () async {
    final (results, events) = await measure(
      script: (session, call) => call < 2 ? cut : null,
    );
    expect(results.problem, isNull);
    expect(results.noHost!.reachedCap, isTrue);
    expect(events.where((e) => e.contains('ready')), [
      'run measure-hook-ready-0',
      'run measure-hook-ready-1',
    ]);
    expect(results.hostReady!.times, hasLength(3));
  });

  test('a host that does not get ready fails it, ends the host and goes '
      'no further', () async {
    final (results, events) = await measure(
      script: (session, call) => call == 0 ? null : cut,
    );
    expect(results.problem, contains('not ready'));
    expect(results.hostReady, isNull);
    expect(results.sharing, isNull);
    expect(events.last, 'end hosts');
    expect(events.where((e) => e == 'end hosts'), hasLength(1));
  });

  test('a host running before the first row fails it with no hook run, '
      'and the hosts are ended', () async {
    final (results, events) = await measure(hostBefore: true);
    expect(results.problem, contains('was running'));
    expect(events, ['end hosts']);
  });

  test('a no-host run that neither named the error nor was cut fails it, '
      'with no host-ready row and no sharing check', () async {
    final (results, events) = await measure(
      script: (session, call) => call == 0
          ? (exitCode: 0, stdout: '', stderr: '', elapsed: Duration.zero)
          : null,
    );
    expect(results.problem, contains('the hook with no host running'));
    expect(results.noHost!.problem, isNotNull);
    expect(results.hostReady, isNull);
    expect(results.sharing, isNull);
    expect(events.last, 'end hosts');
  });

  test('a host-ready run that did not exit 2 fails it, names the run, and '
      'skips the sharing check', () async {
    final (results, _) = await measure(
      // Calls: 0 no host, 1 ready, 2 the first host-ready run, 3 the second.
      script: (session, call) => call == 3
          ? (exitCode: 0, stdout: '', stderr: '', elapsed: Duration.zero)
          : null,
    );
    expect(results.problem, contains('the hook with the host ready'));
    expect(results.problem, contains('run 2'));
    expect(results.hostReady!.times, hasLength(2));
    expect(results.sharing, isNull);
  });

  test('a hook run that throws (it never ended, or its output stayed '
      'open) is the problem, and the hosts are ended', () async {
    final (results, events) = await measure(
      script: (session, call) => call == 2
          ? throw StateError(
              'the hook had not ended after 120 s, and was killed',
            )
          : null,
    );
    expect(results.problem, contains('had not ended'));
    expect(events.last, 'end hosts');
    expect(results.sharing, isNull);
  });

  test('an exception that is not a StateError (a process that cannot be '
      'started) is the problem too, with its message, and the hosts are '
      'ended', () async {
    final (results, events) = await measure(
      script: (session, call) => call == 2
          ? throw const ProcessException('/work/appstein', [], 'not found', 2)
          : null,
    );
    expect(results.problem, contains('not found'));
    expect(events.last, 'end hosts');
    expect(results.sharing, isNull);
    expect(edited.readAsStringSync(), '/// A.\nclass A {}\n');
  });

  test('hosts that could not be ended fail it, and the sharing check '
      'does not run', () async {
    final (results, events) = await measure(
      endProblems: ['processes of the analysis host are still running: 100'],
    );
    expect(results.problem, contains('still running: 100'));
    expect(results.hostReady!.times, hasLength(3));
    expect(results.sharing, isNull);
    expect(events, isNot(contains('start session')));
  });

  test('a failed sharing check is the problem, prefixed, with the rows '
      'before it kept', () async {
    final (results, _) = await measure(
      script: (session, call) => session == 'measure-hook-sharing' ? cut : null,
    );
    expect(results.problem, startsWith('the sharing check:'));
    expect(results.hostReady!.times, hasLength(3));
    expect(results.noHost, isNotNull);
  });
}
