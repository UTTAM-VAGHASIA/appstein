import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/temp.dart';
import 'support/analysis_support.dart';
import 'support/host_support.dart';

/// The codes of the diagnostics the reading of [scope] has for [file].
Future<List<String>> codesIn(CodeAnalysisScope scope, String file) => scope(
  (analysis) async => [
    for (final found in (await analysis.read()).diagnostics)
      if (found.file == file) found.code,
  ],
);

/// A stand-in for the host's analysis server, for a host run in the test's
/// own process: no process is started. Its readings take the times in
/// [readTimes] (then none), and its rewrite waits for [applyHeld] and then
/// writes one file through the host's write gate, which tells [written].
/// Its pending-fix passes put a temporary edit into it ([editing], which a
/// reading then shows as the file `lib/temporary.dart`) and hold it until
/// [passesHeld] completes. [asked] tells what it was asked, in order, and
/// whether a reading saw the edit.
final class _StandInServer implements StoppableCodeAnalysis {
  _StandInServer(this._writes);

  final AnalysisHostWrites _writes;
  late final _write = _writes.gate((path, _) async => written.add(path));
  final readTimes = <Duration>[];
  final asked = <String>[];
  final written = <String>[];
  final applyHeld = Completer<void>();
  final passesBegan = Completer<void>();
  final passesHeld = Completer<void>();
  var editing = false;

  @override
  Future<CodeReading> read() async {
    asked.add(editing ? 'read saw the edit' : 'read');
    if (readTimes.isNotEmpty) {
      await Future<void>.delayed(readTimes.removeAt(0));
    }
    return CodeReading(
      analyzedFiles: ['lib/a.dart', if (editing) 'lib/temporary.dart'],
    );
  }

  @override
  Future<AppliedChanges> applyFixesAndFormat({
    required Future<bool> Function(String file) leaveUnformatted,
    required Duration within,
  }) async {
    asked.add('apply');
    await applyHeld.future;
    try {
      await _write('lib/a.dart', 'new text');
    } on FileSystemException catch (error) {
      return AppliedChanges(leftAlone: {'lib/a.dart': error.message});
    }
    return const AppliedChanges(written: ['lib/a.dart']);
  }

  @override
  Future<bool> canDartFix(
    CodeDiagnostic diagnostic, {
    required Duration within,
  }) async => false;

  @override
  Future<FormatAnswers> formatChanges(
    List<String> files, {
    required Duration within,
  }) async => const FormatAnswers();

  @override
  Future<PendingFixes> pendingFixes({required Duration within}) async {
    asked.add('passes');
    editing = true;
    passesBegan.complete();
    await passesHeld.future;
    editing = false;
    asked.add('passes ended');
    return const PendingFixes();
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> close() async {}
}

/// A host for the project [app] run in the test's own process, with a
/// [_StandInServer], an idle time of 2 s, [version] and an address-file
/// folder of its own (or [folder]). The test waits for it to end itself
/// afterwards.
Future<({_StandInServer server, String folder, AnalysisHostAddress address})>
inProcessHost(String app, {String? folder, String version = 'test'}) async {
  folder ??= p.join(tempDir().path, 'hosts');
  late _StandInServer server;
  final done = runAnalysisHost(
    projectRoot: app,
    analysis: (writes) => server = _StandInServer(writes),
    addressFolder: folder,
    appsteinVersion: version,
    idleStop: const Duration(seconds: 2),
  );
  addTearDown(() => done);
  final file = analysisHostAddressFile(folder, app);
  for (var i = 0; i < 100 && readAnalysisHostAddress(file) == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return (
    server: server,
    folder: folder,
    address: readAnalysisHostAddress(file)!,
  );
}

/// The ID of a process that has ended: a `dart --version` run to its end.
Future<int> endedProcess() async {
  final ended = await Process.start(Platform.resolvedExecutable, ['--version']);
  await ended.exitCode;
  return ended.pid;
}

/// The next line of [lines], as JSON.
Future<Map<String, Object?>> nextLine(StreamIterator<String> lines) async {
  expect(await lines.moveNext(), isTrue, reason: 'the connection closed');
  return jsonDecode(lines.current) as Map<String, Object?>;
}

/// Sends [question] on [socket].
void send(Socket socket, AnalysisHostQuestion question) =>
    socket.writeln(jsonEncode(question.toJson()));

/// A raw client of the host at [address], welcomed, whose lines come in
/// order through the iterator.
Future<({Socket socket, StreamIterator<String> lines})> rawClient(
  AnalysisHostAddress address,
) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    address.port,
  );
  // A peer that resets the connection fails `done` once something was
  // written (EPIPE on Linux, ECONNRESET on macOS): nobody waits on it.
  socket.done.ignore();
  final lines = StreamIterator(
    utf8.decoder.bind(socket).transform(const LineSplitter()),
  );
  socket.writeln(
    jsonEncode(
      AnalysisHostHello(
        secret: address.secret,
        appsteinVersion: 'test',
      ).toJson(),
    ),
  );
  expect(await lines.moveNext(), isTrue, reason: 'no welcome');
  return (socket: socket, lines: lines);
}

const _wrong = '/// Wrong on purpose.\nint wrong() => \'text\';\n';
const _right = '/// Right.\nint right = 1;\n';

/// The first line a raw connection to the host at [port] gets after it sends
/// [first] (none when the host closes it first, or none comes in 10 s).
Future<List<String>> answerTo(int port, String first) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  socket.done.ignore();
  socket.write('$first\n');
  final lines = <String>[];
  final done = Completer<void>();
  void end() {
    if (!done.isCompleted) done.complete();
  }

  final listening = utf8.decoder
      .bind(socket)
      .transform(const LineSplitter())
      .listen(
        (line) {
          lines.add(line);
          end();
        },
        onDone: end,
        onError: (Object _) => end(),
      );
  await done.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  await listening.cancel();
  socket.destroy();
  return lines;
}

// The code analysis interface, answered by a real analysis host on a fixture
// app (slice 1d.7, ticket 02; the spec's seam 2): the host is started as a
// detached process by the first question, and each test gives it its own
// address-file folder and cache folder, and kills it and what runs under it
// afterwards.
void main() {
  test('the address file of a project is in the folder given, named by a '
      'hash of its path, the same for the same folder', () {
    final folder = tempDir().path;
    final one = analysisHostAddressFile(folder, '/work/my app');
    expect(File(one).parent.path, folder);
    expect(analysisHostAddressFile(folder, '/work/my app/'), one);
    expect(analysisHostAddressFile(folder, '/work/my app 2'), isNot(one));
    // Letter case counts only where the system says it does.
    expect(
      analysisHostAddressFile(folder, '/Work/My App', os: HostOs.windows),
      analysisHostAddressFile(folder, '/work/my app', os: HostOs.windows),
    );
    expect(
      analysisHostAddressFile(folder, '/Work/My App', os: HostOs.linux),
      isNot(analysisHostAddressFile(folder, '/work/my app', os: HostOs.linux)),
    );
    expect(
      analysisHostFailureFile(one),
      endsWith('${p.basenameWithoutExtension(one)}.failed'),
    );
  });

  test("the folder is the variable's when it is set, and the user's own "
      'otherwise', () {
    final given = tempDir().path;
    expect(
      analysisHostFolder(fakeEnvironment({analysisHostFolderVariable: given})),
      given,
    );
    final mine = tempDir().path;
    if (Platform.isWindows) {
      expect(
        analysisHostFolder(fakeEnvironment({'LOCALAPPDATA': mine})),
        p.join(mine, 'appstein'),
      );
    } else {
      expect(
        analysisHostFolder(fakeEnvironment({'XDG_RUNTIME_DIR': mine})),
        p.join(mine, 'appstein'),
      );
    }
    if (Platform.isWindows) {
      expect(
        analysisHostFolder(fakeEnvironment({})),
        p.join(Directory.systemTemp.path, 'appstein'),
      );
    } else {
      // The temporary folder is shared by every user on Linux: the name is
      // the user's own.
      final uid = '${Process.runSync('id', ['-u']).stdout}'.trim();
      expect(
        analysisHostFolder(fakeEnvironment({})),
        p.join(Directory.systemTemp.path, 'appstein-$uid'),
      );
    }
  });

  test(
    'off Windows the folder is made user-only (700) and the address file '
    'too (600); a client refuses a folder or file that is not once there is '
    'an address, and a folder others can write to always',
    () async {
      final folder = p.join(tempDir().path, 'hosts');
      final file = analysisHostAddressFile(folder, '/work/my app');
      // No address file: a folder of the user's own at 755 or 775 (as a host
      // killed before its chmod leaves it) is not refused, one others can
      // write to is; the strict look, after an address was read, wants 700.
      Directory(folder).createSync();
      for (final open in ['755', '775']) {
        Process.runSync('chmod', [open, folder]);
        expect(await untrustedAddress(file), isNull, reason: open);
      }
      expect(
        await untrustedAddress(file, strict: true),
        contains('mode 775, not 700'),
      );
      expect(
        await untrustedAddressFolder(folder),
        contains('mode 775, not 700'),
      );
      for (final open in ['757', '777']) {
        Process.runSync('chmod', [open, folder]);
        expect(
          await untrustedAddress(file),
          contains('mode $open, so other users can write to it'),
          reason: open,
        );
      }

      await writeAnalysisHostAddress(
        file,
        const AnalysisHostAddress(
          port: 1,
          secret: 's',
          processId: 1,
          appsteinVersion: 'test',
        ),
      );
      int mode(String path) => FileStat.statSync(path).mode & 0x1FF;
      expect(mode(folder).toRadixString(8), '700');
      expect(mode(file).toRadixString(8), '600');
      expect(await untrustedAddress(file), isNull);
      expect(await untrustedAddress(file, strict: true), isNull);
      expect(await untrustedAddressFolder(folder), isNull);

      Process.runSync('chmod', ['644', file]);
      expect(await untrustedAddress(file), contains('mode 644, not 600'));
      expect(
        await untrustedAddress(file, strict: true),
        contains('mode 644, not 600'),
      );
      Process.runSync('chmod', ['600', file]);
      // An address file in a folder that is not 700: refused, before and
      // after the read.
      Process.runSync('chmod', ['755', folder]);
      expect(await untrustedAddress(file), contains('mode 755, not 700'));
      expect(
        await untrustedAddress(file, strict: true),
        contains('mode 755, not 700'),
      );

      // A client of that project then refuses to use the host, with why.
      final (:scope, folder: _) = testHost('/work/my app', folder: folder);
      await expectLater(
        codesIn(scope, 'lib/main.dart'),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            contains('will not use the analysis host address file'),
          ),
        ),
      );
    },
    skip: Platform.isWindows
        ? 'On Windows the folder is in %LOCALAPPDATA%, the user\'s own, and '
              'has no Unix mode'
        : false,
  );

  test(
    'off Windows a folder path that is a link is refused, with an address '
    'file behind it or none',
    () async {
      final mine = p.join(tempDir().path, 'my own');
      Directory(mine).createSync();
      final linked = p.join(tempDir().path, 'appstein-planted');
      Link(linked).createSync(mine);
      final file = analysisHostAddressFile(linked, '/work/my app');
      expect(await untrustedAddress(file), contains('is not a plain folder'));
      expect(
        await untrustedAddressFolder(linked),
        contains('is not a plain folder'),
      );

      // A good address in a good folder, reached through the link.
      await writeAnalysisHostAddress(
        analysisHostAddressFile(mine, '/work/my app'),
        const AnalysisHostAddress(
          port: 1,
          secret: 's',
          processId: 1,
          appsteinVersion: 'test',
        ),
      );
      expect(File(file).existsSync(), isTrue);
      expect(await untrustedAddress(file), contains('is not a plain folder'));
      expect(
        await untrustedAddress(file, strict: true),
        contains('is not a plain folder'),
      );
    },
    skip: Platform.isWindows
        ? 'On Windows the folder is in %LOCALAPPDATA%, the user\'s own, and '
              'has no Unix mode'
        : false,
  );

  test(
    "off Windows a host started into a folder of the user's own at 755, with "
    'no address file, starts, answers and leaves the folder at 700',
    () async {
      final app = copyFixtureApp();
      final folder = p.join(tempDir().path, 'host folder');
      Directory(folder).createSync();
      Process.runSync('chmod', ['755', folder]);
      final (:scope, folder: _) = testHost(app, folder: folder);
      expect(await codesIn(scope, 'lib/main.dart'), isEmpty);
      expect(hostProcess(folder, app), isNotNull);
      expect((FileStat.statSync(folder).mode & 0x1FF).toRadixString(8), '700');
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: Platform.isWindows
        ? 'On Windows the folder is in %LOCALAPPDATA%, the user\'s own, and '
              'has no Unix mode'
        : false,
  );

  test('an address is written whole and read back; a missing or damaged '
      'file reads as none', () async {
    final folder = '${tempDir().path}${Platform.pathSeparator}hosts';
    final file = analysisHostAddressFile(folder, '/work/my app');
    expect(readAnalysisHostAddress(file), isNull);
    const address = AnalysisHostAddress(
      port: 50123,
      secret: 'abc',
      processId: 42,
      appsteinVersion: '0.1.0',
    );
    await writeAnalysisHostAddress(file, address);
    final read = readAnalysisHostAddress(file)!;
    expect(read.toJson(), address.toJson());
    // Nothing but the file itself is left in the folder.
    expect(Directory(folder).listSync(), hasLength(1));
    File(file).writeAsStringSync('{"port": ');
    expect(readAnalysisHostAddress(file), isNull);
  });

  test('the first question starts the host; a second client gets the same one, '
      'with the same analysis server, and sees an edit made between', () async {
    final app = copyFixtureApp();
    writeProjectFile(app, 'lib/broken.dart', _wrong);
    final (:scope, :folder) = testHost(app);
    expect(hostProcess(folder, app), isNull);

    expect(await codesIn(scope, 'lib/broken.dart'), ['return_of_invalid_type']);
    final host = hostProcess(folder, app);
    expect(host, isNotNull, reason: 'no address file');
    expect(await processAlive(host!), isTrue);
    final under = await processesUnder(host);
    // The guard and the analysis server, at least.
    expect(under.length, greaterThanOrEqualTo(2), reason: '$under');
    await recordProcesses(under);

    writeProjectFile(app, 'lib/broken.dart', _right);
    // Each use of the scope is a client of its own, with a connection of
    // its own, as another session's would be.
    expect(await codesIn(scope, 'lib/broken.dart'), isEmpty);
    expect(hostProcess(folder, app), host);
    expect(await processesUnder(host), under, reason: 'a new server');

    // The project's path has spaces (`copyFixtureApp`), and on Windows,
    // where letter case doesn't matter, a client that spells it in other
    // letters is a client of the same host.
    if (Platform.isWindows) {
      final spelled = app.toUpperCase();
      final (scope: other, folder: _) = testHost(spelled, folder: folder);
      expect(await codesIn(other, 'lib/broken.dart'), isEmpty);
      expect(hostProcess(folder, spelled), host);
      expect(await processesUnder(host), under, reason: 'a new server');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the host takes its server for one question at a time: a client that '
      'stays connected between its questions does not keep another '
      'client waiting', () async {
    final app = copyFixtureApp();
    final (:scope, folder: _) = testHost(app);
    final firstAsked = Completer<void>();
    final secondAnswered = Completer<void>();
    final first = scope((analysis) async {
      await analysis.read();
      firstAsked.complete();
      // Still connected, asking nothing, until the other client is answered.
      await secondAnswered.future.timeout(const Duration(minutes: 2));
      return (await analysis.read()).analyzedFiles;
    });
    await firstAsked.future;
    expect(await codesIn(scope, 'lib/main.dart'), isEmpty);
    secondAnswered.complete();
    expect(await first, contains('lib/main.dart'));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('every question of the interface crosses: formatting, the pending fixes '
      'and applying them, with a generated file left unformatted', () async {
    final app = copyFixtureApp();
    writeProjectFile(app, 'lib/messy.dart', 'int   messy( )=>1;\n');
    writeProjectFile(
      app,
      'lib/made.g.dart',
      '// GENERATED CODE - DO NOT MODIFY BY HAND\n\nint   made( )=>1;\n',
    );
    final (:scope, folder: _) = testHost(app);
    final outcome = await scope((analysis) async {
      final reading = await analysis.read();
      final format = await analysis.formatChanges([
        'lib/messy.dart',
        'lib/made.g.dart',
      ], within: const Duration(seconds: 30));
      final pending = await analysis.pendingFixes(
        within: const Duration(seconds: 60),
      );
      final applied = await applyToProject(analysis, projectRoot: app);
      return (
        reading: reading,
        format: format,
        pending: pending,
        applied: applied,
      );
    });
    expect(outcome.reading.analyzedFiles, contains('lib/messy.dart'));
    expect(outcome.format.changed, {
      'lib/messy.dart': true,
      'lib/made.g.dart': true,
    });
    expect(outcome.pending.unfinished, isNull);
    expect(outcome.applied.written, contains('lib/messy.dart'));
    expect(outcome.applied.written, isNot(contains('lib/made.g.dart')));
    expect(
      File('$app/lib/messy.dart').readAsStringSync(),
      'int messy() => 1;\n',
    );
    expect(
      File('$app/lib/made.g.dart').readAsStringSync(),
      contains('int   made( )=>1;'),
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a connection that does not send the secret first is closed; one that '
      'does is welcomed', () async {
    final app = copyFixtureApp();
    final (:scope, :folder) = testHost(app);
    await codesIn(scope, 'lib/main.dart');
    final address = readAnalysisHostAddress(
      analysisHostAddressFile(folder, app),
    )!;
    expect(address.secret.length, greaterThanOrEqualTo(32));
    expect(address.appsteinVersion, 'test');

    String hello(String secret) => jsonEncode(
      AnalysisHostHello(secret: secret, appsteinVersion: 'test').toJson(),
    );
    expect(await answerTo(address.port, hello('not the secret')), isEmpty);
    expect(await answerTo(address.port, '{"id": 1, "kind": "read"}'), isEmpty);
    final welcome = await answerTo(address.port, hello(address.secret));
    expect(welcome, hasLength(1));
    expect(
      AnalysisHostWelcome.fromJson(
        jsonDecode(welcome.single) as Map<String, Object?>,
      ).processId,
      address.processId,
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the host ends itself, with its guard and server, after its idle time '
      'with no question, even while a client stays connected, and never during '
      'a question; the next question starts a new one', () async {
    final app = copyFixtureApp();
    writeProjectFile(app, 'lib/broken.dart', _wrong);
    const idle = Duration(seconds: 2);
    final (:scope, :folder) = testHost(app, idle: idle);
    int? host;
    var under = <int>{};
    await scope((analysis) async {
      // The first reading starts the guard and the server from source,
      // which takes longer than the idle time: the host does not end
      // during it.
      final watch = Stopwatch()..start();
      await analysis.read();
      expect(watch.elapsed, greaterThan(idle), reason: 'a weak test');
      host = hostProcess(folder, app);
      under = await processesUnder(host!);
      await recordProcesses([host!, ...under]);
      // Connected, asking nothing: the host still ends.
      expect(
        await goneWithin([host!, ...under], const Duration(seconds: 30)),
        isNotNull,
        reason: 'the idle host or what ran under it',
      );
      expect(hostProcess(folder, app), isNull, reason: 'its address file');
      // The next reading of this client, which depends on nothing asked
      // before, is asked of a new host.
      writeProjectFile(app, 'lib/broken.dart', _right);
      expect((await analysis.read()).diagnostics, isEmpty);
    });
    expect(hostProcess(folder, app), allOf(isNotNull, isNot(host)));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a killed host takes its guard and server with it, and the next '
      'question starts a new one', () async {
    final app = copyFixtureApp();
    final (:scope, :folder) = testHost(app);
    await codesIn(scope, 'lib/main.dart');
    final host = hostProcess(folder, app)!;
    final under = await processesUnder(host);
    await recordProcesses([host, ...under]);
    Process.killPid(host, ProcessSignal.sigkill);
    expect(
      await goneWithin([host, ...under], const Duration(seconds: 20)),
      isNotNull,
    );
    await codesIn(scope, 'lib/main.dart');
    expect(hostProcess(folder, app), isNot(host));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a host that can\'t start is Appstein failing: the question throws a '
      'CodeAnalysisException that says so', () async {
    final app = copyFixtureApp();
    final (:scope, folder: _) = testHost(
      app,
      hostCommand: [Platform.resolvedExecutable, 'no such script.dart'],
    );
    await expectLater(
      codesIn(scope, 'lib/main.dart'),
      throwsA(
        isA<CodeAnalysisException>().having(
          (error) => error.reason,
          'reason',
          contains('analysis host'),
        ),
      ),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a host that fails before it has an address leaves why beside it, and '
      'throws', () async {
    final app = tempDir().path;
    final folder = p.join(tempDir().path, 'host folder');
    final file = analysisHostAddressFile(folder, app);
    // A folder where the address file must go: the rename onto it fails.
    Directory(file).createSync(recursive: true);
    await expectLater(
      runAnalysisHost(
        projectRoot: app,
        analysis: _StandInServer.new,
        addressFolder: folder,
        appsteinVersion: 'test',
      ),
      throwsA(isA<FileSystemException>()),
    );
    final why = File(analysisHostFailureFile(file)).readAsStringSync();
    expect(why, startsWith('the analysis host could not start: '));
    expect(why, isNot(contains('\n')));
  });

  test("the client's error repeats why the host it started could not start, "
      'and takes the reason away', () async {
    final app = tempDir().path;
    final folder = p.join(tempDir().path, 'host folder');
    const why = 'the analysis host could not start: a reason (a path)';
    final (:scope, folder: _) = testHost(
      app,
      folder: folder,
      hostCommand: [
        Platform.resolvedExecutable,
        analysisSupportFile('failing_host_main.dart'),
        folder,
        '700',
        why,
      ],
    );
    await expectLater(
      codesIn(scope, 'lib/main.dart'),
      throwsA(
        isA<CodeAnalysisException>().having(
          (error) => error.reason,
          'reason',
          why,
        ),
      ),
    );
    // Read, and so taken away.
    expect(
      File(
        analysisHostFailureFile(analysisHostAddressFile(folder, app)),
      ).existsSync(),
      isFalse,
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'off Windows a reason left in a folder that is not 700 is never read: '
    "the client's error names the folder instead",
    () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'host folder');
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        hostCommand: [
          Platform.resolvedExecutable,
          analysisSupportFile('failing_host_main.dart'),
          folder,
          '755',
          'the analysis host could not start: planted',
        ],
      );
      await expectLater(
        codesIn(scope, 'lib/main.dart'),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            allOf(
              startsWith('the analysis host could not start: the folder '),
              contains('mode 755, not 700'),
              isNot(contains('planted')),
            ),
          ),
        ),
      );
      // Not read, so left as it was.
      expect(
        File(
          analysisHostFailureFile(analysisHostAddressFile(folder, app)),
        ).existsSync(),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: Platform.isWindows
        ? 'On Windows the folder is in %LOCALAPPDATA%, the user\'s own, and '
              'has no Unix mode'
        : false,
  );

  // Ticket 03: every session shares one host.
  group('one host for every client of a project', () {
    test('clients that start a host at the same moment end with one host and '
        'one analysis server: the one that loses waits for the winner and '
        'connects to it', () async {
      final app = copyFixtureApp();
      final (scope: one, :folder) = testHost(app);
      final (scope: two, folder: _) = testHost(app, folder: folder);
      expect(
        await Future.wait([
          codesIn(one, 'lib/main.dart'),
          codesIn(two, 'lib/main.dart'),
        ]),
        [isEmpty, isEmpty],
      );
      final started = startedHostProcesses(folder);
      expect(started, hasLength(2), reason: 'both did not start: a weak test');
      final host = hostProcess(folder, app)!;
      expect(started, contains(host));
      // The one that lost ends by itself, having started no server.
      expect(
        await goneWithin([
          for (final id in started)
            if (id != host) id,
        ], const Duration(seconds: 30)),
        isNotNull,
      );
      expect(await processAlive(host), isTrue);
      final under = await processesUnder(host);
      await recordProcesses(under);
      expect(under.length, greaterThanOrEqualTo(2), reason: '$under');
      // Both clients' next questions go to that host and server.
      expect(await codesIn(one, 'lib/main.dart'), isEmpty);
      expect(await codesIn(two, 'lib/main.dart'), isEmpty);
      expect(hostProcess(folder, app), host);
      expect(await processesUnder(host), under);
      // Nothing but the address file is left in the folder.
      expect(
        [
          for (final entry in Directory(folder).listSync())
            p.basename(entry.path),
        ],
        [p.basename(analysisHostAddressFile(folder, app))],
      );
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('an address file whose host refuses the connection, or has ended and '
        'whose port answers no welcome, is deleted and a new host is '
        'started', () async {
      // A process ID that is no process's now.
      final ended = await endedProcess();
      for (final how in ['refuses', 'ended']) {
        final app = copyFixtureApp();
        final folder = p.join(tempDir().path, 'host folder');
        final file = analysisHostAddressFile(folder, app);
        final listening = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final port = listening.port;
        if (how == 'refuses') {
          await listening.close();
        } else {
          // Another program has the port now: it takes the connection and
          // says nothing.
          addTearDown(listening.close);
          listening.listen((socket) {});
        }
        await writeAnalysisHostAddress(
          file,
          AnalysisHostAddress(
            port: port,
            secret: 'dead',
            processId: ended,
            appsteinVersion: 'test',
          ),
        );
        final (:scope, folder: _) = testHost(app, folder: folder);
        expect(await codesIn(scope, 'lib/main.dart'), isEmpty, reason: how);
        final address = readAnalysisHostAddress(file)!;
        expect(address.secret, isNot('dead'), reason: how);
        expect(startedHostProcesses(folder), [address.processId], reason: how);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('an address file is deleted only while it still holds the address '
        'found dead: one another starter has just written is left', () async {
      final folder = p.join(tempDir().path, 'hosts');
      final file = analysisHostAddressFile(folder, '/work/my app');
      AnalysisHostAddress address(String secret) => AnalysisHostAddress(
        port: 1,
        secret: secret,
        processId: 1,
        appsteinVersion: 'test',
      );
      await writeAnalysisHostAddress(file, address('dead'));
      // Another client replaced it after this one found it dead.
      await writeAnalysisHostAddress(file, address('new'));
      expect(await removeAnalysisHostAddress(file, 'dead'), isFalse);
      expect(readAnalysisHostAddress(file)!.secret, 'new');
      expect(await removeAnalysisHostAddress(file, 'new'), isTrue);
      expect(File(file).existsSync(), isFalse);
      expect(await removeAnalysisHostAddress(file, 'new'), isFalse);
      // The lock it took is gone too.
      expect(File(analysisHostLockFile(file)).existsSync(), isFalse);
    });

    test('the lock on an address file lets one change at a time, and a lock '
        'left by a process that died is cleared', () async {
      final folder = p.join(tempDir().path, 'hosts');
      Directory(folder).createSync(recursive: true);
      final file = analysisHostAddressFile(folder, '/work/my app');
      var inside = 0;
      var most = 0;
      Future<void> change() => withAnalysisHostLock(file, () async {
        most = max(most, ++inside);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        inside--;
      });
      await Future.wait([for (var i = 0; i < 5; i++) change()]);
      expect(most, 1);
      expect(File(analysisHostLockFile(file)).existsSync(), isFalse);

      // Left by a process that has ended: cleared at once.
      final lock = File(analysisHostLockFile(file))
        ..writeAsStringSync('${await endedProcess()}');
      final watch = Stopwatch()..start();
      expect(await withAnalysisHostLock(file, () async => 'in'), 'in');
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      // Empty (its maker died before it wrote its ID) and old: cleared.
      lock
        ..writeAsStringSync('')
        ..setLastModifiedSync(
          DateTime.now().subtract(const Duration(seconds: 20)),
        );
      watch.reset();
      expect(await withAnalysisHostLock(file, () async => 'in'), 'in');
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('an old lock is cleared whatever process it names, even a live one '
        'whose ID was given to another program', () async {
      final folder = p.join(tempDir().path, 'hosts');
      Directory(folder).createSync(recursive: true);
      final file = analysisHostAddressFile(folder, '/work/my app');
      // A live process that is not the lock's maker: this test's own.
      final lock = File(analysisHostLockFile(file))
        ..writeAsStringSync('$pid')
        ..setLastModifiedSync(
          DateTime.now().subtract(const Duration(seconds: 20)),
        );
      final watch = Stopwatch()..start();
      expect(await withAnalysisHostLock(file, () async => 'in'), 'in');
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(lock.existsSync(), isFalse);

      // A new one, held for a moment by a live process: left alone.
      lock.writeAsStringSync('$pid');
      watch.reset();
      final waited = withAnalysisHostLock(file, () async => 'in');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      lock.deleteSync();
      expect(await waited, 'in');
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 450)));
    });

    test('a lock made anew between the two looks, with the same text, is '
        'left: the modified time tells it from the old one', () async {
      final folder = p.join(tempDir().path, 'hosts');
      Directory(folder).createSync(recursive: true);
      final file = analysisHostAddressFile(folder, '/work/my app');
      final lock = File(analysisHostLockFile(file))
        ..writeAsStringSync('')
        ..setLastModifiedSync(
          DateTime.now().subtract(const Duration(seconds: 20)),
        );
      var looks = 0;
      final watch = Stopwatch()..start();
      final result = await withAnalysisHostLock(
        file,
        () async => 'in',
        stale: const Duration(seconds: 2),
        beforeClear: () async {
          // Another starter made its lock, empty for now, the moment the old
          // one was found abandoned.
          if (looks++ == 0) {
            lock
              ..deleteSync()
              ..writeAsStringSync('');
          }
        },
      );
      expect(result, 'in');
      // The new lock was left until it was stale itself.
      expect(looks, 2);
      // Not 1900: before Dart 3.13 a modified time on Linux has whole-second
      // resolution (dart-lang/sdk#42444), so the 2 s limit can fire after 1 s.
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 900)));
    });

    test('versions compare as semantic versions; one that is not one counts '
        'as newer than the client', () {
      expect(compareAppsteinVersions('0.2.0', '0.2.0'), 0);
      expect(compareAppsteinVersions('0.10.0', '0.9.0'), greaterThan(0));
      expect(compareAppsteinVersions('0.9.0', '0.10.0'), lessThan(0));
      expect(compareAppsteinVersions('1.0.0-dev', '1.0.0'), lessThan(0));
      expect(compareAppsteinVersions('test', 'test'), 0);
      // Either unreadable: the client is older, so it stops nothing.
      expect(compareAppsteinVersions('2.0.0', 'garbage'), lessThan(0));
      expect(compareAppsteinVersions('garbage', '1.0.0'), lessThan(0));
    });

    test('a client of a newer Appstein version asks the host to stop; its '
        "answer comes from a new host of its own version, and the old host "
        'ends with its guard and server', () async {
      final app = copyFixtureApp();
      writeProjectFile(app, 'lib/broken.dart', _wrong);
      final (scope: older, :folder) = testHost(app, version: '1.0.0');
      expect(await codesIn(older, 'lib/broken.dart'), [
        'return_of_invalid_type',
      ]);
      final old = hostProcess(folder, app)!;
      final under = await processesUnder(old);
      await recordProcesses([old, ...under]);

      final (scope: newer, folder: _) = testHost(
        app,
        folder: folder,
        version: '2.0.0',
      );
      expect(await codesIn(newer, 'lib/broken.dart'), [
        'return_of_invalid_type',
      ]);
      final address = readAnalysisHostAddress(
        analysisHostAddressFile(folder, app),
      )!;
      expect(address.appsteinVersion, '2.0.0');
      expect(address.processId, isNot(old));
      expect(
        await goneWithin([old, ...under], const Duration(seconds: 30)),
        isNotNull,
        reason: 'the old host, its guard or its server',
      );
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a client of an older Appstein version leaves a newer host running, '
        'answers from a server of its own, and says the session should be '
        'restarted', () async {
      final app = copyFixtureApp();
      writeProjectFile(app, 'lib/broken.dart', _wrong);
      final (scope: newer, :folder) = testHost(app, version: '2.0.0');
      expect(await codesIn(newer, 'lib/broken.dart'), [
        'return_of_invalid_type',
      ]);
      final host = hostProcess(folder, app)!;
      final under = await processesUnder(host);
      await recordProcesses([host, ...under]);

      final (scope: older, folder: _) = testHost(
        app,
        folder: folder,
        version: '1.0.0',
      );
      final reading = await older((analysis) => analysis.read());
      expect(
        [
          for (final found in reading.diagnostics)
            if (found.file == 'lib/broken.dart') found.code,
        ],
        ['return_of_invalid_type'],
      );
      expect(reading.notices, [olderThanHostNotice('1.0.0', '2.0.0')]);
      expect(reading.notices.single, contains('Restart the session'));
      // The host and its server are as they were, and nothing was started.
      expect(hostProcess(folder, app), host);
      expect(await processAlive(host), isTrue);
      expect(await processesUnder(host), under);
      expect(startedHostProcesses(folder), [host]);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('two sessions of two versions no longer replace each other: the '
        'newer keeps its host, the older answers from its own server each '
        'time', () async {
      final app = copyFixtureApp();
      final (scope: older, :folder) = testHost(app, version: '1.0.0');
      final (scope: newer, folder: _) = testHost(
        app,
        folder: folder,
        version: '2.0.0',
      );
      // The older first: its host is replaced once by the newer's.
      expect(await codesIn(older, 'lib/main.dart'), isEmpty);
      expect(await codesIn(newer, 'lib/main.dart'), isEmpty);
      final host = hostProcess(folder, app)!;
      expect(startedHostProcesses(folder), hasLength(2));
      for (var round = 0; round < 2; round++) {
        final reading = await older((analysis) => analysis.read());
        expect(reading.notices, hasLength(1), reason: 'round $round');
        expect(await codesIn(newer, 'lib/main.dart'), isEmpty);
        expect(hostProcess(folder, app), host, reason: 'round $round');
      }
      expect(startedHostProcesses(folder), hasLength(2));
      expect(await processAlive(host), isTrue);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test("a change of the project's SDK starts the host's server again; the "
        'next answer comes from the new SDK', () async {
      final app = copyFixtureApp();
      writeProjectFile(app, 'lib/broken.dart', _wrong);
      // Where the host finds the project's `dart`, as `fvm use` changes it.
      final pointer = File(p.join(tempDir().path, 'sdk.txt'))
        ..writeAsStringSync(testDart);
      final (:scope, :folder) = testHost(app, dartFrom: pointer.path);
      expect(await codesIn(scope, 'lib/broken.dart'), [
        'return_of_invalid_type',
      ]);
      final host = hostProcess(folder, app)!;
      final first = await processesUnder(host);
      await recordProcesses([host, ...first]);

      // An SDK that is not there: the answer says so, so it is the new
      // SDK's.
      final missing = dartExecutableIn(p.join(tempDir().path, 'no sdk'));
      pointer.writeAsStringSync(missing);
      await expectLater(
        codesIn(scope, 'lib/broken.dart'),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            contains(missing),
          ),
        ),
      );
      expect(
        await goneWithin(first, const Duration(seconds: 30)),
        isNotNull,
        reason: "the old SDK's guard or server",
      );

      // Another SDK folder: the folders of the one the tests run on, linked,
      // and a `version` file of its own, as an SDK upgraded in place
      // changes it.
      final other = Directory(p.join(tempDir().path, 'other sdk'))
        ..createSync();
      for (final entry in Directory(testDartSdk).listSync()) {
        final into = p.join(other.path, p.basename(entry.path));
        if (entry is Directory) {
          // Taken away before the temporary folder is deleted, so that
          // delete never reaches the real SDK through it.
          final link = Link(into)..createSync(entry.path);
          addTearDown(link.deleteSync);
        } else if (entry is File) {
          entry.copySync(into);
        }
      }
      pointer.writeAsStringSync(dartExecutableIn(other.path));
      expect(await codesIn(scope, 'lib/broken.dart'), [
        'return_of_invalid_type',
      ]);
      expect(hostProcess(folder, app), host);
      final second = await processesUnder(host);
      expect(second.length, greaterThanOrEqualTo(2), reason: '$second');
      expect(second.intersection(first), isEmpty);
      await recordProcesses(second);

      // The same `dart`, upgraded in place (`flutter upgrade`): only its
      // SDK's version file says so.
      final version = File(p.join(other.path, 'version'));
      expect(version.readAsStringSync().trim(), isNot('9.9.9'));
      version.writeAsStringSync('9.9.9\n');
      expect(await codesIn(scope, 'lib/broken.dart'), [
        'return_of_invalid_type',
      ]);
      expect(hostProcess(folder, app), host);
      expect(
        await goneWithin(second, const Duration(seconds: 30)),
        isNotNull,
        reason: "the server of the SDK before the upgrade",
      );
      final third = await processesUnder(host);
      expect(third.length, greaterThanOrEqualTo(2), reason: '$third');
      expect(third.intersection(second), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a project with a long name, spelled in other letters on Windows, '
        'has one host; another project gets a host of its own', () async {
      final copied = copyFixtureApp();
      // The stubs it uses are found from its parent folder, so it is renamed
      // beside them.
      final app = p
          .join(p.dirname(copied), 'An App Whose Name Goes On And On ' * 3)
          .trimRight();
      Directory(copied).renameSync(app);
      final (:scope, :folder) = testHost(app);
      expect(await codesIn(scope, 'lib/main.dart'), isEmpty);
      final host = hostProcess(folder, app)!;
      if (Platform.isWindows) {
        final spelled = app.toLowerCase();
        final (scope: other, folder: _) = testHost(spelled, folder: folder);
        expect(await codesIn(other, 'lib/main.dart'), isEmpty);
        expect(hostProcess(folder, spelled), host);
      }
      final another = copyFixtureApp();
      final (scope: second, folder: _) = testHost(another, folder: folder);
      expect(await codesIn(second, 'lib/main.dart'), isEmpty);
      final its = hostProcess(folder, another)!;
      expect(its, isNot(host));
      expect(await processAlive(host), isTrue);
      expect(await processAlive(its), isTrue);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('the queue of a host in this process, with a stand-in server', () {
    test("a question asked during another client's pending-fix passes waits "
        'for them, and never sees their temporary edits', () async {
      final app = tempDir().path;
      final (:server, :folder, :address) = await inProcessHost(app);
      // A failed test still lets the host end.
      addTearDown(() {
        if (!server.passesHeld.isCompleted) server.passesHeld.complete();
      });
      // The client of a full run, asking its passes.
      final full = await rawClient(address);
      addTearDown(full.socket.destroy);
      send(
        full.socket,
        const AnalysisHostQuestion(
          id: 0,
          kind: AnalysisHostQuestionKind.pendingFixes,
          within: Duration(seconds: 60),
        ),
      );
      expect(AnalysisHostTurn.isTurn(await nextLine(full.lines)), isTrue);
      await server.passesBegan.future;

      // Another client's fast reading, sent while the passes hold the
      // server with their edit.
      final (scope: fast, folder: _) = testHost(app, folder: folder);
      var answered = false;
      final reading = fast((analysis) => analysis.read()).then((reading) {
        answered = true;
        return reading;
      });
      // It reached the host and waits in its queue: the host has its line
      // (the reading's turn has not come), and the passes still run.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(server.editing, isTrue, reason: 'the passes ended: a weak test');
      expect(answered, isFalse, reason: 'answered during the passes');
      expect(server.asked, ['passes']);

      server.passesHeld.complete();
      expect(
        AnalysisHostAnswer.fromJson(await nextLine(full.lines)).value,
        isNotNull,
      );
      // Begun only after the passes ended, and without their edit.
      expect((await reading).analyzedFiles, ['lib/a.dart']);
      expect(server.asked, ['passes', 'passes ended', 'read']);
    });

    test('a question waiting behind a slow one is answered: its time limit '
        'starts with its turn, not while it waits', () async {
      final app = tempDir().path;
      final (:server, :folder, address: _) = await inProcessHost(app);
      server.readTimes.add(const Duration(seconds: 3));
      final (scope: slow, folder: _) = testHost(app, folder: folder);
      final first = codesIn(slow, 'lib/a.dart');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // A client whose readings may take 1 s, asking while the slow one
      // takes 3 s.
      final (scope: fast, folder: _) = testHost(
        app,
        folder: folder,
        readyTimeout: Duration.zero,
        answerGrace: const Duration(seconds: 1),
      );
      expect(await codesIn(fast, 'lib/a.dart'), isEmpty);
      expect(await first, isEmpty);
      expect(server.asked, ['read', 'read']);
    });

    test('a question whose client went away while it waited is never '
        'begun: no file is written', () async {
      final app = tempDir().path;
      final (:server, folder: _, :address) = await inProcessHost(app);
      server
        ..readTimes.add(const Duration(seconds: 2))
        ..applyHeld.complete();
      final busy = await rawClient(address);
      busy.socket.writeln(
        jsonEncode(
          const AnalysisHostQuestion(
            id: 0,
            kind: AnalysisHostQuestionKind.read,
          ).toJson(),
        ),
      );
      final gone = await rawClient(address);
      gone.socket.writeln(
        jsonEncode(
          const AnalysisHostQuestion(
            id: 0,
            kind: AnalysisHostQuestionKind.applyFixesAndFormat,
            within: Duration(seconds: 5),
          ).toJson(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      gone.socket.destroy();
      // The read's turn, then its answer.
      expect(await busy.lines.moveNext(), isTrue);
      expect(await busy.lines.moveNext(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      busy.socket.destroy();
      expect(server.asked, ['read']);
      expect(server.written, isEmpty);
    });

    test('a rewrite whose client went away while the server worked writes '
        'nothing', () async {
      final app = tempDir().path;
      final (:server, folder: _, :address) = await inProcessHost(app);
      final client = await rawClient(address);
      client.socket.writeln(
        jsonEncode(
          const AnalysisHostQuestion(
            id: 0,
            kind: AnalysisHostQuestionKind.applyFixesAndFormat,
            within: Duration(seconds: 5),
          ).toJson(),
        ),
      );
      // Its turn began: the server is working on it.
      expect(await client.lines.moveNext(), isTrue);
      expect(
        AnalysisHostTurn.isTurn(
          jsonDecode(client.lines.current) as Map<String, Object?>,
        ),
        isTrue,
      );
      client.socket.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      server.applyHeld.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.asked, ['apply']);
      expect(server.written, isEmpty);
    });

    test('a host asked to stop answers the questions it has, and takes no new '
        'one: a question sent after the stop gets an ending, is never begun, '
        'and an --apply then writes nothing', () async {
      final app = tempDir().path;
      final (:server, :folder, :address) = await inProcessHost(app);
      server
        ..readTimes.add(const Duration(seconds: 1))
        ..applyHeld.complete();
      final busy = await rawClient(address);
      final queued = await rawClient(address);
      final late = await rawClient(address);
      final stopper = await rawClient(address);
      for (final client in [busy, queued, late, stopper]) {
        addTearDown(client.socket.destroy);
      }
      const read = AnalysisHostQuestion(
        id: 0,
        kind: AnalysisHostQuestionKind.read,
      );
      send(busy.socket, read);
      expect(AnalysisHostTurn.isTurn(await nextLine(busy.lines)), isTrue);
      send(queued.socket, read);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      stopper.socket.writeln(jsonEncode(const AnalysisHostStop().toJson()));
      expect(await stopper.lines.moveNext(), isFalse);
      expect(
        File(analysisHostAddressFile(folder, app)).existsSync(),
        isFalse,
        reason: 'the address is given up at once',
      );
      send(
        late.socket,
        const AnalysisHostQuestion(
          id: 0,
          kind: AnalysisHostQuestionKind.applyFixesAndFormat,
          within: Duration(seconds: 5),
        ),
      );
      expect(await nextLine(late.lines), const AnalysisHostEnding(0).toJson());
      expect(await late.lines.moveNext(), isFalse);

      // What it had is answered: the one under way and the one queued.
      expect(
        AnalysisHostAnswer.fromJson(await nextLine(busy.lines)).value,
        isNotNull,
      );
      expect(AnalysisHostTurn.isTurn(await nextLine(queued.lines)), isTrue);
      expect(
        AnalysisHostAnswer.fromJson(await nextLine(queued.lines)).value,
        isNotNull,
      );
      expect(server.asked, ['read', 'read']);
      expect(server.written, isEmpty);
    });

    test('a host that ends after its idle time begins no question that comes '
        'while it ends', () async {
      final app = tempDir().path;
      final (:server, :folder, :address) = await inProcessHost(app);
      final client = await rawClient(address);
      addTearDown(client.socket.destroy);
      final file = analysisHostAddressFile(folder, app);
      // The address is given up as the host begins to end, and the
      // connection stays open until what was written has gone out.
      while (File(file).existsSync()) {
        await Future<void>.delayed(Duration.zero);
      }
      send(
        client.socket,
        const AnalysisHostQuestion(id: 0, kind: AnalysisHostQuestionKind.read),
      );
      // The host answers with an ending or closes the connection; it never
      // takes the question.
      try {
        while (await client.lines.moveNext()) {
          final line = jsonDecode(client.lines.current) as Map<String, Object?>;
          expect(AnalysisHostTurn.isTurn(line), isFalse);
        }
      } on SocketException {
        // The host closed it before reading the question: a reset is a close.
      }
      expect(server.asked, isEmpty, reason: 'never begun');
    });

    test("a client whose question meets a stopped host gets its answer from "
        'the host that took the project, in the same run', () async {
      final app = tempDir().path;
      final first = await inProcessHost(app);
      final (:scope, folder: _) = testHost(app, folder: first.folder);
      final replaced = Completer<void>();
      final answered = scope((analysis) async {
        await analysis.read();
        await replaced.future;
        return (await analysis.read()).analyzedFiles;
      });
      while (first.server.asked.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      // Another client asks the host to stop, and starts the next one.
      final stopper = await rawClient(first.address);
      stopper.socket.writeln(jsonEncode(const AnalysisHostStop().toJson()));
      expect(await stopper.lines.moveNext(), isFalse);
      final second = await inProcessHost(app, folder: first.folder);
      replaced.complete();

      expect(await answered, ['lib/a.dart']);
      expect(first.server.asked, ['read'], reason: 'the old host answered');
      expect(second.server.asked, ['read']);
    });

    test('a rewrite whose client stays writes', () async {
      final app = tempDir().path;
      final (:server, :folder, address: _) = await inProcessHost(app);
      server.applyHeld.complete();
      final (:scope, folder: _) = testHost(app, folder: folder);
      final applied = await scope((analysis) async {
        await analysis.read();
        return analysis.applyFixesAndFormat(
          leaveUnformatted: (_) async => false,
          within: const Duration(seconds: 5),
        );
      });
      expect(applied.written, ['lib/a.dart']);
      expect(server.written, ['lib/a.dart']);
    });
  });

  test(
    'off Windows, a folder path that is a link is refused: the host makes '
    'and changes nothing through it, and a client says why',
    () async {
      final mine = Directory(p.join(tempDir().path, 'my own'))..createSync();
      Process.runSync('chmod', ['755', mine.path]);
      final folder = p.join(tempDir().path, 'appstein-planted');
      Link(folder).createSync(mine.path);
      final file = analysisHostAddressFile(folder, '/work/my app');
      await expectLater(
        writeAnalysisHostAddress(
          file,
          const AnalysisHostAddress(
            port: 1,
            secret: 's',
            processId: 1,
            appsteinVersion: 'test',
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(mine.listSync(), isEmpty);
      expect(
        (FileStat.statSync(mine.path).mode & 0x1FF).toRadixString(8),
        '755',
      );
      expect(await untrustedAddress(file), contains('is not a plain folder'));
    },
    skip: Platform.isWindows
        ? 'The link check is for Linux and macOS, where the folder can be in '
              'a temporary folder that other users share'
        : false,
  );

  group('a host that stops answering (a stand-in in this process)', () {
    /// A stand-in host for the project [app] in [folder]: it welcomes a
    /// client with the secret and then does [onQuestion] with its socket.
    Future<void> standIn(
      String folder,
      String app,
      void Function(Socket socket) onQuestion, {
      void Function()? onClientClosed,
    }) async {
      final listening = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(listening.close);
      await writeAnalysisHostAddress(
        analysisHostAddressFile(folder, app),
        AnalysisHostAddress(
          port: listening.port,
          secret: 'stand-in',
          processId: pid,
          appsteinVersion: 'test',
        ),
      );
      listening.listen((socket) {
        socket.done.ignore();
        var lines = 0;
        utf8.decoder
            .bind(socket)
            .transform(const LineSplitter())
            .listen(
              (line) {
                if (lines++ == 0) {
                  socket.writeln(
                    jsonEncode(
                      const AnalysisHostWelcome(
                        appsteinVersion: 'test',
                        processId: 1,
                      ).toJson(),
                    ),
                  );
                } else {
                  onQuestion(socket);
                }
              },
              onError: (Object _) {},
              onDone: onClientClosed,
            );
      });
    }

    test('one whose connection times out while its process runs is not taken '
        'for dead: the question fails, the address is left and no host is '
        'started', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      final file = analysisHostAddressFile(folder, app);
      // A live process: this test's own.
      await writeAnalysisHostAddress(
        file,
        AnalysisHostAddress(
          port: 1,
          secret: 'slow',
          processId: pid,
          appsteinVersion: 'test',
        ),
      );
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        // What `Socket.connect` throws when its timeout runs out.
        connect: (port) async => throw SocketException(
          'Connection timed out, host: 127.0.0.1, port: $port',
        ),
      );
      await expectLater(
        codesIn(scope, 'lib/main.dart'),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            startsWith('the analysis host did not take the connection'),
          ),
        ),
      );
      expect(readAnalysisHostAddress(file)?.secret, 'slow');
      expect(startedHostProcesses(folder), isEmpty);
    });

    test('one that ends during a question fails it, saying so', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      await standIn(folder, app, (socket) => socket.destroy());
      final (:scope, folder: _) = testHost(app, folder: folder);
      await expectLater(
        codesIn(scope, 'lib/main.dart'),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            'the analysis host ended, or closed the connection, before it '
                'answered',
          ),
        ),
      );
    });

    test('one that ends before a question other than a reading, after it '
        'answered one, fails it: it is not asked again of another', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      var questions = 0;
      await standIn(folder, app, (socket) {
        if (questions++ == 0) {
          socket
            ..writeln(jsonEncode(const AnalysisHostTurn(0).toJson()))
            ..writeln(
              jsonEncode(
                AnalysisHostAnswer.answered(
                  0,
                  const CodeReading().toJson(),
                ).toJson(),
              ),
            );
        } else {
          socket.destroy();
        }
      });
      final (:scope, folder: _) = testHost(app, folder: folder);
      await expectLater(
        scope((analysis) async {
          await analysis.read();
          return analysis.pendingFixes(within: const Duration(seconds: 5));
        }),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            'the analysis host ended, or closed the connection, before it '
                'answered',
          ),
        ),
      );
      expect(questions, 2, reason: 'not asked again of another');
    });

    test('one that does not answer in time fails the question, saying '
        'so', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      // Its turn begins, and no answer ever comes.
      await standIn(
        folder,
        app,
        (socket) =>
            socket.writeln(jsonEncode(const AnalysisHostTurn(0).toJson())),
      );
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        readyTimeout: Duration.zero,
        answerGrace: const Duration(seconds: 2),
      );
      await expectLater(
        codesIn(scope, 'lib/main.dart'),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            'the analysis host did not answer within 2 s',
          ),
        ),
      );
    });

    test('one that never begins the question fails it within the turn limit, '
        'saying so, and leaves no socket open', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      // It welcomes the client and reads the question, and sends no turn.
      final closed = Completer<void>();
      await standIn(
        folder,
        app,
        (_) {},
        onClientClosed: () => closed.complete(),
      );
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        turnLimit: const Duration(seconds: 1),
      );
      final watch = Stopwatch()..start();
      await expectLater(
        codesIn(scope, 'lib/main.dart'),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            'the analysis host did not begin the question within 1 s',
          ),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      // The client closed its end: the stand-in's side sees the end.
      await closed.future.timeout(const Duration(seconds: 5));
    });

    // Slice 1d.7, ticket 09: a fast run that reached its cap stops waiting
    // and its scope ends; what its question was still waiting for must end
    // with it.
    test('a scope that ends while its question waits for the welcome of a '
        'host that never sends one closes that connection and looks no '
        'more', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      final listening = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(listening.close);
      await writeAnalysisHostAddress(
        analysisHostAddressFile(folder, app),
        AnalysisHostAddress(
          port: listening.port,
          secret: 'silent',
          processId: pid,
          appsteinVersion: 'test',
        ),
      );
      var connections = 0;
      final firstClosed = Completer<void>();
      listening.listen((socket) {
        if (connections++ == 0) {
          // It reads the greeting and never answers it.
          socket.listen(
            (_) {},
            onError: (Object _) {},
            onDone: firstClosed.complete,
          );
        } else {
          socket.destroy();
        }
      });
      final (:scope, folder: _) = testHost(app, folder: folder);
      late Future<Object?> abandoned;
      final watch = Stopwatch()..start();
      await scope((analysis) async {
        abandoned = analysis.read().then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      // Not the 10 s the welcome would be waited for.
      await firstClosed.future.timeout(const Duration(seconds: 3));
      expect(
        await abandoned.timeout(const Duration(seconds: 5)),
        isA<CodeAnalysisException>().having(
          (error) => error.reason,
          'reason',
          contains('after the run that used it had ended'),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(connections, 1, reason: 'no look after the run ended');
    });

    test('a scope that ends while its client waits for a host of an older '
        'version to stop closes that connection and looks no more', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      final listening = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(listening.close);
      await writeAnalysisHostAddress(
        analysisHostAddressFile(folder, app),
        AnalysisHostAddress(
          port: listening.port,
          secret: 'older',
          processId: pid,
          appsteinVersion: '0.9.0',
        ),
      );
      var connections = 0;
      final firstClosed = Completer<void>();
      final stopAsked = Completer<void>();
      listening.listen((socket) {
        socket.done.ignore();
        if (connections++ > 0) {
          socket.destroy();
          return;
        }
        var lines = 0;
        utf8.decoder
            .bind(socket)
            .transform(const LineSplitter())
            .listen(
              // It welcomes the client as a host of an older version, and
              // never answers the stop it is sent (the client's second line).
              (_) {
                if (lines++ == 0) {
                  socket.writeln(
                    jsonEncode(
                      const AnalysisHostWelcome(
                        appsteinVersion: '0.9.0',
                        processId: 1,
                      ).toJson(),
                    ),
                  );
                } else if (!stopAsked.isCompleted) {
                  stopAsked.complete();
                }
              },
              onError: (Object _) {},
              onDone: firstClosed.complete,
            );
      });
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        version: '1.0.0',
      );
      late Future<Object?> abandoned;
      final watch = Stopwatch()..start();
      await scope((analysis) async {
        abandoned = analysis.read().then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );
        // The scope ends once the client waits for the stop to be answered,
        // not after a fixed time: a slow runner could end it while the
        // client still waited for the welcome.
        await stopAsked.future.timeout(const Duration(seconds: 30));
      });
      // Not the 10 s the stop would be waited for.
      await firstClosed.future.timeout(const Duration(seconds: 3));
      expect(
        await abandoned.timeout(const Duration(seconds: 5)),
        isA<CodeAnalysisException>().having(
          (error) => error.reason,
          'reason',
          contains('after the run that used it had ended'),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(connections, 1, reason: 'no look after the run ended');
    });

    test('warmUp launches the host that is not running while the run does '
        'other work; a client that starts no host starts nothing', () async {
      final app = tempDir().path;
      final marks = tempDir().path;
      // A "host" that only leaves a mark and ends.
      File(p.join(marks, 'host.dart')).writeAsStringSync(
        "import 'dart:io';\n"
        'void main(List<String> arguments) =>\n'
        "    File('\${arguments.first}').writeAsStringSync('started');\n",
      );
      List<String> command(String mark) => [
        Platform.resolvedExecutable,
        p.join(marks, 'host.dart'),
        mark,
      ];
      final watch = Stopwatch()..start();
      final folder = p.join(tempDir().path, 'hosts');
      // The address of a host that has ended: finding that out takes time,
      // and the run is over before it is known.
      await writeAnalysisHostAddress(
        analysisHostAddressFile(folder, app),
        const AnalysisHostAddress(
          port: 1,
          secret: 'dead',
          processId: 2147480000,
          appsteinVersion: 'test',
        ),
      );
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        hostCommand: command(p.join(marks, 'started')),
        connect: (port) async {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          throw SocketException(
            'refused',
            osError: const OSError('refused', 111),
          );
        },
      );
      final mark = File(p.join(marks, 'started'));
      var markedWhileBusy = false;
      await scope((analysis) async {
        (analysis as WarmableCodeAnalysis).warmUp();
        // The run's other work (the refresh) goes on, and the launch is
        // requested meanwhile, as soon as the look has found no host.
        final busy = Stopwatch()..start();
        while (!mark.existsSync() &&
            busy.elapsed < const Duration(seconds: 15)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        markedWhileBusy = mark.existsSync();
      });
      expect(markedWhileBusy, isTrue);
      // The scope ends at once: it waits for nothing.
      expect(watch.elapsed, lessThan(const Duration(seconds: 20)));

      final (scope: terminal, folder: _) = testHost(
        app,
        startHost: false,
        hostCommand: command(p.join(marks, 'terminal')),
      );
      await terminal((analysis) async {
        (analysis as WarmableCodeAnalysis).warmUp();
      });
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(File(p.join(marks, 'terminal')).existsSync(), isFalse);
    });

    test('a look that failed stays the run\'s answer: the first question gets '
        'the same failure at once, and no second host is launched', () async {
      final app = tempDir().path;
      final marks = tempDir().path;
      // A "host" that adds a line to the mark and dies at start.
      File(p.join(marks, 'host.dart')).writeAsStringSync(
        "import 'dart:io';\n"
        'void main(List<String> arguments) => File(arguments.first)\n'
        "    .writeAsStringSync('launched\\n', mode: FileMode.append);\n",
      );
      final mark = File(p.join(marks, 'launches'));
      final (:scope, folder: _) = testHost(
        app,
        hostCommand: [
          Platform.resolvedExecutable,
          p.join(marks, 'host.dart'),
          mark.path,
        ],
      );
      await scope((analysis) async {
        (analysis as WarmableCodeAnalysis).warmUp();
        // The look fails: the host it launched has ended without an address.
        final waited = Stopwatch()..start();
        while (waited.elapsed < const Duration(seconds: 20) &&
            !mark.existsSync()) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await Future<void>.delayed(const Duration(seconds: 2));
        final asked = Stopwatch()..start();
        await expectLater(
          analysis.read(),
          throwsA(
            isA<CodeAnalysisException>().having(
              (error) => error.reason,
              'reason',
              contains('ended before it answered'),
            ),
          ),
        );
        // The same failure, not another look.
        expect(asked.elapsed, lessThan(const Duration(seconds: 1)));
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(mark.readAsLinesSync(), ['launched']);
    });

    test('nothing of the look keeps the process alive after the run: a '
        'connection still being made is cancelled when the run ends', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      // The address of a host whose process is alive (this test runner's own,
      // so the look dials), on a port nothing listens on: on Windows the
      // refusal comes after about 2 s, so the connection is still being made
      // when the run ends. (A process that has ended is found dead without a
      // dial.)
      await writeAnalysisHostAddress(
        analysisHostAddressFile(folder, app),
        AnalysisHostAddress(
          port: 1,
          secret: 'live',
          processId: pid,
          appsteinVersion: 'test',
        ),
      );
      final process = await Process.start(Platform.resolvedExecutable, [
        analysisSupportFile('dial_main.dart'),
        folder,
        app,
      ]);
      final ended = Completer<Stopwatch>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line == 'ended' && !ended.isCompleted) {
              ended.complete(Stopwatch()..start());
            }
          });
      unawaited(process.stderr.drain<void>());
      addTearDown(process.kill);
      final sinceEnded = await ended.future.timeout(
        const Duration(seconds: 60),
      );
      await process.exitCode.timeout(const Duration(seconds: 30));
      // Not the 2 s of the connection that was still being made.
      expect(sinceEnded.elapsed, lessThan(const Duration(milliseconds: 1000)));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
      'a wait for the address file\'s lock ends when the run is over',
      () async {
        final folder = p.join(tempDir().path, 'hosts');
        final file = analysisHostAddressFile(folder, tempDir().path);
        await writeAnalysisHostAddress(
          file,
          const AnalysisHostAddress(
            port: 1,
            secret: 'dead',
            processId: 1,
            appsteinVersion: 'test',
          ),
        );
        // A lock held by a live process (this one), not yet old: it is waited
        // for, up to 10 s before it counts as left behind.
        File(analysisHostLockFile(file)).writeAsStringSync('$pid');
        var over = false;
        Timer(const Duration(milliseconds: 300), () => over = true);
        final watch = Stopwatch()..start();
        final removed = await removeAnalysisHostAddress(
          file,
          'dead',
          cancelled: () => over,
        );
        expect(removed, isFalse);
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(File(file).existsSync(), isTrue);
      },
    );

    test('a stale address file naming a process that has ended is dead '
        'without a connection attempt', () async {
      final app = tempDir().path;
      final marks = tempDir().path;
      File(p.join(marks, 'host.dart')).writeAsStringSync(
        "import 'dart:io';\n"
        'void main(List<String> arguments) => File(arguments.first)\n'
        "    .writeAsStringSync('launched\\n', mode: FileMode.append);\n",
      );
      final mark = File(p.join(marks, 'launches'));
      final folder = p.join(tempDir().path, 'hosts');
      // A listener that counts the connections made to it: the port of the
      // address file.
      var connections = 0;
      final listening = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(listening.close);
      listening.listen((socket) {
        connections++;
        socket.destroy();
      });
      await writeAnalysisHostAddress(
        analysisHostAddressFile(folder, app),
        AnalysisHostAddress(
          port: listening.port,
          secret: 'stale',
          processId: 2147480000,
          appsteinVersion: 'test',
        ),
      );
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        hostCommand: [
          Platform.resolvedExecutable,
          p.join(marks, 'host.dart'),
          mark.path,
        ],
      );
      await scope((analysis) async {
        (analysis as WarmableCodeAnalysis).warmUp();
        final waited = Stopwatch()..start();
        while (!mark.existsSync() &&
            waited.elapsed < const Duration(seconds: 20)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      // The stale address was found dead, deleted, and a host launched; the
      // port was never dialed.
      expect(mark.existsSync(), isTrue);
      expect(connections, 0);
    });

    test('a run launches one host, though warmUp and the first question '
        'both look for it', () async {
      final app = tempDir().path;
      final marks = tempDir().path;
      // A "host" that adds a line to the mark, and ends.
      File(p.join(marks, 'host.dart')).writeAsStringSync(
        "import 'dart:io';\n"
        'void main(List<String> arguments) => File(arguments.first)\n'
        "    .writeAsStringSync('launched\\n', mode: FileMode.append);\n",
      );
      final mark = File(p.join(marks, 'launches'));
      final (:scope, folder: _) = testHost(
        app,
        hostCommand: [
          Platform.resolvedExecutable,
          p.join(marks, 'host.dart'),
          mark.path,
        ],
      );
      await scope((analysis) async {
        (analysis as WarmableCodeAnalysis).warmUp();
        // The first question joins the look that is under way. The "host"
        // ends without answering, which is that question's failure.
        await expectLater(
          analysis.read(),
          throwsA(isA<CodeAnalysisException>()),
        );
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(mark.readAsLinesSync(), ['launched']);
    });

    test('warmUp does not outlast the run when the host is only starting: a '
        'host that listens and has not welcomed the client yet is left to '
        'start, and the scope ends at once', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      final listening = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(listening.close);
      await writeAnalysisHostAddress(
        analysisHostAddressFile(folder, app),
        AnalysisHostAddress(
          port: listening.port,
          secret: 'starting',
          processId: pid,
          appsteinVersion: 'test',
        ),
      );
      // It takes the connection and reads the greeting; it is not ready to
      // welcome anyone.
      listening.listen(
        (socket) => socket.listen((_) {}, onError: (Object _) {}),
      );
      final (:scope, folder: _) = testHost(app, folder: folder);
      final watch = Stopwatch()..start();
      await scope((analysis) async {
        (analysis as WarmableCodeAnalysis).warmUp();
      });
      // The cap was spent before the first question, so the run is over at
      // once: it does not wait for the welcome (10 s), nor for the longest
      // wait the close allows.
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 400)));
      // And it started nothing: a host listens already.
      expect(startedHostProcesses(folder), isEmpty);
    });

    test('a scope that ends while its client waits for a host it started '
        'stops the wait', () async {
      final app = tempDir().path;
      // A host that never comes: a program that ends by itself soon.
      final waiter = File(p.join(tempDir().path, 'wait.dart'))
        ..writeAsStringSync(
          'import \'dart:async\';\n'
          'void main() => Timer(const Duration(seconds: 4), () {});\n',
        );
      final (:scope, folder: _) = testHost(
        app,
        hostCommand: [Platform.resolvedExecutable, waiter.path],
      );
      late Future<Object?> abandoned;
      final watch = Stopwatch()..start();
      await scope((analysis) async {
        abandoned = analysis.read().then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );
        await Future<void>.delayed(const Duration(milliseconds: 600));
      });
      expect(
        await abandoned.timeout(const Duration(seconds: 3)),
        isA<CodeAnalysisException>().having(
          (error) => error.reason,
          'reason',
          contains('after the run that used it had ended'),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('a client that starts no host: one that ends during a question '
        'fails it, and no host or server of its own is started', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      await standIn(folder, app, (socket) => socket.destroy());
      final own = _OwnStubs();
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        startHost: false,
        ownServer: own.create,
      );
      await expectLater(
        codesIn(scope, 'lib/main.dart'),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            'the analysis host ended, or closed the connection, before it '
                'answered',
          ),
        ),
      );
      expect(own.created, 0);
      expect(startedHostProcesses(folder), isEmpty);
    });

    test('a client that starts no host: a host that tells it is ending before '
        'anything was answered is replaced by a server of its own, with a '
        'notice, and no host is started', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      final file = analysisHostAddressFile(folder, app);
      // The host is stopped by a newer session: it answers the question with
      // an ending and takes its address with it.
      await standIn(folder, app, (socket) {
        socket.writeln(jsonEncode(const AnalysisHostEnding(0).toJson()));
        File(file).deleteSync();
      });
      final own = _OwnStubs();
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        startHost: false,
        ownServer: own.create,
      );
      final reading = await scope((analysis) => analysis.read());
      expect(reading.analyzedFiles, ['own']);
      expect(reading.notices, [
        unusableHostNotice('it ended or was replaced before it answered'),
      ]);
      expect(own.created, 1);
      expect(own.stubs.single.closed, isTrue);
      expect(startedHostProcesses(folder), isEmpty);
      expect(File(file).existsSync(), isFalse);
    });

    test('a client that starts no host: a host that fails after it answered '
        'fails the run, and the run starts no host and uses no server of its '
        'own', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      final file = analysisHostAddressFile(folder, app);
      var questions = 0;
      await standIn(folder, app, (socket) {
        if (questions++ == 0) {
          socket
            ..writeln(jsonEncode(const AnalysisHostTurn(0).toJson()))
            ..writeln(
              jsonEncode(
                AnalysisHostAnswer.answered(
                  0,
                  const CodeReading().toJson(),
                ).toJson(),
              ),
            );
        } else {
          // It ends before the second question's turn, with its address.
          File(file).deleteSync();
          socket.destroy();
        }
      });
      final own = _OwnStubs();
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        startHost: false,
        ownServer: own.create,
      );
      await expectLater(
        scope((analysis) async {
          await analysis.read();
          return analysis.read();
        }),
        throwsA(
          isA<CodeAnalysisException>().having(
            (error) => error.reason,
            'reason',
            'the analysis host stopped answering during this run',
          ),
        ),
      );
      expect(own.created, 0);
      expect(startedHostProcesses(folder), isEmpty);
    });
  });

  // A terminal run (slice 1d.7, ticket 04): it uses a host that is there, and
  // never starts or stops one.
  group('a client that starts no host (a terminal run)', () {
    test('with no host it uses a server of its own, stops it at the end, and '
        'starts and writes no host', () async {
      final app = tempDir().path;
      final own = _OwnStubs();
      final (:scope, :folder) = testHost(
        app,
        startHost: false,
        ownServer: own.create,
      );
      final reading = await scope((analysis) => analysis.read());
      expect(reading.analyzedFiles, ['own']);
      expect(reading.notices, isEmpty);
      expect(own.created, 1);
      expect(own.stubs.single.closed, isTrue);
      expect(startedHostProcesses(folder), isEmpty);
      expect(
        readAnalysisHostAddress(analysisHostAddressFile(folder, app)),
        isNull,
      );
    });

    test('a host of its own version answers, and no server of its own is '
        'started', () async {
      final app = tempDir().path;
      final host = await inProcessHost(app);
      final own = _OwnStubs();
      final (:scope, :folder) = testHost(
        app,
        folder: host.folder,
        startHost: false,
        ownServer: own.create,
      );
      final reading = await scope((analysis) => analysis.read());
      expect(reading.analyzedFiles, ['lib/a.dart']);
      expect(host.server.asked, ['read']);
      expect(own.created, 0);
      expect(startedHostProcesses(folder), isEmpty);
    });

    for (final (clientVersion, hostVersion) in [
      ('1.0.0', '2.0.0'),
      ('2.0.0', '1.0.0'),
    ]) {
      test('a host of another version ($hostVersion, beside a client of '
          '$clientVersion) is left alone: the run uses a server of its own, '
          'sends no stop and says nothing of it', () async {
        final app = tempDir().path;
        final host = await inProcessHost(app, version: hostVersion);
        final own = _OwnStubs();
        final (:scope, :folder) = testHost(
          app,
          folder: host.folder,
          version: clientVersion,
          startHost: false,
          ownServer: own.create,
        );
        final reading = await scope((analysis) => analysis.read());
        expect(reading.analyzedFiles, ['own']);
        expect(reading.notices, isEmpty);
        expect(own.stubs.single.closed, isTrue);
        // The host was not asked anything, not stopped, and still answers
        // as the host of the project.
        expect(host.server.asked, isEmpty);
        expect(
          readAnalysisHostAddress(analysisHostAddressFile(folder, app))?.secret,
          host.address.secret,
        );
        // A stop would have ended it: it still welcomes a client.
        final raw = await rawClient(host.address);
        raw.socket.destroy();
        expect(startedHostProcesses(folder), isEmpty);
      });
    }

    test('an address whose host has ended is left as it was: the run uses a '
        'server of its own and starts no host', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      final file = analysisHostAddressFile(folder, app);
      await writeAnalysisHostAddress(
        file,
        AnalysisHostAddress(
          port: 1,
          secret: 'dead',
          processId: await endedProcess(),
          appsteinVersion: 'test',
        ),
      );
      final own = _OwnStubs();
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        startHost: false,
        ownServer: own.create,
      );
      final reading = await scope((analysis) => analysis.read());
      expect(reading.analyzedFiles, ['own']);
      // Quiet: the file stays, so a notice would print on every run.
      expect(reading.notices, isEmpty);
      expect(readAnalysisHostAddress(file)?.secret, 'dead');
      expect(startedHostProcesses(folder), isEmpty);
    });

    test('a host that won\'t take the connection within 5 s while its process '
        'runs counts as no host: a server of its own and a notice that says '
        'why; the address is left and no host is started', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      final file = analysisHostAddressFile(folder, app);
      // A live process: this test's own.
      await writeAnalysisHostAddress(
        file,
        AnalysisHostAddress(
          port: 1,
          secret: 'slow',
          processId: pid,
          appsteinVersion: 'test',
        ),
      );
      final own = _OwnStubs();
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        startHost: false,
        ownServer: own.create,
        // What `Socket.connect` throws when its timeout runs out.
        connect: (port) async => throw SocketException(
          'Connection timed out, host: 127.0.0.1, port: $port',
        ),
      );
      final reading = await scope((analysis) => analysis.read());
      expect(reading.analyzedFiles, ['own']);
      expect(reading.notices, [
        unusableHostNotice(
          'it did not take the connection (Connection timed out, host: '
          '127.0.0.1, port: 1)',
        ),
      ]);
      expect(readAnalysisHostAddress(file)?.secret, 'slow');
      expect(startedHostProcesses(folder), isEmpty);
    });

    test('a host that never welcomes the client counts as no host: a server '
        'of its own and a notice that says why; no host is started', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'hosts');
      // It takes the connection and says nothing.
      final listening = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(listening.close);
      final held = <Socket>[];
      listening.listen(held.add);
      addTearDown(() {
        for (final socket in held) {
          socket.destroy();
        }
      });
      await writeAnalysisHostAddress(
        analysisHostAddressFile(folder, app),
        AnalysisHostAddress(
          port: listening.port,
          secret: 'mute',
          processId: pid,
          appsteinVersion: 'test',
        ),
      );
      final own = _OwnStubs();
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        startHost: false,
        ownServer: own.create,
      );
      final reading = await scope((analysis) => analysis.read());
      expect(reading.analyzedFiles, ['own']);
      expect(reading.notices, [
        unusableHostNotice('it did not welcome the client'),
      ]);
      expect(startedHostProcesses(folder), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test(
      'an address file that may not be trusted counts as no host: a server '
      'of its own and a notice that says why, and the file is left as it is',
      () async {
        final app = tempDir().path;
        final folder = p.join(tempDir().path, 'hosts');
        final file = analysisHostAddressFile(folder, app);
        await writeAnalysisHostAddress(
          file,
          const AnalysisHostAddress(
            port: 1,
            secret: 'planted',
            processId: 1,
            appsteinVersion: 'test',
          ),
        );
        Process.runSync('chmod', ['755', folder]);
        final own = _OwnStubs();
        final (:scope, folder: _) = testHost(
          app,
          folder: folder,
          startHost: false,
          ownServer: own.create,
        );
        final reading = await scope((analysis) => analysis.read());
        expect(reading.analyzedFiles, ['own']);
        expect(reading.notices, hasLength(1));
        expect(
          reading.notices.single,
          allOf(
            contains('address file may not be trusted'),
            contains('mode 755, not 700'),
          ),
        );
        expect(readAnalysisHostAddress(file)?.secret, 'planted');
        expect(startedHostProcesses(folder), isEmpty);
      },
      skip: Platform.isWindows
          ? 'On Windows the folder is in %LOCALAPPDATA%, the user\'s own, and '
                'has no Unix mode'
          : false,
    );
  });
}

/// Stand-ins for the analysis server a client that starts no host uses beside
/// no host, or beside a host of another version: [create] is its
/// `ownServer`.
final class _OwnStubs {
  final stubs = <_OwnStub>[];

  int get created => stubs.length;

  StoppableCodeAnalysis create() {
    final stub = _OwnStub();
    stubs.add(stub);
    return stub;
  }
}

/// A stand-in for a run's own analysis server: it reads one file, `own`, and
/// notes that it was closed.
final class _OwnStub implements StoppableCodeAnalysis {
  var closed = false;

  @override
  Future<CodeReading> read() async => const CodeReading(analyzedFiles: ['own']);

  @override
  Future<bool> canDartFix(
    CodeDiagnostic diagnostic, {
    required Duration within,
  }) async => false;

  @override
  Future<FormatAnswers> formatChanges(
    List<String> files, {
    required Duration within,
  }) async => const FormatAnswers();

  @override
  Future<PendingFixes> pendingFixes({required Duration within}) async =>
      const PendingFixes();

  @override
  Future<AppliedChanges> applyFixesAndFormat({
    required Future<bool> Function(String file) leaveUnformatted,
    required Duration within,
  }) async => const AppliedChanges();

  @override
  Future<void> stop() async {}

  @override
  Future<void> close() async => closed = true;
}
