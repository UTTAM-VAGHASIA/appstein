import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:dart_mcp/client.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../analysis/support/analysis_support.dart';
import '../knowledge/support/sync_harness.dart';
import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import '../support/flutter_test_output.dart';
import '../support/temp.dart';
import 'support/mcp_client.dart';

const _packs = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];

// The `verify` tool with a real analysis server that is kept between calls
// (slice 1d.2, ticket 04), as `appstein mcp` keeps it. Every call is made at
// once after the change before it, with no wait.
void main() {
  late String app;
  late String sdk;

  setUp(() {
    app = copyFixtureApp();
    sdk = fakeFlutter();
    // The first call starts the real server, which can take longer than the
    // cap of a fast run on a busy machine; these tests are not about it.
    writeProjectFile(
      app,
      'appstein.yaml',
      'appstein: 1\nverify:\n  fast_timeout_seconds: 600\n',
    );
  });

  // A full run also runs the project's tests (ticket 10): scripted as a
  // run whose tests all pass, so the findings here are the analysis's.
  KnowledgeSync sync() {
    final runner = FakeProcessRunner();
    scriptFlutterTest(runner, sdk);
    return knowledgeSync(
      flutterRoot: sdk,
      runner: runner,
      packs: _packs,
      packageSkills: false,
    );
  }

  Future<ServerConnection> serve(KeptAnalysisServer kept) async {
    final controller = StreamChannelController<String>();
    final server = AppsteinMcpServer(
      controller.local,
      projectRoot: app,
      syncFor: sync,
      codeAnalysis: kept.use,
      appsteinVersion: '0.1.0-dev',
      dartSdkPath: testDartSdk,
    );
    addTearDown(kept.close);
    addTearDown(server.shutdown);
    return connectTo(controller.foreign);
  }

  Future<Map<String, Object?>> verify(
    ServerConnection server, [
    String scope = 'fast',
  ]) async {
    final result = await call(server, 'verify', {'scope': scope});
    expect(result.isError, isNot(isTrue), reason: textOf(result));
    return result.structuredContent!;
  }

  /// The `dart.*` findings of a reply, as `id file line`.
  List<String> dart(Map<String, Object?> json) => [
    for (final finding
        in (json['findings']! as List).cast<Map<String, Object?>>())
      if ('${finding['id']}'.startsWith('dart.'))
        '${finding['id']} ${finding['file']} ${finding['line']}',
  ];

  test('no analysis server is started until the first verify call; the '
      'calls after it use the same server, and each reports the files as '
      'they are: an error added between two calls appears, and an error '
      'removed is gone', () async {
    final kept = KeptAnalysisServer(realAnalysisServer(app));
    final server = await serve(kept);
    expect(kept.server.processes, isNull);
    // Other tools start none.
    expect((await call(server, 'overview')).isError, isNot(isTrue));
    await call(server, 'where_is', {'query': 'login screen'});
    expect(kept.server.processes, isNull);

    expect(dart(await verify(server)), isEmpty);
    final processes = kept.server.processes;
    expect(processes, isNotNull);
    expect(await processAlive(processes!.guard), isTrue);
    expect(await processAlive(processes.server), isTrue);

    for (var round = 0; round < 5; round++) {
      writeProjectFile(
        app,
        'lib/my folder/broken.dart',
        '/// Wrong, round $round.\nint wrong() => \'text\';\n',
      );
      expect(dart(await verify(server)), [
        'dart.error lib/my folder/broken.dart 2',
      ], reason: 'round $round, the error added');
      // An error in a file that was not touched: `sides` is gone.
      writeProjectFile(
        app,
        'lib/my folder/broken.dart',
        '/// Right, round $round.\nint right() => $round;\n',
      );
      writeProjectFile(app, 'lib/shape.dart', '''
/// A shape.
class Shape {
  /// How many ${round.isEven ? 'corners' : 'sides'} it has.
  int ${round.isEven ? 'corners' : 'sides'} = 0;
}
''');
      writeProjectFile(app, 'lib/uses_shape.dart', '''
import 'shape.dart';

/// Reads the sides.
int sidesOf(Shape shape) => shape.sides;
''');
      expect(
        dart(await verify(server, round.isEven ? 'fast' : 'full')),
        round.isEven ? ['dart.error lib/uses_shape.dart 4'] : isEmpty,
        reason: 'round $round, the first error removed',
      );
      deleteProjectFile(app, 'lib/uses_shape.dart');
      expect(
        dart(await verify(server)),
        isEmpty,
        reason: 'round $round, the file with the error deleted',
      );
    }
    expect(kept.server.processes, processes, reason: 'a server was restarted');

    // The knowledge refresh of each call saw the change too.
    expect((await verify(server))['freshness'], {'state': 'current'});
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the findings of the tool equal the findings of a terminal run on '
      'the same files, in both scopes, before and after an edit', () async {
    writeProjectFile(
      app,
      'lib/my folder/broken.dart',
      '/// Wrong on purpose.\nint wrong() => \'text\';\n',
    );
    final kept = KeptAnalysisServer(realAnalysisServer(app));
    final server = await serve(kept);

    Future<void> expectSame(String what) async {
      for (final mode in VerifyMode.values) {
        final tool = await verify(server, mode.name);
        // As a terminal run does it: a server of its own, stopped after.
        final terminal =
            await ownAnalysisServer(
              projectRoot: app,
              guardCommand: testGuardCommand,
              dartExecutable: () => testDart,
              environment: testAnalysisEnvironment(),
            )(
              (analysis) => runVerify(
                projectRoot: app,
                config: const AppsteinConfig(),
                packs: _packs,
                sync: sync(),
                mode: mode,
                checks: checksFor(_packs),
                codeAnalysis: analysis,
                dartSdkPath: testDartSdk,
                clock: RunClock(limit: const Duration(minutes: 10)),
              ),
            );
        final json = terminal.toJson();
        for (final key in json.keys) {
          expect(tool[key], json[key], reason: '$what, ${mode.name}: $key');
        }
        expect(dart(tool), isNotEmpty, reason: '$what, ${mode.name}');
      }
    }

    await expectSame('at first');
    writeProjectFile(app, 'lib/second.dart', '''
import 'my folder/broken.dart';

/// Wrong too.
String second() => wrong();
''');
    await expectSame('after an edit');
    final found = dart(await verify(server));
    expect(found, [
      'dart.error lib/my folder/broken.dart 2',
      'dart.error lib/second.dart 4',
    ]);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('an analysis server that died is started again by the next verify '
      'call, which answers', () async {
    writeProjectFile(
      app,
      'lib/broken.dart',
      '/// Wrong on purpose.\nint wrong() => \'text\';\n',
    );
    final kept = KeptAnalysisServer(realAnalysisServer(app));
    final server = await serve(kept);
    expect(dart(await verify(server)), ['dart.error lib/broken.dart 2']);
    final (:guard, server: serverId) = kept.server.processes!;

    // The server this test started; the error is fixed while it is dead.
    await recordProcesses([guard, serverId]);
    Process.killPid(serverId, ProcessSignal.sigkill);
    writeProjectFile(app, 'lib/broken.dart', '/// Right.\nint right = 1;\n');
    expect(dart(await verify(server)), isEmpty);
    expect(
      await goneWithin([guard, serverId], const Duration(seconds: 10)),
      isNotNull,
    );
    final now = kept.server.processes!;
    await recordProcesses([now.guard, now.server]);
    expect(await processAlive(now.server), isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('an analysis server that can\'t be started is an error reply with '
      'the reason and `appstein doctor`; the MCP server keeps running, and '
      'answers verify once the server can start', () async {
    var dartPath = p.join(tempDir().path, 'no sdk', 'bin', 'dart');
    final missing = dartPath;
    final kept = KeptAnalysisServer(
      AnalysisServer(
        projectRoot: app,
        guardCommand: testGuardCommand,
        dartExecutable: () => dartPath,
        environment: testAnalysisEnvironment(),
      ),
    );
    final server = await serve(kept);
    for (var i = 0; i < 2; i++) {
      final failed = await call(server, 'verify', {'scope': 'fast'});
      expect(failed.isError, isTrue);
      expect(
        textOf(failed),
        startsWith(
          'The Dart analysis server could not answer: there is no Dart '
          'executable at $missing. Run `appstein doctor` to see what is '
          'wrong.',
        ),
      );
      expect(kept.server.processes, isNull);
      expect((await call(server, 'overview')).isError, isNot(isTrue));
    }
    dartPath = testDart;
    expect(dart(await verify(server)), isEmpty);
    expect(kept.server.processes, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('when the owner closes the kept server, as `appstein mcp` does when '
      'it stops, the analysis server and its guard are gone', () async {
    final kept = KeptAnalysisServer(realAnalysisServer(app));
    final server = await serve(kept);
    await verify(server);
    final (:guard, server: serverId) = kept.server.processes!;
    await server.shutdown();
    await kept.close();
    expect(
      await goneWithin([guard, serverId], const Duration(seconds: 5)),
      isNotNull,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
