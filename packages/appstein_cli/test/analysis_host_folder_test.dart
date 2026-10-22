import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/analysis_hosts.dart';
import 'support/child_processes.dart';
import 'support/dart_sdk.dart';
import 'support/fake_flutter_sdk.dart';

// The client that chooses its host's folder from the machine (ticket 12),
// through the path the hooks and the `verify` tool use.
void main() {
  group('a host is told to follow its folder only where the machine chose it '
      'and it is Linux', () {
    HostEnvironment machine(
      HostOs os, [
      Map<String, String> variables = const {},
    ]) => HostEnvironment(
      os: os,
      variables: variables,
      workingDirectory: '/work',
    );

    test('on Linux it is; on Windows and macOS it never is', () {
      expect(hostFollowsFolder(machine(HostOs.linux)), isTrue);
      expect(hostFollowsFolder(machine(HostOs.windows)), isFalse);
      expect(hostFollowsFolder(machine(HostOs.macos)), isFalse);
    });

    test('a folder the variable gave, or a test that says so, is never '
        'followed', () {
      expect(
        hostFollowsFolder(
          machine(HostOs.linux, {analysisHostFolderVariable: '/given'}),
        ),
        isFalse,
      );
      expect(
        hostFollowsFolder(machine(HostOs.linux), followFolder: false),
        isFalse,
      );
    });
  });

  group('the server of its own that a session keeps', () {
    /// A run's own server that counts: the analysis server stand-in.
    final made = <_Own>[];
    StoppableCodeAnalysis newOwn() {
      final own = _Own();
      made.add(own);
      return own;
    }

    CodeAnalysisScope scope({SessionOwnServer? keep}) {
      made.clear();
      final folder = Directory.systemTemp.createTempSync('appstein hosts ');
      addTearDown(() => folder.deleteSync(recursive: true));
      return hostCodeAnalysis(
        projectRoot: p.join(folder.path, 'my app'),
        environment: HostEnvironment(
          os: HostOs.current,
          variables: {analysisHostFolderVariable: folder.path},
          workingDirectory: folder.path,
        ),
        // A terminal run: it starts no host, and a run with no host that
        // can be used asks a server of its own.
        startHost: false,
        keepOwnServer: keep,
        newOwnServer: newOwn,
      );
    }

    test('appstein mcp keeps one for the session, whatever the number of '
        'calls', () async {
      final session = SessionOwnServer();
      final calls = scope(keep: session);
      for (var i = 0; i < 3; i++) {
        final reading = await calls((analysis) => analysis.read());
        expect(reading.analyzedFiles, ['own']);
      }
      expect(made, hasLength(1), reason: 'one server for three calls');
      expect(made.single.closed, isFalse, reason: 'kept between calls');
      expect(made.single.reads, 3);
    });

    test('the end of the session stops the server it kept, at once, and no '
        'call can use it afterwards', () async {
      final session = SessionOwnServer();
      final calls = scope(keep: session);
      await calls((analysis) => analysis.read());
      expect(made.single.closed, isFalse);
      expect(await session.close(), isEmpty);
      expect(made.single.closed, isTrue, reason: 'stopped with the session');
      await expectLater(
        calls((analysis) => analysis.read()),
        throwsA(isA<CodeAnalysisException>()),
      );
      expect(made, hasLength(1), reason: 'no new server after the end');
    });

    test('a session that never needed a server of its own stops nothing', () {
      expect(SessionOwnServer().close(), completion(isEmpty));
    });

    test(
      'a call that is not a session\'s starts its own and stops it',
      () async {
        final calls = scope();
        for (var i = 0; i < 2; i++) {
          await calls((analysis) => analysis.read());
        }
        expect(made, hasLength(2));
        expect(made.every((own) => own.closed), isTrue);
      },
    );
  });

  test(
    'on Linux a client chooses the folder from the machine and its host '
    'runs there, whatever a folder in /tmp that another user made: nothing '
    'is written to /tmp/appstein-<uid>, nothing of the real machine\'s folders '
    'is touched, and the client is answered',
    () async {
      final uid = '${Process.runSync('id', ['-u']).stdout}'.trim();
      final work = Directory.systemTemp.createTempSync('appstein cli tëst ');
      addTearDown(() => work.deleteSync(recursive: true));
      final project = p.join(work.path, 'my app');
      Directory(project).createSync();
      File(
        p.join(project, 'pubspec.yaml'),
      ).writeAsStringSync('name: my_app\nenvironment:\n  sdk: ^3.12.0\n');
      final home = Directory(p.join(work.path, 'home'))..createSync();
      Process.runSync('chmod', ['700', home.path]);

      // As another user's folder looks to the client: others can write to
      // it. One that is there already (the user's own, from an older run) is
      // left as it is, and the 757 case is then not exercised on this run.
      final squatted = Directory(p.join('/tmp', 'appstein-$uid'));
      var squatter = false;
      if (!squatted.existsSync()) {
        squatted.createSync();
        Process.runSync('chmod', ['757', squatted.path]);
        squatter = true;
        addTearDown(() {
          if (squatted.existsSync()) squatted.deleteSync(recursive: true);
        });
      }

      // The machine is described by the test: a home of its own, no
      // /run/user folder, no private group, the facts of nothing else. The
      // host is not told to follow its folder (`followFolder: false`), so it
      // never looks at the real machine's folders either, and writes its
      // address only where the client chose.
      final environment = HostEnvironment(
        os: HostOs.linux,
        variables: {
          'FLUTTER_ROOT': createFakeFlutterSdk(p.join(work.path, 'flutter')),
          analysisCacheVariable: testAnalysisCache(),
          // None of these changes the choice on Linux.
          'HOME': '/nonexistent',
          'XDG_CACHE_HOME': '/nonexistent/cache',
          'XDG_RUNTIME_DIR': '/nonexistent/run',
          'TMPDIR': '/nonexistent/tmp',
        },
        workingDirectory: project,
        userHome: home.path,
        privateGroupId: -1,
        runUserRoot: p.join(work.path, 'no run folder'),
      );
      final chosen = chooseAnalysisHostFolder(environment);
      expect(chosen.folder, isNot(squatted.path));
      expect(
        p.dirname(chosen.folder),
        p.join(home.path, '.cache', 'appstein', 'hosts'),
      );
      // Chosen again from the same facts: the same folder.
      expect(chooseAnalysisHostFolder(environment).folder, chosen.folder);

      await withChildProcessesToItself(() async {
        final scope = hostCodeAnalysis(
          projectRoot: project,
          environment: environment,
          dartSdkPath: testDartSdk,
          followFolder: false,
        );
        final reading = await scope((analysis) => analysis.read());
        expect(reading.analyzedFiles, isNotNull);
        expect(reading.notices, isEmpty, reason: 'a host answered');
        // The host wrote its address in that folder, and the client chose
        // the same folder again from the same facts.
        expect(hostProcess(chosen.folder, project), isNotNull);
        expect(chooseAnalysisHostFolder(environment).folder, chosen.folder);
        if (squatter) {
          expect(
            squatted.listSync(),
            isEmpty,
            reason: 'nothing is written to the folder others could write to',
          );
        }
      }, cleanup: () => killHost(chosen.folder, project));
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: Platform.isLinux
        ? false
        : 'Only on Linux is the folder chosen from the machine and /tmp '
              'shared by every user',
  );
}

/// A server of its own that notes what it was asked and whether it was
/// closed.
final class _Own implements StoppableCodeAnalysis {
  var closed = false;
  var reads = 0;

  @override
  Future<CodeReading> read() async {
    reads++;
    return const CodeReading(analyzedFiles: ['own']);
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
  Future<AppliedChanges> applyFixesAndFormat({
    required Future<bool> Function(String file) leaveUnformatted,
    required Duration within,
  }) async => const AppliedChanges();

  @override
  Future<void> stop() async {}

  @override
  Future<void> close() async => closed = true;
}
