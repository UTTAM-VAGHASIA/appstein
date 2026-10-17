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

import 'support/analysis_hosts.dart';
import 'support/child_processes.dart';
import 'support/dart_sdk.dart';
import 'support/fake_flutter_sdk.dart';
import 'support/scripted_code_analysis.dart';

void main() {
  late StringBuffer out;
  late StringBuffer err;
  late String project;
  late String sdk;
  late String cache;
  late String hosts;

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
    cache = testAnalysisCache();
    hosts = p.join(work.path, 'host folder');
    // Before the folders are deleted: no host a test started outlives it.
    addTearDown(() => killHost(hosts, project));
  });

  HostEnvironment machine({String? cwd}) => HostEnvironment(
    os: HostOs.current,
    variables: {
      'FLUTTER_ROOT': sdk,
      analysisCacheVariable: cache,
      analysisHostFolderVariable: hosts,
    },
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

  // Warm analysis with real processes (slice 1d.2, ticket 04; slice 1d.7,
  // ticket 02): the project's analysis host started as `dart
  // bin/appstein.dart analysis-host`, detached, its guard started as `dart
  // bin/appstein.dart analysis-server-guard`, and the analysis server of the
  // SDK that runs the tests. Each test's host has its own address-file
  // folder and cache folder, and is killed with what runs under it after
  // the test. Only processes these tests started are looked at or ended.
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

    /// The findings of a fast `verify` call, as JSON.
    Future<List<Object?>> verifyFindings(ServerConnection server) async {
      final result = await server.callTool(
        CallToolRequest(name: 'verify', arguments: const {'scope': 'fast'}),
      );
      expect(result.isError, isNot(isTrue), reason: '${result.content}');
      return result.structuredContent!['findings']! as List;
    }

    Future<List<String>> dartFindings(ServerConnection server) async => [
      for (final finding in await verifyFindings(server))
        if (finding case {
          'id': final String id,
          'file': final String file,
        } when id.startsWith('dart.'))
          '$id $file',
    ];

    /// Each `dart.` finding of [findings] whole: ID, file, line, severity
    /// and message.
    List<String> wholeDartFindings(List<Object?> findings) => [
      for (final finding in findings)
        if (finding case {'id': final String id} when id.startsWith('dart.'))
          [
            for (final key in ['id', 'file', 'line', 'severity', 'message'])
              '${(finding as Map)[key]}',
          ].join(' | '),
    ];

    File broken() =>
        File(p.join(project, 'lib', 'my folder', 'broken.dart'))
          ..parent.createSync(recursive: true);

    test(
      'starting the command starts no host; the first verify call starts '
      'one, the next uses it and reports an edit, and its findings equal a '
      "terminal run's; when the client closes, the command ends and the host "
      'keeps its server for the next session',
      () => withChildProcessesToItself(() async {
        final before = await childProcesses();
        Future<Map<int, String>> started() async =>
            (await childProcesses())
              ..removeWhere((id, _) => before.containsKey(id));
        // An error and a warning, so the comparison below has more than one
        // kind of finding to compare.
        broken().writeAsStringSync(
          '/// Wrong.\nint wrong() => \'text\';\n\n'
          '/// Unused.\nvoid unused() {\n  final left = 1;\n}\n',
        );

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
        expect(hostProcess(hosts, project), isNull);

        final first = wholeDartFindings(await verifyFindings(server));
        expect(first, contains(startsWith('dart.error | lib/my folder/')));
        expect(first, contains(startsWith('dart.warning | lib/my folder/')));
        final host = hostProcess(hosts, project);
        expect(host, isNotNull, reason: 'no address file');
        expect(await processAlive(host!), isTrue);
        final under = await processesUnder(host);
        // The guard and the analysis server, at least.
        expect(under.length, greaterThanOrEqualTo(2), reason: '$under');
        await recordProcesses([host, ...under]);

        // The same project state, checked by a terminal run.
        final terminal = StringBuffer();
        expect(
          await runAppstein(
            ['verify', '--fast', '--format', 'json'],
            out: terminal,
            err: err,
            environment: machine(),
            dartSdkPath: testDartSdk,
          ),
          ExitCodes.errorsFound,
          reason: '$err',
        );
        final ran = jsonDecode('$terminal') as Map<String, Object?>;
        // Every `dart.` finding whole, in the same order.
        expect(wholeDartFindings(ran['findings']! as List), first);

        // An edit, and a call at once: the same host, and so the same server.
        broken().writeAsStringSync('/// Right.\nint right() => 1;\n');
        expect(await dartFindings(server), isEmpty);
        expect(hostProcess(hosts, project), host);
        expect(await processesUnder(host), under);

        await server.shutdown();
        expect(await exit, ExitCodes.ok);
        // The host is no session's: it stays, with its server, until it has
        // been idle for ten minutes (the tear-down ends it).
        expect(await processAlive(host), isTrue);
        for (final id in under) {
          expect(await processAlive(id), isTrue, reason: 'process $id');
        }
        expect(out.toString(), isEmpty);
        // The server's cache is the folder the machine names, not the one
        // the machine shares.
        expect(
          Directory(p.join(cache, analysisDriverFolder)).existsSync(),
          isTrue,
        );
      }),
      timeout: const Timeout(Duration(minutes: 10)),
    );

    test(
      'an analysis server that cannot start in the host is an error reply '
      'that says to run appstein doctor, and the server keeps answering',
      () => withChildProcessesToItself(() async {
        broken().writeAsStringSync('/// Wrong.\nint wrong() => \'text\';\n');
        final controller = StreamChannelController<String>();
        final exit = runAppstein(
          ['mcp'],
          out: out,
          err: err,
          environment: machine(),
          mcpChannel: () => controller.local,
          dartSdkPath: p.join(project, 'no such sdk'),
        );
        final server = await connect(controller.foreign);
        final verified = await server.callTool(
          CallToolRequest(name: 'verify', arguments: const {'scope': 'fast'}),
        );
        expect(verified.isError, isTrue);
        final text = [
          for (final content in verified.content)
            if (content case TextContent(:final text)) text,
        ].join('\n');
        expect(text, contains('The Dart analysis server could not answer'));
        expect(text, contains('appstein doctor'));
        final overview = await server.callTool(
          CallToolRequest(name: 'overview', arguments: const {}),
        );
        expect(overview.isError, isNot(isTrue), reason: '${overview.content}');
        await server.shutdown();
        expect(await exit, ExitCodes.ok);
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
        cache,
        hosts,
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
      // The host it started: not under it, since it was started detached.
      final host = hostProcess(hosts, project);
      expect(host, isNotNull, reason: 'no address file\n$errors');
      final under = {host!, ...await processesUnder(host)};
      await recordProcesses([...recorded, ...under]);
      // The host, its guard and the analysis server, at least.
      expect(under.length, greaterThanOrEqualTo(3), reason: '$under\n$errors');
      return (process: process, serving: serving, under: under, server: server);
    }

    /// The `dart.` findings of a `verify` call of a new session's `appstein
    /// mcp`, in this process.
    Future<List<String>> anotherSession() async {
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
      final found = await dartFindings(server);
      await server.shutdown();
      expect(await exit, ExitCodes.ok);
      return found;
    }

    test(
      'in a process of its own: when its input closes, it exits 0, and the '
      'host it started serves the next session with the same server',
      () => withChildProcessesToItself(() async {
        final (:process, serving: _, :under, :server) = await serveInAProcess();
        await server.shutdown();
        expect(
          await process.exitCode.timeout(const Duration(seconds: 30)),
          ExitCodes.ok,
        );
        broken().writeAsStringSync('/// Right.\nint right() => 1;\n');
        expect(await anotherSession(), isEmpty);
        for (final id in under) {
          expect(await processAlive(id), isTrue, reason: 'process $id');
        }
        final host = hostProcess(hosts, project)!;
        expect({host, ...await processesUnder(host)}, under);
      }),
      timeout: const Timeout(Duration(minutes: 10)),
    );

    test(
      'in a process of its own: when it is killed, the host and its server '
      'keep running for the next session',
      () => withChildProcessesToItself(() async {
        final (:process, :serving, :under, server: _) = await serveInAProcess();
        // The process this test started, which said it serves.
        Process.killPid(serving, ProcessSignal.sigkill);
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 30));
        for (final id in under) {
          expect(await processAlive(id), isTrue, reason: 'process $id');
        }
        expect(await anotherSession(), [
          'dart.error lib/my folder/broken.dart',
        ]);
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
