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
      // It had answered, so the next question is answered by a new server
      // (ticket 04), not failed.
      await server.read();
      // (Its processes may have been given the IDs of the ones that
      // ended, so the IDs are not compared.)
      final now = server.processes!;
      await recordProcesses([now.guard, now.server]);
      expect(await processAlive(now.server), isTrue);
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
  }, timeout: const Timeout(Duration(minutes: 5)));

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

    test('a server that dies before it has answered: the question fails '
        'with its exit code, the guard is gone, and the next question '
        'starts a new server', () async {
      final server = realAnalysisServer(app);
      addTearDown(server.stop);
      final asked = server.read();
      final failed = expectLater(
        asked,
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            startsWith('it ended by itself with exit code '),
          ),
        ),
      );
      // Until the guard has named the server it has just started, which
      // then has its whole first analysis before it.
      ({int guard, int server})? processes;
      for (var i = 0; i < 1500 && processes == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        processes = server.processes;
      }
      expect(processes, isNotNull, reason: 'the guard never named itself');
      final (:guard, server: serverId) = processes!;
      // The server this test started.
      Process.killPid(serverId, ProcessSignal.sigkill);
      await failed;
      expect(
        await goneWithin([guard, serverId], const Duration(seconds: 10)),
        isNotNull,
      );
      await server.read();
      final now = server.processes!;
      await recordProcesses([now.guard, now.server]);
      expect(await processAlive(now.server), isTrue);
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
  }, timeout: const Timeout(Duration(minutes: 3)));

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

    test('a guard that is killed before its server has answered: the '
        'question fails and says the guard ended without it', () async {
      final server = scripted('slow');
      final asked = server.read();
      final failed = expectLater(
        asked,
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            startsWith('its guard ended without it, with exit code '),
          ),
        ),
      );
      // Until the guard has named itself; the analysis takes 1.5 s more.
      ({int guard, int server})? processes;
      for (var i = 0; i < 100 && processes == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        processes = server.processes;
      }
      expect(processes, isNotNull, reason: 'the guard never named itself');
      // The scripted guard this test started.
      Process.killPid(processes!.guard, ProcessSignal.sigkill);
      await failed;
      expect(server.processes, isNull);
    });

    test('a kept server tells the server each change and waits for the '
        'answer: the requests of two readings with an edit, a new file and '
        'a deleted file between them', () async {
      File(p.join(app, 'lib', 'kept.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('int kept = 1;\n');
      final gone = File(p.join(app, 'lib', 'gone.dart'))
        ..writeAsStringSync('int gone = 1;\n');
      // A folder the server leaves out, and so does the look at the disk.
      File(p.join(app, '.dart_tool', 'hidden.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('int hidden = 1;\n');
      final log = File(p.join(tempDir().path, 'requests.txt'));
      final server = scripted('log:${log.path}');
      await server.read();
      // Files this old are told again only when their time or size differs.
      final old = DateTime.now().subtract(const Duration(minutes: 1));
      for (final name in ['kept.dart', 'gone.dart']) {
        File(p.join(app, 'lib', name)).setLastModifiedSync(old);
      }
      await server.read();
      log.writeAsStringSync('');

      await server.read();
      expect(log.readAsLinesSync(), ['server.getVersion']);
      log.writeAsStringSync('');

      File(
        p.join(app, 'lib', 'kept.dart'),
      ).writeAsStringSync('int kept = 22;\n');
      File(
        p.join(app, 'lib', 'new.dart'),
      ).writeAsStringSync('int added = 1;\n');
      File(
        p.join(app, '.dart_tool', 'hidden.dart'),
      ).writeAsStringSync('int hidden = 22;\n');
      gone.deleteSync();
      await server.read();
      expect(log.readAsLinesSync(), [
        'analysis.updateContent remove '
            '${p.join(app, 'lib', 'gone.dart')}, '
            '${p.join(app, 'lib', 'kept.dart')}, '
            '${p.join(app, 'lib', 'new.dart')}',
        'analysis.getErrors ${p.join(app, 'lib', 'kept.dart')}',
      ]);
    });

    group('a process is ended by its ID only when it is shown to be the '
        'one the guard named', () {
      /// A process of this test's own, which a scripted guard names as its
      /// server. It waits until its input closes.
      Future<Process> bystander() async {
        final process = await Process.start(Platform.resolvedExecutable, [
          analysisSupportFile('silent_guard.dart'),
        ]);
        process.stdout.drain<void>().ignore();
        process.stderr.drain<void>().ignore();
        addTearDown(() async {
          await process.stdin.close();
          await process.exitCode.timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              process.kill(ProcessSignal.sigkill);
              return -1;
            },
          );
        });
        return process;
      }

      /// A server whose scripted guard names [named] as its server, after
      /// one reading, with its guard then killed: the guard ended without
      /// saying so, which is when Appstein ends the server by its ID.
      Future<AnalysisServer> afterItsGuardWasKilled(
        int named,
        ProcessLookup lookup,
      ) async {
        final server = AnalysisServer(
          projectRoot: app,
          guardCommand: [
            Platform.resolvedExecutable,
            analysisSupportFile('fake_server_guard.dart'),
            'names:$named',
          ],
          dartExecutable: () => testDart,
          processLookup: lookup,
        );
        addTearDown(server.stop);
        await server.read();
        final guard = server.processes!.guard;
        await recordProcesses([guard]);
        // The scripted guard this test started.
        Process.killPid(guard, ProcessSignal.sigkill);
        expect(
          await goneWithin([guard], const Duration(seconds: 10)),
          isNotNull,
        );
        // The next reading is asked after the guard's end was judged, and
        // is answered by a new server.
        await server.read();
        return server;
      }

      test('the process that has the ID is the one that was named: it is '
          'ended', () async {
        final named = await bystander();
        await recordProcesses([named.pid]);
        final server = await afterItsGuardWasKilled(named.pid, lookUpProcess);
        expect(
          await goneWithin([named.pid], const Duration(seconds: 5)),
          isNotNull,
          reason: 'the orphan was not ended',
        );
        expect(server.leftProcesses(), isEmpty);
      });

      test('the ID belongs to another process by now: it is left alone, and '
          'nothing is reported', () async {
        final other = await bystander();
        final real = identityOf(other.pid)!;
        // When the guard names its server, the ID is that of a process
        // that started earlier; afterwards it is the bystander's.
        var asked = 0;
        ProcessSeen lookup(int id) {
          if (id != other.pid) return lookUpProcess(id);
          return asked++ == 0
              ? ProcessRunning(
                  ProcessIdentity(id: id, start: 'earlier', image: real.image),
                )
              : lookUpProcess(id);
        }

        final server = await afterItsGuardWasKilled(other.pid, lookup);
        expect(asked, greaterThan(1), reason: 'no kill by ID was weighed');
        expect(identityOf(other.pid), real, reason: 'it was ended');
        expect(server.leftProcesses(), isEmpty);
        expect((await server.read()).notices, isEmpty);
      });

      test('who has the ID can\'t be told at all (as with a `ps` that gives '
          'no start): nothing is ended, and every reading reports it, with '
          'the command to end it by hand, until it is gone', () async {
        final unknown = await bystander();
        ProcessSeen lookup(int id) {
          if (id != unknown.pid) return lookUpProcess(id);
          // Can't tell, while it runs; gone, once it has ended.
          return lookUpProcess(id) is ProcessGone
              ? const ProcessGone()
              : const ProcessUnknown();
        }

        final real = identityOf(unknown.pid)!;
        final server = await afterItsGuardWasKilled(unknown.pid, lookup);
        expect(identityOf(unknown.pid), real, reason: 'it was ended');
        for (var i = 0; i < 2; i++) {
          final notices = (await server.read()).notices;
          expect(notices, [
            'Process ${unknown.pid} may be an analysis server that Appstein '
                'started and could not stop. Appstein could not tell what '
                'the process is, so it did not end it. To end it by hand: '
                '`${endByHandCommand(unknown.pid)}`',
          ]);
        }
        expect(identityOf(unknown.pid), real, reason: 'it was ended');
        await unknown.stdin.close();
        await unknown.exitCode;
        expect((await server.read()).notices, isEmpty);
      });

      test('a process both ends of a stop leave is reported once: the guard '
          'does not end when its input closes, so the stop ends it, and the '
          'server it named is weighed by the stop and again as the orphan '
          'of a guard that did not end in order', () async {
        final unknown = await bystander();
        var asked = 0;
        ProcessSeen lookup(int id) {
          if (id != unknown.pid) return lookUpProcess(id);
          // Not told when it was named; who it is afterwards.
          return asked++ == 0 ? const ProcessUnknown() : lookUpProcess(id);
        }

        final server = AnalysisServer(
          projectRoot: app,
          guardCommand: [
            Platform.resolvedExecutable,
            analysisSupportFile('fake_server_guard.dart'),
            'deaf:${unknown.pid}',
          ],
          dartExecutable: () => testDart,
          processLookup: lookup,
        );
        addTearDown(server.stop);
        await server.read();
        final guard = server.processes!.guard;
        await recordProcesses([guard]);
        await server.stop();
        expect(
          await goneWithin([guard], const Duration(seconds: 10)),
          isNotNull,
          reason: 'the deaf guard was not ended',
        );
        expect(asked, greaterThan(2), reason: 'not weighed twice');
        expect(server.leftProcesses(), hasLength(1));
        expect(identityOf(unknown.pid), isNotNull, reason: 'it was ended');
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('the ID has ended: nothing is ended and nothing is '
          'reported', () async {
        final ended = await Process.start(Platform.resolvedExecutable, [
          '--version',
        ]);
        await ended.stdout.drain<void>();
        await ended.exitCode;
        final server = await afterItsGuardWasKilled(ended.pid, lookUpProcess);
        expect(server.leftProcesses(), isEmpty);
        expect((await server.read()).notices, isEmpty);
      });

      test('the process could not be told when it was named: it is left '
          'alone, every reading says so with the command to end it by '
          'hand, and it is forgotten once it has ended', () async {
        final unknown = await bystander();
        final real = identityOf(unknown.pid)!;
        var asked = 0;
        ProcessSeen lookup(int id) {
          if (id != unknown.pid) return lookUpProcess(id);
          return asked++ == 0 ? const ProcessUnknown() : lookUpProcess(id);
        }

        final server = await afterItsGuardWasKilled(unknown.pid, lookup);
        expect(identityOf(unknown.pid), real, reason: 'it was ended');
        for (var i = 0; i < 2; i++) {
          final notices = (await server.read()).notices;
          expect(notices, hasLength(1));
          expect(
            notices.single,
            'Process ${unknown.pid} (${real.image}) may be an analysis '
            'server that Appstein started and could not stop. Appstein '
            'could not confirm that it is its own, so it did not end it. To '
            'end it by hand: '
            '`${endByHandCommand(unknown.pid, image: real.image)}`',
          );
        }
        expect(identityOf(unknown.pid), real, reason: 'it was ended');

        // The bystander ends; Appstein forgets it.
        await unknown.stdin.close();
        await unknown.exitCode;
        expect((await server.read()).notices, isEmpty);
        expect(server.leftProcesses(), isEmpty);
      });

      test('a run with a server of its own (a terminal run) is told what '
          'its stop left, after the server was closed', () async {
        final unknown = await bystander();
        final real = identityOf(unknown.pid)!;
        var asked = 0;
        final told = <String>[];
        final scope = ownAnalysisServer(
          projectRoot: app,
          guardCommand: [
            Platform.resolvedExecutable,
            analysisSupportFile('fake_server_guard.dart'),
            'names:${unknown.pid}',
          ],
          dartExecutable: () => testDart,
          processLookup: (id) {
            if (id != unknown.pid) return lookUpProcess(id);
            return asked++ == 0 ? const ProcessUnknown() : lookUpProcess(id);
          },
          onLeft: told.addAll,
        );
        await scope((analysis) async {
          await analysis.read();
          final guard = (analysis as AnalysisServer).processes!.guard;
          await recordProcesses([guard]);
          // The scripted guard this test started.
          Process.killPid(guard, ProcessSignal.sigkill);
          expect(
            await goneWithin([guard], const Duration(seconds: 10)),
            isNotNull,
          );
          expect(told, isEmpty, reason: 'told before the run ended');
        });
        expect(told, hasLength(1));
        expect(told.single, contains('Process ${unknown.pid} '));
        expect(
          told.single,
          endsWith('`${endByHandCommand(unknown.pid, image: real.image)}`'),
        );
        expect(identityOf(unknown.pid), real, reason: 'it was ended');
      });
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
  }, timeout: const Timeout(Duration(minutes: 2)));
}
