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

  KnowledgeSync sync({List<Pack> packs = const [OfficialMvvmPack()]}) =>
      KnowledgeSync(
        environment: fakeEnvironment({'FLUTTER_ROOT': sdk}),
        appsteinVersion: '0.1.0-dev',
        packs: packs,
        runner: runner,
        clock: () => DateTime.utc(2026, 10, 1, 9),
      );

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
    expect(report.files.keys, ['platform/sdk.json', 'platform/toolchain.json']);
    expect(report.map!.packages, PackagesAction.fetchFailed);
    expect(report.map!.packagesReason, contains('Could not reach pub.dev.'));
    expect(report.map!.skipped, 'the packages could not be fetched');
    expect(Directory(p.join(app, '.appstein', 'map')).existsSync(), isFalse);
    expect((state(app)['files']! as Map).keys, [
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

  test('without packs, only the generic map files are written, with no '
      'layers', () async {
    final app = copyFixtureApp();
    final report = await sync(
      packs: const [],
    ).run(app, dartSdkPath: testDartSdk);
    expect(report.files.keys, [
      'platform/sdk.json',
      'platform/toolchain.json',
      MapFiles.deps,
      MapFiles.layers,
      MapFiles.symbols,
    ]);
    final layers = LayersMap.fromJson(readMapBody(app, 'layers.json'));
    expect(layers.violations, isEmpty);
    expect(layers.files.values.map((f) => f.layer), everyElement(isNull));
  });
}
