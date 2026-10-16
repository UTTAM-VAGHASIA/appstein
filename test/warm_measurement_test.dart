import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/mcp_session.dart';
import '../tool/src/process_memory.dart';
import '../tool/src/warm_measurement.dart';

// The warm measurement against the fake MCP server of
// test/support/fake_mcp_server.dart, which reads the edited Dart file from
// disk the way a correct analysis server does, or is made to answer wrongly.
void main() {
  const relative = 'lib/a.dart';
  const original = '/// A.\nclass A {}\n';
  late Directory project;
  late File edited;

  setUp(() {
    project = Directory.systemTemp.createTempSync('appstein warm ');
    addTearDown(() => project.deleteSync(recursive: true));
    edited = File(p.join(project.path, 'lib', 'a.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync(original);
  });

  Future<McpSession> serve([
    List<String> flags = const [],
    Duration callTimeout = const Duration(seconds: 60),
  ]) => McpSession.start(
    Platform.resolvedExecutable,
    [
      p.join('test', 'support', 'fake_mcp_server.dart'),
      '--file',
      edited.path,
      '--name',
      relative,
      ...flags,
    ],
    clientName: 'warm_measurement_test',
    callTimeout: callTimeout,
  );

  Future<WarmResult> measure(
    McpSession session, {
    ProcessLister lister = listProcesses,
  }) => measureWarm(
    session,
    project: project.path,
    file: relative,
    lister: lister,
    goneAttempts: 20,
    goneDelay: const Duration(milliseconds: 100),
  );

  test('a server that reports each edit as it is on disk passes: three '
      'timed runs of each kind, the error found on its line each time, the '
      'file put back, and nothing left running', () async {
    final session = await serve();
    final result = await measure(session);
    expect(result.problem, isNull);
    expect(result.fast, hasLength(3));
    expect(result.fixed, hasLength(3));
    expect(result.refresh, hasLength(3));
    expect(result.afterRefresh, hasLength(3));
    expect(result.startUp, greaterThan(Duration.zero));
    expect(result.memoryReady, greaterThan(1024 * 1024));
    expect(result.memoryAfter, greaterThan(1024 * 1024));
    expect(edited.readAsStringSync(), original);
    // The measurement closed it.
    expect(await session.close(), isTrue);
  });

  test('a fast answer that missed every change fails, whatever its '
      'time', () async {
    final result = await measure(await serve(['--blind']));
    expect(result.problem, allOf(contains('edit 0'), contains('dart.error')));
    expect(result.fast, hasLength(1));
  });

  test('an answer that still reports the error after it was fixed fails '
      '(first loop)', () async {
    // Call 1 is the warm-up, 2 the first edit, 3 the check after the fix.
    final result = await measure(await serve(['--stale-after', '3']));
    expect(result.problem, contains('after fixing edit 0'));
    expect(result.problem, contains('still reports an error'));
  });

  test('an answer that still reports the error after it was fixed fails '
      'in the rows that say where the time goes too', () async {
    // 1 warm-up, 2-7 the first loop, 8 the timed call of edit 3, 9 the check
    // after it was fixed.
    final result = await measure(await serve(['--stale-after', '9']));
    expect(result.problem, contains('after fixing edit 3'));
    expect(result.afterRefresh, hasLength(1));
  });

  test('an answer repeated from the call before fails: a clean answer '
      'repeated for an edit with an error', () async {
    // From call 4 (the second edit) on the server repeats the answer of
    // call 3, a clean one.
    final result = await measure(await serve(['--stale-after', '4']));
    expect(result.problem, contains('edit 1'));
    expect(result.problem, contains('does not report a dart.error'));
  });

  test('an answer that names the line of an earlier edit fails: every edit '
      'has its error on a line of its own', () async {
    // The server reports the first line it ever reported while the file has
    // an error. Edit 0 is on line 5 and passes; edit 1 is on line 6.
    final result = await measure(await serve(['--sticky-line']));
    expect(result.problem, contains('edit 1'));
    expect(result.problem, contains('$relative:6'));
  });

  test(
    'a verify call that answers with an error fails with its text',
    () async {
      final result = await measure(await serve(['--error-reply-at', '4']));
      expect(
        result.problem,
        allOf(contains('error'), contains('The analysis server is gone.')),
      );
    },
  );

  test('an error already in the project before the first edit fails the '
      'warm-up', () async {
    edited.writeAsStringSync("int wrong9() => 'x';\n");
    final result = await measure(await serve());
    expect(result.problem, contains('the first verify call'));
  });

  test('a call that gets no answer in time is a problem, not an '
      'exception', () async {
    final session = await serve([
      '--slow-ms',
      '1500',
    ], const Duration(milliseconds: 500));
    final result = await measure(session);
    expect(result.problem, contains('no answer'));
  });

  test('a first call that gets no answer still checks that nothing is left '
      'running: the tree is listed before the session is closed', () async {
    final session = await serve([
      '--slow-ms',
      '1500',
    ], const Duration(milliseconds: 500));
    final result = await measure(
      session,
      lister: () async => [
        ProcessRow(session.pid, 1, 1 << 20, 1000),
        // A guard and a server that outlive appstein mcp.
        ProcessRow(999993, session.pid, 1 << 20, 2000),
      ],
    );
    expect(result.problem, contains('no answer'));
    expect(result.problem, contains('999993'));
    expect(result.problem, contains('still running'));
  });

  test('a first call that answers with an error checks for leftovers '
      'too', () async {
    final session = await serve(['--error-reply-at', '1']);
    final result = await measure(
      session,
      lister: () async => [
        ProcessRow(session.pid, 1, 1 << 20, 1000),
        ProcessRow(999994, session.pid, 1 << 20, 2000),
      ],
    );
    expect(result.problem, contains('the first verify call'));
    expect(result.problem, contains('999994'));
  });

  test('a server that does not end when its input closes is killed, and '
      'the run fails', () async {
    final session = await serve(['--stubborn']);
    final result = await measureWarm(
      session,
      project: project.path,
      file: relative,
      lister: listProcesses,
      goneAttempts: 3,
      goneDelay: const Duration(milliseconds: 100),
      closePatience: const Duration(milliseconds: 500),
    );
    expect(result.problem, contains('did not end'));
    expect(result.problem, contains('killed'));
  });

  group('the check that nothing is left running', () {
    late McpSession session;

    setUp(() async {
      session = await serve();
    });

    ProcessLister listing(List<ProcessRow> Function(int sessionPid) rows) =>
        () async => rows(session.pid);

    test('names a process of the tree that is still running when the '
        'server has ended, by ID, with the command to end it', () async {
      final result = await measure(
        session,
        lister: listing(
          (pid) => [
            ProcessRow(pid, 1, 1 << 20, 1000),
            ProcessRow(999991, pid, 1 << 20, 2000),
          ],
        ),
      );
      expect(result.problem, contains('999991'));
      expect(result.problem, contains('still running'));
      expect(result.problem, anyOf(contains('taskkill'), contains('kill ')));
    });

    test('does not name a process that has the ID of one in the tree but '
        'started after the measurement looked: another program was given '
        'the ID', () async {
      var listings = 0;
      final result = await measure(
        session,
        lister: () async {
          listings++;
          final pid = session.pid;
          final far = DateTime.now().millisecondsSinceEpoch + 600000;
          // While the server runs it has the child; afterwards the same IDs
          // belong to programs that started later.
          return listings <= 2
              ? [
                  ProcessRow(pid, 1, 1 << 20, 1000),
                  ProcessRow(999992, pid, 1 << 20, 1500),
                ]
              : [
                  ProcessRow(pid, 1, 1 << 20, far),
                  ProcessRow(999992, 1, 1 << 20, far),
                ];
        },
      );
      expect(result.problem, isNull);
    });

    test('does not name a program that was already running and was given '
        'the ID of a process of the tree that ended', () async {
      var listings = 0;
      final result = await measure(
        session,
        lister: () async {
          listings++;
          final pid = session.pid;
          final far = DateTime.now().millisecondsSinceEpoch + 600000;
          return listings <= 2
              ? [
                  ProcessRow(pid, 1, 1 << 20, 50000),
                  ProcessRow(999995, pid, 1 << 20, 100000),
                ]
              // The child ended; its ID is now an old program's, which
              // started long before it did.
              : [
                  ProcessRow(pid, 1, 1 << 20, far),
                  ProcessRow(999995, 1, 1 << 20, 1000),
                ];
        },
      );
      expect(result.problem, isNull);
    });

    test('a listing that fails after the server ended is a problem, not a '
        'pass', () async {
      var listings = 0;
      final result = await measure(
        session,
        lister: () async {
          if (++listings > 2) throw StateError('the process list failed');
          return [ProcessRow(session.pid, 1, 1 << 20, 1000)];
        },
      );
      expect(result.problem, contains('the process list failed'));
    });
  });
}
