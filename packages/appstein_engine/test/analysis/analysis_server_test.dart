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
  // How `--apply` writes a file (fix round 1 of ticket 08).
  group('replaceFileText', () {
    late Directory folder;

    setUp(() => folder = tempDir());

    List<String> namesIn() =>
        [for (final entity in folder.listSync()) p.basename(entity.path)]
          ..sort();

    test('writes the text exactly as it is, byte order mark and CRLF line '
        'ends included, and leaves nothing beside the file', () async {
      final file = File(p.join(folder.path, 'a b.dart'))
        ..writeAsStringSync('old\n');
      const text = '\u{FEFF}// New.\r\nint a = 1;\r\n';
      await replaceFileText(file.path, text);
      expect(file.readAsBytesSync(), utf8.encode(text));
      expect(file.readAsBytesSync().take(3), [0xEF, 0xBB, 0xBF]);
      expect(namesIn(), ['a b.dart']);
    });

    test('a file held open without its deletion shared can\'t be replaced: '
        'it is written in place, and nothing is left beside it', () async {
      final file = File(p.join(folder.path, 'held.dart'))
        ..writeAsStringSync('old, and longer than the new text\n');
      // Dart opens a file on Windows without sharing its deletion, so the
      // new file can't take its place while this is open.
      final held = file.openSync();
      var open = true;
      addTearDown(() {
        if (open) held.closeSync();
      });
      // The rename is refused here, so the write in place is what is tried.
      final probe = File(p.join(folder.path, 'probe.txt'))
        ..writeAsStringSync('x');
      expect(
        () => probe.renameSync(file.path),
        throwsA(isA<FileSystemException>()),
      );
      probe.deleteSync();
      await replaceFileText(file.path, 'new\n');
      held.closeSync();
      open = false;
      expect(file.readAsStringSync(), 'new\n');
      expect(namesIn(), ['held.dart']);
    }, testOn: 'windows');

    test('a new file that could not be written completely (a full disk) is '
        'deleted, and the original is never written in place', () async {
      final file = File(p.join(folder.path, 'full.dart'))
        ..writeAsStringSync('original\n');
      final before = file.readAsBytesSync();
      await expectLater(
        replaceFileText(
          file.path,
          'a new text that does not fit\n',
          writeBeside: (open, bytes) async {
            await open.writeFrom(bytes.sublist(0, 5));
            throw const FileSystemException('There is not enough space');
          },
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            'its new text could not be written to a new file beside it '
                '(There is not enough space)',
          ),
        ),
      );
      expect(file.readAsBytesSync(), before);
      expect(namesIn(), ['full.dart']);
    });

    test('a new file that could not even be made because the disk is full '
        'leaves the original untouched', () async {
      final file = File(p.join(folder.path, 'full.dart'))
        ..writeAsStringSync('original\n');
      final before = file.readAsBytesSync();
      final diskFull = OSError(
        'There is not enough space on the disk.',
        Platform.isWindows ? 112 : 28,
      );
      await expectLater(
        replaceFileText(
          file.path,
          'a new text that does not fit\n',
          openBeside: (_) async =>
              throw FileSystemException('Cannot open file', 'x', diskFull),
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            startsWith('no new file could be made beside it: the disk is full'),
          ),
        ),
      );
      expect(file.readAsBytesSync(), before);
      expect(namesIn(), ['full.dart']);
    });

    test('a new file that could not be made for another reason (a folder no '
        'file can be made in) is written in place', () async {
      final file = File(p.join(folder.path, 'denied.dart'))
        ..writeAsStringSync('old\n');
      await replaceFileText(
        file.path,
        'new\n',
        openBeside: (_) async => throw const FileSystemException(
          'Cannot open file',
          'x',
          OSError('Access is denied.', 5),
        ),
      );
      expect(file.readAsStringSync(), 'new\n');
      expect(namesIn(), ['denied.dart']);
    });

    test('a full disk is told apart by its error code on each system', () {
      expect(isDiskFull(null), isFalse);
      expect(isDiskFull(const OSError('denied', 5)), isFalse);
      if (Platform.isWindows) {
        expect(isDiskFull(const OSError('full', 112)), isTrue);
        expect(isDiskFull(const OSError('full', 39)), isTrue);
        expect(isDiskFull(const OSError('quota', 1295)), isTrue);
      } else {
        expect(isDiskFull(const OSError('full', 28)), isTrue);
        expect(
          isDiskFull(OSError('quota', Platform.isMacOS ? 69 : 122)),
          isTrue,
        );
      }
    });

    test('a link to a file stays a link: the file it points to gets the '
        'text', () async {
      final target = File(p.join(folder.path, 'real', 'target.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('old\n');
      final link = Link(p.join(folder.path, 'link.dart'));
      try {
        link.createSync(target.path);
      } on FileSystemException catch (error) {
        markTestSkipped(
          'No link to a file can be made here (on Windows that needs '
          'developer mode or administrator rights): ${error.message}',
        );
        return;
      }
      await replaceFileText(link.path, 'new\n');
      expect(FileSystemEntity.isLinkSync(link.path), isTrue);
      expect(target.readAsStringSync(), 'new\n');
      expect(namesIn(), ['link.dart', 'real']);
      expect(
        Directory(
          p.join(folder.path, 'real'),
        ).listSync().map((entity) => p.basename(entity.path)),
        ['target.dart'],
      );
    });

    test('the permissions to give the new file: the original\'s, and only '
        'when they differ', () {
      expect(permissionsToSet(besideMode: 0x81A4, originalMode: 0x81ED), '755');
      expect(
        permissionsToSet(besideMode: 0x81A4, originalMode: 0x81A4),
        isNull,
      );
      // Only the permission bits count, not the kind of file.
      expect(permissionsToSet(besideMode: 0x1A4, originalMode: 0x81A4), isNull);
      expect(permissionsToSet(besideMode: 0x81A4, originalMode: 0x8180), '600');
    });

    test('on Linux and macOS the new file gets the original\'s permissions, '
        'with no chmod when they are the same; a chmod that fails means a '
        'write in place', () async {
      final file = File(p.join(folder.path, 'run.dart'))
        ..writeAsStringSync('old\n');
      expect(Process.runSync('chmod', ['755', file.path]).exitCode, 0);
      final asked = <String>[];
      Future<bool> counted(String mode, String path) async {
        asked.add(mode);
        return (await Process.run('chmod', [mode, path])).exitCode == 0;
      }

      await replaceFileText(file.path, 'new\n', chmod: counted);
      expect(file.statSync().mode & 0x1FF, 0x1ED);
      expect(file.readAsStringSync(), 'new\n');
      expect(asked, ['755']);

      // The same permissions as a new file gets: no chmod at all.
      final plain = File(p.join(folder.path, 'plain.dart'))
        ..writeAsStringSync('old\n');
      asked.clear();
      await replaceFileText(plain.path, 'new\n', chmod: counted);
      expect(asked, isEmpty);

      // chmod fails: the complete new text is written in place, so the
      // original keeps its permissions.
      await replaceFileText(file.path, 'newer\n', chmod: (_, _) async => false);
      expect(file.statSync().mode & 0x1FF, 0x1ED);
      expect(file.readAsStringSync(), 'newer\n');
      expect(namesIn(), ['plain.dart', 'run.dart']);
    }, testOn: '!windows');
  });

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
        environment: testAnalysisEnvironment(),
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

    // Ticket 13 of slice 1d.2, moved to the guard by ticket 01 of slice
    // 1d.7. A killed server leaves files named `<entry>-temp-<its process
    // ID>` in its cache; the test places such files while the server runs,
    // since whether the kill itself catches a write in the middle is
    // chance.
    test('a terminal run\'s stop returns with the half-written files of its '
        'server\'s ID deleted from the server\'s own cache folder, and '
        'nothing else', () async {
      final environment = testAnalysisEnvironment();
      final cache = environment[analysisCacheVariable]!;
      final driver = Directory(p.join(cache, analysisDriverFolder))
        ..createSync(recursive: true);
      File write(String relative) =>
          File(p.joinAll([driver.path, ...relative.split('/')]))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('x');
      // Placed before the server starts: a complete entry in its shard, and
      // the half-written file of another process (this one, which runs).
      final complete = write('0c/0c9ec3067b9dbc9efc4c2b9cd29aa1a6.unlinked2');
      final others = write(
        '0c9ec3067b9dbc9efc4c2b9cd29aa1a6.resolved2-temp-$pid',
      );
      // A folder outside the cache, which a link in it points to.
      final outside = Directory(p.join(tempDir().path, 'outside'))
        ..createSync();
      final target = File(p.join(outside.path, 'kept.txt'))
        ..writeAsStringSync('x');

      late int serverId;
      final kept = <File>[];
      final ofTheServer = <File>[];
      final scope = ownAnalysisServer(
        projectRoot: app,
        guardCommand: testGuardCommand,
        dartExecutable: () => testDart,
        environment: environment,
      );
      final watch = Stopwatch();
      await scope((analysis) async {
        await analysis.read();
        serverId = (analysis as AnalysisServer).processes!.server;
        ofTheServer.addAll([
          write('11fc7d1a2b3c4d5e6f708192a3b4c5d6.unlinked2-temp-$serverId'),
          write('3e2605a57214b14d8ac9620cf0141588.resolved2-temp-$serverId'),
        ]);
        kept.addAll([
          // Other IDs that begin or end with the server's.
          write('a1.unlinked2-temp-1$serverId'),
          write('a2.unlinked2-temp-${serverId}0'),
          // Another isolate's name, and a file below the folder.
          write('a3.unlinked2-temp-$serverId-plugin'),
          write('a4/a4.unlinked2-temp-$serverId'),
        ]);
        final link = Link(p.join(driver.path, 'a5.unlinked2-temp-$serverId'))
          ..createSync(outside.path);
        // The link alone, before the folders are deleted.
        addTearDown(link.deleteSync);
        watch.start();
      });
      watch.stop();
      // The guard deleted them before it ended, so nothing is waited for
      // after the stop returned.

      final left = [
        for (final entry in driver.listSync(followLinks: false))
          p.basename(entry.path),
      ];
      for (final file in ofTheServer) {
        expect(file.existsSync(), isFalse, reason: file.path);
      }
      expect(left.where((name) => RegExp('-temp-$serverId\$').hasMatch(name)), [
        'a5.unlinked2-temp-$serverId',
      ], reason: 'only the link is left');
      for (final file in [complete, others, ...kept, target]) {
        expect(file.existsSync(), isTrue, reason: file.path);
      }
      expect(
        Link(p.join(driver.path, 'a5.unlinked2-temp-$serverId')).existsSync(),
        isTrue,
      );
      // The server used this folder: it wrote entries in their shards.
      expect(
        driver
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => !file.path.contains('-temp-'))
            .length,
        greaterThan(1),
      );
      // The stop with its cleanup took no longer than a stop takes.
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
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
      // The holder's server inherits the holder's environment.
      final holder = await Process.start(Platform.resolvedExecutable, [
        analysisSupportFile('server_holder.dart'),
        app,
        testDart,
        analysisSupportFile('guard_main.dart'),
      ], environment: testAnalysisEnvironment());
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

    // Ticket 01 of slice 1d.7: the guard, not the process that started it,
    // deletes the half-written cache files of its server, so a killed
    // process leaves none. The test places the files while the server
    // runs, since whether a kill catches a write in the middle is chance.
    group('the guard deletes the half-written files of its server', () {
      /// Starts the holder (`server_holder.dart`, a process of its own that
      /// starts a guard and a server) with the cache folder [environment]
      /// names, and returns its process ID, its guard's and its server's.
      Future<(int, int, int)> hold(Map<String, String> environment) async {
        final holder = await Process.start(Platform.resolvedExecutable, [
          analysisSupportFile('server_holder.dart'),
          app,
          testDart,
          analysisSupportFile('guard_main.dart'),
        ], environment: environment);
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
        return (ids[0], ids[1], ids[2]);
      }

      late Map<String, String> environment;
      late Directory driver;
      late File outside;
      late Link link;

      /// Places a file at [relative] (with `/`) in the server's cache.
      File write(String relative) =>
          File(p.joinAll([driver.path, ...relative.split('/')]))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('x');

      setUp(() {
        environment = testAnalysisEnvironment();
        driver = Directory(
          p.join(environment[analysisCacheVariable]!, analysisDriverFolder),
        )..createSync(recursive: true);
        outside = File(p.join(tempDir().path, 'kept.txt'))
          ..writeAsStringSync('x');
      });

      /// The files of other IDs and other places, which must stay; and the
      /// link, which is never followed.
      List<File> placeOthers(int serverId) {
        link = Link(p.join(driver.path, 'a5.unlinked2-temp-$serverId'))
          ..createSync(outside.parent.path);
        addTearDown(() {
          if (link.existsSync()) link.deleteSync();
        });
        return [
          write('0c/0c9e.unlinked2'),
          write('0c9e.resolved2-temp-$pid'),
          write('a1.unlinked2-temp-1$serverId'),
          write('a2.unlinked2-temp-${serverId}0'),
          write('a3.unlinked2-temp-$serverId-plugin'),
          write('a4/a4.unlinked2-temp-$serverId'),
          outside,
        ];
      }

      test('when the process that started them is killed, the guard ends '
          'the server and deletes only its files, then ends', () async {
        final (parent, guard, serverId) = await hold(environment);
        final own = [
          write('11fc.unlinked2-temp-$serverId'),
          write('3e26.resolved2-temp-$serverId'),
        ];
        final others = placeOthers(serverId);

        // `dart` may run the script in a child process: the parent to kill
        // is the process that said it holds the server.
        Process.killPid(parent, ProcessSignal.sigkill);
        expect(
          await goneWithin([guard, serverId], const Duration(seconds: 10)),
          isNotNull,
          reason: 'the guard or the server is still running',
        );
        // The guard ended after it cleaned up, so nothing is waited for.
        for (final file in own) {
          expect(file.existsSync(), isFalse, reason: file.path);
        }
        for (final file in others) {
          expect(file.existsSync(), isTrue, reason: file.path);
        }
        expect(link.existsSync(), isTrue, reason: 'the link is not followed');
      }, timeout: const Timeout(Duration(minutes: 5)));

      test('a guard killed, and its server killed right after it, leave the '
          'files: a known limit', () async {
        final (_, guard, serverId) = await hold(environment);
        final own = write('11fc.unlinked2-temp-$serverId');
        Process.killPid(guard, ProcessSignal.sigkill);
        Process.killPid(serverId, ProcessSignal.sigkill);
        expect(
          await goneWithin([guard, serverId], const Duration(seconds: 10)),
          isNotNull,
        );
        expect(own.existsSync(), isTrue);
      }, timeout: const Timeout(Duration(minutes: 5)));
    });
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
        environment: testAnalysisEnvironment(),
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
        environment: testAnalysisEnvironment(),
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
        environment: testAnalysisEnvironment(),
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
        environment: testAnalysisEnvironment(),
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

    // The files the `format` scenario answers about (see the scenario).
    List<String> formatFiles() {
      for (final name in ['a', 'b', 'c', 'd']) {
        writeProjectFile(app, 'lib/$name.dart', 'int $name = 1;\n');
      }
      return [
        for (final name in ['a', 'b', 'c', 'd']) 'lib/$name.dart',
      ];
    }

    test('a file the formatter throws on is refused alone, with what the '
        'server said: the other answers are kept, and a question never '
        'answered is in neither list', () async {
      final files = formatFiles();
      final server = scripted('format');
      await server.read();
      final answers = await server.formatChanges(
        files,
        within: const Duration(milliseconds: 600),
      );
      expect(answers.changed, {'lib/a.dart': true, 'lib/d.dart': false});
      expect(answers.refused, {
        'lib/b.dart':
            'it refused a request (Error during `edit.format`: the '
            'formatter threw)',
      });
      expect(
        files.where(
          (file) =>
              !answers.changed.containsKey(file) &&
              !answers.refused.containsKey(file),
        ),
        ['lib/c.dart'],
      );
      // Kept answers cost nothing, even with no time at all; a refusal is
      // not kept.
      final kept = await server.formatChanges(files, within: Duration.zero);
      expect(kept.changed, {'lib/a.dart': true, 'lib/d.dart': false});
      expect(kept.refused, isEmpty);
    });

    test('an answer for a file that is not the text of the reading by the '
        'time it comes is neither used nor kept', () async {
      final files = formatFiles();
      final server = scripted('format');
      await server.read();
      // Edited after the reading: the server answers from its own copy.
      writeProjectFile(app, 'lib/a.dart', 'int a = 2;\n');
      final stale = await server.formatChanges([
        'lib/a.dart',
        'lib/d.dart',
      ], within: const Duration(milliseconds: 600));
      expect(stale.changed, {'lib/d.dart': false});
      expect(stale.refused.keys, ['lib/a.dart']);
      expect(stale.refused['lib/a.dart'], contains('changed'));
      // Nothing was kept for the edited file; once a reading has seen the
      // edit it is asked about again and answered.
      await server.read();
      final fresh = await server.formatChanges([
        'lib/a.dart',
      ], within: const Duration(milliseconds: 600));
      expect(fresh.changed, {'lib/a.dart': true});
      expect(files, hasLength(4));
    });

    test('a file that does not parse is answered "would not change" only '
        'for the text of the reading: edited since, it is refused, and '
        'nothing is kept for a later reading of the old text', () async {
      formatFiles();
      writeProjectFile(app, 'lib/e.dart', 'int e = 1;\n');
      final server = scripted('format');
      await server.read();
      // A broken text of another size, and the server refuses it.
      writeProjectFile(app, 'lib/e.dart', 'int e = 22 +;\n');
      final stale = await server.formatChanges([
        'lib/e.dart',
      ], within: const Duration(milliseconds: 600));
      expect(stale.changed, isEmpty);
      expect(stale.refused.keys, ['lib/e.dart']);
      // Undone: a reading of the old text again.
      writeProjectFile(app, 'lib/e.dart', 'int e = 1;\n');
      await server.read();
      final nothing = await server.formatChanges([
        'lib/e.dart',
      ], within: Duration.zero);
      expect(nothing.changed, isEmpty, reason: 'an answer was kept');
      final again = await server.formatChanges([
        'lib/e.dart',
      ], within: const Duration(milliseconds: 600));
      expect(again.changed, {'lib/e.dart': false});
    });

    test('a file found different from the reading, that the look cannot '
        'see change (same size, time put back), is told to the server '
        'again by the next reading, which then answers', () async {
      final files = formatFiles();
      final hourAgo = DateTime.now().subtract(const Duration(hours: 1));
      for (final file in files) {
        File(p.join(app, file)).setLastModifiedSync(hourAgo);
      }
      final server = scripted('format');
      await server.read();
      final edited = File(p.join(app, 'lib/a.dart'));
      edited.writeAsStringSync('int a = 2;\n');
      edited.setLastModifiedSync(hourAgo);
      final stale = await server.formatChanges([
        'lib/a.dart',
        'lib/d.dart',
      ], within: const Duration(milliseconds: 600));
      expect(stale.changed, {'lib/d.dart': false});
      expect(stale.refused.keys, ['lib/a.dart']);
      // The look sees no change; the file is told all the same, so the next
      // question is about the text the reading took.
      await server.read();
      final fresh = await server.formatChanges([
        'lib/a.dart',
      ], within: const Duration(milliseconds: 600));
      expect(fresh.changed, {'lib/a.dart': true});
      expect(fresh.refused, isEmpty);
    });

    // Ticket 08: the pending fixes in passes on overlays, and `--apply`, on
    // the `fixes-<how>@<log>` scenarios.
    group('pending fixes', () {
      late String log;

      /// The five files the scenarios know, and the server for [how].
      AnalysisServer fixesServer(String how) {
        for (final name in ['a', 'b', 'c', 'd', 'e']) {
          writeProjectFile(app, 'lib/$name.dart', 'int $name = 1;\n');
        }
        log = p.join(tempDir().path, 'requests.log');
        return scripted('fixes-$how@$log');
      }

      /// The requests the server got since the last call, one line each.
      List<String> requests() {
        final file = File(log);
        if (!file.existsSync()) return [];
        final lines = file.readAsLinesSync();
        file.deleteSync();
        return lines;
      }

      Map<String, List<int>> disk() => {
        for (final name in ['a', 'b', 'c', 'd', 'e'])
          name: File(p.join(app, 'lib', '$name.dart')).readAsBytesSync(),
      };

      test('the passes until one finds none: the counts summed, each pass '
          'applied to an overlay, the overlays removed at the end, nothing '
          'written, and the next reading tells the server those files '
          'again', () async {
        final server = fixesServer('done');
        await server.read();
        final before = disk();
        requests();
        final found = await server.pendingFixes(
          within: const Duration(seconds: 30),
        );
        expect(found.counts, {
          'lib/a.dart': {'x_code': 2},
        });
        expect(found.passes, 1);
        expect(found.unfinished, isNull);
        expect(requests(), [
          'edit.bulkFixes',
          'analysis.updateContent add lib/a.dart',
          'edit.bulkFixes',
          'analysis.updateContent remove lib/a.dart',
        ]);
        expect(disk(), before);
        // The overlaid file is told again (with any file the look sees as
        // possibly changed).
        await server.read();
        expect(
          requests().first,
          allOf(
            startsWith('analysis.updateContent '),
            contains('remove lib/a.dart'),
          ),
        );
      });

      test('a refused pass, a pass never answered and a refused overlay stop '
          'the passes with why, keep what the passes before found, and still '
          'remove the overlays', () async {
        for (final (how, why) in [
          ('refuse', 'the analysis server refused a pass (it refused a '),
          ('silent', 'the analysis server did not finish them within 1.5 s'),
          ('refuseadd', 'the analysis server refused an overlay (it refused '),
        ]) {
          final server = fixesServer(how);
          await server.read();
          final before = disk();
          requests();
          final found = await server.pendingFixes(
            within: const Duration(milliseconds: 1500),
          );
          expect(found.unfinished, startsWith(why), reason: how);
          expect(found.counts['lib/a.dart']!['x_code'], 2, reason: how);
          expect(found.passes, how == 'refuseadd' ? 0 : 1, reason: how);
          // Sent, taken or not: removed all the same.
          expect(requests().last, 'analysis.updateContent remove lib/a.dart');
          expect(disk(), before, reason: how);
          await server.stop();
        }
      });

      test('passes that never end stop after four, as dart fix does, and '
          'that is finished, not cut short', () async {
        final server = fixesServer('forever');
        await server.read();
        requests();
        final found = await server.pendingFixes(
          within: const Duration(seconds: 30),
        );
        expect(found.unfinished, isNull);
        expect(found.passes, AnalysisServer.mostFixPasses);
        expect(found.passes, 4);
        expect(found.counts, {
          'lib/a.dart': {'x_code': 8},
        });
        expect(
          requests().where((request) => request == 'edit.bulkFixes'),
          hasLength(4),
        );
      });

      test('a server that never answers an overlay\'s change is given up and '
          'stopped, so the overlay ends with it: the question fails, nothing '
          'is written, and the next reading is a new server\'s', () async {
        final server = fixesServer('deafadd');
        await server.read();
        final first = server.processes!;
        await recordProcesses([first.guard, first.server]);
        final before = disk();
        final watch = Stopwatch()..start();
        await expectLater(
          server.pendingFixes(within: const Duration(seconds: 1)),
          throwsA(
            isA<CodeAnalysisException>().having(
              (error) => error.reason,
              'reason',
              'it did not answer an overlay of the fixes within 5 s',
            ),
          ),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
        expect(
          await goneWithin([first.guard], const Duration(seconds: 10)),
          isNotNull,
        );
        expect(disk(), before);
        // A new server answers, and the next question is asked of it.
        await server.read();
        expect(server.processes!.guard, isNot(first.guard));

        // The overlays' removal never answered: the rewrite fails before it
        // has written anything.
        final deaf = fixesServer('deafremove');
        await deaf.read();
        final untouched = disk();
        await expectLater(
          deaf.applyFixesAndFormat(
            leaveUnformatted: (_) async => false,
            within: const Duration(seconds: 1),
          ),
          throwsA(
            isA<CodeAnalysisException>().having(
              (error) => error.reason,
              'reason',
              'it did not answer the removal of the overlays within 5 s',
            ),
          ),
        );
        expect(disk(), untouched);
      });

      test('a file whose text the reading could not tell (it changed between '
          'the reading\'s two whole reads) is never changed: the passes stop '
          'with why, and the rewrite leaves it and names it', () async {
        for (final name in ['a', 'b', 'c', 'd', 'e']) {
          writeProjectFile(app, 'lib/$name.dart', 'int $name = 1;\n');
        }
        log = p.join(tempDir().path, 'requests.log');
        var once = true;
        final server = AnalysisServer(
          projectRoot: app,
          guardCommand: [
            Platform.resolvedExecutable,
            analysisSupportFile('fake_server_guard.dart'),
            'fixes-done@$log',
          ],
          dartExecutable: () => testDart,
          environment: testAnalysisEnvironment(),
          // Between the reading's two whole reads of every file.
          afterLook: () async {
            if (!once) return;
            once = false;
            writeProjectFile(app, 'lib/a.dart', 'int a = 22;\n');
          },
        );
        addTearDown(server.stop);
        await server.read();
        final pending = await server.pendingFixes(
          within: const Duration(seconds: 30),
        );
        expect(
          pending.unfinished,
          'the text of lib/a.dart on disk is not the one the reading saw, or '
          'the reading could not tell which text it saw',
        );
        expect(pending.counts, isEmpty);
        final changes = await server.applyFixesAndFormat(
          leaveUnformatted: (_) async => false,
          within: const Duration(seconds: 30),
        );
        expect(
          File(p.join(app, 'lib', 'a.dart')).readAsStringSync(),
          'int a = 22;\n',
        );
        expect(changes.written, isNot(contains('lib/a.dart')));
        expect(changes.leftAlone.keys, contains('lib/a.dart'));
        expect(
          changes.notices.first,
          startsWith('Applying fixes and formatting left `lib/a.dart` as it '),
        );
      });

      /// The `fixes-done` server, with what the rewrite writes with and the
      /// process lookup replaced.
      AnalysisServer fixesServerWith({
        Future<void> Function(String path, String text) replaceText =
            replaceFileText,
        ProcessLookup processLookup = lookUpProcess,
      }) {
        for (final name in ['a', 'b', 'c', 'd', 'e']) {
          writeProjectFile(app, 'lib/$name.dart', 'int $name = 1;\n');
        }
        log = p.join(tempDir().path, 'requests.log');
        final server = AnalysisServer(
          projectRoot: app,
          guardCommand: [
            Platform.resolvedExecutable,
            analysisSupportFile('fake_server_guard.dart'),
            'fixes-done@$log',
          ],
          dartExecutable: () => testDart,
          environment: testAnalysisEnvironment(),
          replaceText: replaceText,
          processLookup: processLookup,
        );
        addTearDown(server.stop);
        return server;
      }

      test('a file whose new text could not be written completely is left '
          'untouched and named, with why; the others are written', () async {
        final server = fixesServerWith(
          replaceText: (path, text) => replaceFileText(
            path,
            text,
            writeBeside: (open, bytes) async {
              if (path.endsWith('a.dart')) {
                await open.writeFrom(bytes.sublist(0, 2));
                throw const FileSystemException('disk full');
              }
              await open.writeFrom(bytes);
            },
          ),
        );
        await server.read();
        final before = disk();
        final changes = await server.applyFixesAndFormat(
          leaveUnformatted: (_) async => false,
          within: const Duration(seconds: 30),
        );
        expect(disk()['a'], before['a']);
        expect(changes.leftAlone, {
          'lib/a.dart':
              'it could not be written (its new text could not be written to '
              'a new file beside it (disk full))',
        });
        expect(changes.written, [
          'lib/b.dart',
          'lib/c.dart',
          'lib/d.dart',
          'lib/e.dart',
        ]);
        expect(
          Directory(
            p.join(app, 'lib'),
          ).listSync().map((entity) => p.basename(entity.path)),
          hasLength(5),
        );
      });

      test('a new file an earlier rewrite left beside a file is removed '
          'before the writes, unless the process that made it still '
          'runs', () async {
        // A process that has ended and one that runs, as the lookup says.
        const ended = 999991;
        const running = 999992;
        final server = fixesServerWith(
          processLookup: (id) => switch (id) {
            ended => const ProcessGone(),
            running => const ProcessRunning(
              ProcessIdentity(id: running, start: 'now', image: 'appstein'),
            ),
            _ => lookUpProcess(id),
          },
        );
        await server.read();
        String beside(String name, int maker) =>
            p.join(app, 'lib', besideFileName(name, maker));
        for (final (name, maker) in [
          ('b.dart', ended),
          ('c.dart', running),
          ('d.dart', pid),
        ]) {
          File(beside(name, maker)).writeAsStringSync('a full copy\n');
        }
        File(p.join(app, 'lib', '.notes.tmp')).writeAsStringSync('mine\n');
        await server.applyFixesAndFormat(
          leaveUnformatted: (_) async => false,
          within: const Duration(seconds: 30),
        );
        expect(File(beside('b.dart', ended)).existsSync(), isFalse);
        expect(File(beside('d.dart', pid)).existsSync(), isFalse);
        expect(File(beside('c.dart', running)).existsSync(), isTrue);
        expect(File(p.join(app, 'lib', '.notes.tmp')).existsSync(), isTrue);
      });

      test('the writes have no time limit: a write slower than the whole '
          'call\'s limit is still named, and the server is not given '
          'up', () async {
        const within = Duration(seconds: 1);
        final slower = fixQuestionLimit(within) + const Duration(seconds: 1);
        var waited = false;
        final server = fixesServerWith(
          replaceText: (path, text) async {
            if (!waited) {
              waited = true;
              await Future<void>.delayed(slower);
            }
            await replaceFileText(path, text);
          },
        );
        await server.read();
        final changes = await server.applyFixesAndFormat(
          leaveUnformatted: (_) async => false,
          within: within,
        );
        expect(changes.written, hasLength(5));
        expect(changes.leftAlone, isEmpty);
        // Still the same, healthy server.
        final guard = server.processes!.guard;
        await server.read();
        expect(server.processes!.guard, guard);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('a question with no reading taken from the server fails', () async {
        final server = fixesServer('done');
        await expectLater(
          server.pendingFixes(within: const Duration(seconds: 5)),
          throwsA(isA<CodeAnalysisException>()),
        );
        await expectLater(
          server.applyFixesAndFormat(
            leaveUnformatted: (_) async => false,
            within: const Duration(seconds: 5),
          ),
          throwsA(isA<CodeAnalysisException>()),
        );
      });

      test('apply writes each file once with its fixed and formatted text, '
          'never a file edited since the reading, one the caller leaves '
          'unformatted, or one that is not UTF-8; the overlays are removed '
          'and the next reading tells every file it touched', () async {
        final server = fixesServer('done');
        File(
          p.join(app, 'lib', 'e.dart'),
        ).writeAsBytesSync([...utf8.encode('int e = 1; // '), 0xFF, 10]);
        await server.read();
        // Edited after the reading: it must not be overwritten.
        writeProjectFile(app, 'lib/c.dart', 'int c = 2;\n');
        final eBefore = File(p.join(app, 'lib', 'e.dart')).readAsBytesSync();
        requests();
        final left = <String>[];
        final changes = await server.applyFixesAndFormat(
          leaveUnformatted: (file) async {
            left.add(file);
            return file == 'lib/d.dart';
          },
          within: const Duration(seconds: 30),
        );
        expect(changes.written, ['lib/a.dart', 'lib/b.dart']);
        expect(changes.leftAlone, {
          'lib/c.dart':
              'its text on disk is not the one the reading saw, or the '
              'reading could not tell which text it saw',
          'lib/e.dart':
              'it is not valid UTF-8, so it could not be written back '
              'unchanged',
        });
        // Nothing is left beside the files.
        expect(
          [
            for (final entity in Directory(p.join(app, 'lib')).listSync())
              p.basename(entity.path),
          ]..sort(),
          ['a.dart', 'b.dart', 'c.dart', 'd.dart', 'e.dart'],
        );
        String text(String name) =>
            File(p.join(app, 'lib', '$name.dart')).readAsStringSync();
        expect(text('a'), 'num a = 1;\n');
        expect(text('b'), '// formatted\nint b = 1;\n');
        expect(text('c'), 'int c = 2;\n');
        expect(text('d'), 'int d = 1;\n');
        expect(File(p.join(app, 'lib', 'e.dart')).readAsBytesSync(), eBefore);
        expect(
          left,
          unorderedEquals([for (final n in 'abcde'.split('')) 'lib/$n.dart']),
        );
        final asked = requests();
        expect(asked.first, 'edit.bulkFixes');
        expect(asked.last, 'analysis.updateContent remove lib/a.dart');
        // The formatter was asked about the fixed file while its overlay was
        // in place, and never about the file left unformatted.
        expect(
          asked.indexOf('edit.format lib/a.dart'),
          lessThan(asked.indexOf('analysis.updateContent remove lib/a.dart')),
        );
        expect(asked, isNot(contains('edit.format lib/d.dart')));
        await server.read();
        expect(
          requests().first,
          allOf(
            startsWith('analysis.updateContent '),
            contains('remove lib/a.dart'),
            contains('remove lib/b.dart'),
          ),
        );
      });
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
      /// server. It waits until its input closes. It is returned once its
      /// Dart code runs: on Linux and macOS a `dart <script>` process execs
      /// `dartvm` in the same process ID, so an identity taken before that
      /// differs from one taken after it (the macOS failure of CI run
      /// 38721583522; see [untilItsDartRuns]).
      Future<Process> bystander() async {
        final process = await Process.start(Platform.resolvedExecutable, [
          analysisSupportFile('silent_guard.dart'),
        ]);
        process.stdout.drain<void>().ignore();
        final running = untilItsDartRuns(process);
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
        await running;
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
          environment: testAnalysisEnvironment(),
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
          environment: testAnalysisEnvironment(),
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
          environment: testAnalysisEnvironment(),
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
