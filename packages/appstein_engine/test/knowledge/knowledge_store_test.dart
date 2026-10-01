import 'dart:async';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  late String project;
  late File sdkJson;

  setUp(() {
    project = tempDir().path;
    sdkJson = File(p.join(project, '.appstein', 'platform', 'sdk.json'));
  });

  KnowledgeStore storeAt(DateTime time) =>
      KnowledgeStore(project, clock: () => time);

  Future<bool> write(KnowledgeStore store, String hash) => store.writeGenerated(
    'platform/sdk.json',
    {'flutter': '3.47.5'},
    inputHash: hash,
    appsteinVersion: '0.1.0-dev',
    sdkVersion: '3.47.5',
  );

  test('writes canonical JSON with its meta, creating folders', () async {
    final wrote = await write(
      storeAt(DateTime.utc(2026, 10, 1, 9, 30, 5)),
      'h1',
    );
    expect(wrote, isTrue);
    expect(
      sdkJson.readAsStringSync(),
      '{\n'
      '  "flutter": "3.47.5",\n'
      '  "meta": {\n'
      '    "appsteinVersion": "0.1.0-dev",\n'
      '    "formatVersion": 1,\n'
      '    "generatedAt": "2026-10-01T09:30:05Z",\n'
      '    "inputHash": "h1",\n'
      '    "sdkVersion": "3.47.5"\n'
      '  }\n'
      '}\n',
    );
    expect(File('${sdkJson.path}.tmp').existsSync(), isFalse);
  });

  test('skips a file whose input hash is unchanged, so no byte changes '
      '(spec §6.2)', () async {
    await write(storeAt(DateTime.utc(2026, 10, 1)), 'h1');
    final before = sdkJson.readAsStringSync();
    final wrote = await write(storeAt(DateTime.utc(2026, 10, 2)), 'h1');
    expect(wrote, isFalse);
    expect(sdkJson.readAsStringSync(), before);
  });

  test('rewrites a file whose input hash changed', () async {
    await write(storeAt(DateTime.utc(2026, 10, 1)), 'h1');
    final wrote = await write(storeAt(DateTime.utc(2026, 10, 2)), 'h2');
    expect(wrote, isTrue);
    expect(sdkJson.readAsStringSync(), contains('"inputHash": "h2"'));
    expect(sdkJson.readAsStringSync(), contains('2026-10-02T00:00:00Z'));
  });

  for (final damaged in ['not json', '[]', '{"flutter": 1}', '{"meta": 3}']) {
    test('rewrites a damaged file: $damaged', () async {
      sdkJson.parent.createSync(recursive: true);
      sdkJson.writeAsStringSync(damaged);
      expect(await write(storeAt(DateTime.utc(2026, 10, 1)), 'h1'), isTrue);
      expect(sdkJson.readAsStringSync(), contains('"inputHash": "h1"'));
    });
  }

  test('puts back a file whose body was hand-edited but whose meta is '
      'intact (spec §6.2)', () async {
    await write(storeAt(DateTime.utc(2026, 10, 1)), 'h1');
    final original = sdkJson.readAsStringSync();
    sdkJson.writeAsStringSync(
      original.replaceFirst('"flutter": "3.47.5"', '"flutter": "9.9.9"'),
    );
    final wrote = await write(storeAt(DateTime.utc(2026, 10, 2)), 'h1');
    expect(wrote, isTrue);
    // The body is restored, with the time of the rewrite.
    expect(
      sdkJson.readAsStringSync(),
      original.replaceFirst('2026-10-01T', '2026-10-02T'),
    );
  });

  test('puts back a file that differs only in formatting', () async {
    await write(storeAt(DateTime.utc(2026, 10, 1)), 'h1');
    final original = sdkJson.readAsStringSync();
    sdkJson.writeAsStringSync(original.replaceAll('  ', '    '));
    final wrote = await write(storeAt(DateTime.utc(2026, 10, 2)), 'h1');
    expect(wrote, isTrue);
    expect(
      sdkJson.readAsStringSync(),
      original.replaceFirst('2026-10-01T', '2026-10-02T'),
    );
  });

  test('a body may not carry its own meta', () {
    expect(
      () => storeAt(DateTime.utc(2026)).writeGenerated(
        'platform/sdk.json',
        {'meta': 1},
        inputHash: 'h',
        appsteinVersion: 'v',
        sdkVersion: 's',
      ),
      throwsArgumentError,
    );
  });

  test('writes state.json as canonical JSON', () async {
    await storeAt(DateTime.utc(2026)).writeState(
      const KnowledgeState(
        formatVersion: 1,
        appsteinVersion: '0.1.0-dev',
        lastSync: '2026-10-01T00:00:00Z',
        files: {'platform/sdk.json': 'h1'},
      ),
    );
    expect(
      File(p.join(project, '.appstein', 'state.json')).readAsStringSync(),
      '{\n'
      '  "appsteinVersion": "0.1.0-dev",\n'
      '  "files": {\n'
      '    "platform/sdk.json": "h1"\n'
      '  },\n'
      '  "formatVersion": 1,\n'
      '  "lastSync": "2026-10-01T00:00:00Z"\n'
      '}\n',
    );
  });

  test('now() is the clock in the .appstein/ time format', () {
    expect(
      storeAt(DateTime.utc(2026, 10, 1, 9, 30, 5)).now(),
      '2026-10-01T09:30:05Z',
    );
  });

  group('Markdown files', () {
    File deltaFile() =>
        File(p.join(project, '.appstein', 'platform', 'delta.md'));

    Future<bool> writeMarkdown(
      KnowledgeStore store,
      String hash, {
      String text = '# Delta\n\nBody.\n',
    }) => store.writeGeneratedMarkdown(
      'platform/delta.md',
      text,
      inputHash: hash,
      appsteinVersion: '0.1.0-dev',
      sdkVersion: '3.47.5',
    );

    test('writes the text after front matter, creating folders', () async {
      final wrote = await writeMarkdown(
        storeAt(DateTime.utc(2026, 10, 1, 9, 30, 5)),
        'h1',
      );
      expect(wrote, isTrue);
      expect(
        deltaFile().readAsStringSync(),
        '---\n'
        'appsteinVersion: "0.1.0-dev"\n'
        'formatVersion: 1\n'
        'generatedAt: "2026-10-01T09:30:05Z"\n'
        'inputHash: "h1"\n'
        'sdkVersion: "3.47.5"\n'
        '---\n'
        '\n'
        '# Delta\n'
        '\n'
        'Body.\n',
      );
    });

    test('skips unchanged Markdown, so no byte changes', () async {
      await writeMarkdown(storeAt(DateTime.utc(2026, 10, 1)), 'h1');
      final before = deltaFile().readAsStringSync();
      final wrote = await writeMarkdown(
        storeAt(DateTime.utc(2026, 10, 2)),
        'h1',
      );
      expect(wrote, isFalse);
      expect(deltaFile().readAsStringSync(), before);
    });

    test('rewrites Markdown whose input hash changed', () async {
      await writeMarkdown(storeAt(DateTime.utc(2026, 10, 1)), 'h1');
      final wrote = await writeMarkdown(
        storeAt(DateTime.utc(2026, 10, 2)),
        'h2',
      );
      expect(wrote, isTrue);
      expect(deltaFile().readAsStringSync(), contains('inputHash: "h2"'));
      expect(deltaFile().readAsStringSync(), contains('2026-10-02T00:00:00Z'));
    });

    test(
      'puts back hand-edited Markdown whose front matter is intact',
      () async {
        await writeMarkdown(storeAt(DateTime.utc(2026, 10, 1)), 'h1');
        final original = deltaFile().readAsStringSync();
        deltaFile().writeAsStringSync(
          original.replaceFirst('Body.', 'Edited.'),
        );
        final wrote = await writeMarkdown(
          storeAt(DateTime.utc(2026, 10, 2)),
          'h1',
        );
        expect(wrote, isTrue);
        expect(
          deltaFile().readAsStringSync(),
          original.replaceFirst('2026-10-01T', '2026-10-02T'),
        );
      },
    );

    for (final damaged in ['no front matter\n', '---\n---\n', '']) {
      test('rewrites a damaged Markdown file: ${damaged.trim()}', () async {
        deltaFile()
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(damaged);
        expect(
          await writeMarkdown(storeAt(DateTime.utc(2026, 10, 1)), 'h1'),
          isTrue,
        );
        expect(deltaFile().readAsStringSync(), contains('inputHash: "h1"'));
      });
    }

    test('writeAll writes JSON and Markdown files and lists both in '
        'state.json', () async {
      final store = storeAt(DateTime.utc(2026, 10, 1));
      final written = await store.writeAll(
        const [
          GeneratedFile(
            path: 'platform/sdk.json',
            body: {'flutter': '3.47.5'},
            inputHash: 'h1',
          ),
          GeneratedFile.markdown(
            path: 'platform/delta.md',
            markdown: '# Delta\n',
            inputHash: 'h2',
          ),
        ],
        appsteinVersion: '0.1.0-dev',
        sdkVersion: '3.47.5',
      );
      expect(written, {'platform/sdk.json': true, 'platform/delta.md': true});
      expect(readFrontMatter(deltaFile().readAsStringSync())!.inputHash, 'h2');
      expect(
        File(p.join(project, '.appstein', 'state.json')).readAsStringSync(),
        contains('"platform/delta.md": "h2"'),
      );
    });
  });

  test('locked() runs the action under the lock and releases it', () async {
    final store = storeAt(DateTime.utc(2026));
    expect(await store.locked(() async => 42), 42);
    final lock = await KnowledgeLock.acquire(
      store.folder,
      timeout: const Duration(seconds: 1),
    );
    lock.release();
  });

  test('locked() releases the lock when the action throws', () async {
    final store = storeAt(DateTime.utc(2026));
    await expectLater(
      store.locked<void>(() async => throw StateError('boom')),
      throwsStateError,
    );
    final lock = await KnowledgeLock.acquire(
      store.folder,
      timeout: const Duration(seconds: 1),
    );
    lock.release();
  });

  group('replaceFile', () {
    test('replaces a file another handle has open once it is closed '
        '(Windows refuses while it is open)', () async {
      final target = File(p.join(project, 'target.json'))
        ..writeAsStringSync('old');
      final reader = target.openSync();
      Timer(const Duration(milliseconds: 300), reader.closeSync);
      await replaceFile(target.path, 'new');
      expect(target.readAsStringSync(), 'new');
    });

    test('gives up after retryFor with a clear message', () async {
      final target = File(p.join(project, 'target.json'))
        ..writeAsStringSync('old');
      final reader = target.openSync();
      addTearDown(reader.closeSync);
      await expectLater(
        replaceFile(
          target.path,
          'new',
          retryFor: const Duration(milliseconds: 100),
        ),
        throwsA(
          isA<KnowledgeWriteException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains(target.path), contains('open')),
          ),
        ),
      );
      expect(File('${target.path}.tmp').existsSync(), isFalse);
    }, testOn: 'windows');

    test('reports a parent that is a file', () async {
      File(p.join(project, 'blocker')).writeAsStringSync('');
      await expectLater(
        replaceFile(p.join(project, 'blocker', 'x.json'), '{}'),
        throwsA(isA<KnowledgeWriteException>()),
      );
    });
  });
}
