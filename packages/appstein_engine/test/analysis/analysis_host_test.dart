import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:crypto/crypto.dart';
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

  group(
    'the folder of the address files, chosen from facts every process of the '
    'user shares and one look at the folders on the way',
    () {
      // The look at the disk is the test's own: nothing is read from the
      // real machine, so these run on every system. By default there is no
      // /run/user folder and every other folder can be trusted.
      HostEnvironment machine(
        HostOs os, {
        Map<String, String> variables = const {},
        String name = 'box',
        String machineId = '',
        int? userId = 1000,
        String? home = '/home/me',
      }) => fakeEnvironment(
        variables,
        os: os,
        machineName: name,
        machineId: machineId,
        userId: userId,
        userHome: home,
      );
      String? Function(List<String>, {bool mustExist}) noRun(
        void Function(List<String> chain)? saw,
      ) => (chain, {mustExist = false}) {
        saw?.call(chain);
        return mustExist ? '${chain.first} is not there' : null;
      };
      String folder(
        HostOs os, {
        Map<String, String> variables = const {},
        String name = 'box',
        String machineId = '',
        int? userId = 1000,
        String? home = '/home/me',
        CacheFolderCheck? trusted,
      }) => analysisHostFolder(
        machine(
          os,
          variables: variables,
          name: name,
          machineId: machineId,
          userId: userId,
          home: home,
        ),
        trustedCache: trusted ?? noRun(null),
      );
      // `box-<12 hex>` in the hosts folder of the home.
      final hosts = p.join('/home/me', '.cache', 'appstein', 'hosts');
      Matcher cacheFolderOf(String name) => matches(
        RegExp('^${RegExp.escape(p.join(hosts, name))}-[0-9a-f]{12}\$'),
      );
      final weird = {
        'HOME': '/elsewhere',
        'XDG_CACHE_HOME': '/elsewhere/cache',
        'XDG_RUNTIME_DIR': '/run/user/777',
        'TMPDIR': '/elsewhere/tmp',
      };

      test('the variable moves it, on every system', () {
        for (final os in HostOs.values) {
          expect(
            folder(
              os,
              variables: {analysisHostFolderVariable: '/given', ...weird},
            ),
            p.normalize(p.absolute('/given')),
            reason: '$os',
          );
        }
      });

      test('on Windows it is appstein in LOCALAPPDATA', () {
        expect(
          folder(HostOs.windows, variables: {'LOCALAPPDATA': '/local'}),
          p.join('/local', 'appstein'),
        );
      });

      test('on macOS it is appstein in XDG_RUNTIME_DIR when it is set, else '
          "appstein-<uid> in the user's temporary folder", () {
        expect(
          folder(HostOs.macos, variables: {'XDG_RUNTIME_DIR': '/run/me'}),
          p.join('/run/me', 'appstein'),
        );
        expect(
          folder(HostOs.macos, variables: {'HOME': '/home/me'}),
          p.join(Directory.systemTemp.path, 'appstein-1000'),
        );
      });

      test('on Linux it is appstein in /run/user/<uid> when that folder is '
          'there and can be trusted: the look is one for that folder, which '
          'must exist', () {
        final seen = <List<String>>[];
        expect(
          folder(
            HostOs.linux,
            trusted: (chain, {mustExist = false}) {
              seen.add([...chain, '$mustExist']);
              return null;
            },
          ),
          p.join('/run/user', '1000', 'appstein'),
        );
        expect(seen, [
          [p.join('/run/user', '1000'), 'true'],
        ]);
      });

      test('on Linux without it it is appstein/hosts/<machine folder name> '
          'in the .cache folder of the home the user database has, when the '
          'folders on the way can be trusted: the look is one for the home '
          'down to hosts', () {
        final seen = <List<String>>[];
        expect(
          folder(HostOs.linux, trusted: noRun(seen.add)),
          cacheFolderOf('box'),
        );
        expect(seen, [
          [p.join('/run/user', '1000')],
          [
            '/home/me',
            p.join('/home/me', '.cache'),
            p.join('/home/me', '.cache', 'appstein'),
            hosts,
          ],
        ]);
        expect(
          folder(HostOs.linux, home: '/srv/other'),
          startsWith(p.join('/srv/other', '.cache', 'appstein', 'hosts')),
        );
      });

      test('on Linux nothing in the environment changes the folder: HOME, '
          'XDG_CACHE_HOME, XDG_RUNTIME_DIR and TMPDIR are not read', () {
        for (final trusted in <CacheFolderCheck?>[
          null, // cache folder
          (chain, {mustExist = false}) => null, // /run/user
          (chain, {mustExist = false}) => 'a problem', // /tmp
        ]) {
          expect(
            folder(HostOs.linux, variables: weird, trusted: trusted),
            folder(HostOs.linux, trusted: trusted),
          );
        }
      });

      test('on Linux, where no folder of the user can be used, it is '
          'appstein-<uid> in /tmp itself, whatever TMPDIR says', () {
        final expected = p.join('/tmp', 'appstein-1000');
        expect(
          folder(
            HostOs.linux,
            variables: weird,
            trusted: (chain, {mustExist = false}) => 'a problem',
          ),
          expected,
        );
        expect(folder(HostOs.linux, home: ''), expected);
        // No user ID: the user's name, from USER.
        expect(
          folder(HostOs.linux, userId: -1, variables: {'USER': 'me'}),
          startsWith(p.join('/tmp', 'appstein-')),
        );
      });

      test('a machine folder name is the clean name, then 12 hex characters '
          'of a hash of the machine ID, else of the name', () {
        String named(String name, {String machineId = ''}) =>
            p.basename(folder(HostOs.linux, name: name, machineId: machineId));
        final hash = RegExp(r'-[0-9a-f]{12}$');
        expect(named('box'), matches(RegExp(r'^box-[0-9a-f]{12}$')));
        expect(named('My-Laptop.local'), startsWith('my-laptop.local-'));
        expect(named('My Laptop'), startsWith('my_laptop-'));
        expect(named(r'a/b\c'), startsWith('a_b_c-'));
        expect(named('..'), startsWith('_-'));
        expect(named('../etc'), startsWith('_etc-'));
        expect(named('.hidden'), startsWith('_hidden-'));
        expect(named('ü-box'), startsWith('_-box-'));
        expect(named(''), startsWith('unknown-'));
        expect(
          named('x' * 300),
          matches(RegExp('^${'x' * 60}-[0-9a-f]{12}\$')),
        );
        for (final name in ['a/b', '..', '../../tmp', r'..\x', 'a b', '']) {
          final made = named(name);
          expect(made, isNot(contains('/')), reason: name);
          expect(made, isNot(contains(r'\')), reason: name);
          expect(made, isNot(contains('..')), reason: name);
          expect(made, isNot(startsWith('.')), reason: name);
          expect(made, matches(hash), reason: name);
        }
      });

      test('machines that the clean name does not tell apart still get '
          'folders of their own, and one machine always the same', () {
        String named(String name, {String machineId = ''}) =>
            folder(HostOs.linux, name: name, machineId: machineId);
        const id = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
        const other = '0f1e2d3c4b5a69788796a5b4c3d2e1f0';
        // Two names that clean up to the same text.
        expect(named('a b'), isNot(named('a_b')));
        // Names that differ only in letter case (a home that ignores it).
        expect(named('Box'), isNot(named('box')));
        // The same name cut at 60 characters.
        expect(named('x' * 70), isNot(named('x' * 80)));
        // The same name on two machines that share a home over the network.
        expect(
          named('box', machineId: id),
          isNot(named('box', machineId: other)),
        );
        expect(named('box', machineId: id), isNot(named('box')));
        // The same machine: the same folder, with a machine ID or without.
        expect(named('box', machineId: id), named('box', machineId: id));
        expect(named('box'), named('box'));
        // A machine that is renamed keeps the hex (the machine ID's), so its
        // old folder can be found by it; names that clean up to the same text
        // are one folder on one machine.
        String hexOf(String folder) => p.basename(folder).split('-').last;
        expect(
          hexOf(named('before', machineId: id)),
          hexOf(named('after', machineId: id)),
        );
        expect(
          named('before', machineId: id),
          isNot(named('after', machineId: id)),
        );
        expect(named('a b', machineId: id), named('a_b', machineId: id));
        // With no machine ID the hex is the name's: a rename changes it.
        expect(hexOf(named('before')), isNot(hexOf(named('after'))));
        // And another home is another folder only by its path.
        expect(
          p.basename(folder(HostOs.linux, home: '/other')),
          p.basename(named('box')),
        );
      });

      test("with no machine name given, it is this machine's own", () {
        expect(
          analysisHostFolder(
            fakeEnvironment(
              const {},
              os: HostOs.linux,
              userId: 1000,
              userHome: '/home/me',
            ),
            trustedCache: noRun(null),
          ),
          analysisHostFolder(
            fakeEnvironment(
              const {},
              os: HostOs.linux,
              userId: 1000,
              userHome: '/home/me',
              machineName: Platform.localHostname,
            ),
            trustedCache: noRun(null),
          ),
        );
      });

      test('when the folders of the user are not used on Linux, the choice '
          'says why, for the client to tell the user', () {
        final chosen = chooseAnalysisHostFolder(
          machine(HostOs.linux),
          trustedCache: (chain, {mustExist = false}) =>
              mustExist ? 'no run folder' : '/home/me/.cache has mode 775',
        );
        expect(chosen.folder, p.join('/tmp', 'appstein-1000'));
        expect(
          chosen.cacheNote,
          allOf(
            contains(p.join(hosts, 'box-')),
            contains('was not used: /home/me/.cache has mode 775'),
          ),
        );
        expect(
          chooseAnalysisHostFolder(
            machine(HostOs.linux, home: ''),
            trustedCache: noRun(null),
          ).cacheNote,
          contains('no home folder is known'),
        );
        expect(
          chooseAnalysisHostFolder(
            machine(HostOs.linux, userId: -1),
            trustedCache: noRun(null),
          ).cacheNote,
          contains("ID can't be read"),
        );
        // Nothing to say where there was nothing to use instead, or the
        // folder is used.
        for (final chosen in [
          chooseAnalysisHostFolder(machine(HostOs.macos)),
          chooseAnalysisHostFolder(machine(HostOs.windows)),
          chooseAnalysisHostFolder(
            machine(HostOs.linux),
            trustedCache: (chain, {mustExist = false}) => null,
          ),
          chooseAnalysisHostFolder(
            machine(HostOs.linux),
            trustedCache: noRun(null),
          ),
        ]) {
          expect(chosen.cacheNote, isNull, reason: chosen.folder);
        }
      });
    },
  );

  test('the facts of the real machine are read as the system has them', () {
    final machine = HostEnvironment.current();
    expect(machine.machineName, isNotEmpty);
    expect(machine.machineId, matches(RegExp(r'^([0-9a-f]{32})?$')));
    final uid = int.parse('${Process.runSync('id', ['-u']).stdout}'.trim());
    expect(machine.userId, uid);
    // The user database's home, which is a folder (not `$HOME`).
    expect(machine.userHome, isNotNull);
    expect(Directory(machine.userHome!).existsSync(), isTrue);
    // What a test describes replaces what is read.
    final described = HostEnvironment(
      os: HostOs.linux,
      variables: const {'HOME': '/elsewhere'},
      workingDirectory: '/',
      machineName: 'n',
      machineId: 'i',
      userId: 42,
      userHome: '',
    );
    expect(
      (described.machineName, described.machineId, described.userId),
      ('n', 'i', 42),
    );
    expect(described.userHome, isNull);
  }, skip: Platform.isLinux ? false : 'The facts are read from Linux files');

  // The look at the folders on the way with a disk of the test's own (fake
  // paths and users), so it runs on every system; the same look on the real
  // disk is the next group.
  group('the folders on the way judged from the facts of a fake disk', () {
    const me = 1000;
    const privateGroup = 1000;
    CacheFolderFacts folder(
      int mode, {
      int owner = me,
      int group = privateGroup,
    }) => (isFolder: true, owner: owner, group: group, mode: mode);
    final root = folder(493, owner: 0); // 0755, root's

    /// What is wrong with the folders [chain] on a disk that has [disk]
    /// (posix paths) and nothing else, for user 1000; null when nothing is.
    String? problem(
      List<String> chain,
      Map<String, CacheFolderFacts> disk, {
      bool mustExist = false,
      int? group,
    }) => cacheFoldersProblem(
      chain,
      userId: me,
      privateGroup: group,
      mustExist: mustExist,
      look: (paths) => [
        for (final path in paths) disk[path.replaceAll(r'\', '/')],
      ],
    );

    /// The chain for the home [home]: the home, `.cache`, `appstein`, `hosts`.
    List<String> homeChain(String home) => [
      home,
      '$home/.cache',
      '$home/.cache/appstein',
      '$home/.cache/appstein/hosts',
    ];

    test("a user's own home at 700, 750 or 755 is fine, with the cache "
        'folders there or not', () {
      for (final mode in [448, 488, 493]) {
        final disk = {'/': root, '/home': root, '/home/me': folder(mode)};
        final chain = homeChain('/home/me');
        expect(problem(chain, disk), isNull, reason: mode.toRadixString(8));
        disk['/home/me/.cache'] = folder(493);
        expect(problem(chain, disk), isNull);
        disk['/home/me/.cache/appstein'] = folder(448);
        disk['/home/me/.cache/appstein/hosts'] = folder(448);
        expect(problem(chain, disk), isNull);
      }
    });

    test('the base, and every folder down to hosts that exists, is looked '
        'at: the home too, when the cache folder is under it', () {
      final chain = homeChain('/home/me');
      for (final mode in [511, 509, 495]) {
        final disk = {'/home/me': folder(mode), '/home/me/.cache': folder(448)};
        expect(
          problem(chain, disk),
          contains('/home/me has mode ${mode.toRadixString(8)}'),
          reason: 'home ${mode.toRadixString(8)}',
        );
      }
    });

    test('a home of / or of a folder that is not there is judged by the '
        "root of the disk, which is not the user's own", () {
      expect(
        problem(homeChain('/'), {'/': root}),
        contains('/ belongs to another user'),
        reason: 'HOME=/',
      );
      expect(
        problem(homeChain('/nonexistent'), {'/': root}),
        contains('/ belongs to another user'),
        reason: 'HOME=/nonexistent',
      );
      // But a folder of the user's own above the missing ones is fine, and
      // it alone is looked at.
      expect(
        problem(homeChain('/home/me/nobody/home'), {
          '/': root,
          '/home': root,
          '/home/me': folder(448),
        }),
        isNull,
      );
    });

    test('a base that must exist (/run/user/<uid>) and is not there is a '
        'problem, not a reason to look above it', () {
      expect(
        problem(
          ['/run/user/1000'],
          {'/': root, '/run/user': root},
          mustExist: true,
        ),
        contains('/run/user/1000 is not there'),
      );
      expect(
        problem(
          ['/run/user/1000'],
          {'/run/user/1000': folder(448)},
          mustExist: true,
        ),
        isNull,
      );
      expect(
        problem(
          ['/run/user/1000'],
          {'/run/user/1000': folder(448, owner: 1001)},
          mustExist: true,
        ),
        contains('belongs to another user'),
      );
    });

    test('a home others can write to is refused: /tmp (1777), 777, 775 and '
        "757, and so is a .cache they made or one that is another user's", () {
      for (final mode in [1023, 511, 509, 495]) {
        expect(
          problem(homeChain('/tmp'), {'/': root, '/tmp': folder(mode)}),
          isNotNull,
          reason: 'HOME=/tmp at ${mode.toRadixString(8)}',
        );
      }
      expect(
        problem(homeChain('/tmp'), {'/': root, '/tmp': folder(1023)}),
        allOf(contains('/tmp'), contains('other users can write')),
      );
      expect(
        problem(homeChain('/home/me'), {
          '/home/me': folder(448),
          '/home/me/.cache': folder(448, owner: 1001),
        }),
        contains('/home/me/.cache belongs to another user'),
        reason: 'a .cache another user made',
      );
      expect(
        problem(homeChain('/home/me'), {
          '/home/me': folder(448, owner: 0),
          '/home/me/.cache': folder(448, owner: 0),
        }),
        contains('belongs to another user'),
        reason:
            'root\'s folders: `sudo` that kept the user\'s HOME, or a '
            'process of root with the folders the user made',
      );
    });

    test('an appstein or hosts folder that exists must also be the '
        "user's own and not writable by the group or the world", () {
      final home = {'/home/me': folder(448), '/home/me/.cache': folder(448)};
      final chain = homeChain('/home/me');
      for (final mode in [495, 509, 511]) {
        expect(
          problem(chain, {...home, '/home/me/.cache/appstein': folder(mode)}),
          contains('/home/me/.cache/appstein has mode'),
          reason: 'appstein ${mode.toRadixString(8)}',
        );
        expect(
          problem(chain, {
            ...home,
            '/home/me/.cache/appstein': folder(448),
            '/home/me/.cache/appstein/hosts': folder(mode),
          }),
          contains('/home/me/.cache/appstein/hosts has mode'),
          reason: 'hosts ${mode.toRadixString(8)}',
        );
      }
      // Group-writable: the group's message.
      expect(
        problem(chain, {...home, '/home/me/.cache/appstein': folder(509)}),
        contains('others in its group can write to it'),
      );
      // A group-writable appstein above a hosts folder that is fine: the
      // group could still rename hosts away.
      expect(
        problem(chain, {
          ...home,
          '/home/me/.cache/appstein': folder(509),
          '/home/me/.cache/appstein/hosts': folder(448),
        }),
        isNotNull,
      );
    });

    test("a folder the group can write to (775) is fine when the group is the "
        "user's private group (Ubuntu's umask of 002 makes ~/.cache so), and "
        'not when it is shared; the world can never write', () {
      final chain = homeChain('/home/me');
      final home = {'/home/me': folder(493), '/home/me/.cache': folder(509)};
      expect(problem(chain, home, group: privateGroup), isNull);
      expect(
        problem(chain, home),
        contains('/home/me/.cache has mode 775, so others in its group'),
        reason: 'no private group',
      );
      expect(
        problem(chain, {
          ...home,
          '/home/me/.cache': folder(509, group: 100),
        }, group: privateGroup),
        contains('others in its group can write to it'),
        reason: 'a group that is not the private one',
      );
      expect(
        problem(chain, {
          ...home,
          '/home/me/.cache': folder(507),
        }, group: privateGroup),
        contains('other users can write to it'),
        reason: '777 even in the private group',
      );
      expect(
        problem(chain, {
          ...home,
          '/home/me/.cache/appstein': folder(509),
          '/home/me/.cache/appstein/hosts': folder(509),
        }, group: privateGroup),
        isNull,
      );
    });

    test('nothing above the base is looked at, as ssh trusts the folders '
        'above a home', () {
      expect(
        problem(homeChain('/data/me'), {
          '/data': folder(511, owner: 0),
          '/data/me': folder(448),
        }),
        isNull,
      );
    });

    test('something that is not a folder, a user that is not known, or '
        'what can not be looked at is not trusted', () {
      expect(
        problem(homeChain('/home/me'), {
          '/home/me': folder(448),
          '/home/me/.cache': (
            isFolder: false,
            owner: me,
            group: 1000,
            mode: 420,
          ),
        }),
        contains('/home/me/.cache is not a folder'),
      );
      expect(
        cacheFoldersProblem(
          homeChain('/home/me'),
          userId: me,
          look: (_) => throw const FileSystemException('no access'),
        ),
        contains("can't be looked at"),
      );
      expect(
        cacheFoldersProblem(
          homeChain('/home/me'),
          userId: me,
          look: (_) => const [],
        ),
        contains("can't be looked at"),
      );
      expect(
        cacheFoldersProblem(homeChain('/home/me'), userId: null),
        contains("ID can't be read"),
      );
    });
  });

  // The look at the folders on the way, on the real disk (a Linux user's home
  // and its `.cache`).
  group(
    'off Windows the folders of the home are used only when the user can '
    'trust them',
    () {
      final uid = Platform.isWindows
          ? ''
          : '${Process.runSync('id', ['-u']).stdout}'.trim();
      // As root, `stat` says a folder is root's whoever made it, and every
      // folder is the user's own, so a folder of another user can't be told
      // from one's own.
      final root = uid == '0';

      Directory made(String path, String mode) {
        final folder = Directory(path)..createSync(recursive: true);
        Process.runSync('chmod', [mode, folder.path]);
        return folder;
      }

      /// A Linux user, as the system knows them, whose home is [home]; there is
      /// no /run/user folder (the root of those is a folder that is not there).
      /// The user has no private group unless [privateGroup] says (the
      /// runner's own passwd and group files must not decide these).
      String chosen(String home, {int privateGroup = -1}) => analysisHostFolder(
        fakeEnvironment(
          const {},
          os: HostOs.linux,
          machineName: 'box',
          userHome: home,
          privateGroupId: privateGroup,
          runUserRoot: '/no such run folder',
        ),
      );

      /// The name of the machine's folder, as every choice makes it.
      final name = p.basename(
        analysisHostFolder(
          fakeEnvironment(
            const {},
            os: HostOs.linux,
            machineName: 'box',
            userId: 1,
            userHome: '/h',
          ),
          trustedCache: (chain, {mustExist = false}) =>
              mustExist ? 'none' : null,
        ),
      );
      String cacheOf(String home) =>
          p.join(home, '.cache', 'appstein', 'hosts', name);
      final temporary = p.join('/tmp', 'appstein-$uid');

      for (final mode in ['700', '750', '755']) {
        test('a home at $mode that has no cache folder yet gives the cache '
            'folder', () {
          final home = made(p.join(tempDir().path, 'home'), mode).path;
          expect(chosen(home), cacheOf(home));
        });
      }

      test('a home others can write to (777, or 1777 like /tmp) and no '
          '~/.cache in it gives /tmp; so does a ~/.cache they can write '
          'to', () {
        for (final mode in ['777', '1777', '775', '757']) {
          final home = made(p.join(tempDir().path, 'home $mode'), mode).path;
          expect(chosen(home), temporary, reason: 'home $mode');
        }
        final home = made(p.join(tempDir().path, 'home'), '700').path;
        made(p.join(home, '.cache'), '770');
        expect(chosen(home), temporary, reason: '.cache 770');
        Process.runSync('chmod', ['755', p.join(home, '.cache')]);
        expect(chosen(home), cacheOf(home));
      });

      test('an appstein or hosts folder that is there already must not be '
          'writable by others (757, 775): /tmp otherwise', () {
        final home = made(p.join(tempDir().path, 'home'), '700').path;
        final appstein = made(p.join(home, '.cache', 'appstein'), '700');
        expect(chosen(home), cacheOf(home));
        for (final mode in ['757', '775', '777']) {
          Process.runSync('chmod', [mode, appstein.path]);
          expect(chosen(home), temporary, reason: 'appstein $mode');
        }
        Process.runSync('chmod', ['700', appstein.path]);
        final hosts = made(p.join(appstein.path, 'hosts'), '700');
        expect(chosen(home), cacheOf(home));
        for (final mode in ['757', '775']) {
          Process.runSync('chmod', [mode, hosts.path]);
          expect(chosen(home), temporary, reason: 'hosts $mode');
        }
        // Even with every folder under them fine: a group-writable
        // appstein lets another user swap hosts.
        Process.runSync('chmod', ['700', hosts.path]);
        Process.runSync('chmod', ['775', appstein.path]);
        expect(chosen(home), temporary, reason: 'appstein 775, hosts 700');
      });

      test('a home that does not exist is judged by the deepest folder that '
          "does: one of the user's own is fine, the root of the disk is not "
          '(HOME=/nonexistent, as Debian service users have)', () {
        final own = made(p.join(tempDir().path, 'own'), '700').path;
        final gone = p.join(own, 'nobody', 'home');
        expect(chosen(gone), cacheOf(gone));
        if (!root) {
          expect(chosen('/'), temporary);
          expect(chosen('/nonexistent-appstein-home'), temporary);
        }
      });

      test('a link on the way is followed: ~/.cache linked to a folder of '
          "the user's own is fine, one linked to a folder others can write "
          'to, or to nothing, or to a file, is not', () {
        final home = made(p.join(tempDir().path, 'home'), '700').path;
        final own = made(p.join(tempDir().path, 'elsewhere'), '700').path;
        final link = Link(p.join(home, '.cache'))..createSync(own);
        expect(chosen(home), cacheOf(home));
        link.deleteSync();
        final open = made(p.join(tempDir().path, 'open'), '777').path;
        link.createSync(open);
        expect(chosen(home), temporary, reason: 'to a folder others write to');
        link.deleteSync();
        link.createSync(p.join(tempDir().path, 'nothing'));
        expect(chosen(home), temporary, reason: 'dangling');
        link.deleteSync();
        final file = File(p.join(tempDir().path, 'file'))..createSync();
        link.createSync(file.path);
        expect(chosen(home), temporary, reason: 'to a file');
      });

      test('a file where a cache folder should be is not used', () {
        final home = made(p.join(tempDir().path, 'home'), '700').path;
        File(p.join(home, '.cache')).createSync();
        expect(chosen(home), temporary);
      });

      test("a ~/.cache the group can write to (775, as Ubuntu's umask of 002 "
          "makes it) is used when its group is the user's private group, and "
          'not when the group is shared', () {
        final gid = int.parse('${Process.runSync('id', ['-g']).stdout}'.trim());
        final home = made(p.join(tempDir().path, 'home'), '755').path;
        made(p.join(home, '.cache'), '775');
        expect(chosen(home, privateGroup: gid), cacheOf(home));
        expect(chosen(home), temporary, reason: 'a shared group');
        expect(
          chosen(home, privateGroup: gid + 1),
          temporary,
          reason: "a group that is not the folder's",
        );
        // 777 is never accepted.
        Process.runSync('chmod', ['777', p.join(home, '.cache')]);
        expect(chosen(home, privateGroup: gid), temporary);
      });

      test('with one `stat` for the folders that are there, and the user ID '
          'read without a process', () {
        // The same answers as above, from the real look, with its cost: the
        // look for a home with every folder there is one process.
        final home = made(p.join(tempDir().path, 'home'), '700').path;
        made(p.join(home, '.cache', 'appstein', 'hosts', name), '700');
        final watch = Stopwatch()..start();
        for (var i = 0; i < 20; i++) {
          expect(chosen(home), cacheOf(home));
        }
        // Printed for the report: the time of one choice.
        // ignore: avoid_print
        print('a folder choice takes ${watch.elapsedMicroseconds ~/ 20} us');
      });
    },
    // The rule is Linux's: macOS's `stat` has no `-c` and its home is chosen
    // differently.
    skip: Platform.isLinux
        ? false
        : 'The folders of a home are looked at on Linux only (GNU `stat`)',
  );

  test(
    'off Windows the host makes the folders that are missing on the way with '
    'mode 700, and leaves one that is there as it is',
    () async {
      final base = Directory(p.join(tempDir().path, 'cache'))..createSync();
      Process.runSync('chmod', ['755', base.path]);
      final folder = p.join(base.path, 'appstein', 'hosts', 'box');
      await writeAnalysisHostAddress(
        analysisHostAddressFile(folder, '/work/my app'),
        const AnalysisHostAddress(
          port: 1,
          secret: 's',
          processId: 1,
          appsteinVersion: 'test',
        ),
      );
      String mode(String path) =>
          (FileStat.statSync(path).mode & 0xFFF).toRadixString(8);
      expect(mode(base.path), '755', reason: 'there already: left as it is');
      for (final made in [
        p.join(base.path, 'appstein'),
        p.join(base.path, 'appstein', 'hosts'),
        folder,
      ]) {
        expect(mode(made), '700', reason: made);
      }
    },
    skip: Platform.isWindows
        ? 'On Windows the folder is in %LOCALAPPDATA%, the user\'s own, and '
              'has no Unix mode'
        : false,
  );

  test(
    'off Windows the folder chosen before a host starts is the one chosen '
    'after it did, every folder it made is 700, also when the host runs '
    'under a umask of 002 (which would leave them 775)',
    () async {
      final home = tempDir().path;
      Process.runSync('chmod', ['700', home]);
      // The user's own facts, except a home and no /run/user folder of the
      // real machine's.
      final environment = fakeEnvironment(
        const {},
        os: HostOs.linux,
        machineName: 'box',
        userHome: home,
        privateGroupId: -1,
        runUserRoot: '/no such run folder',
      );
      final before = analysisHostFolder(environment);
      expect(p.dirname(before), p.join(home, '.cache', 'appstein', 'hosts'));
      expect(Directory(p.join(home, '.cache')).existsSync(), isFalse);
      final app = copyFixtureApp();
      // The host notes itself beside the folder it must make, so the note
      // is kept elsewhere.
      final started = p.join(tempDir().path, 'started');
      final (:scope, folder: _) = testHost(
        app,
        folder: before,
        started: started,
        hostCommand: [
          'sh',
          '-c',
          'umask 002; exec "\$@"',
          'sh',
          Platform.resolvedExecutable,
          analysisSupportFile('host_main.dart'),
          before,
          testDart,
          '${const Duration(minutes: 10).inMilliseconds}',
          'test',
          started,
        ],
      );
      expect(await codesIn(scope, 'lib/main.dart'), isEmpty);
      expect(hostProcess(before, app), isNotNull);
      expect(analysisHostFolder(environment), before, reason: 'it flipped');
      for (final made in [
        p.join(home, '.cache'),
        p.join(home, '.cache', 'appstein'),
        p.join(home, '.cache', 'appstein', 'hosts'),
        before,
      ]) {
        expect(
          (FileStat.statSync(made).mode & 0xFFF).toRadixString(8),
          '700',
          reason: made,
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    // The rule, and the folders made 700, are Linux's.
    skip: Platform.isLinux
        ? false
        : 'The folder under the home is chosen on Linux only',
  );

  test('a client whose folder is refused is answered by a server of its own, '
      'with a notice that says why: the reason, and why the user\'s own '
      'folders were not used', () async {
    final folder = p.join(tempDir().path, 'host folder');
    const note =
        'the folder /home/u/.cache/appstein/hosts/box was not '
        'used: /home/u/.cache has mode 775, so others in its group can '
        'write to it';
    // A folder that is a link: refused before anything is read.
    final mine = Directory(p.join(tempDir().path, 'my own'))..createSync();
    Link(folder).createSync(mine.path);
    final app = tempDir().path;
    final own = _OwnStubs();
    final (:scope, folder: _) = testHost(
      app,
      folder: folder,
      folderNote: note,
      ownServer: own.create,
    );
    final reading = await scope((analysis) => analysis.read());
    expect(reading.analyzedFiles, ['own']);
    expect(
      reading.notices.single,
      allOf(contains('is not a plain folder'), contains('; $note)')),
    );
    expect(startedHostProcesses(folder), isEmpty, reason: 'no host started');
    expect(own.created, 1);
    // The same client with no note says nothing more.
    final plain = _OwnStubs();
    final (scope: second, folder: _) = testHost(
      app,
      folder: folder,
      ownServer: plain.create,
    );
    final other = await second((analysis) => analysis.read());
    expect(other.notices.single, isNot(contains('was not used')));
  }, skip: Platform.isWindows ? 'The link check is off Windows only' : false);

  test(
    'off Windows a link in a parent of the folder is fine (a user with '
    '~/.cache linked elsewhere): only the folder itself must be no link',
    () async {
      final elsewhere = Directory(p.join(tempDir().path, 'elsewhere'))
        ..createSync();
      final home = tempDir().path;
      Link(p.join(home, '.cache')).createSync(elsewhere.path);
      final folder = p.join(home, '.cache', 'appstein', 'hosts', 'box');
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
      expect(readAnalysisHostAddress(file)?.secret, 's');
      expect(await untrustedAddress(file), isNull);
      expect(await untrustedAddress(file, strict: true), isNull);
      expect(await untrustedAddressFolder(folder), isNull);
      expect((FileStat.statSync(folder).mode & 0x1FF).toRadixString(8), '700');
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
    "the client is answered by its own server, whose notice names the "
    'folder instead',
    () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'host folder');
      final own = _OwnStubs();
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        ownServer: own.create,
        hostCommand: [
          Platform.resolvedExecutable,
          analysisSupportFile('failing_host_main.dart'),
          folder,
          '755',
          'the analysis host could not start: planted',
        ],
      );
      final reading = await scope((analysis) => analysis.read());
      expect(reading.analyzedFiles, ['own']);
      expect(
        reading.notices.single,
        allOf(
          contains('the analysis host could not start: the folder '),
          contains('mode 755, not 700'),
          isNot(contains('planted')),
        ),
      );
      expect(own.created, 1);
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

  group('a host that follows its folder, keeps its file young and sweeps '
      'old folders (a stand-in server in this process)', () {
    /// Waits until [done] is true.
    Future<void> until(bool Function() done, String reason) async {
      for (var i = 0; i < 500 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(done(), isTrue, reason: reason);
    }

    /// A host for [app] in [folder] in this process, whose housekeeping runs
    /// every [tick]. [folderNow] makes it follow its folder. After the test
    /// it is asked to stop, wherever its address is among [folders].
    Future<({_StandInServer server, Future<void> done})> start(
      String app,
      String folder, {
      String Function({bool fresh})? folderNow,
      Duration tick = const Duration(milliseconds: 100),
      Duration beat = const Duration(hours: 1),
      Duration sweepAge = const Duration(days: 7),
      Duration idle = const Duration(seconds: 30),
      List<String> folders = const [],
    }) async {
      late _StandInServer server;
      final done = runAnalysisHost(
        projectRoot: app,
        analysis: (writes) => server = _StandInServer(writes),
        addressFolder: folder,
        appsteinVersion: 'test',
        idleStop: idle,
        folderNow: folderNow,
        maintenanceEvery: tick,
        heartbeatEvery: beat,
        sweepAge: sweepAge,
      );
      addTearDown(() async {
        for (final where in [folder, ...folders]) {
          final address = readAnalysisHostAddress(
            analysisHostAddressFile(where, app),
          );
          if (address == null || address.processId != pid) continue;
          final client = await rawClient(address);
          client.socket.writeln(jsonEncode(const AnalysisHostStop().toJson()));
          await client.lines.moveNext();
          client.socket.destroy();
        }
        await done.timeout(const Duration(seconds: 20));
      });
      final file = analysisHostAddressFile(folder, app);
      await until(() => readAnalysisHostAddress(file) != null, 'no address');
      return (server: server, done: done);
    }

    AnalysisHostAddress? addressIn(String folder, String app) =>
        readAnalysisHostAddress(analysisHostAddressFile(folder, app));

    test('a host whose address file was deleted writes it back, with the '
        'same secret and port, and does not need to be asked', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'appstein', 'hosts', 'box');
      await start(app, folder, folderNow: ({fresh = false}) => folder);
      final first = addressIn(folder, app)!;
      File(analysisHostAddressFile(folder, app)).deleteSync();
      await until(() => addressIn(folder, app) != null, 'not written back');
      expect(addressIn(folder, app)!.secret, first.secret);
      expect(addressIn(folder, app)!.port, first.port);
    });

    test('a host whose folder name changes (the machine was renamed) moves '
        'its address there, and the next client gets the same host: no '
        'second host is started', () async {
      final app = tempDir().path;
      final hosts = p.join(tempDir().path, 'appstein', 'hosts');
      final before = p.join(hosts, 'before');
      final after = p.join(hosts, 'after');
      var now = before;
      final (:server, done: _) = await start(
        app,
        before,
        folderNow: ({fresh = false}) => now,
        folders: [after],
      );
      final first = addressIn(before, app)!;
      now = after;
      await until(() => addressIn(after, app) != null, 'not moved');
      expect(addressIn(after, app)!.secret, first.secret);
      expect(addressIn(after, app)!.port, first.port);
      await until(() => addressIn(before, app) == null, 'the old file stays');
      // The next client, which now looks in the new folder, is answered by
      // this host: it starts none.
      final (:scope, folder: _) = testHost(app, folder: after);
      expect(await codesIn(scope, 'lib/a.dart'), isEmpty);
      expect(server.asked, ['read']);
      expect(startedHostProcesses(after), isEmpty);
    });

    test('a host whose folder disappears (the system removes /run/user/<uid> '
        'when the last session ends) moves to the folder chosen then, and '
        'the new choice is looked at afresh only then', () async {
      final app = tempDir().path;
      final run = p.join(tempDir().path, 'run');
      final gone = p.join(run, 'appstein');
      final next = p.join(tempDir().path, 'appstein', 'hosts', 'box');
      var looks = 0;
      // As the real memo: the answer of the last look is kept.
      var answer = gone;
      await start(
        app,
        gone,
        folderNow: ({fresh = false}) {
          if (fresh) {
            looks++;
            answer = next;
          }
          return answer;
        },
        folders: [next],
      );
      final first = addressIn(gone, app)!;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(looks, 0, reason: 'a normal round makes no new look');
      Directory(run).deleteSync(recursive: true);
      await until(() => addressIn(next, app) != null, 'not moved');
      expect(addressIn(next, app)!.secret, first.secret);
      expect(Directory(run).existsSync(), isFalse, reason: 'made again');
      // Many rounds later, on a slow runner too: still the one look.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(looks, 1);
    });

    test("a host that finds another host's address in the folder chosen now "
        'gives its own up and ends after the question it is answering, never '
        'in the middle of one (a rewrite under way is not cut off)', () async {
      final app = tempDir().path;
      final hosts = p.join(tempDir().path, 'appstein', 'hosts');
      final before = p.join(hosts, 'before');
      final after = p.join(hosts, 'after');
      var now = before;
      final (:server, :done) = await start(
        app,
        before,
        folderNow: ({fresh = false}) => now,
      );
      // A question under way: a reading that takes a while.
      server.readTimes.add(const Duration(seconds: 2));
      final address = addressIn(before, app)!;
      final busy = await rawClient(address);
      addTearDown(busy.socket.destroy);
      send(
        busy.socket,
        const AnalysisHostQuestion(id: 0, kind: AnalysisHostQuestionKind.read),
      );
      expect(AnalysisHostTurn.isTurn(await nextLine(busy.lines)), isTrue);
      await writeAnalysisHostAddress(
        analysisHostAddressFile(after, app),
        const AnalysisHostAddress(
          port: 1,
          secret: 'another host',
          processId: 1,
          appsteinVersion: 'test',
        ),
      );
      now = after;
      // Its own file is given up at once, and the other's is left.
      await until(() => addressIn(before, app) == null, 'the file stays');
      var ended = false;
      unawaited(done.then((_) => ended = true));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(ended, isFalse, reason: 'it ended during a question');
      // The question is answered, and then the host ends.
      expect(
        AnalysisHostAnswer.fromJson(await nextLine(busy.lines)).value,
        isNotNull,
      );
      await done.timeout(const Duration(seconds: 10));
      expect(addressIn(after, app)!.secret, 'another host');
    });

    test('a host that finds nothing in the folder chosen now but its own '
        'file ends nothing: the heartbeat looks afresh (a home that became '
        'unsafe is noticed) and finds the folder the same', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'appstein', 'hosts', 'box');
      var looks = 0;
      await start(
        app,
        folder,
        beat: const Duration(milliseconds: 300),
        folderNow: ({fresh = false}) {
          if (fresh) looks++;
          return folder;
        },
      );
      final first = addressIn(folder, app)!;
      await until(() => looks >= 2, 'no new look at the beat');
      expect(addressIn(folder, app)!.secret, first.secret);
    });

    test('a host that is told by a fresh look that its home became unsafe '
        '(the choice now is /tmp) moves there at the next beat', () async {
      final app = tempDir().path;
      final hosts = p.join(tempDir().path, 'appstein', 'hosts');
      final cache = p.join(hosts, 'box');
      final tmp = p.join(tempDir().path, 'appstein-1000');
      var unsafe = false;
      await start(
        app,
        cache,
        beat: const Duration(milliseconds: 300),
        folderNow: ({fresh = false}) => fresh && unsafe ? tmp : cache,
        folders: [tmp],
      );
      final first = addressIn(cache, app)!;
      unsafe = true;
      await until(() => addressIn(tmp, app) != null, 'not moved');
      expect(addressIn(tmp, app)!.secret, first.secret);
      await until(() => addressIn(cache, app) == null, 'the old file stays');
    });

    test(
      "a host sets its file's modified time to now every heartbeat",
      () async {
        final app = tempDir().path;
        final folder = p.join(tempDir().path, 'appstein', 'hosts', 'box');
        await start(
          app,
          folder,
          beat: const Duration(milliseconds: 300),
          folderNow: ({fresh = false}) => folder,
        );
        final file = File(analysisHostAddressFile(folder, app));
        final old = DateTime.now().subtract(const Duration(hours: 1));
        file.setLastModifiedSync(old);
        await until(
          () => file.lastModifiedSync().isAfter(
            DateTime.now().subtract(const Duration(minutes: 1)),
          ),
          'the file stays old',
        );
      },
    );

    test("a host does not touch a file that holds another host's address, "
        'whatever its heartbeat', () async {
      final app = tempDir().path;
      final folder = p.join(tempDir().path, 'appstein', 'hosts', 'box');
      // A host that does not follow its folder: it neither rewrites the file
      // nor ends, so the file is what the test makes it.
      await start(
        app,
        folder,
        beat: const Duration(milliseconds: 100),
        idle: const Duration(seconds: 3),
      );
      final file = File(analysisHostAddressFile(folder, app));
      file.deleteSync();
      await writeAnalysisHostAddress(
        file.path,
        const AnalysisHostAddress(
          port: 1,
          secret: 'another host',
          processId: 1,
          appsteinVersion: 'test',
        ),
      );
      final old = DateTime.now().subtract(const Duration(hours: 1));
      file.setLastModifiedSync(old);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(
        file.lastModifiedSync().isBefore(
          DateTime.now().subtract(const Duration(minutes: 30)),
        ),
        isTrue,
      );
    });

    test('a host that was not told to follow its folder keeps to it: a '
        'deleted file stays deleted, and nothing is swept', () async {
      final app = tempDir().path;
      final hosts = p.join(tempDir().path, 'appstein', 'hosts');
      final folder = p.join(hosts, 'box');
      final other = Directory(p.join(hosts, 'other'))
        ..createSync(recursive: true);
      File(p.join(other.path, 'a')).writeAsStringSync('old');
      _ageAll(other.path);
      // It ends itself once its file is gone and nobody asks.
      await start(app, folder, idle: const Duration(seconds: 2));
      File(analysisHostAddressFile(folder, app)).deleteSync();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(addressIn(folder, app), isNull);
      expect(other.existsSync(), isTrue);
    });

    test('a host sweeps, when it starts, the folders in hosts that nothing '
        'has touched for a time: an old one goes, a new one stays, and so '
        'does one with a new file, a link (not followed), a folder with a '
        'link in it, and a folder that is not 700', () async {
      final app = tempDir().path;
      final hosts = p.join(tempDir().path, 'appstein', 'hosts');
      Directory(hosts).createSync(recursive: true);
      Directory made(String name, {Map<String, String> files = const {}}) {
        final folder = Directory(p.join(hosts, name))..createSync();
        for (final MapEntry(:key, :value) in files.entries) {
          File(p.join(folder.path, key)).writeAsStringSync(value);
        }
        if (!Platform.isWindows) Process.runSync('chmod', ['700', folder.path]);
        return folder;
      }

      final outside = Directory(p.join(tempDir().path, 'outside'))
        ..createSync();
      File(p.join(outside.path, 'keep')).writeAsStringSync('old');
      _ageAll(outside.path);
      final gone = made('old', files: {'host.json': '{}', 'host.lock': '1'});
      final mixed = made('mixed', files: {'host.json': '{}'});
      final linked = made('has link', files: {'host.json': '{}'});
      final open = made('open', files: {'host.json': '{}'});
      if (!Platform.isWindows) {
        Link(p.join(linked.path, 'out')).createSync(outside.path);
        Link(p.join(hosts, 'linked')).createSync(outside.path);
        Process.runSync('chmod', ['755', open.path]);
      }
      // Everything so far is a month old, but one file in `mixed`, a new
      // one, and a folder that is new.
      for (final old in [gone, mixed, linked, open]) {
        _ageAll(old.path);
      }
      File(p.join(mixed.path, 'new')).writeAsStringSync('new');
      final young = made('fresh', files: {'host.json': '{}'});
      final folder = p.join(hosts, 'box');
      await start(app, folder, folderNow: ({fresh = false}) => folder);
      await until(() => !gone.existsSync(), 'the old folder was not swept');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(young.existsSync(), isTrue);
      expect(mixed.existsSync(), isTrue);
      expect(File(p.join(mixed.path, 'new')).existsSync(), isTrue);
      expect(Directory(folder).existsSync(), isTrue, reason: 'its own');
      expect(File(p.join(outside.path, 'keep')).existsSync(), isTrue);
      if (!Platform.isWindows) {
        expect(linked.existsSync(), isTrue, reason: 'a folder with a link');
        expect(Link(p.join(hosts, 'linked')).existsSync(), isTrue);
        expect(open.existsSync(), isTrue, reason: 'not 700');
      }
    });

    test('a folder that is written to after the sweep renamed it (its host '
        'wrote again) is renamed back, not deleted', () async {
      final hosts = p.join(tempDir().path, 'appstein', 'hosts');
      Directory(hosts).createSync(recursive: true);
      final old = Directory(p.join(hosts, 'old'))..createSync();
      File(p.join(old.path, 'host.json')).writeAsStringSync('{}');
      if (!Platform.isWindows) Process.runSync('chmod', ['700', old.path]);
      _ageAll(old.path);
      final removed = await sweepStaleHostFolders(
        hosts,
        keep: p.join(hosts, 'box'),
        olderThan: const Duration(days: 7),
        afterRename: (moved) async {
          // Not the old name any more: nobody finds the folder there while
          // it is looked at again.
          expect(Directory(p.join(hosts, 'old')).existsSync(), isFalse);
          File(p.join(moved, 'host.json')).writeAsStringSync('new');
        },
      );
      expect(removed, isEmpty);
      expect(Directory(p.join(hosts, 'old')).existsSync(), isTrue);
      expect(File(p.join(old.path, 'host.json')).readAsStringSync(), 'new');
      expect(
        [
          for (final entry in Directory(hosts).listSync())
            p.basename(entry.path),
        ],
        ['old'],
        reason: 'no folder of the sweep is left',
      );
      // And with nothing written, the folder goes.
      _ageAll(old.path);
      expect(
        await sweepStaleHostFolders(
          hosts,
          keep: p.join(hosts, 'box'),
          olderThan: const Duration(days: 7),
        ),
        [p.join(hosts, 'old')],
      );
      expect(Directory(hosts).listSync(), isEmpty);
    });

    test('the folder is looked at afresh only when what it is chosen from '
        'changes or when asked, so a round starts no process', () {
      var looks = 0;
      final environment = fakeEnvironment(
        const {},
        os: HostOs.linux,
        machineName: 'box',
        userId: 1000,
        userHome: '/home/me',
        runUserRoot: '/no such run folder',
      );
      final now = analysisHostFolderNow(
        environment,
        trustedCache: (chain, {mustExist = false}) {
          looks++;
          return mustExist ? 'no run folder' : null;
        },
      );
      final first = now();
      final looked = looks;
      expect(looked, greaterThan(0));
      for (var i = 0; i < 5; i++) {
        expect(now(), first);
      }
      expect(looks, looked, reason: 'a round that changed nothing');
      expect(now(fresh: true), first);
      expect(looks, looked * 2, reason: 'asked to look again');
    });
  });

  group('the facts of the machine, read once', () {
    const passwd =
        'root:x:0:0:root:/root:/bin/bash\n'
        'me:x:1000:1000:Me:/home/me:/bin/bash\n'
        'other:x:1001:1001::/home/other:/bin/sh\n'
        'rel:x:1002:1002::relative/home:/bin/sh\n';
    const status =
        'Name:\tdart\nUid:\t1000\t1001\t1000\t1000\nGid:\t1\t1\t1\t1\n';

    /// Facts read from [files] (none is read from the real machine), with the
    /// reads and the runs counted.
    ({MachineFacts facts, List<String> reads, List<String> runs}) described(
      Map<String, String> files, {
      Map<String, ProcessResult> results = const {},
    }) {
      final reads = <String>[];
      final runs = <String>[];
      return (
        facts: MachineFacts(
          readFile: (path) {
            reads.add(path);
            return files[path];
          },
          run: (program, arguments) {
            runs.add('$program ${arguments.join(' ')}');
            return results['$program ${arguments.join(' ')}'];
          },
        ),
        reads: reads,
        runs: runs,
      );
    }

    test(
      'the user is the effective ID: the second number of the Uid: line',
      () {
        final it = described({'/proc/self/status': status});
        expect(it.facts.userId, 1001);
        expect(it.runs, isEmpty, reason: 'no process where /proc tells');
      },
    );

    test('with no /proc, `id -u` tells; and what could not be told once is '
        'not asked for again (no read, no process, every round of a host)', () {
      final it = described(
        {},
        results: {'id -u': ProcessResult(1, 0, '1000\n', '')},
      );
      expect(it.facts.userId, 1000);
      expect(it.facts.userId, 1000);
      expect(it.runs, ['id -u']);

      final none = described({});
      expect(none.facts.userId, isNull);
      final reads = none.reads.length;
      for (var i = 0; i < 5; i++) {
        expect(none.facts.userId, isNull);
        expect(none.facts.userHome(null), isNull);
        expect(none.facts.userHomeFromFiles(null), isNull);
        expect(none.facts.privateGroupId(null), isNull);
        expect(none.facts.machineId, '');
      }
      expect(none.runs, ['id -u'], reason: 'asked once');
      // The machine ID files were read once each, whatever else was asked.
      expect(
        none.reads.where((path) => path.endsWith('machine-id')),
        hasLength(2),
      );
      expect(none.reads.length, lessThanOrEqualTo(reads + 2));
    });

    test('a home is the passwd line of the user, read without a process; one '
        'that is not an absolute path is no home', () {
      final it = described({'/etc/passwd': passwd});
      expect(it.facts.userHome(1000), '/home/me');
      expect(it.facts.userHomeFromFiles(1001), '/home/other');
      expect(it.facts.userHome(1002), isNull, reason: 'relative/home');
      expect(it.facts.userHome(4242), isNull);
      expect(it.runs, [
        'getent passwd 1002',
        'getent passwd 4242',
      ], reason: 'getent only for the users the file does not give a home');
    });

    test('a user that only getent knows (LDAP) has the home getent gives, if '
        'it is an absolute path', () {
      final it = described(
        {'/etc/passwd': passwd},
        results: {
          'getent passwd 5000': ProcessResult(
            1,
            0,
            'ldap:*:5000:5000::/srv/ldap:/bin/sh\n',
            '',
          ),
          'getent passwd 5001': ProcessResult(
            1,
            0,
            'bad:*:5001:5001::nowhere:/bin/sh\n',
            '',
          ),
        },
      );
      expect(it.facts.userHome(5000), '/srv/ldap');
      expect(it.facts.userHome(5001), isNull);
      expect(it.facts.userHome(5000), '/srv/ldap');
      expect(it.runs, ['getent passwd 5000', 'getent passwd 5001']);
    });

    test(
      "the user's private group is their primary group when no other user "
      'has it and the group lists no other member (Debian\'s OpenSSH rule)',
      () {
        String group(String members) => 'staff:x:50:\nme:x:1000:$members\n';
        final private = described({
          '/etc/passwd': passwd,
          '/etc/group': group(''),
        });
        expect(private.facts.privateGroupId(1000), 1000);
        expect(
          described({
            '/etc/passwd': passwd,
            '/etc/group': group('me'),
          }).facts.privateGroupId(1000),
          1000,
          reason: 'the user is the member',
        );
        expect(
          described({
            '/etc/passwd': passwd,
            '/etc/group': group('me,other'),
          }).facts.privateGroupId(1000),
          isNull,
          reason: 'another member',
        );
        expect(
          described({
            '/etc/passwd':
                '$passwd'
                'friend:x:1003:1000::/home/friend:/bin/sh\n',
            '/etc/group': group(''),
          }).facts.privateGroupId(1000),
          isNull,
          reason: 'another user has it as the primary group',
        );
        expect(
          described({'/etc/group': group('')}).facts.privateGroupId(1000),
          isNull,
          reason: 'no passwd line to tell it by',
        );
      },
    );

    test('a machine ID is the first line of /etc/machine-id, else of the '
        'dbus one, when it is 32 hex characters; else none', () {
      const id = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
      expect(described({'/etc/machine-id': '$id\n'}).facts.machineId, id);
      expect(
        described({'/var/lib/dbus/machine-id': '$id\n'}).facts.machineId,
        id,
      );
      expect(described({'/etc/machine-id': 'not an id\n'}).facts.machineId, '');
      expect(described({}).facts.machineId, '');
    });

    test('an environment is described with its own facts, or reads them '
        'through the facts it was given', () {
      final it = described({
        '/proc/self/status': status,
        '/etc/passwd': passwd,
      });
      final machine = HostEnvironment(
        os: HostOs.linux,
        variables: const {},
        workingDirectory: '/',
        facts: it.facts,
      );
      expect(machine.userId, 1001);
      expect(machine.userHome, '/home/other');
      expect(machine.userHomeWithoutProcess, '/home/other');
      expect(machine.userHomeNeedsProcess, isFalse);
      final unknown = HostEnvironment(
        os: HostOs.linux,
        variables: const {},
        workingDirectory: '/',
        userId: 4242,
        facts: it.facts,
      );
      expect(unknown.userHomeNeedsProcess, isTrue);
    });
  });

  group('the host is looked for in the places the rule could have given', () {
    const id = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
    HostEnvironment machine(String home, {String name = 'box'}) =>
        fakeEnvironment(
          const {},
          os: HostOs.linux,
          machineName: name,
          machineId: id,
          userId: 1000,
          userHome: home,
          runUserRoot: '/run/user',
        );
    // Every folder can be trusted, and /run/user/1000 is there.
    String? trusting(List<String> chain, {bool mustExist = false}) => null;

    test('they are /run/user/<uid>, the machine under its old names in hosts, '
        'and /tmp: each but the folder chosen', () {
      final home = tempDir().path;
      final hosts = p.join(home, '.cache', 'appstein', 'hosts');
      // This machine under two names (the hex is the machine ID's), and
      // another machine's folder.
      final before = Directory(p.join(hosts, 'before-${_hexOf(id)}'))
        ..createSync(recursive: true);
      Directory(p.join(hosts, 'older-${_hexOf(id)}')).createSync();
      Directory(p.join(hosts, 'stranger-0123456789ab')).createSync();
      final current = analysisHostFolder(
        machine(home),
        trustedCache: (chain, {mustExist = false}) =>
            mustExist ? 'not there' : null,
      );
      expect(current, startsWith(p.join(hosts, 'box-')));
      final places = otherAnalysisHostPlaces(
        machine(home),
        chosen: current,
        trustedCache: trusting,
      );
      expect(
        {for (final place in places) place.folder},
        {
          p.join('/run/user', '1000', 'appstein'),
          before.path,
          p.join(hosts, 'older-${_hexOf(id)}'),
          p.join('/tmp', 'appstein-1000'),
        },
      );
      // The chosen one is left out: when the run folder is the choice, the
      // cache one is among the others.
      final chosenRun = p.join('/run/user', '1000', 'appstein');
      expect([
        for (final place in otherAnalysisHostPlaces(
          machine(home),
          chosen: chosenRun,
          trustedCache: trusting,
        ))
          place.folder,
      ], contains(current));
      expect([
        for (final place in otherAnalysisHostPlaces(
          machine(home),
          chosen: chosenRun,
          trustedCache: trusting,
        ))
          place.folder,
      ], isNot(contains(chosenRun)));
    });

    test('there are none off Linux, for a folder the variable gave, or '
        'without a user', () {
      expect(
        otherAnalysisHostPlaces(
          fakeEnvironment(const {}, os: HostOs.windows),
          chosen: 'x',
        ),
        isEmpty,
      );
      expect(
        otherAnalysisHostPlaces(
          fakeEnvironment({analysisHostFolderVariable: '/x'}, os: HostOs.linux),
          chosen: '/x',
        ),
        isEmpty,
      );
      expect(
        otherAnalysisHostPlaces(
          fakeEnvironment(const {}, os: HostOs.linux, userId: -1),
          chosen: 'x',
        ),
        isEmpty,
      );
    });

    test('a client that finds no host in its folder uses one it finds in '
        'another place, and starts none; a place that fails its check is not '
        'used', () async {
      final app = tempDir().path;
      final (:server, folder: elsewhere, address: _) = await inProcessHost(app);
      final primary = p.join(tempDir().path, 'primary');
      final (:scope, folder: _) = testHost(
        app,
        folder: primary,
        others: [(folder: elsewhere, problem: () => null)],
      );
      expect(await codesIn(scope, 'lib/a.dart'), isEmpty);
      expect(server.asked, ['read']);
      expect(startedHostProcesses(primary), isEmpty, reason: 'no host started');

      // The same place, whose check fails: not used, and the client starts a
      // host of its own in its folder (here, one that cannot start).
      final (scope: refused, folder: _) = testHost(
        app,
        folder: p.join(tempDir().path, 'primary'),
        hostCommand: [Platform.resolvedExecutable, 'no such script.dart'],
        others: [(folder: elsewhere, problem: () => 'not trusted')],
      );
      await expectLater(
        codesIn(refused, 'lib/a.dart'),
        throwsA(isA<CodeAnalysisException>()),
      );
      expect(server.asked, ['read'], reason: 'the host was not asked');
    });

    test('the places are asked only when no host is in the folder, so the '
        'normal case adds nothing', () async {
      final app = tempDir().path;
      final (server: _, :folder, address: _) = await inProcessHost(app);
      var asked = 0;
      final (:scope, folder: _) = testHost(
        app,
        folder: folder,
        others: [],
        onOthers: () => asked++,
      );
      expect(await codesIn(scope, 'lib/a.dart'), isEmpty);
      expect(asked, 0);
    });

    test('where the host is and how it is started are decided at the first '
        'question: a run that asks nothing makes no choice', () async {
      var chosen = 0;
      final scope = analysisHostCodeAnalysis(
        projectRoot: '/work/my app',
        appsteinVersion: 'test',
        ownServer: () => throw StateError('no server'),
        location: () {
          chosen++;
          return (
            folder: p.join(tempDir().path, 'hosts'),
            command: [Platform.resolvedExecutable, 'no such script.dart'],
            note: null,
            others: () => const <AnalysisHostPlace>[],
          );
        },
      );
      await scope((analysis) async {});
      expect(chosen, 0);
      await scope((analysis) async {
        // `warmUp` is a first question too.
        (analysis as WarmableCodeAnalysis).warmUp();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      expect(chosen, 1);
    });
  });

  group('the folders of a host are made at 700 only', () {
    test('two starters that make the same folders at the same moment end '
        'with one set of folders at 700, and nothing of theirs left', () async {
      final base = Directory(p.join(tempDir().path, 'cache'))..createSync();
      final folder = p.join(base.path, 'appstein', 'hosts', 'box');
      AnalysisHostAddress address(String secret) => AnalysisHostAddress(
        port: 1,
        secret: secret,
        processId: 1,
        appsteinVersion: 'test',
      );
      await Future.wait([
        writeAnalysisHostAddress(
          analysisHostAddressFile(folder, '/work/one'),
          address('one'),
        ),
        writeAnalysisHostAddress(
          analysisHostAddressFile(folder, '/work/two'),
          address('two'),
        ),
      ]);
      expect(
        [
          for (final entry in Directory(
            p.join(base.path, 'appstein'),
          ).listSync())
            p.basename(entry.path),
        ],
        ['hosts'],
        reason: 'nothing of the starters is left beside it',
      );
      expect(Directory(base.path).listSync().length, 1);
      if (!Platform.isWindows) {
        for (final made in [
          p.join(base.path, 'appstein'),
          p.join(base.path, 'appstein', 'hosts'),
          folder,
        ]) {
          expect(
            (FileStat.statSync(made).mode & 0xFFF).toRadixString(8),
            '700',
            reason: made,
          );
        }
      }
    });

    test('a client that looks while the folders are being made never sees one '
        'that is not 700', () async {
      final base = Directory(p.join(tempDir().path, 'cache'))..createSync();
      final folder = p.join(base.path, 'a', 'b', 'c', 'box');
      final seen = <String, Set<String>>{};
      var making = true;
      final watching = () async {
        while (making) {
          for (final level in ['a', 'a/b', 'a/b/c', 'a/b/c/box']) {
            final path = p.join(base.path, level);
            if (FileSystemEntity.typeSync(path) ==
                FileSystemEntityType.directory) {
              (seen[level] ??= {}).add(
                (FileStat.statSync(path).mode & 0xFFF).toRadixString(8),
              );
            }
          }
          await Future<void>.delayed(Duration.zero);
        }
      }();
      await writeAnalysisHostAddress(
        analysisHostAddressFile(folder, '/work/one'),
        const AnalysisHostAddress(
          port: 1,
          secret: 'one',
          processId: 1,
          appsteinVersion: 'test',
        ),
      );
      making = false;
      await watching;
      for (final MapEntry(:key, :value) in seen.entries) {
        expect(value, {'700'}, reason: 'the folder $key');
      }
    }, skip: Platform.isWindows ? 'Windows has no Unix mode' : false);

    test('the address file check tells the owner by one `stat` of the folder '
        'and the file: another user ID is refused for both, whatever chmod '
        'would say', () async {
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
      final mine = MachineFacts.system.userId!;
      expect(await untrustedAddress(file, userId: mine), isNull);
      expect(await untrustedAddress(file, strict: true, userId: mine), isNull);
      expect(await untrustedAddressFolder(folder, userId: mine), isNull);
      expect(
        await untrustedAddress(file, strict: true, userId: mine + 1),
        contains("is not the user's own"),
      );
      expect(
        await untrustedAddressFolder(folder, userId: mine + 1),
        contains("is not the user's own"),
      );
    }, skip: Platform.isWindows ? 'Windows has no owner of this kind' : false);

    test(
      'what a host that died while it made a folder left beside it is '
      'cleared once it is an hour old: an empty folder of that name only',
      () async {
        final parent = tempDir().path;
        String folder(String name, {bool withFile = false}) {
          final made = Directory(p.join(parent, name))..createSync();
          if (withFile) File(p.join(made.path, 'x')).writeAsStringSync('x');
          return made.path;
        }

        final left = folder('.hosts.4242.17.making');
        final full = folder('.appstein.4242.18.making', withFile: true);
        final named = folder('.cache.making');
        final other = folder('hosts');
        for (final path in [left, full, named, other]) {
          _ageAll(path);
        }
        final fresh = folder('.hosts.4242.19.making');
        expect(await clearMakingLeftovers(parent), [left]);
        expect(Directory(left).existsSync(), isFalse);
        for (final kept in [full, named, other, fresh]) {
          expect(Directory(kept).existsSync(), isTrue, reason: kept);
        }

        // A host that makes its folder clears such leftovers on the way.
        final hosts = p.join(tempDir().path, 'appstein', 'hosts');
        Directory(hosts).createSync(recursive: true);
        final leftover = p.join(hosts, '.box-0123456789ab.4242.20.making');
        Directory(leftover).createSync();
        _ageAll(leftover);
        await writeAnalysisHostAddress(
          analysisHostAddressFile(p.join(hosts, 'box-0123456789ab'), '/work/a'),
          const AnalysisHostAddress(
            port: 1,
            secret: 's',
            processId: 1,
            appsteinVersion: 'test',
          ),
        );
        expect(Directory(leftover).existsSync(), isFalse);
      },
    );

    test(
      "the owner's `stat` on macOS is the system's own, by its full path, so "
      'a GNU stat first on the PATH (Homebrew) never answers it',
      () {
        final (mac, macArguments) = ownerStatCommand(HostOs.macos);
        expect(mac, '/usr/bin/stat');
        expect(macArguments, ['-f', '%u']);
        final (linux, linuxArguments) = ownerStatCommand(HostOs.linux);
        expect(linux, 'stat');
        expect(linuxArguments, ['-c', '%u']);
      },
    );

    test('a home that getent gives with a trailing `/` is read in its normal '
        'spelling, and the folders stat names with `//` are matched to it', () {
      final home = Directory(p.join(tempDir().path, 'home'))..createSync();
      Directory(p.join(home.path, '.cache')).createSync();
      final asGiven = '${home.path}/';
      final both = homeAndFoldersOfUser(
        1000,
        run: (_, _) => ProcessResult(
          0,
          0,
          'home $asGiven\n'
              '1000 1000 700 $asGiven\n'
              '1000 1000 700 $asGiven/.cache\n',
          '',
        ),
      );
      expect(both!.home, home.path);
      expect(both.facts[0]!.owner, 1000, reason: 'the home');
      expect(both.facts[1]!.isFolder, isTrue, reason: '~/.cache');
      expect(both.facts[1]!.owner, 1000);
      expect(both.facts.skip(2), [null, null], reason: 'not made yet');
    }, skip: Platform.isWindows ? 'A home from getent is a POSIX path' : false);

    test(
      'for a user that only getent knows, one process gives the home and the '
      'facts of the folders on the way',
      () {
        final uid = MachineFacts.system.userId!;
        final both = homeAndFoldersOfUser(uid);
        expect(both, isNotNull);
        expect(both!.home, HostEnvironment.current().userHome);
        expect(both.facts, hasLength(4));
        // The home is there, and the user's own.
        expect(both.facts.first, isNotNull);
        expect(both.facts.first!.owner, uid);
      },
      skip: Platform.isLinux ? false : 'getent and GNU stat are Linux\'s',
    );
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

/// Makes everything in the folder [path], and the folder, a month old: the
/// files first, then the folders from the inside out (a change to a file
/// changes its folder's time).
void _ageAll(String path) {
  final old = DateTime.now().subtract(const Duration(days: 30));
  final entries = Directory(path).listSync(recursive: true, followLinks: false);
  for (final entry in entries.whereType<File>()) {
    entry.setLastModifiedSync(old);
  }
  final folders = [
    for (final entry in entries.whereType<Directory>()) entry.path,
    path,
  ]..sort((a, b) => b.length.compareTo(a.length));
  for (final folder in folders) {
    if (Platform.isWindows) {
      // Dart can't set the time of a folder on Windows.
      Process.runSync('powershell', [
        '-NoProfile',
        '-Command',
        "(Get-Item -LiteralPath '${folder.replaceAll("'", "''")}')"
            '.LastWriteTime = [DateTime]::Now.AddDays(-30)',
      ]);
    } else {
      // Nor anywhere else: `setLastModified` is for files ("Is a directory"
      // on Linux and macOS). `touch -m -t` is in GNU, BusyBox and macOS.
      final stamp = [
        old.year,
        old.month,
        old.day,
        old.hour,
        old.minute,
      ].map((n) => '$n'.padLeft(2, '0')).join();
      final touched = Process.runSync('touch', ['-m', '-t', stamp, folder]);
      if (touched.exitCode != 0) {
        throw StateError('touch failed on $folder: ${touched.stderr}');
      }
    }
  }
}

/// The 12 hex characters a machine folder name ends in for the machine ID
/// [id].
String _hexOf(String id) =>
    sha256.convert(utf8.encode(id)).toString().substring(0, 12);
