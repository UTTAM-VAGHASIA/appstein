import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  late String root;

  setUp(() => root = tempDir().path);

  void write(String path, String text) =>
      File(p.joinAll([root, '.appstein', ...path.split('/')]))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(text);

  test('reads INDEX.md without its front matter, with its generatedAt', () {
    write(
      'INDEX.md',
      '---\nappsteinVersion: "0.1.0-dev"\nformatVersion: 1\n'
          'generatedAt: "2026-10-01T09:00:00Z"\ninputHash: "h"\n'
          'sdkVersion: "3.47.5"\n---\n\n# fixture_app\n\nText.\n',
    );
    final index = KnowledgeSnapshot(root).index.value!;
    expect(index.body, '# fixture_app\n\nText.\n');
    expect(index.generatedAt, '2026-10-01T09:00:00Z');
  });

  test('reads sdk.json and deps.json', () {
    write(
      'platform/sdk.json',
      '{"flutter": "3.47.5", "dart": "3.13.4", "channel": "stable", '
          '"languageVersion": "3.12", "fvm": null}',
    );
    write(
      'map/deps.json',
      '{"packages": {"go_router": {"constraint": "^18.0.0", "version": '
          '"18.1.0", "dependency": "direct main", "source": "hosted", '
          '"usages": ["lib/routing/router.dart"]}}}',
    );
    final snapshot = KnowledgeSnapshot(root);
    expect(snapshot.sdk.value!.flutterVersion, '3.47.5');
    expect(snapshot.deps.value!.packages['go_router']!.version, '18.1.0');
  });

  test('a missing or damaged sdk.json or deps.json is a problem', () {
    expect(
      KnowledgeSnapshot(root).sdk.problem,
      '`.appstein/platform/sdk.json` is missing',
    );
    expect(
      KnowledgeSnapshot(root).deps.problem,
      '`.appstein/map/deps.json` is missing',
    );
    write('platform/sdk.json', '{"flutter": 3}');
    write('map/deps.json', '[]');
    expect(
      KnowledgeSnapshot(root).sdk.problem,
      startsWith('`.appstein/platform/sdk.json` is damaged ('),
    );
    expect(
      KnowledgeSnapshot(root).deps.problem,
      startsWith('`.appstein/map/deps.json` is damaged ('),
    );
  });

  test('a missing file is a problem that names it', () {
    final read = KnowledgeSnapshot(root).features;
    expect(read.value, isNull);
    expect(read.problem, '`.appstein/map/features.json` is missing');
  });

  test('a damaged file is a problem that says why', () {
    write('map/features.json', '{"features": 3}');
    expect(
      KnowledgeSnapshot(root).features.problem,
      startsWith('`.appstein/map/features.json` is damaged ('),
    );
    write('map/routes.json', 'not json');
    expect(
      KnowledgeSnapshot(root).routes.problem,
      startsWith('`.appstein/map/routes.json` is damaged ('),
    );
  });

  test('a file that is not UTF-8 is damaged, not a crash', () {
    final file = File(p.joinAll([root, '.appstein', 'map', 'features.json']))
      ..parent.createSync(recursive: true);
    file.writeAsBytesSync([0xC3, 0x28]);
    expect(
      KnowledgeSnapshot(root).features.problem,
      startsWith('`.appstein/map/features.json` is damaged ('),
    );
  });

  test('INDEX.md without front matter is damaged', () {
    write('INDEX.md', '# Hand-written\n');
    expect(
      KnowledgeSnapshot(root).index.problem,
      '`.appstein/INDEX.md` is damaged (it has no front matter)',
    );
  });

  test('refusalFor gives the first problem, with what to do', () {
    write('map/symbols.json', '{"symbols": []}');
    final snapshot = KnowledgeSnapshot(root);
    expect(snapshot.refusalFor([snapshot.symbols]), isNull);
    expect(
      snapshot.refusalFor([snapshot.symbols, snapshot.routes])?.message,
      '`.appstein/map/routes.json` is missing, so this can\'t be answered '
      'yet. Run `appstein sync` in the project to see why.',
    );
  });
}
