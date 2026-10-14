import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:dart_mcp/client.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/child_processes.dart';
import 'support/dart_sdk.dart';
import 'support/fake_flutter_sdk.dart';
import 'support/scripted_code_analysis.dart';

void main() {
  late StringBuffer out;
  late StringBuffer err;
  late String project;
  late String sdk;

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
    final work = Directory.systemTemp.createTempSync('appstein cli tëst ');
    addTearDown(() => work.deleteSync(recursive: true));
    project = p.join(work.path, 'my app');
    Directory(project).createSync();
    File(
      p.join(project, 'pubspec.yaml'),
    ).writeAsStringSync('name: my_app\nenvironment:\n  sdk: ^3.12.0\n');
    sdk = createFakeFlutterSdk(p.join(work.path, 'flutter'));
  });

  HostEnvironment machine({String? cwd}) => HostEnvironment(
    os: HostOs.current,
    variables: {'FLUTTER_ROOT': sdk},
    workingDirectory: cwd ?? project,
  );

  Future<int> run(List<String> args, McpChannel channel, {String? cwd}) =>
      runAppstein(
        args,
        out: out,
        err: err,
        environment: machine(cwd: cwd),
        mcpChannel: () => channel,
        // The fake SDK has no `dart` to run an analysis server with.
        codeAnalysis: ScriptedCodeAnalysis().scope,
      );

  test('serves the tools until the client closes, writing nothing to the '
      'output sink', () async {
    final controller = StreamChannelController<String>();
    final exit = run(['mcp'], controller.local);
    final client = MCPClient(Implementation(name: 'test', version: '1'));
    final server = client.connectServer(controller.foreign);
    await server.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    server.notifyInitialized();
    final tools = (await server.listTools()).tools;
    expect([for (final tool in tools) tool.name], mcpToolNames);
    final overview = await server.callTool(
      CallToolRequest(name: 'overview', arguments: const {}),
    );
    expect(overview.isError, isNot(isTrue), reason: '${overview.content}');
    expect(overview.structuredContent!['index'], startsWith('# my_app\n'));
    // `verify` answers with the project's packs (the fake SDK can't build
    // the map, so the answer is the stale knowledge and what did not run).
    final verified = await server.callTool(
      CallToolRequest(name: 'verify', arguments: const {'scope': 'full'}),
    );
    expect(verified.isError, isNot(isTrue), reason: '${verified.content}');
    expect(
      [
        for (final finding in verified.structuredContent!['findings']! as List)
          (finding as Map)['id'],
      ],
      ['knowledge.stale'],
    );
    expect(
      [
        for (final check in verified.structuredContent!['notRun']! as List)
          (check as Map)['id'],
      ],
      ['docs.stale', 'verify.test_required'],
    );
    await server.shutdown();
    expect(await exit, ExitCodes.ok);
    expect(out.toString(), isEmpty);
  });

  test('re-reads appstein.yaml on every call', () async {
    final controller = StreamChannelController<String>();
    final exit = run(['mcp'], controller.local);
    final client = MCPClient(Implementation(name: 'test', version: '1'));
    final server = client.connectServer(controller.foreign);
    await server.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    server.notifyInitialized();
    await server.callTool(
      CallToolRequest(name: 'overview', arguments: const {}),
    );
    File(p.join(project, 'appstein.yaml')).writeAsStringSync('nonsense: 1\n');
    final result = await server.callTool(
      CallToolRequest(name: 'overview', arguments: const {}),
    );
    final freshness = result.structuredContent!['freshness']! as Map;
    expect(freshness['state'], 'stale');
    expect(freshness['problem'], startsWith('appstein.yaml is invalid: '));
    await server.shutdown();
    expect(await exit, ExitCodes.ok);
  });

  test('outside a project it exits 3 with a message', () async {
    final elsewhere = Directory.systemTemp.createTempSync('appstein no prj ');
    addTearDown(() => elsewhere.deleteSync(recursive: true));
    final controller = StreamChannelController<String>();
    expect(
      await run(['mcp'], controller.local, cwd: elsewhere.path),
      ExitCodes.appsteinFailed,
    );
    expect(err.toString(), contains('appstein mcp needs a Flutter project'));
  });

  // Warm analysis with real processes (slice 1d.2, ticket 04): the command's
  // own kept server, the guard started as `dart bin/appstein.dart
  // analysis-server-guard`, and the analysis server of the SDK that runs
  // the tests. Only processes these tests started are looked at or ended.
  group('with a real analysis server', () {
    Future<ServerConnection> connect(StreamChannel<String> channel) async {
      final client = MCPClient(Implementation(name: 'test', version: '1'));
      final server = client.connectServer(channel);
      addTearDown(server.shutdown);
      await server.initialize(
        InitializeRequest(
          protocolVersion: ProtocolVersion.latestSupported,
          capabilities: client.capabilities,
          clientInfo: client.implementation,
        ),
      );
      server.notifyInitialized();
      return server;
    }

    Future<List<String>> dartFindings(ServerConnection server) async {
      final result = await server.callTool(
        CallToolRequest(name: 'verify', arguments: const {'scope': 'fast'}),
      );
      expect(result.isError, isNot(isTrue), reason: '${result.content}');
      return [
        for (final finding in result.structuredContent!['findings']! as List)
          if (finding case {
            'id': final String id,
            'file': final String file,
          } when id.startsWith('dart.'))
            '$id $file',
      ];
    }

    File broken() =>
        File(p.join(project, 'lib', 'my folder', 'broken.dart'))
          ..parent.createSync(recursive: true);

    test(
      'starting the command starts no analysis server; the first verify '
      'call starts one, the next uses it and reports an edit; when the '
      'client closes, the command ends and the server and its guard are '
      'gone',
      () => withChildProcessesToItself(() async {
        final before = await childProcesses();
        Future<Map<int, String>> started() async =>
            (await childProcesses())
              ..removeWhere((id, _) => before.containsKey(id));
        broken().writeAsStringSync('/// Wrong.\nint wrong() => \'text\';\n');

        final controller = StreamChannelController<String>();
        final exit = runAppstein(
          ['mcp'],
          out: out,
          err: err,
          environment: machine(),
          mcpChannel: () => controller.local,
          dartSdkPath: testDartSdk,
        );
        final server = await connect(controller.foreign);
        await server.callTool(
          CallToolRequest(name: 'overview', arguments: const {}),
        );
        expect(await started(), isEmpty, reason: 'before any verify call');

        expect(await dartFindings(server), [
          'dart.error lib/my folder/broken.dart',
        ]);
        final guards = await started();
        expect(guards, hasLength(1), reason: '$guards');
        final guard = guards.keys.single;
        final under = await processesUnder(guard);
        expect(under, isNotEmpty, reason: 'the guard has no analysis server');
        await recordProcesses([guard, ...under]);

        // An edit, and a call at once: the same guard, and so the same server.
        broken().writeAsStringSync('/// Right.\nint right() => 1;\n');
        expect(await dartFindings(server), isEmpty);
        expect((await started()).keys, [guard]);
        expect(await processesUnder(guard), under);

        await server.shutdown();
        expect(await exit, ExitCodes.ok);
        // The command returned only after both had ended.
        expect(await processAlive(guard), isFalse);
        for (final id in under) {
          expect(await processAlive(id), isFalse, reason: 'process $id');
        }
        expect(await started(), isEmpty);
        expect(out.toString(), isEmpty);
      }),
      timeout: const Timeout(Duration(minutes: 10)),
    );

    /// `appstein mcp` in a process of its own, after one `verify` call: the
    /// process that serves, every process under the one that was started,
    /// and the connection.
    Future<
      ({Process process, int serving, Set<int> under, ServerConnection server})
    >
    serveInAProcess() async {
      broken().writeAsStringSync('/// Wrong.\nint wrong() => \'text\';\n');
      final package = p.dirname(
        p.dirname(
          Isolate.resolvePackageUriSync(
            Uri.parse('package:appstein_cli/appstein_cli.dart'),
          )!.toFilePath(),
        ),
      );
      final process = await Process.start(Platform.resolvedExecutable, [
        p.join(package, 'test', 'support', 'mcp_process.dart'),
        project,
        sdk,
        testDartSdk,
      ], workingDirectory: package);
      final recorded = <int>{process.pid};
      addTearDown(() async {
        // Only what this test started and recorded.
        for (final id in recorded) {
          if (await processAlive(id)) {
            Process.killPid(id, ProcessSignal.sigkill);
          }
        }
      });
      final named = Completer<int>();
      final errors = StringBuffer();
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (!named.isCompleted && line.startsWith('serving ')) {
              named.complete(int.parse(line.substring('serving '.length)));
            } else {
              errors.writeln(line);
            }
          });
      final outgoing = StreamController<String>();
      unawaited(
        outgoing.stream
            .map<List<int>>((message) => utf8.encode('$message\n'))
            .pipe(process.stdin)
            .catchError((Object _) {}),
      );
      final server = await connect(
        StreamChannel(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
          outgoing.sink,
        ),
      );
      final serving = await named.future.timeout(const Duration(minutes: 1));
      recorded.add(serving);
      expect(
        await processesUnder(serving),
        isEmpty,
        reason: 'a process was started before any verify call\n$errors',
      );
      expect(await dartFindings(server), [
        'dart.error lib/my folder/broken.dart',
      ], reason: '$errors');
      final under = await processesUnder(process.pid);
      recorded.addAll(under);
      await recordProcesses(recorded);
      // The guard and the analysis server, at least.
      expect(
        under.difference({serving}).length,
        greaterThanOrEqualTo(2),
        reason: '$under\n$errors',
      );
      return (process: process, serving: serving, under: under, server: server);
    }

    test(
      'in a process of its own: when its input closes, it exits 0 and the '
      'guard and the analysis server are gone',
      () => withChildProcessesToItself(() async {
        final (:process, serving: _, :under, :server) = await serveInAProcess();
        // A second call, at once after an edit, is answered by the same
        // processes.
        broken().writeAsStringSync('/// Right.\nint right() => 1;\n');
        expect(await dartFindings(server), isEmpty);
        expect(await processesUnder(process.pid), containsAll(under));
        await server.shutdown();
        expect(
          await process.exitCode.timeout(const Duration(seconds: 30)),
          ExitCodes.ok,
        );
        expect(
          await survivorsAfter(under, const Duration(seconds: 5)),
          isEmpty,
          reason: 'what outlived `appstein mcp` (of $under)',
        );
      }),
      timeout: const Timeout(Duration(minutes: 10)),
    );

    test(
      'in a process of its own: when it is killed, the guard and the '
      'analysis server are gone within a few seconds',
      () => withChildProcessesToItself(() async {
        final (:process, :serving, :under, server: _) = await serveInAProcess();
        // The process this test started, which said it serves.
        Process.killPid(serving, ProcessSignal.sigkill);
        process.kill(ProcessSignal.sigkill);
        expect(
          await survivorsAfter(under, const Duration(seconds: 10)),
          isEmpty,
          reason: 'what outlived the killed `appstein mcp` (of $under)',
        );
      }),
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });

  group('mcpSyncFactory', () {
    test('never runs package skills and shares one held cache', () {
      final held = HeldAnalyzerCache();
      final syncFor = mcpSyncFactory(
        projectRoot: project,
        environment: machine(),
        held: held,
      );
      final first = syncFor();
      expect(first.packageSkills, isFalse);
      expect(first.heldCache, same(held));
      expect(syncFor().heldCache, same(held));
    });

    test('builds each KnowledgeSync from the current appstein.yaml', () {
      final syncFor = mcpSyncFactory(
        projectRoot: project,
        environment: machine(),
        held: HeldAnalyzerCache(),
      );
      expect(syncFor().baseline, const AppsteinConfig().delta.baseline);
      File(
        p.join(project, 'appstein.yaml'),
      ).writeAsStringSync('delta:\n  baseline: "3.40"\n');
      expect(syncFor().baseline, '3.40');
    });
  });
}
