import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/fake_sdk.dart';
import '../support/fixture_app.dart';
import '../support/flutter_fixtures.dart';
import '../support/temp.dart';

void main() {
  late String sdk;
  late FakeProcessRunner runner;

  setUp(() {
    sdk = createFakeSdk(p.join(tempDir().path, 'flutter'));
    addToolchainFiles(sdk, '3.47.5');
    runner = FakeProcessRunner();
  });

  String flutter() =>
      p.join(sdk, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter');

  KnowledgeSync sync({
    List<Pack> packs = const [OfficialMvvmPack()],
    String baseline = '3.16',
    DeltaCollector? deltaCollector,
  }) => KnowledgeSync(
    deltaCollector: deltaCollector,
    environment: fakeEnvironment({'FLUTTER_ROOT': sdk}),
    appsteinVersion: '0.1.0-dev',
    packs: packs,
    runner: runner,
    clock: () => DateTime.utc(2026, 10, 1, 9),
    baseline: baseline,
  );

  String delta(String project) => File(
    p.join(project, '.appstein', 'platform', 'delta.md'),
  ).readAsStringSync();

  Map<String, Object?> state(String project) =>
      jsonDecode(
            File(p.join(project, '.appstein', 'state.json')).readAsStringSync(),
          )
          as Map<String, Object?>;

  test('the first sync writes the platform layer and the five map files, '
      'which match the goldens', () async {
    final app = copyFixtureApp();
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.files, {
      'platform/sdk.json': true,
      'platform/toolchain.json': true,
      'platform/delta.md': true,
      for (final path in MapFiles.all) path: true,
    });
    expect(report.map!.packages, PackagesAction.upToDate);
    expect(report.map!.skipped, isNull);
    expect(runner.calls, isEmpty);
    for (final path in MapFiles.all) {
      final name = p.posix.basename(path);
      expectGolden(name, readMapBody(app, name));
    }
    expect(
      (state(app)['files']! as Map).keys,
      unorderedEquals([
        'platform/sdk.json',
        'platform/toolchain.json',
        'platform/delta.md',
        ...MapFiles.all,
      ]),
    );
    final meta = KnowledgeMeta.fromJson(
      (jsonDecode(
                File(
                  p.join(app, '.appstein', 'map', 'symbols.json'),
                ).readAsStringSync(),
              )
              as Map<String, Object?>)['meta']!
          as Map<String, Object?>,
    );
    expect(meta.sdkVersion, '3.47.5');
    expect(meta.generatedAt, '2026-10-01T09:00:00Z');
  });

  test('a second sync changes nothing', () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    final second = await sync().run(app, dartSdkPath: testDartSdk);
    expect(second.files.values, everyElement(isFalse));
  });

  test('stale packages are fetched with flutter pub get in the project '
      'first', () async {
    final app = copyFixtureApp();
    File(
      p.join(app, 'pubspec.yaml'),
    ).setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
    runner.when(flutter(), ['pub', 'get'], const RunResult(exitCode: 0));
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.map!.packages, PackagesAction.fetched);
    expect(
      report.map!.packagesReason,
      'pubspec.yaml changed after they were fetched',
    );
    expect(runner.calls, ['${flutter()} pub get']);
    expect(runner.workingDirectories, [app]);
    expect(report.files.keys, containsAll(MapFiles.all));
  });

  test('when pub get fails, the platform layer is written and the map is '
      'skipped', () async {
    final app = copyFixtureApp();
    File(p.join(app, '.dart_tool', 'package_config.json')).deleteSync();
    runner.when(flutter(), [
      'pub',
      'get',
    ], const RunResult(exitCode: 69, stderr: 'Could not reach pub.dev.'));
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.files.keys, [
      'platform/sdk.json',
      'platform/toolchain.json',
      'platform/delta.md',
    ]);
    expect(report.map!.packages, PackagesAction.fetchFailed);
    expect(report.map!.packagesReason, contains('Could not reach pub.dev.'));
    expect(report.map!.skipped, 'the packages could not be fetched');
    expect(Directory(p.join(app, '.appstein', 'map')).existsSync(), isFalse);
    expect((state(app)['files']! as Map).keys, [
      'platform/delta.md',
      'platform/sdk.json',
      'platform/toolchain.json',
    ]);
  });

  test('an incomplete Dart SDK skips the map, saying why', () async {
    final app = copyFixtureApp();
    final empty = Directory(p.join(tempDir().path, 'dart-sdk'))..createSync();
    final report = await sync().run(app, dartSdkPath: empty.path);
    expect(report.map!.skipped, contains('lib/core/core.dart'));
    expect(report.files.keys, isNot(contains(MapFiles.symbols)));
  });

  test('a project that is not official_mvvm still gets its map', () async {
    final project = p.join(tempDir().path, 'plain app');
    File(p.join(project, 'lib', 'plain.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync("/// Says hi.\nString hi() => 'hi';\n");
    File(
      p.join(project, 'pubspec.yaml'),
    ).writeAsStringSync('name: plain_app\nenvironment:\n  sdk: ^3.12.0\n');
    writeStubPackages(project);
    final report = await sync().run(project, dartSdkPath: testDartSdk);
    expect(report.map!.skipped, isNull);
    expect(readMapBody(project, 'features.json'), {
      'features': <String, Object?>{},
    });
    expect(readMapBody(project, 'routes.json'), {
      'routes': <Object>[],
      'routers': <Object>[],
    });
    expect(readMapBody(project, 'symbols.json'), {
      'symbols': [
        {
          'name': 'hi',
          'kind': 'function',
          'file': 'lib/plain.dart',
          'line': 2,
          'layer': null,
          'feature': null,
          'summary': 'Says hi.',
        },
      ],
    });
    expect(readMapBody(project, 'deps.json'), {
      'packages': <String, Object?>{},
    });
  });

  test('a hand-edited map file is put back, and only it', () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    File(
      p.join(app, '.appstein', 'map', 'routes.json'),
    ).writeAsStringSync('{}');
    final second = await sync().run(app, dartSdkPath: testDartSdk);
    expect(second.files[MapFiles.routes], isTrue);
    expect(
      {
        for (final MapEntry(:key, :value) in second.files.entries)
          if (key != MapFiles.routes) key: value,
      }.values,
      everyElement(isFalse),
    );
  });

  test('a corrupted pubspec.lock skips the map and keeps the old deps.json, '
      'saying why', () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    final depsFile = File(p.join(app, '.appstein', 'map', 'deps.json'));
    final before = depsFile.readAsStringSync();
    // Newer than pubspec.yaml, so the packages still count as fresh.
    File(
      p.join(app, 'pubspec.lock'),
    ).writeAsStringSync('packages:\n<<<<<<< HEAD\n  a: 1\n=======\n');
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.files.keys, [
      'platform/sdk.json',
      'platform/toolchain.json',
      'platform/delta.md',
    ]);
    expect(report.map!.skipped, contains('pubspec.lock is not valid YAML'));
    expect(report.map!.skipped, contains('flutter pub get'));
    expect(depsFile.readAsStringSync(), before);
    expect(readMapBody(app, 'deps.json')['packages'], isNotEmpty);
  });

  test('a failed fetch after a good sync leaves the old map files and lists '
      'only the platform files in state.json', () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    final mapDir = Directory(p.join(app, '.appstein', 'map'));
    final before = {
      for (final file in mapDir.listSync().whereType<File>())
        file.path: file.readAsStringSync(),
    };
    expect(before, hasLength(5));
    File(
      p.join(app, 'pubspec.yaml'),
    ).setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
    runner.when(flutter(), [
      'pub',
      'get',
    ], const RunResult(exitCode: 69, stderr: 'Could not reach pub.dev.'));
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.map!.packages, PackagesAction.fetchFailed);
    expect({
      for (final file in mapDir.listSync().whereType<File>())
        file.path: file.readAsStringSync(),
    }, before);
    expect((state(app)['files']! as Map).keys, [
      'platform/delta.md',
      'platform/sdk.json',
      'platform/toolchain.json',
    ]);
  });

  test('editing a source file changes every map file\'s input hash, and '
      'state.json agrees with each file', () async {
    final app = copyFixtureApp();
    String? hashOf(String path) =>
        ((jsonDecode(File(p.join(app, '.appstein', path)).readAsStringSync())
                    as Map<String, Object?>)['meta']!
                as Map<String, Object?>)['inputHash']
            as String?;
    await sync().run(app, dartSdkPath: testDartSdk);
    final first = {for (final path in MapFiles.all) path: hashOf(path)};
    final source = File(p.join(app, 'lib', 'utils', 'result.dart'));
    source.writeAsStringSync('${source.readAsStringSync()}\n// edited\n');
    await sync().run(app, dartSdkPath: testDartSdk);
    final files = state(app)['files']! as Map;
    for (final path in MapFiles.all) {
      final hash = hashOf(path);
      expect(hash, isNot(first[path]), reason: path);
      expect(files[path], hash, reason: path);
    }
  });

  test("editing the project's analysis_options.yaml changes every map file's "
      'input hash', () async {
    final app = copyFixtureApp();
    String? hashOf(String path) =>
        ((jsonDecode(File(p.join(app, '.appstein', path)).readAsStringSync())
                    as Map<String, Object?>)['meta']!
                as Map<String, Object?>)['inputHash']
            as String?;
    await sync().run(app, dartSdkPath: testDartSdk);
    final first = {for (final path in MapFiles.all) path: hashOf(path)};
    File(
      p.join(app, 'analysis_options.yaml'),
    ).writeAsStringSync('analyzer:\n  exclude:\n    - lib/generated/**\n');
    await sync().run(app, dartSdkPath: testDartSdk);
    for (final path in MapFiles.all) {
      expect(hashOf(path), isNot(first[path]), reason: path);
    }
  });

  test('without packs, only the generic map files are written, with no '
      'layers', () async {
    final app = copyFixtureApp();
    final report = await sync(
      packs: const [],
    ).run(app, dartSdkPath: testDartSdk);
    expect(report.files.keys, [
      'platform/sdk.json',
      'platform/toolchain.json',
      'platform/delta.md',
      MapFiles.deps,
      MapFiles.layers,
      MapFiles.symbols,
    ]);
    final layers = LayersMap.fromJson(readMapBody(app, 'layers.json'));
    expect(layers.violations, isEmpty);
    expect(layers.files.values.map((f) => f.layer), everyElement(isNull));
  });

  test('the first sync writes delta.md: the notes, then what the stand-ins '
      'and the Dart SDK mark, with go_router\'s removed location', () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    final text = delta(app);
    final meta = readFrontMatter(text)!;
    expect(meta.sdkVersion, '3.47.5');
    expect(meta.generatedAt, '2026-10-01T09:00:00Z');
    expect(
      text,
      contains('# Version delta: Flutter 3.47.5, Dart language 3.12\n'),
    );
    expect(text, contains('## Notes'));
    expect(text, contains('popscope-not-willpopscope'));
    expect(text, contains('## Deprecated'));
    expect(
      text,
      contains(
        "- `GoRouterState.location`: removed. Replaces 'location' in "
        "'GoRouterState' with `uri.toString()`.",
      ),
    );
    expect((state(app)['files']! as Map)['platform/delta.md'], meta.inputHash);
  });

  test('when the map is skipped, delta.md holds only the notes and says '
      'why', () async {
    final app = copyFixtureApp();
    File(p.join(app, '.dart_tool', 'package_config.json')).deleteSync();
    runner.when(flutter(), [
      'pub',
      'get',
    ], const RunResult(exitCode: 69, stderr: 'Could not reach pub.dev.'));
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.files['platform/delta.md'], isTrue);
    final text = delta(app);
    expect(
      text,
      contains(
        'Deprecated and removed APIs are missing: the packages could not be '
        'fetched. Fix that, then run `appstein sync` again.',
      ),
    );
    expect(text, contains('popscope-not-willpopscope'));
    expect(text, isNot(contains('## Deprecated')));
  });

  test('a later baseline drops the older notes', () async {
    final app = copyFixtureApp();
    await sync(baseline: '3.47').run(app, dartSdkPath: testDartSdk);
    final text = delta(app);
    expect(text, contains('since Flutter 3.47'));
    expect(text, isNot(contains('popscope-not-willpopscope')));
  });

  test('a hand-edited delta.md is put back', () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    final file = File(p.join(app, '.appstein', 'platform', 'delta.md'));
    final original = file.readAsStringSync();
    file.writeAsStringSync(original.replaceFirst('## Notes', '## Edited'));
    final second = await sync().run(app, dartSdkPath: testDartSdk);
    expect(second.files['platform/delta.md'], isTrue);
    expect(file.readAsStringSync(), contains('## Notes'));
  });

  test("editing a source file changes delta.md's input hash", () async {
    final app = copyFixtureApp();
    await sync().run(app, dartSdkPath: testDartSdk);
    final before = readFrontMatter(delta(app))!.inputHash;
    final source = File(p.join(app, 'lib', 'utils', 'result.dart'));
    source.writeAsStringSync('${source.readAsStringSync()}\n// edited\n');
    await sync().run(app, dartSdkPath: testDartSdk);
    expect(readFrontMatter(delta(app))!.inputHash, isNot(before));
  });

  test(
    'changing only the baseline rewrites delta.md and no map file',
    () async {
      final app = copyFixtureApp();
      await sync().run(app, dartSdkPath: testDartSdk);
      Map<String, String> mapBytes() => {
        for (final file in Directory(
          p.join(app, '.appstein', 'map'),
        ).listSync().whereType<File>())
          file.path: base64Encode(file.readAsBytesSync()),
      };
      final before = readFrontMatter(delta(app))!.inputHash;
      final mapBefore = mapBytes();
      final second = await sync(
        baseline: '3.47',
      ).run(app, dartSdkPath: testDartSdk);
      expect(second.files['platform/delta.md'], isTrue);
      expect(readFrontMatter(delta(app))!.inputHash, isNot(before));
      expect(mapBytes(), mapBefore);
      for (final path in MapFiles.all) {
        expect(second.files[path], isFalse, reason: path);
      }
    },
  );

  test('a collector that fails does not fail the sync: the map is written '
      'and delta.md says why the APIs are missing', () async {
    final app = copyFixtureApp();
    final report = await sync(
      deltaCollector: (analysis, {required dartSdkPath}) =>
          throw StateError('boom'),
    ).run(app, dartSdkPath: testDartSdk);
    expect(report.map!.skipped, isNull);
    expect(
      report.map!.deltaSkipped,
      "the version delta couldn't be collected: Bad state: boom",
    );
    expect(report.files.keys, containsAll(MapFiles.all));
    for (final path in MapFiles.all) {
      expectGolden(
        p.posix.basename(path),
        readMapBody(app, p.posix.basename(path)),
      );
    }
    final text = delta(app);
    expect(
      text,
      contains(
        "Deprecated and removed APIs are missing: the version delta couldn't "
        'be collected: Bad state: boom. Fix that, then run `appstein sync` '
        'again.',
      ),
    );
    expect(text, contains('popscope-not-willpopscope'));
    expect(text, isNot(contains('## Deprecated')));
    final healthy = await sync().run(app, dartSdkPath: testDartSdk);
    expect(healthy.files['platform/delta.md'], isTrue);
    expect(delta(app), contains('## Deprecated'));
  });
}
