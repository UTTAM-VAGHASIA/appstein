import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/command_run.dart';
import '../tool/src/mcp_session.dart';
import '../tool/src/process_memory.dart';
import '../tool/src/sharing_check.dart';
import 'support/measure_fixtures.dart';
import 'support/temp_repo.dart';

// The sharing check against the fake MCP server of
// test/support/fake_mcp_server.dart and scripted process lists: the sessions
// are real processes, the host, its guard and its server are rows of a list.
void main() {
  const since = 10000;
  late File file;

  setUp(() {
    file = File(p.join(tempFolder().path, 'a.dart'))
      ..writeAsStringSync('/// A.\nclass A {}\n');
  });

  const silent = (exitCode: 0, stdout: '', stderr: '', elapsed: Duration.zero);

  /// One compiled binary runs as the host and as the guard, so one system
  /// gives both the same kind of name: the binary's own, or, where the Dart VM
  /// names a process after its script, `dart:<script>` for both. These are the
  /// four namings a process list can show, as trees of a host with its guard
  /// and its server.
  final namings =
      <String, List<ProcessRow> Function({required int parent, int host})>{
        'Windows, the binary named appstein.exe':
            ({required parent, host = 100}) =>
                hostTreeRows(parent: parent, host: host),
        'Windows, every process named dart.exe':
            ({required parent, host = 100}) => hostTreeRows(
              parent: parent,
              host: host,
              hostName: 'dart.exe',
              guardName: 'dart.exe',
            ),
        'Linux, the binary named by its path':
            ({required parent, host = 100}) => hostTreeRows(
              parent: parent,
              host: host,
              hostName: '/work/appstein',
              guardName: '/work/appstein',
              serverName: '/sdk/bin/cache/dart-sdk/bin/dart',
            ),
        'Linux, the VM names the binary dart:<script>':
            ({required parent, host = 100}) => hostTreeRows(
              parent: parent,
              host: host,
              hostName: 'dart:analysis_hos',
              guardName: 'dart:analysis_gua',
              serverName: '/sdk/bin/cache/dart-sdk/bin/dart',
            ),
      };

  /// The names of Linux with the binary named by its path.
  List<ProcessRow> linuxHostTree({required int parent, int host = 100}) =>
      namings['Linux, the binary named by its path']!(
        parent: parent,
        host: host,
      );

  group('analysisServerRows', () {
    List<int> ids(List<ProcessRow> rows, {List<int> roots = const [100]}) => [
      for (final row in analysisServerRows(rows, since: since, roots: roots))
        row.id,
    ];

    test('the Dart program inside the host\'s tree, from the check on', () {
      final rows = [
        ...hostTreeRows(parent: 1),
        // A Dart program of the machine, not inside any tree of the check.
        const ProcessRow(300, 200, 1, 20000, 'dart.exe'),
        const ProcessRow(200, 1, 1, 100, 'explorer.exe'),
        // A child of the guard that is no Dart program (Windows' console).
        const ProcessRow(320, 101, 1, 20300, 'conhost.exe'),
      ];
      expect(ids(rows), [102]);
    });

    test('a server in the host\'s tree whose parent is not named appstein '
        'is found: the structure decides, not the name', () {
      final rows = [
        const ProcessRow(100, 1, 1, 20000, 'host-process'),
        const ProcessRow(101, 100, 1, 20100, 'some-guard'),
        const ProcessRow(102, 101, 1, 20200, 'dart'),
      ];
      expect(ids(rows), [102]);
    });

    for (final MapEntry(key: naming, value: tree) in namings.entries) {
      test('$naming: the host\'s tree has one server, whatever the host and '
          'the guard are called', () {
        final found = ids(tree(parent: 1));
        // The host is a root. When the guard reads as a Dart program too, it
        // is the top Dart program of the tree and the server under it is not
        // counted again: one either way.
        expect(found, hasLength(1));
        expect(found.single, anyOf(101, 102));
      });
    }

    test('a Dart program whose parent is a root is a server, not a part of '
        'another: the host and the guard both named dart:<script>', () {
      final rows = namings['Linux, the VM names the binary dart:<script>']!(
        parent: 1,
      );
      expect(ids(rows), [101], reason: 'the guard is under the root host');
    });

    test('a server started before the check does not count', () {
      final rows = [
        ...hostTreeRows(parent: 1),
        ...hostTreeRows(parent: 1, host: 500, at: 1000),
      ];
      expect(ids(rows, roots: [100, 500]), [102]);
    });

    test('a session\'s own server counts, in the session\'s tree', () {
      final rows = [
        ...hostTreeRows(parent: 1),
        const ProcessRow(50, 1, 1, 5000, 'whatever'),
        const ProcessRow(51, 50, 1, 20300, 'whatever-guard'),
        const ProcessRow(52, 51, 1, 20400, 'dart'),
      ];
      expect(ids(rows, roots: [100, 50]), [102, 52]);
      expect(ids(rows), [102], reason: 'the session is not a root');
    });

    test('an orphan left by a process of the check counts: its parent has '
        'ended (Windows keeps the ID), or is process 1 (Linux, macOS)', () {
      final rows = [
        ...hostTreeRows(parent: 1),
        const ProcessRow(60, 9999, 1, 20500, 'dart.exe'),
        const ProcessRow(61, 1, 1, 20500, 'dart'),
        // An orphan that started before the check is somebody else's.
        const ProcessRow(62, 1, 1, 100, 'dart'),
      ];
      expect(ids(rows), [102, 60, 61]);
    });

    test('a Dart program under a Dart program is one server', () {
      final rows = [
        ...hostTreeRows(parent: 1),
        const ProcessRow(110, 102, 1, 20300, 'dartvm.exe'),
      ];
      expect(ids(rows), [102]);
    });

    test('a process whose start is not known counts', () {
      final rows = [
        const ProcessRow(100, 1, 1, null, 'appstein'),
        const ProcessRow(101, 100, 1, null, 'dart'),
      ];
      expect(ids(rows), [101]);
    });
  });

  group('sharingProblem', () {
    String? problem(
      List<ProcessRow> rows, {
      List<int> hostIds = const [100],
      List<int> sessionIds = const [],
    }) => sharingProblem(
      rows,
      hostIds: hostIds,
      sessionIds: sessionIds,
      since: since,
    );

    for (final MapEntry(key: naming, value: tree) in namings.entries) {
      test('$naming: one host with one server under it passes', () {
        expect(problem(tree(parent: 1)), isNull);
      });

      test('$naming: two hosts with an address, each with a server, fail', () {
        expect(
          problem(
            [...tree(parent: 1), ...tree(parent: 1, host: 200)],
            hostIds: [100, 200],
          ),
          contains('2 analysis servers'),
        );
      });

      test('$naming: a second host with no address file, whose parent has '
          'ended and which started after the check, is seen: 2 servers', () {
        final rows = [
          ...tree(parent: 1),
          ...tree(parent: 9999, host: 300).map(
            (row) => ProcessRow(
              row.id,
              row.parent,
              row.bytes,
              row.start! + 1000,
              row.name,
            ),
          ),
        ];
        expect(problem(rows), contains('2 analysis servers'));
      });

      test('$naming: the same second host, orphaned in Linux style (parent '
          '1), is seen too', () {
        expect(
          problem([...tree(parent: 1), ...tree(parent: 1, host: 300)]),
          contains('2 analysis servers'),
        );
      });

      test('$naming: an orphan host tree that started before the check is '
          'somebody else\'s and does not count', () {
        final rows = [
          ...tree(parent: 1),
          ...tree(parent: 9999, host: 300).map(
            (row) => ProcessRow(
              row.id,
              row.parent,
              row.bytes,
              row.start! - 15000,
              row.name,
            ),
          ),
        ];
        expect(problem(rows), isNull);
      });
    }

    test('names a session\'s own server beside the host\'s', () {
      final rows = [
        ...linuxHostTree(parent: 1),
        const ProcessRow(50, 1, 1, 5000, '/work/appstein'),
        const ProcessRow(51, 50, 1, 20300, '/work/appstein'),
        const ProcessRow(52, 51, 1, 20400, '/sdk/bin/dart'),
      ];
      expect(problem(rows, sessionIds: [50]), contains('2 analysis servers'));
    });

    test('names a lone server that is not under the host', () {
      final rows = [
        const ProcessRow(100, 1, 1, 20000, '/work/appstein'),
        const ProcessRow(50, 1, 1, 5000, '/work/appstein'),
        const ProcessRow(51, 50, 1, 20100, '/work/appstein'),
        const ProcessRow(52, 51, 1, 20200, '/sdk/bin/dart'),
      ];
      expect(
        problem(rows, sessionIds: [50]),
        contains('not under the analysis host'),
      );
    });

    test('names an orphaned server from a hook that was left', () {
      final rows = [
        ...linuxHostTree(parent: 1),
        const ProcessRow(70, 1, 1, 21000, '/sdk/bin/dart'),
      ];
      expect(problem(rows), contains('2 analysis servers'));
    });

    test('names no server, no host, a host that is not running, and two '
        'addresses', () {
      expect(
        problem(hostTreeRows(parent: 1), hostIds: []),
        contains('0 analysis hosts'),
      );
      expect(
        problem(hostTreeRows(parent: 1), hostIds: [100, 200]),
        contains('2 analysis hosts'),
      );
      expect(
        problem(hostTreeRows(parent: 1), hostIds: [999]),
        contains('is not running'),
      );
      expect(
        problem([const ProcessRow(100, 1, 1, 20000, 'appstein.exe')]),
        contains('0 analysis servers'),
      );
    });
  });

  group('measureSharing', () {
    late List<McpSession> sessions;
    late int ended;

    setUp(() {
      sessions = [];
      ended = 0;
    });

    /// A check whose host exists once the first session started.
    Future<SharingResult> check({
      List<ProcessRow> Function(List<int> sessionPids)? rows,
      Future<CommandRun> Function(String)? hook,
      String? hostsProblem,
      List<int> Function(int started)? ids,
    }) => measureSharing(
      startSession: () async {
        final session = await startFakeMcp(file: file, name: 'a.dart');
        sessions.add(session);
        return session;
      },
      runHook: hook ?? (_) async => silent,
      hostIds: () =>
          ids?.call(sessions.length) ?? (sessions.isEmpty ? [] : [100]),
      endHosts: () async {
        ended++;
        return hostsProblem;
      },
      lister: () async {
        final pids = [for (final session in sessions) session.pid];
        return rows != null
            ? rows(pids)
            : [
                for (final pid in pids)
                  ProcessRow(pid, 1, 10 * 1000, 5000, 'appstein.exe'),
                ...hostTreeRows(parent: pids.first),
              ];
      },
      clock: () => since,
    );

    test('one host and one server for two sessions and a hook passes: the '
        'memory of one session and of two is taken, and both sessions and '
        'the host are ended', () async {
      final result = await check();
      expect(result.problem, isNull);
      expect(result.hosts, 1);
      expect(result.servers, 1);
      // One session: its process, the host, the guard and the server.
      expect(result.memoryOne, 10000 + 100000 + 10000 + 1000000);
      // Two sessions add the second process.
      expect(result.memoryTwo, result.memoryOne + 10000);
      expect(ended, 1);
      for (final session in sessions) {
        expect(await session.close(), isTrue, reason: 'ended already');
      }
    });

    test('passes with the names of Linux', () async {
      final result = await check(
        rows: (pids) => [
          for (final pid in pids) ProcessRow(pid, 1, 10000, 5000, 'appstein'),
          ...linuxHostTree(parent: pids.first),
        ],
      );
      expect(result.problem, isNull);
      expect(result.servers, 1);
    });

    test('a second server fails it, after the second session and the '
        'hook, and still ends everything', () async {
      var listings = 0;
      final result = await check(
        rows: (pids) {
          listings++;
          return [
            for (final pid in pids) ProcessRow(pid, 1, 1000, 5000, 'appstein'),
            ...hostTreeRows(parent: pids.first),
            // The second session starts a server of its own, under its own
            // guard, from the second listing on.
            if (listings >= 2) ...hostTreeRows(parent: pids.last, host: 200),
          ];
        },
      );
      expect(
        result.problem,
        allOf(contains('2 analysis servers'), contains('two sessions')),
      );
      expect(ended, 1);
    });

    test('a server under a session, not under the host, fails it', () async {
      final result = await check(
        rows: (pids) => [
          for (final pid in pids) ProcessRow(pid, 1, 1000, 5000, 'appstein'),
          const ProcessRow(100, 1, 1, 20000, 'appstein.exe'),
          ProcessRow(201, pids.first, 1, 20100, 'appstein.exe'),
          const ProcessRow(202, 201, 1, 20200, 'dart.exe'),
        ],
      );
      expect(result.problem, contains('not under the analysis host'));
      expect(ended, 1);
    });

    test(
      'a session that cannot be started (an exception that is not a '
      'StateError) fails it with its message, and the hosts are ended',
      () async {
        final result = await measureSharing(
          startSession: () async => throw const ProcessException(
            '/work/appstein',
            [],
            'not found',
            2,
          ),
          runHook: (_) async => silent,
          hostIds: () => [],
          endHosts: () async {
            ended++;
            return null;
          },
          lister: () async => [],
          clock: () => since,
        );
        expect(result.problem, contains('not found'));
        expect(ended, 1);
      },
    );

    test('two hosts with an address fail it', () async {
      final result = await check(
        ids: (started) => started == 0 ? [] : [100, 200],
      );
      expect(result.problem, contains('2 analysis hosts'));
    });

    test('a host running before the check fails it, with no session '
        'started', () async {
      final result = await check(ids: (_) => [100]);
      expect(result.problem, contains('already running'));
      expect(sessions, isEmpty);
    });

    test('a hook that was cut by the cap fails it', () async {
      final result = await check(
        hook: (_) async => (
          exitCode: 0,
          stdout: 'the code checks of this change are still pending',
          stderr: '',
          elapsed: Duration.zero,
        ),
      );
      expect(result.problem, contains('the hook of the sharing check'));
      expect(ended, 1);
    });

    test('hosts that could not be ended are part of the problem', () async {
      final result = await check(
        hostsProblem: 'processes of the analysis host are still running: 100',
      );
      expect(result.problem, contains('still running: 100'));
    });

    test('an error in the project fails the first call', () async {
      file.writeAsStringSync('int wrong1() => 1;\n');
      final result = await check();
      expect(result.problem, contains('first session'));
      expect(result.problem, contains('still reports an error'));
    });
  });
}
