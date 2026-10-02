import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import 'support/sync_harness.dart';

void main() {
  late String sdk;
  late FakeProcessRunner runner;
  late String app;

  setUp(() {
    sdk = fakeFlutter();
    runner = FakeProcessRunner();
    app = copyFixtureApp();
  });

  KnowledgeSync sync({
    List<Pack> packs = const [OfficialMvvmPack()],
    String baseline = '3.16',
    String? flutterRoot,
    String appsteinVersion = '0.1.0-dev',
  }) => knowledgeSync(
    flutterRoot: flutterRoot ?? sdk,
    runner: runner,
    packs: packs,
    baseline: baseline,
    appsteinVersion: appsteinVersion,
  );

  Future<SyncReport> full({List<Pack> packs = const [OfficialMvvmPack()]}) =>
      sync(packs: packs).run(app, dartSdkPath: testDartSdk);

  Future<SyncReport> detect({
    List<Pack> packs = const [OfficialMvvmPack()],
    String baseline = '3.16',
    String? flutterRoot,
    String appsteinVersion = '0.1.0-dev',
  }) => sync(
    packs: packs,
    baseline: baseline,
    flutterRoot: flutterRoot,
    appsteinVersion: appsteinVersion,
  ).detect(app, dartSdkPath: testDartSdk);

  File fileOf(String relative) =>
      File(p.joinAll([app, ...relative.split('/')]));

  void write(String relative, String text) => fileOf(relative)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  KnowledgeState state() => KnowledgeState.fromJson(
    jsonDecode(fileOf('.appstein/state.json').readAsStringSync())
        as Map<String, Object?>,
  );

  /// A full sync right after writes nothing, so what detect wrote is what a
  /// full sync writes.
  Future<void> expectLikeFullSync() async {
    final again = await sync().run(app, dartSdkPath: testDartSdk);
    expect(again.files.values, everyElement(isFalse));
  }

  group('nothing changed', () {
    test(
      'detect writes no byte, and leaves every modified time alone',
      () async {
        await full();
        await detect(); // Empties the change list the full sync recorded.
        final before = snapshot(app);
        final report = await detect();
        expect(report.current, isTrue);
        expect(report.files, isEmpty);
        expect(snapshot(app), before);
      },
    );

    test('the first detect after a sync empties the change list, and changes '
        'nothing else', () async {
      await full();
      expect(state().changed, isNotEmpty);
      final knowledge = knowledgeFiles(app)..remove('state.json');
      final report = await detect();
      expect(report.current, isTrue);
      expect(state().changed, isEmpty);
      expect(knowledgeFiles(app)..remove('state.json'), knowledge);
    });

    test('freshness() says current and writes nothing', () async {
      await full();
      final before = snapshot(app);
      final freshness = sync().freshness(app);
      expect(freshness.current, isTrue, reason: '${freshness.reasons}');
      expect(snapshot(app), before);
    });
  });

  group('a change rebuilds, as a full sync would', () {
    setUp(() async {
      await full();
      await detect();
    });

    test('a Dart file edited', () async {
      fileOf('lib/main.dart').writeAsStringSync(
        "\n/// Says hi.\nString hi() => 'hi';\n",
        mode: FileMode.append,
      );
      final report = await detect();
      expect(report.current, isFalse);
      expect(report.changed, ['project:lib/main.dart']);
      expect(report.files[MapFiles.symbols], isTrue);
      expect(jsonEncode(readMapBody(app, 'symbols.json')), contains('"hi"'));
      expect(state().changed, ['project:lib/main.dart']);
      expect(
        state().sources['project:lib/main.dart'],
        sha256Hex(fileOf('lib/main.dart').readAsBytesSync()),
      );
      await expectLikeFullSync();
    });

    test('a Dart file added, then deleted', () async {
      write('lib/extra.dart', '/// Extra.\nclass Extra {}\n');
      expect((await detect()).changed, ['project:lib/extra.dart']);
      fileOf('lib/extra.dart').deleteSync();
      final report = await detect();
      expect(report.changed, ['project:lib/extra.dart']);
      expect(
        jsonEncode(readMapBody(app, 'symbols.json')),
        isNot(contains('Extra')),
      );
      await expectLikeFullSync();
    });

    test('pubspec.lock edited', () async {
      fileOf(
        'pubspec.lock',
      ).writeAsStringSync('\n# edited\n', mode: FileMode.append);
      expect((await detect()).changed, ['pubspec.lock']);
    });

    test('pubspec.yaml edited: the packages are fetched first', () async {
      runner.when(flutterCommand(sdk), [
        'pub',
        'get',
      ], const RunResult(exitCode: 0));
      fileOf(
        'pubspec.yaml',
      ).writeAsStringSync('\n# edited\n', mode: FileMode.append);
      final report = await detect();
      expect(report.changed, contains('pubspec.yaml'));
      expect(runner.calls, ['${flutterCommand(sdk)} pub get']);
    });

    test('analysis_options.yaml added', () async {
      write('analysis_options.yaml', 'analyzer:\n  exclude: [testing/**]\n');
      expect((await detect()).changed, ['analysis_options.yaml']);
    });

    test('a local package edited', () async {
      File(
        p.join(p.dirname(app), 'stubs', 'go_router', 'lib', 'go_router.dart'),
      ).writeAsStringSync('\n// edited\n', mode: FileMode.append);
      expect((await detect()).changed, [
        'local-package:go_router/lib/go_router.dart',
      ]);
    });

    test('a decision file or current.md: INDEX.md is rebuilt', () async {
      write(
        '.appstein/decisions/0001-state.md',
        '---\nid: 0001\ntitle: State\nstatus: accepted\n---\nWhy: test.\n',
      );
      var report = await detect();
      expect(report.changed, isEmpty);
      expect(report.rebuiltBecause, contains('INDEX.md is out of date'));
      write('.appstein/memory/current.md', 'Goal: test.\n');
      report = await detect();
      expect(report.rebuiltBecause, contains('INDEX.md is out of date'));
    });

    test('the delta baseline changed', () async {
      final report = await detect(baseline: '3.22');
      expect(
        report.rebuiltBecause,
        contains('platform/delta.md is out of date'),
      );
    });

    test('another Flutter version', () async {
      final other = fakeFlutter(version: '3.44.9');
      runner.when(flutterCommand(other), [
        'pub',
        'get',
      ], const RunResult(exitCode: 0));
      final report = await detect(flutterRoot: other);
      expect(
        report.rebuiltBecause,
        contains('platform/sdk.json is out of date'),
      );
      expect(
        report.rebuiltBecause,
        contains(startsWith('the packages need `flutter pub get`')),
      );
    });

    test('another Appstein', () async {
      final report = await detect(appsteinVersion: '0.2.0');
      expect(
        report.rebuiltBecause,
        contains('the last sync was made by Appstein 0.1.0-dev'),
      );
    });
  });

  group('knowledge and state.json that disagree', () {
    setUp(() async {
      await full();
      await detect();
    });

    test('a knowledge file changed by hand is put back', () async {
      final original = fileOf('.appstein/map/symbols.json').readAsStringSync();
      fileOf('.appstein/map/symbols.json').writeAsStringSync('{}');
      final report = await detect();
      expect(
        report.rebuiltBecause,
        contains('map/symbols.json was changed by hand'),
      );
      expect(fileOf('.appstein/map/symbols.json').readAsStringSync(), original);
    });

    test('a deleted knowledge file is written again', () async {
      fileOf('.appstein/INDEX.md').deleteSync();
      final report = await detect();
      expect(report.rebuiltBecause, contains('INDEX.md is missing'));
      expect(fileOf('.appstein/INDEX.md').existsSync(), isTrue);
    });

    test('a damaged state.json', () async {
      fileOf('.appstein/state.json').writeAsStringSync('{not json');
      final report = await detect();
      expect(report.rebuiltBecause, [
        'state.json is damaged or from an older Appstein',
      ]);
      expect(state().changed, isNotEmpty);
    });

    test('a state.json from before 1b.7', () async {
      final json =
          jsonDecode(fileOf('.appstein/state.json').readAsStringSync())
                as Map<String, Object?>
            ..remove('sources');
      fileOf('.appstein/state.json').writeAsStringSync(jsonEncode(json));
      final report = await detect();
      expect(report.rebuiltBecause, [
        'state.json is damaged or from an older Appstein',
      ]);
    });
  });

  test('a file edited while the sync analyzes is rebuilt by the next '
      'detect', () async {
    var edited = false;
    final syncing = knowledgeSync(
      flutterRoot: sdk,
      runner: runner,
      deltaCollector: (analysis, {required dartSdkPath}) async {
        if (!edited) {
          edited = true;
          fileOf('lib/main.dart').writeAsStringSync(
            '\n/// Late.\nclass Late {}\n',
            mode: FileMode.append,
          );
        }
        return collectDelta(analysis, dartSdkPath: dartSdkPath);
      },
    );
    await syncing.run(app, dartSdkPath: testDartSdk);
    expect(edited, isTrue);
    final report = await detect();
    expect(report.current, isFalse);
    expect(report.changed, ['project:lib/main.dart']);
    expect(jsonEncode(readMapBody(app, 'symbols.json')), contains('"Late"'));
  });

  test('the first detect, with no state.json, rebuilds; the report lists no '
      'changes, but state.json lists every input', () async {
    final report = await detect();
    expect(report.rebuiltBecause, ['no sync has run here yet']);
    expect(report.changed, isEmpty);
    expect(state().changed, contains('project:lib/main.dart'));
  });

  test('when the last sync skipped the map, detect tries again', () async {
    fileOf('.dart_tool/package_config.json').deleteSync();
    runner.when(flutterCommand(sdk), [
      'pub',
      'get',
    ], const RunResult(exitCode: 69, stderr: 'offline'));
    await full();
    final report = await detect();
    expect(report.current, isFalse);
    expect(
      report.rebuiltBecause,
      contains('the last sync could not build the project map'),
    );
    expect(runner.calls, hasLength(2));
  });

  test('an Android file changed: native.json is rebuilt', () async {
    const packs = [OfficialMvvmPack(), AndroidPack()];
    await full(packs: packs);
    await detect(packs: packs);
    write('android/app/src/main/AndroidManifest.xml', '<manifest/>\n');
    final report = await detect(packs: packs);
    expect(report.changed, isEmpty);
    expect(report.rebuiltBecause, contains('map/native.json is out of date'));
  });

  test('other packs: rebuilt', () async {
    await full();
    final report = await detect(
      packs: const [OfficialMvvmPack(), AndroidPack()],
    );
    expect(report.current, isFalse);
  });
}
