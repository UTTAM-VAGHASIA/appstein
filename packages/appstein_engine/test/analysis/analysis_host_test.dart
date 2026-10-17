import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
final class _StandInServer implements StoppableCodeAnalysis {
  _StandInServer(this._writes);

  final AnalysisHostWrites _writes;
  late final _write = _writes.gate((path, _) async => written.add(path));
  final readTimes = <Duration>[];
  final asked = <String>[];
  final written = <String>[];
  final applyHeld = Completer<void>();

  @override
  Future<CodeReading> read() async {
    asked.add('read');
    if (readTimes.isNotEmpty) {
      await Future<void>.delayed(readTimes.removeAt(0));
    }
    return const CodeReading(analyzedFiles: ['lib/a.dart']);
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
  Future<PendingFixes> pendingFixes({required Duration within}) async =>
      const PendingFixes();

  @override
  Future<void> stop() async {}

  @override
  Future<void> close() async {}
}

/// A host for the project [app] run in the test's own process, with a
/// [_StandInServer], an idle time of 2 s and an address-file folder of its
/// own. The test waits for it to end itself afterwards.
Future<({_StandInServer server, String folder, AnalysisHostAddress address})>
inProcessHost(String app) async {
  final folder = p.join(tempDir().path, 'hosts');
  late _StandInServer server;
  final done = runAnalysisHost(
    projectRoot: app,
    analysis: (writes) => server = _StandInServer(writes),
    addressFolder: folder,
    appsteinVersion: 'test',
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

/// A raw client of the host at [address], welcomed, whose lines come in
/// order through the iterator.
Future<({Socket socket, StreamIterator<String> lines})> rawClient(
  AnalysisHostAddress address,
) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    address.port,
  );
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
    'too (600); a client refuses a folder or file that is not',
    () async {
      final folder = p.join(tempDir().path, 'hosts');
      final file = analysisHostAddressFile(folder, '/work/my app');
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

      Process.runSync('chmod', ['644', file]);
      expect(await untrustedAddress(file), contains('mode 644, not 600'));
      Process.runSync('chmod', ['600', file]);
      Process.runSync('chmod', ['755', folder]);
      expect(await untrustedAddress(file), contains('mode 755, not 700'));

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
      // Connected, asking nothing: the host still ends, and the next
      // question of this client fails.
      expect(
        await goneWithin([host!, ...under], const Duration(seconds: 30)),
        isNotNull,
        reason: 'the idle host or what ran under it',
      );
      await expectLater(analysis.read(), throwsA(isA<CodeAnalysisException>()));
    });
    expect(hostProcess(folder, app), isNull, reason: 'its address file');

    writeProjectFile(app, 'lib/broken.dart', _right);
    expect(await codesIn(scope, 'lib/broken.dart'), isEmpty);
    expect(hostProcess(folder, app), isNot(host));
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

  test('a host that fails before it has an address leaves why, and the '
      "client's error says it", () async {
    final app = copyFixtureApp();
    final folder = p.join(tempDir().path, 'host folder');
    // A folder where the address file must go: the rename onto it fails.
    Directory(analysisHostAddressFile(folder, app)).createSync(recursive: true);
    final (:scope, folder: _) = testHost(app, folder: folder);
    await expectLater(
      codesIn(scope, 'lib/main.dart'),
      throwsA(
        isA<CodeAnalysisException>().having(
          (error) => error.reason,
          'reason',
          startsWith('the analysis host could not start: '),
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

  group('the queue of a host in this process, with a stand-in server', () {
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
  });
}
