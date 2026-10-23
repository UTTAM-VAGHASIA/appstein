import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/github_api.dart';
import '../tool/src/unit_test_runner.dart';

final class _Started implements StartedCommand {
  final done = Completer<int>();

  @override
  Future<int> get exitCode => done.future;
}

/// The recorded events of a real `dart test` run (see
/// unit_test_trace_test.dart).
List<String> recordedEvents() =>
    File('test/support/ci_jobs/dart_test_events.jsonl').readAsLinesSync();

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ci_unit_tests_'));
  tearDown(() => temp.deleteSync(recursive: true));

  final now = DateTime.utc(2026, 10, 22, 10, 58, 12);

  test('the commands are CI\'s, in its order', () {
    final commands = unitTestCommands([
      'packages/appstein_protocol',
      'packages/appstein_cli',
    ]);
    expect(
      [for (final c in commands) '${c.folder} ${c.paths}'],
      ['. [test]', 'packages/appstein_cli []', 'packages/appstein_protocol []'],
    );
    expect(commands.first.prefix, '');
    expect(commands.first.label, 'test');
    expect(commands[1].prefix, 'packages/appstein_cli/');
    expect(commands[1].label, 'packages/appstein_cli');
  });

  /// Runs three commands whose exit codes are [codes]; each child writes
  /// the recorded events to its report file before it ends.
  Future<({int code, List<String> started, List<String> posts, String out})>
  run(
    List<int> codes, {
    TraceWriter Function(List<String> posts)? writer,
  }) async {
    final started = <String>[];
    final posts = <String>[];
    final out = StringBuffer();
    final commands = unitTestCommands(['packages/a', 'packages/b']);
    final code = await runUnitTests(
      commands: commands,
      reportFolder: temp.path,
      attempt: 2,
      out: out,
      now: () => now,
      trace: writer == null
          ? TraceWriter((state, text) async {
              posts.add('$state $text');
            }, out: out)
          : writer(posts),
      start: (command, reportFile) async {
        started.add('${command.folder} ${command.paths} $reportFile');
        final child = _Started();
        final index = started.length - 1;
        // The child writes its report after the wrapper's first look, as a
        // real `dart test` does, and then ends.
        Timer.run(() {
          File(
            reportFile,
          ).writeAsStringSync('${recordedEvents().join('\n')}\n');
          child.done.complete(codes[index]);
        });
        return child;
      },
    );
    return (code: code, started: started, posts: posts, out: out.toString());
  }

  test('every command runs in order, with its own report file', () async {
    final result = await run([0, 0, 0]);
    expect(result.code, 0);
    final sep = Platform.pathSeparator;
    expect(result.started, [
      '. [test] ${temp.path}${sep}1.json',
      'packages/a [] ${temp.path}${sep}2.json',
      'packages/b [] ${temp.path}${sep}3.json',
    ]);
    expect(result.posts.first, 'pending a2 10:58:12 UTC, starting test');
    expect(result.posts.last, 'success a2 10:58:12 UTC, finished');
  });

  test('the first failure stops the step with exit 1', () async {
    final result = await run([0, 1, 0]);
    expect(result.code, 1);
    expect(result.started, hasLength(2));
    expect(result.posts.last, 'failure a2 10:58:12 UTC, unit tests failed');
  });

  test('the trace is posted while a command runs', () async {
    final posts = <String>[];
    final child = _Started();
    late String report;
    final running = runUnitTests(
      commands: unitTestCommands(const []),
      reportFolder: temp.path,
      attempt: 1,
      out: StringBuffer(),
      now: () => now,
      interval: const Duration(milliseconds: 20),
      trace: TraceWriter((state, text) async {
        posts.add('$state $text');
      }, out: StringBuffer()),
      start: (command, reportFile) async {
        report = reportFile;
        return child;
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // The first five events: both files loading. The fifth has no line
    // feed yet, so only four are read: only a_test.dart is loading.
    final events = recordedEvents();
    File(
      report,
    ).writeAsStringSync('${events.take(4).join('\n')}\n${events[4]}');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    child.done.complete(0);
    expect(await running, 0);
    expect(
      posts,
      contains('pending a1 10:58:12 UTC, loading test/a_test.dart'),
    );
    expect(posts.last, 'success a1 10:58:12 UTC, finished');
  });

  test(
    'a command\'s start post waits for a slow post, never skipped',
    () async {
      final posted = <String>[];
      var calls = 0;
      final result = await run(
        [0, 0, 0],
        writer: (_) => TraceWriter((state, text) async {
          // The first post is slow: the next commands start while it is
          // still under way.
          if (++calls == 1) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          posted.add('$state $text');
        }, out: StringBuffer()),
      );
      expect(result.code, 0);
      expect(posted, [
        'pending a2 10:58:12 UTC, starting test',
        'pending a2 10:58:12 UTC, starting packages/a',
        'pending a2 10:58:12 UTC, starting packages/b',
        'success a2 10:58:12 UTC, finished',
      ]);
    },
  );

  for (final status in [401, 403, 404, 422]) {
    test('HTTP $status: one line, posting stops, the tests go on', () async {
      var calls = 0;
      final result = await run(
        [0, 0, 0],
        writer: (posts) => TraceWriter((state, text) async {
          calls++;
          throw GitHubApiException(status, 'Resource not accessible');
        }, out: _Sink(posts)),
      );
      expect(result.code, 0);
      expect(result.started, hasLength(3));
      expect(calls, 1);
      expect(result.posts, [
        'The trace could not be written: HTTP $status Resource not '
            'accessible. The tests go on untraced.',
      ]);
    });
  }

  test('a post that never answers: one line, and posting goes on', () async {
    final states = <String>[];
    final result = await run(
      [0, 0, 1],
      writer: (posts) => TraceWriter(
        (state, text) {
          states.add(state);
          return Completer<void>().future;
        },
        out: _Sink(posts),
        timeout: const Duration(milliseconds: 30),
      ),
    );
    expect(result.code, 1);
    expect(result.started, hasLength(3));
    // Every post was tried, the last word included.
    expect(states.length, greaterThan(1));
    expect(states.last, 'failure');
    expect(result.posts, [
      'The trace could not be written this time: GitHub gave no answer '
          'within 0.03 s. Posting goes on.',
    ]);
  });

  test('a server error, then a good answer: the last word is posted', () async {
    final posted = <String>[];
    final lines = <String>[];
    var calls = 0;
    final writer = TraceWriter((state, text) async {
      calls++;
      if (calls <= 2) throw const GitHubApiException(502, 'Bad Gateway');
      posted.add('$state $text');
    }, out: _Sink(lines));
    await writer.send('pending', 'a1 10:00:00 UTC, starting test');
    await writer.send('pending', 'a1 10:00:30 UTC, starting test');
    await writer.send('pending', 'a1 10:01:00 UTC, starting test');
    await writer.send('success', 'a1 10:01:30 UTC, finished');
    expect(posted, [
      'pending a1 10:01:00 UTC, starting test',
      'success a1 10:01:30 UTC, finished',
    ]);
    // One line for the kind of error, not one per failed post.
    expect(lines, [
      'The trace could not be written this time: HTTP 502 Bad Gateway. '
          'Posting goes on.',
    ]);
  });

  test('a rate limit is waited out, not taken as a refusal', () async {
    final posted = <String>[];
    final lines = <String>[];
    var calls = 0;
    final writer = TraceWriter((state, text) async {
      calls++;
      if (calls == 1) {
        throw const GitHubApiException(
          403,
          'You have exceeded a secondary rate limit.',
          rateLimited: true,
        );
      }
      posted.add(state);
    }, out: _Sink(lines));
    await writer.send('pending', 'x');
    await writer.send('success', 'y');
    expect(posted, ['success']);
    expect(lines, [
      'The trace could not be written this time: HTTP 403 You have exceeded '
          'a secondary rate limit. Posting goes on.',
    ]);
  });

  test('a lost connection, then a good answer: posting goes on', () async {
    final posted = <String>[];
    final lines = <String>[];
    var calls = 0;
    final writer = TraceWriter((state, text) async {
      calls++;
      if (calls == 1) throw const GitHubApiException(0, 'The call failed');
      posted.add(state);
    }, out: _Sink(lines));
    await writer.send('pending', 'x');
    await writer.send('success', 'y');
    expect(posted, ['success']);
    expect(lines, hasLength(1));
  });

  test('a child starts without the token or its parent\'s environment', () {
    final start = dartTestStart(
      dart: '/sdk/bin/dart',
      command: unitTestCommands(const []).first,
      reportFile: '/tmp/1.json',
      parentEnvironment: {'PATH': '/bin', 'APPSTEIN_TRACE_TOKEN': 'secret'},
    );
    expect(start.executable, '/sdk/bin/dart');
    expect(start.arguments, [
      'test',
      '--file-reporter',
      'json:/tmp/1.json',
      'test',
    ]);
    expect(start.workingDirectory, '.');
    expect(start.includeParentEnvironment, isFalse);
    expect(start.environment, {'PATH': '/bin'});
  });

  test(
    'a real dart test, started as CI starts it, does not see the token',
    () async {
      // The child is a real `dart test` of a probe test file in this repo's
      // root package (under the git-ignored .dart_tool/, so `dart test test`
      // never runs it). The probe fails when it sees the token.
      final probeDir = Directory('.dart_tool/t15_token_probe')
        ..createSync(recursive: true);
      addTearDown(() => probeDir.deleteSync(recursive: true));
      File('${probeDir.path}/token_probe_test.dart').writeAsStringSync(
        "import 'dart:io';\n"
        "import 'package:test/test.dart';\n"
        'void main() {\n'
        "  test('the token is not here', () {\n"
        "    expect(Platform.environment.containsKey('APPSTEIN_TRACE_TOKEN'),\n"
        '        isFalse);\n'
        '  });\n'
        '}\n',
      );
      final report = '${temp.path}${Platform.pathSeparator}probe.json';
      final child = await startDartTest(
        dart: Platform.resolvedExecutable,
        command: (
          folder: '.',
          paths: ['${probeDir.path}/token_probe_test.dart'],
          prefix: '',
          label: 'test',
        ),
        reportFile: report,
        parentEnvironment: {
          ...Platform.environment,
          'APPSTEIN_TRACE_TOKEN': 'secret',
        },
        mode: ProcessStartMode.normal,
      );
      expect(await child.exitCode, 0);
      // The JSON reporter wrote its events: the probe's test passed.
      expect(
        File(report).readAsStringSync(),
        contains('"result":"success","skipped":false,"hidden":false'),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('the packages are the folders with a pubspec, as packages/*/ was', () {
    final packages = Directory('${temp.path}/packages');
    for (final name in ['b_pkg', 'a_pkg', '.hidden', 'not_a_package']) {
      Directory('${packages.path}/$name').createSync(recursive: true);
    }
    for (final name in ['b_pkg', 'a_pkg', '.hidden']) {
      File('${packages.path}/$name/pubspec.yaml').writeAsStringSync('name: x');
    }
    File('${packages.path}/README.md').writeAsStringSync('not a folder');
    expect(packageFolders(packages), ['packages/a_pkg', 'packages/b_pkg']);
  });

  test('with no token the tests run untraced', () async {
    final out = StringBuffer();
    var started = 0;
    final code = await runUnitTests(
      commands: unitTestCommands(['packages/a']),
      reportFolder: temp.path,
      attempt: 1,
      out: out,
      start: (command, reportFile) async {
        started++;
        return _Started()..done.complete(0);
      },
    );
    expect(code, 0);
    expect(started, 2);
    expect(
      out.toString(),
      'The trace is off (no APPSTEIN_TRACE_TOKEN): the unit tests run '
      'untraced.\n',
    );
  });
}

/// A sink that adds each line written to [lines].
final class _Sink implements StringSink {
  _Sink(this.lines);

  final List<String> lines;

  @override
  void write(Object? object) => lines.add('$object');

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      lines.add(objects.join(separator));

  @override
  void writeCharCode(int charCode) => lines.add(String.fromCharCode(charCode));
}
