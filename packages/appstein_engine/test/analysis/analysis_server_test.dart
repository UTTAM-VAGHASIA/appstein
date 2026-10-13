import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/temp.dart';
import 'support/analysis_support.dart';

// These tests start real analysis servers, each behind a guard run by
// `dart`. One server is shared by the tests that only read; the others
// start their own, which costs a few seconds each.
void main() {
  group('a real server on a project with problems', () {
    late String app;
    late AnalysisServer server;
    late List<CodeDiagnostic> found;

    setUpAll(() async {
      // `mvvm app`, in a temp folder with a space and a non-ASCII letter.
      app = copyFixtureApp();
      writeProjectFile(
        app,
        'lib/my folder/broken.dart',
        '/// Wrong on purpose.\nint wrong() => \'text\';\n',
      );
      // `Shape` lost its `sides`, which another file still reads.
      writeProjectFile(app, 'lib/shape.dart', '''
/// A shape.
class Shape {
  /// How many corners it has.
  int corners = 0;
}
''');
      writeProjectFile(app, 'lib/uses_shape.dart', '''
import 'shape.dart';

/// Reads what is gone.
int sidesOf(Shape shape) => shape.sides;
''');
      writeProjectFile(app, 'lib/unused.dart', '''
import 'dart:math';

// TODO(someone): finish this.
/// One.
int one() => 1;
''');
      server = realAnalysisServer(app);
      final reading = await server.read();
      found = reading.diagnostics;
      expect(reading.pluginFailures, isEmpty);
    });

    tearDownAll(() => server.stop());

    CodeDiagnostic only(String file) =>
        found.where((diagnostic) => diagnostic.file == file).single;

    test('an error has its file from the project root with `/`, its line, '
        'the analyzer\'s code and its message', () {
      final error = only('lib/my folder/broken.dart');
      expect(error.level, DiagnosticLevel.error);
      expect(error.line, 2);
      expect(error.code, 'return_of_invalid_type');
      expect(error.message, contains("'String'"));
      expect(error.message, contains("'int'"));
    });

    test('breaking a class gives an error in the file that uses it', () {
      final error = only('lib/uses_shape.dart');
      expect(error.level, DiagnosticLevel.error);
      expect(error.line, 4);
      expect(error.code, 'undefined_getter');
      expect(error.correction, isNotNull);
      expect(found.where((d) => d.file == 'lib/shape.dart'), isEmpty);
    });

    test('a warning keeps the analyzer\'s level, and the TODO comment in the '
        'same file is left out, as `dart analyze` leaves it out', () {
      final warning = only('lib/unused.dart');
      expect(warning.level, DiagnosticLevel.warning);
      expect(warning.line, 1);
      expect(warning.code, 'unused_import');
    });

    test('the diagnostics are in file and line order, and all inside the '
        'project', () {
      final files = [for (final diagnostic in found) diagnostic.file];
      expect(files, [...files]..sort());
      for (final file in files) {
        expect(file, isNot(contains(r'\')));
        expect(p.posix.isRelative(file), isTrue, reason: file);
        expect(file, isNot(startsWith('..')));
      }
    });

    test('asking again answers from the same server', () async {
      final processes = server.processes;
      expect(processes, isNotNull);
      final again = (await server.read()).diagnostics;
      expect(server.processes, processes);
      expect(
        [for (final d in again) (d.file, d.line, d.code)],
        [for (final d in found) (d.file, d.line, d.code)],
      );
    });
  });

  group('stopping', () {
    late String app;

    setUp(() {
      app = copyFixtureApp();
    });

    test('after stop, the guard and the server are gone', () async {
      final server = realAnalysisServer(app);
      addTearDown(server.stop);
      expect(server.processes, isNull);
      await server.read();
      final (:guard, server: serverId) = server.processes!;
      expect(await processAlive(guard), isTrue);
      expect(await processAlive(serverId), isTrue);

      await server.stop();
      expect(server.processes, isNull);
      expect(
        await goneWithin([guard, serverId], const Duration(seconds: 5)),
        isNotNull,
      );
      // Stopping twice is fine.
      await server.stop();
    });

    test('a server of its own is stopped when the body ends, normally or '
        'with an error, and is never started when nothing is asked', () async {
      final scope = ownAnalysisServer(
        projectRoot: app,
        guardCommand: testGuardCommand,
        dartExecutable: () => testDart,
      );
      late ({int guard, int server}) first;
      final answer = await scope((analysis) async {
        await analysis.read();
        first = (analysis as AnalysisServer).processes!;
        return 'answered';
      });
      expect(answer, 'answered');
      expect(
        await goneWithin([
          first.guard,
          first.server,
        ], const Duration(seconds: 5)),
        isNotNull,
      );

      late ({int guard, int server}) second;
      await expectLater(
        scope<void>((analysis) async {
          await analysis.read();
          second = (analysis as AnalysisServer).processes!;
          throw StateError('the body failed');
        }),
        throwsStateError,
      );
      expect(
        await goneWithin([
          second.guard,
          second.server,
        ], const Duration(seconds: 5)),
        isNotNull,
      );

      var started = true;
      late CodeAnalysis kept;
      await scope<void>((analysis) async {
        started = (analysis as AnalysisServer).processes != null;
        kept = analysis;
      });
      expect(started, isFalse);

      // The scope has ended: a question now would start a server nobody
      // stops, so it is refused.
      await expectLater(kept.read(), throwsStateError);
      expect((kept as AnalysisServer).processes, isNull);
    });

    test('a guard that is killed alone does not leave its server '
        'running', () async {
      final server = realAnalysisServer(app);
      addTearDown(server.stop);
      await server.read();
      final (:guard, server: serverId) = server.processes!;
      // The guard this test started; its server is left to the product.
      Process.killPid(guard, ProcessSignal.sigkill);
      // Nobody asks or stops anything: noticing the guard's end is enough.
      expect(
        await goneWithin([guard, serverId], const Duration(seconds: 10)),
        isNotNull,
        reason: 'the server outlived its guard',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await expectLater(
        server.read(),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            startsWith('its guard ended without it, with exit code '),
          ),
        ),
      );
    });

    test('when the process that started them is killed, the guard and the '
        'server are gone within a few seconds', () async {
      final holder = await Process.start(Platform.resolvedExecutable, [
        analysisSupportFile('server_holder.dart'),
        app,
        testDart,
        analysisSupportFile('guard_main.dart'),
      ]);
      final errors = StringBuffer();
      holder.stderr.transform(utf8.decoder).listen(errors.write);
      final ids = <int>[];
      addTearDown(() async {
        // Only what this test started: the holder, and what it named.
        holder.kill(ProcessSignal.sigkill);
        for (final id in ids) {
          if (await processAlive(id)) {
            Process.killPid(id, ProcessSignal.sigkill);
          }
        }
      });
      final String line;
      try {
        line = await holder.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .firstWhere((line) => line.startsWith('holding '))
            .timeout(const Duration(minutes: 3));
      } on Object catch (error) {
        fail('The holder never held a server ($error). Its stderr: $errors');
      }
      ids.addAll(line.split(' ').skip(1).map(int.parse));
      final [parent, guard, server] = ids;
      expect(await processAlive(guard), isTrue);
      expect(await processAlive(server), isTrue);

      // `dart` may run the script in a child process: the parent to kill
      // is the process that said it holds the server.
      Process.killPid(parent, ProcessSignal.sigkill);
      final gone = await goneWithin([
        guard,
        server,
      ], const Duration(seconds: 10));
      expect(
        gone,
        isNotNull,
        reason: 'the guard or the server is still running',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('a server that can\'t answer', () {
    late String app;

    setUp(() {
      app = copyFixtureApp();
    });

    test('no Dart executable: the reason names the path, and nothing is '
        'started', () async {
      final missing = p.join(tempDir().path, 'no sdk', 'bin', 'dart');
      final server = AnalysisServer(
        projectRoot: app,
        guardCommand: testGuardCommand,
        dartExecutable: () => missing,
      );
      addTearDown(server.stop);
      await expectLater(
        server.read(),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            'there is no Dart executable at $missing',
          ),
        ),
      );
      expect(server.processes, isNull);
    });

    test('a project without a usable SDK: the reason says so', () {
      expect(
        () => projectDartExecutable(
          fakeEnvironment({'FLUTTER_ROOT': p.join(app, 'no such sdk')}),
          app,
        ),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            startsWith('the project has no usable Flutter SDK ('),
          ),
        ),
      );
      expect(
        projectDartExecutable(
          fakeEnvironment(const {}),
          app,
          dartSdkPath: testDartSdk,
        ),
        testDart,
      );
      expect(p.extension(testDart), Platform.isWindows ? '.exe' : '');
    });

    test('a guard that can\'t be started', () async {
      final server = AnalysisServer(
        projectRoot: app,
        guardCommand: [p.join(app, 'no such appstein')],
        dartExecutable: () => testDart,
      );
      addTearDown(server.stop);
      await expectLater(
        server.read(),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            startsWith('its guard could not be started with '),
          ),
        ),
      );
    });

    test('never ready: it fails at the time limit, and its processes are '
        'ended', () async {
      final server = AnalysisServer(
        projectRoot: app,
        guardCommand: [
          Platform.resolvedExecutable,
          analysisSupportFile('silent_guard.dart'),
        ],
        dartExecutable: () => testDart,
        readyTimeout: const Duration(seconds: 6),
      );
      addTearDown(server.stop);
      final asked = server.read();
      // The guard names itself before the limit is reached.
      ({int guard, int server})? processes;
      for (var i = 0; i < 55 && processes == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        processes = server.processes;
      }
      await expectLater(
        asked,
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => '$error',
            'text',
            'The Dart analysis server could not answer: its analysis was '
                'not done within 6 s.',
          ),
        ),
      );
      expect(processes, isNotNull, reason: 'the guard never named itself');
      expect(
        await goneWithin([processes!.guard], const Duration(seconds: 5)),
        isNotNull,
      );
      expect(server.processes, isNull);
    });

    test('a server that dies: the next question fails with its exit code, '
        'the guard is gone, and the question after that starts a new '
        'server', () async {
      final server = realAnalysisServer(app);
      addTearDown(server.stop);
      await server.read();
      final (:guard, server: serverId) = server.processes!;
      // The server this test started.
      Process.killPid(serverId, ProcessSignal.sigkill);
      expect(
        await goneWithin([guard, serverId], const Duration(seconds: 10)),
        isNotNull,
      );
      await expectLater(
        server.read(),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            startsWith('it ended by itself with exit code '),
          ),
        ),
      );
      await server.read();
      expect(server.processes, isNotNull);
      expect(server.processes!.server, isNot(serverId));
    });

    test('a plugin that can\'t be loaded is told with the reading, which '
        'still has the diagnostics', () async {
      writeProjectFile(
        app,
        'lib/broken.dart',
        '/// Wrong on purpose.\nint wrong() => \'text\';\n',
      );
      // A plugin whose package is nowhere: no network is needed to fail.
      writeProjectFile(
        app,
        'analysis_options.yaml',
        'plugins:\n  ghost_plugin:\n    path: ../no such plugin\n',
      );
      final server = realAnalysisServer(app);
      addTearDown(server.stop);
      final reading = await server.read();
      expect(reading.pluginFailures, hasLength(1));
      final failure = reading.pluginFailures.single;
      expect(failure, contains('ghost_plugin'));
      expect(failure, isNot(contains('\n')));
      expect(failure, isNot(contains('#0')));
      expect([
        for (final found in reading.diagnostics) found.file,
      ], contains('lib/broken.dart'));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  // What a real server can't be made to do on demand, with a scripted one
  // behind the guard (`fake_server_guard.dart`).
  group('a scripted server', () {
    late String app;

    setUp(() {
      app = tempDir().path;
    });

    AnalysisServer scripted(String scenario) {
      final server = AnalysisServer(
        projectRoot: app,
        guardCommand: [
          Platform.resolvedExecutable,
          analysisSupportFile('fake_server_guard.dart'),
          scenario,
        ],
        dartExecutable: () => testDart,
      );
      addTearDown(server.stop);
      return server;
    }

    Future<List<String>> codes(AnalysisServer server) async => [
      for (final found in (await server.read()).diagnostics)
        '${found.file} ${found.code}',
    ];

    test('a file the server takes back with analysis.flushResults is '
        'dropped', () async {
      expect(await codes(scripted('flush')), ['lib/kept.dart kept']);
    });

    test('a file outside the project is left out', () async {
      expect(await codes(scripted('outside')), ['lib/in.dart inside']);
    });

    test('a TODO comment is reported only when the project raised it above '
        'info level; an info-level lint is kept', () async {
      final found = (await scripted('todo').read()).diagnostics;
      expect(
        [for (final d in found) (d.code, d.level)],
        [
          ('fixme', DiagnosticLevel.warning),
          ('hack', DiagnosticLevel.error),
          ('prefer_this', DiagnosticLevel.info),
        ],
      );
    });

    test('a plugin failure is kept once, on one line, without the server\'s '
        'stack trace', () async {
      final reading = await scripted('plugin').read();
      expect(reading.pluginFailures, [
        'An error occurred while setting up the analyzer plugin package at '
            'X. The `dart pub upgrade` command failed: exitCode = 66 stderr '
            '= version solving failed',
      ]);
      expect(reading.diagnostics, isEmpty);
    });

    test('a fatal server error fails the question with its message, and '
        'ends the process', () async {
      final server = scripted('fatal');
      await expectLater(
        server.read(),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            'it reported a fatal error (Out of memory. Nothing more can be '
                'analyzed)',
          ),
        ),
      );
      expect(server.processes, isNull);
    });

    test('a server that dies with unfinished last words: the guard\'s end '
        'is still read as in order, the reason has those words, and no '
        'process is killed', () async {
      // A process of this test's own, named to the client as the server:
      // a kill by that process ID would end it.
      final bystander = await Process.start(Platform.resolvedExecutable, [
        analysisSupportFile('silent_guard.dart'),
      ]);
      addTearDown(() async {
        await bystander.stdin.close();
        await bystander.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            bystander.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      });
      bystander.stdout.drain<void>().ignore();
      bystander.stderr.drain<void>().ignore();

      await expectLater(
        scripted('crash:${bystander.pid}').read(),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            'it ended by itself with exit code 7: Out of memory in the '
                'middle of a wor',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await processAlive(bystander.pid), isTrue);
    });

    test('a refused request fails the question with what the server '
        'said', () async {
      await expectLater(
        scripted('refuse').read(),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            'it refused a request (The root is not a path the server knows)',
          ),
        ),
      );
    });

    test('a diagnostic in a form Appstein does not know fails the question, '
        'and is not read as no diagnostics', () async {
      await expectLater(
        scripted('malformed').read(),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            'it sent a diagnostic for lib/bad.dart in a form Appstein does '
                'not know',
          ),
        ),
      );
    });

    test('two questions at once share one server', () async {
      final server = scripted('slow');
      final both = await Future.wait([codes(server), codes(server)]);
      expect(both, [
        ['lib/slow.dart slow'],
        ['lib/slow.dart slow'],
      ]);
      final processes = server.processes;
      expect(processes, isNotNull);
      await server.read();
      expect(server.processes, processes);
    });

    test('stopped while its analysis is running: the question fails, and '
        'the process is ended', () async {
      final server = scripted('slow');
      final asked = server.read();
      // Until the guard has named itself; the analysis takes 1.5 s more.
      ({int guard, int server})? processes;
      for (var i = 0; i < 100 && processes == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        processes = server.processes;
      }
      expect(processes, isNotNull, reason: 'the guard never named itself');
      final failed = expectLater(
        asked,
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            'it was stopped',
          ),
        ),
      );
      await server.stop();
      await failed;
      expect(
        await goneWithin([processes!.guard], const Duration(seconds: 5)),
        isNotNull,
      );
    });

    test('stopped at once, before its process has started: the question '
        'fails and stop returns', () async {
      final server = scripted('slow');
      final failed = expectLater(
        server.read(),
        throwsA(isA<CodeAnalysisException>()),
      );
      await server.stop();
      await failed;
      expect(server.processes, isNull);
    });
  });
}
