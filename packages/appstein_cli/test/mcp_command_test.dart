import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:dart_mcp/client.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/fake_flutter_sdk.dart';

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
