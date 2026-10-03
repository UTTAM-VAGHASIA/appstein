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

import '../knowledge/support/hold_lock.dart';
import '../knowledge/support/sync_harness.dart';
import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import 'support/mcp_client.dart';
import 'support/mcp_support.dart';

void main() {
  late String sdk;
  late String app;
  late FakeProcessRunner runner;
  late KnowledgeSync Function() syncFor;

  setUp(() {
    sdk = fakeFlutter();
    app = copyFixtureApp();
    runner = FakeProcessRunner();
    syncFor = () => knowledgeSync(
      flutterRoot: sdk,
      runner: runner,
      packs: const [OfficialMvvmPack(), AndroidPack(), IosPack()],
      packageSkills: false,
    );
  });

  Future<ServerConnection> serve() async {
    final controller = StreamChannelController<String>();
    final server = AppsteinMcpServer(
      controller.local,
      projectRoot: app,
      syncFor: () => syncFor(),
      appsteinVersion: '0.1.0-dev',
      dartSdkPath: testDartSdk,
    );
    addTearDown(server.shutdown);
    return connectTo(controller.foreign);
  }

  Map<String, Object?> structured(CallToolResult result) {
    expect(result.isError, isNot(isTrue), reason: textOf(result));
    return result.structuredContent!;
  }

  test('lists the seven tools, each with an output schema', () async {
    final server = await serve();
    final tools = (await server.listTools()).tools;
    expect([for (final tool in tools) tool.name], mcpToolNames);
    for (final tool in tools) {
      expect(tool.outputSchema, isNotNull, reason: tool.name);
      expect(tool.description, isNotEmpty, reason: tool.name);
    }
  });

  test('the first call syncs a project never synced, the second finds it '
      'current', () async {
    final server = await serve();
    final first = structured(await call(server, 'overview'));
    expect(first['index'], startsWith('# fixture_app\n'));
    final freshness = first['freshness']! as Map<String, Object?>;
    expect(freshness['state'], 'rebuilt');
    expect(freshness['because'], contains('no sync has run here yet'));
    final second = structured(await call(server, 'overview'));
    expect(second['freshness'], {'state': 'current'});
    expect(second['summary'], isA<String>());
  });

  test('every tool answers and matches its output schema', () async {
    final server = await serve();
    final tools = {
      for (final tool in (await server.listTools()).tools) tool.name: tool,
    };
    const calls = {
      'overview': <String, Object?>{},
      'where_is': {'query': 'login screen'},
      'feature': {'name': 'auth/login'},
      'route': {'path': '/booking/42'},
      'check_api': {'name': 'WillPopScope'},
      'what_changed': <String, Object?>{},
      'toolchain': <String, Object?>{},
    };
    for (final MapEntry(key: tool, value: arguments) in calls.entries) {
      final result = await call(server, tool, arguments);
      final json = structured(result);
      // ObjectSchema is an extension type over the schema's JSON map.
      expectMatchesSchema(
        tools[tool]!.outputSchema! as Map<String, Object?>,
        json,
      );
      // The schemas don't describe every nested object (toolchain's
      // `valid`), so a null there would pass them: check for it directly.
      expect(withoutNulls(json), json, reason: '$tool: a null slipped in');
      expect(result.content, hasLength(2), reason: tool);
      expect(textOf(result), startsWith(json['summary']! as String));
    }
    final whereIs = structured(
      await call(server, 'where_is', {'query': 'login screen'}),
    );
    expect(((whereIs['matches']! as List).first as Map)['name'], 'LoginScreen');
  });

  test('an edit is picked up before the next answer', () async {
    final server = await serve();
    await call(server, 'overview');
    File(
      p.join(app, 'lib', 'ui', 'home', 'widgets', 'extra_panel.dart'),
    ).writeAsStringSync('/// A panel.\nclass ExtraPanel {}\n');
    final json = structured(
      await call(server, 'where_is', {'query': 'extra panel'}),
    );
    expect(((json['matches']! as List).first as Map)['name'], 'ExtraPanel');
    final freshness = json['freshness']! as Map<String, Object?>;
    expect(freshness['state'], 'rebuilt');
    expect(
      freshness['changed'],
      contains('lib/ui/home/widgets/extra_panel.dart'),
    );
  });

  test('bad input is an error result the agent can read', () async {
    final server = await serve();
    final unknown = await call(server, 'feature', {'name': 'nope'});
    expect(unknown.isError, isTrue);
    expect(unknown.structuredContent, isNull);
    expect(textOf(unknown), startsWith('No feature is named "nope".'));
    final missing = await call(server, 'where_is');
    expect(missing.isError, isTrue);
    expect(missing.content, hasLength(1));
    expect(missing.structuredContent, isNull);
  });

  test('three calls at once are answered one after the other', () async {
    final server = await serve();
    final results = await Future.wait([
      call(server, 'overview'),
      call(server, 'where_is', {'query': 'booking'}),
      call(server, 'feature', {'name': 'home'}),
    ]);
    // One after the other, only the first finds nothing synced; at once,
    // all three would check before any had written, and each rebuild.
    expect(
      [
        for (final result in results)
          (structured(result)['freshness']! as Map)['state'],
      ],
      ['rebuilt', 'current', 'current'],
    );
  });

  test('a lock held by another process: it answers from disk, marked '
      'stale', () async {
    final server = await serve();
    await call(server, 'overview');
    syncFor = () => knowledgeSync(
      flutterRoot: sdk,
      runner: runner,
      packs: const [OfficialMvvmPack(), AndroidPack(), IosPack()],
      packageSkills: false,
      lockTimeout: const Duration(milliseconds: 500),
    );
    File(p.join(app, 'lib', 'extra.dart')).writeAsStringSync('int x = 1;\n');
    await holdLock(p.join(app, '.appstein'), 60000);
    final json = structured(await call(server, 'overview'));
    expect(json['freshness'], {
      'state': 'stale',
      'problem': 'another sync is running and holds the lock',
    });
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('no Flutter SDK and no knowledge: an error that says what to '
      'do', () async {
    syncFor = () => knowledgeSync(
      flutterRoot: p.join(app, 'no flutter here'),
      runner: runner,
      packageSkills: false,
    );
    final server = await serve();
    final result = await call(server, 'overview');
    expect(result.isError, isTrue);
    expect(textOf(result), contains('`.appstein/INDEX.md` is missing'));
    expect(textOf(result), contains('The knowledge may be stale:'));
  });

  test('a failing sync after a good one: answers from disk, marked '
      'stale', () async {
    final server = await serve();
    await call(server, 'overview');
    syncFor = () => throw StateError('boom');
    final json = structured(await call(server, 'feature', {'name': 'home'}));
    expect(json['freshness'], containsPair('state', 'stale'));
    expect(
      (json['freshness']! as Map)['problem'],
      'the sync failed unexpectedly: Bad state: boom',
    );
  });

  test('a damaged map file is refused with its name', () async {
    final server = await serve();
    await call(server, 'overview');
    syncFor = () => throw StateError('no sync');
    File(
      p.join(app, '.appstein', 'map', 'features.json'),
    ).writeAsStringSync('{"features": 3}');
    final result = await call(server, 'feature', {'name': 'home'});
    expect(result.isError, isTrue);
    expect(
      textOf(result),
      startsWith('`.appstein/map/features.json` is damaged ('),
    );
  });

  test('a sync that finds no SDK after a good one: answers from disk, '
      'marked stale with its problem and what to do', () async {
    final server = await serve();
    await call(server, 'overview');
    syncFor = () => throw const SyncException(
      'No Flutter SDK was found',
      'Install Flutter or set FLUTTER_ROOT.',
    );
    final result = await call(server, 'feature', {'name': 'home'});
    final json = structured(result);
    expect(json['name'], 'home');
    expect(json['freshness'], {
      'state': 'stale',
      'problem': 'No Flutter SDK was found',
      'fixHint': 'Install Flutter or set FLUTTER_ROOT.',
    });
    expect(
      textOf(result),
      endsWith(
        'The knowledge may be stale: No Flutter SDK was found. '
        'Install Flutter or set FLUTTER_ROOT.',
      ),
    );
  });

  test('an invalid appstein.yaml while building the sync: answers from '
      'disk, marked stale, naming the file', () async {
    final server = await serve();
    await call(server, 'overview');
    syncFor = () => throw ConfigException(
      '`delta.baseline` must be a Flutter version such as 3.16.',
      sourcePath: 'appstein.yaml',
      line: 3,
      column: 5,
    );
    final json = structured(await call(server, 'feature', {'name': 'home'}));
    expect(json['name'], 'home');
    expect(json['freshness'], {
      'state': 'stale',
      'problem':
          'appstein.yaml is invalid: appstein.yaml:3:5: `delta.baseline` '
          'must be a Flutter version such as 3.16.',
      'fixHint': 'Fix appstein.yaml; the next call syncs again.',
    });
  });
}
