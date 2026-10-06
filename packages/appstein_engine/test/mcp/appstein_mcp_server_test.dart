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
      clock: () => DateTime(2026, 10, 6, 23, 59),
    );
    addTearDown(server.shutdown);
    return connectTo(controller.foreign);
  }

  Map<String, Object?> structured(CallToolResult result) {
    expect(result.isError, isNot(isTrue), reason: textOf(result));
    return result.structuredContent!;
  }

  test('lists the twelve tools, each with an output schema', () async {
    final server = await serve();
    final tools = (await server.listTools()).tools;
    expect([for (final tool in tools) tool.name], mcpToolNames);
    expect(tools, hasLength(12));
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
      'record_decision': {
        'title': 'Routing with go_router',
        'why': 'Deep links.',
        'status': 'accepted',
        'paths': ['lib/routing/**'],
        'checks': ['paths.exist'],
      },
      'decisions': {'topic': 'routing'},
      'memory_write': {'kind': 'current', 'text': '# Goal\nShip it.'},
      'memory_read': <String, Object?>{},
      'verify': {'scope': 'full'},
    };
    expect(calls.keys, unorderedEquals(mcpToolNames));
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
      // `verify`'s `summary` is its counts (spec §9.3); its sentence is in
      // the text only.
      if (tool == 'verify') {
        expect(textOf(result), startsWith('Full verify: '));
      } else {
        expect(textOf(result), startsWith(json['summary']! as String));
      }
    }
    final whereIs = structured(
      await call(server, 'where_is', {'query': 'login screen'}),
    );
    expect(((whereIs['matches']! as List).first as Map)['name'], 'LoginScreen');
  });

  group('decisions and memory', () {
    String index(Map<String, Object?> overview) => overview['index']! as String;

    test('a recorded decision is in INDEX.md when the reply arrives, dated '
        "by the server's clock", () async {
      final server = await serve();
      await call(server, 'overview');
      final recorded = structured(
        await call(server, 'record_decision', {
          'title': 'State management with provider',
          'why': 'One stack pack keeps checks exact.',
        }),
      );
      const file = '.appstein/decisions/0001-state-management-with-provider.md';
      expect((recorded['decision']! as Map)['file'], file);
      expect((recorded['decision']! as Map)['date'], '2026-10-06');
      // The reply states the freshness after the write: what the write
      // changed was rebuilt.
      final freshness = recorded['freshness']! as Map<String, Object?>;
      expect(freshness['state'], 'rebuilt');
      // INDEX.md on disk already lists it, before any other call.
      expect(
        File(p.join(app, '.appstein', 'INDEX.md')).readAsStringSync(),
        contains(
          '- 0001 State management with provider (proposed): '
          '[0001-state-management-with-provider.md]',
        ),
      );
      final overview = structured(await call(server, 'overview'));
      expect(overview['freshness'], {'state': 'current'});
      expect(index(overview), contains('State management with provider'));
      expect(
        index(overview),
        contains('with `record_decision()`, and keep the task'),
      );
    });

    test('accept, then replace, through the server', () async {
      final server = await serve();
      await call(server, 'record_decision', {'title': 'Use dio', 'why': 'x'});
      final accepted = structured(
        // A number as a number: the schema lets it through to the tool.
        await call(server, 'record_decision', {'accept': 1}),
      );
      expect(accepted['action'], 'accepted');
      final replaced = structured(
        await call(server, 'record_decision', {
          'title': 'Use package http',
          'why': 'Fewer dependencies.',
          'status': 'accepted',
          'supersedes': '0001',
        }),
      );
      expect(replaced['action'], 'replaced');
      final all = structured(await call(server, 'decisions'));
      expect(
        [for (final one in all['decisions']! as List) (one as Map)['number']],
        ['0002'],
      );
      expect(all['superseded'], 1);
      final overview = structured(await call(server, 'overview'));
      expect(index(overview), contains('- 0002 Use package http (accepted)'));
      expect(index(overview), isNot(contains('Use dio')));
    });

    test('decisions for a file path', () async {
      final server = await serve();
      await call(server, 'record_decision', {
        'title': 'View models extend ChangeNotifier',
        'why': 'The pack checks it.',
        'paths': ['lib/ui/**/view_models/**'],
      });
      final covering = structured(
        await call(server, 'decisions', {
          'topic': r'lib\ui\home\view_models\home_viewmodel.dart',
        }),
      );
      expect(covering['mode'], 'path');
      expect((covering['decisions']! as List), hasLength(1));
    });

    test('the task in progress shows in INDEX.md, and finishing it clears '
        'it and keeps the lesson', () async {
      final server = await serve();
      await call(server, 'memory_write', {
        'kind': 'current',
        'text': '# Goal\nShip favorites.',
      });
      var overview = structured(await call(server, 'overview'));
      expect(overview['freshness'], {'state': 'current'});
      expect(index(overview), contains('> # Goal\n> Ship favorites.'));
      final done = structured(
        await call(server, 'memory_write', {
          'kind': 'complete',
          'text': 'Favorites shipped.',
        }),
      );
      expect(done['lesson'], '- 2026-10-06: Favorites shipped.');
      overview = structured(await call(server, 'overview'));
      expect(
        index(overview),
        contains('## Current work\n\nNone recorded yet.'),
      );
      final memory = structured(await call(server, 'memory_read'));
      expect(memory.containsKey('current'), isFalse);
      expect(memory['lessons'], ['2026-10-06: Favorites shipped.']);
    });

    test('a refused write is an error result that states the freshness, and '
        'writes nothing', () async {
      final server = await serve();
      await call(server, 'overview');
      final refused = await call(server, 'record_decision', {'accept': '7'});
      expect(refused.isError, isTrue);
      expect(refused.structuredContent, isNull);
      expect(
        textOf(refused),
        'No decision is numbered 0007. The knowledge was current.',
      );
      expect(
        Directory(p.join(app, '.appstein', 'decisions')).existsSync(),
        isFalse,
      );
      final badKind = await call(server, 'memory_write', {
        'kind': 'note',
        'text': 'x',
      });
      expect(badKind.isError, isTrue);
    });
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
    // An error has no structured content, so its text says how fresh the
    // knowledge was: rebuilt by this first call, current on the next.
    expect(
      textOf(unknown),
      endsWith('The knowledge was rebuilt first (no sync has run here yet).'),
    );
    expect(
      textOf(await call(server, 'feature', {'name': 'nope'})),
      endsWith(' The knowledge was current.'),
    );
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

  group('verify', () {
    List<String> ids(Map<String, Object?> json) => [
      for (final finding in json['findings']! as List)
        (finding as Map)['id']! as String,
    ];

    test('full: the findings of the project, with counts and '
        'freshness', () async {
      final server = await serve();
      final result = await call(server, 'verify', {'scope': 'full'});
      final json = structured(result);
      expect(ids(json).where((id) => id == 'docs.stale'), hasLength(11));
      expect(
        ids(json).where((id) => id == 'verify.test_required'),
        hasLength(3),
      );
      expect(json['findings'], hasLength(14));
      expect(json['summary'], {'errors': 0, 'warnings': 14, 'info': 0});
      expect(json['suppressed'], 0);
      expect(json['notRun'], isEmpty);
      expect((json['freshness']! as Map)['state'], 'rebuilt');
      expect(
        textOf(result),
        startsWith('Full verify: 0 errors, 14 warnings, 0 info. '),
      );
      // It reads like `appstein verify --format json`.
      expect(VerifyResult.fromJson(json).warnings, 14);
    });

    test('fast: no full check runs', () async {
      final server = await serve();
      final result = await call(server, 'verify', {'scope': 'fast'});
      final json = structured(result);
      expect(json['findings'], isEmpty);
      expect(json['notRun'], isEmpty);
      expect(
        textOf(result),
        startsWith('Fast verify: 0 errors, 0 warnings, 0 info. '),
      );
    });

    test('it reads `appstein.yaml`: a suppression hides a finding', () async {
      File(p.join(app, 'appstein.yaml')).writeAsStringSync(
        'appstein: 1\n'
        'docs:\n'
        '  enabled: false\n'
        'suppressions:\n'
        '  - id: verify.test_required\n'
        '    path: lib/ui/profile\n'
        '    reason: covered by the integration tests\n',
      );
      final server = await serve();
      final json = structured(await call(server, 'verify', {'scope': 'full'}));
      expect(ids(json), ['verify.test_required', 'verify.test_required']);
      expect(json['suppressed'], 1);
    });

    test('a scope that is missing or wrong is refused before the tool '
        'runs', () async {
      var syncs = 0;
      final inner = syncFor;
      syncFor = () {
        syncs++;
        return inner();
      };
      final server = await serve();
      for (final arguments in [
        <String, Object?>{},
        {'scope': 'all'},
      ]) {
        final result = await call(server, 'verify', arguments);
        expect(result.isError, isTrue, reason: '$arguments');
        expect(result.structuredContent, isNull);
      }
      expect(syncs, 0);
    });

    test('knowledge that cannot be refreshed is a finding, not an error '
        'reply; the sync is built once', () async {
      var syncs = 0;
      syncFor = () {
        syncs++;
        return knowledgeSync(
          flutterRoot: p.join(app, 'no flutter here'),
          runner: runner,
          packs: const [OfficialMvvmPack(), AndroidPack(), IosPack()],
          packageSkills: false,
        );
      };
      final server = await serve();
      final result = await call(server, 'verify', {'scope': 'full'});
      final json = structured(result);
      expect(ids(json), ['knowledge.stale']);
      expect(json['summary'], {'errors': 1, 'warnings': 0, 'info': 0});
      expect(
        [for (final check in json['notRun']! as List) (check as Map)['id']],
        ['docs.stale', 'verify.test_required'],
      );
      final freshness = json['freshness']! as Map<String, Object?>;
      expect(freshness['state'], 'stale');
      // The finding states the problem the freshness check found.
      expect(
        ((json['findings']! as List).single as Map)['message'],
        contains(freshness['problem']),
      );
      expect(
        textOf(result),
        contains(
          '2 checks did not run. Fix the error before the task is done.',
        ),
      );
      expect(syncs, 1);
    });

    test('an invalid appstein.yaml is an error reply that names it', () async {
      final server = await serve();
      await call(server, 'overview');
      File(p.join(app, 'appstein.yaml')).writeAsStringSync('appstein: 99\n');
      final result = await call(server, 'verify', {'scope': 'full'});
      expect(result.isError, isTrue);
      expect(result.structuredContent, isNull);
      expect(
        textOf(result),
        startsWith('The checks could not run: appstein.yaml is invalid: '),
      );
    });

    test('a sync that cannot be built is an error reply that says '
        'why', () async {
      final server = await serve();
      await call(server, 'overview');
      syncFor = () => throw ConfigException(
        '`delta.baseline` must be a Flutter version such as 3.16.',
        sourcePath: 'appstein.yaml',
        line: 3,
        column: 5,
      );
      final result = await call(server, 'verify', {'scope': 'fast'});
      expect(result.isError, isTrue);
      expect(textOf(result), startsWith('The checks could not run. '));
      expect(textOf(result), contains('appstein.yaml is invalid: '));
      expect(textOf(result), contains('`delta.baseline` must be'));
    });
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
