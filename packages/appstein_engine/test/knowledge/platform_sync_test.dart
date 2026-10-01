import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_sdk.dart';
import '../support/flutter_fixtures.dart';
import '../support/temp.dart';

void main() {
  late String project;
  late String sdk;

  setUp(() {
    final root = tempDir().path;
    project = p.join(root, 'my app');
    Directory(project).createSync();
    File(
      p.join(project, 'pubspec.yaml'),
    ).writeAsStringSync('name: my_app\nenvironment:\n  sdk: ^3.9.0\n');
    sdk = createFakeSdk(p.join(root, 'flutter'));
    addToolchainFiles(sdk, '3.47.5');
  });

  PlatformSync sync(DateTime time) => PlatformSync(
    environment: fakeEnvironment({'FLUTTER_ROOT': sdk}),
    appsteinVersion: '0.1.0-dev',
    clock: () => time,
  );

  File knowledge(String path) =>
      File(p.joinAll([project, '.appstein', ...path.split('/')]));

  Map<String, Object?> json(String path) =>
      jsonDecode(knowledge(path).readAsStringSync()) as Map<String, Object?>;

  test(
    'the first sync writes sdk.json, toolchain.json and state.json',
    () async {
      final report = await sync(DateTime.utc(2026, 10, 1, 9)).run(project);
      expect(report.files, {
        'platform/sdk.json': true,
        'platform/toolchain.json': true,
      });
      expect(report.sdk.flutterVersion, '3.47.5');
      expect(report.sdk.notesCoverage, NotesCoverage.complete);
      expect(report.newestNotes, '3.47');
      expect(report.fallbacks, isEmpty);

      final sdkJson = json('platform/sdk.json');
      expect(sdkJson['flutter'], '3.47.5');
      expect(sdkJson['languageVersion'], '3.9');
      expect(sdkJson['appsteinNotesCoverage'], 'complete');
      final meta = KnowledgeMeta.fromJson(
        sdkJson['meta']! as Map<String, Object?>,
      );
      expect(meta.sdkVersion, '3.47.5');
      expect(meta.generatedAt, '2026-10-01T09:00:00Z');

      final toolchain = Toolchain.fromJson(json('platform/toolchain.json'));
      expect(toolchain.android?.source, ToolchainSource.sdk);
      expect(toolchain.ios?.value.deploymentTarget, '15.0');

      final state = KnowledgeState.fromJson(json('state.json'));
      expect(state.lastSync, '2026-10-01T09:00:00Z');
      expect(state.files.keys, [
        'platform/sdk.json',
        'platform/toolchain.json',
      ]);
      expect(state.files['platform/sdk.json'], meta.inputHash);
    },
  );

  test('a second sync changes no knowledge bytes, only lastSync', () async {
    await sync(DateTime.utc(2026, 10, 1)).run(project);
    final sdkBefore = knowledge('platform/sdk.json').readAsStringSync();
    final toolchainBefore = knowledge(
      'platform/toolchain.json',
    ).readAsStringSync();
    final report = await sync(DateTime.utc(2026, 10, 2)).run(project);
    expect(report.files.values, everyElement(isFalse));
    expect(knowledge('platform/sdk.json').readAsStringSync(), sdkBefore);
    expect(
      knowledge('platform/toolchain.json').readAsStringSync(),
      toolchainBefore,
    );
    expect(
      KnowledgeState.fromJson(json('state.json')).lastSync,
      '2026-10-02T00:00:00Z',
    );
  });

  test('a new SDK version rewrites both, with partial coverage above the '
      'notes', () async {
    await sync(DateTime.utc(2026, 10, 1)).run(project);
    createFakeSdk(sdk, flutter: '3.48.0-0.1.pre', channel: 'beta');
    final report = await sync(DateTime.utc(2026, 10, 2)).run(project);
    expect(report.files.values, everyElement(isTrue));
    expect(report.sdk.notesCoverage, NotesCoverage.partial);
    expect(json('platform/sdk.json')['appsteinNotesCoverage'], 'partial');
  });

  test('a new language version rewrites sdk.json only', () async {
    await sync(DateTime.utc(2026, 10, 1)).run(project);
    File(
      p.join(project, 'pubspec.yaml'),
    ).writeAsStringSync('name: my_app\nenvironment:\n  sdk: ^3.12.0\n');
    final report = await sync(DateTime.utc(2026, 10, 2)).run(project);
    expect(report.files, {
      'platform/sdk.json': true,
      'platform/toolchain.json': false,
    });
    expect(json('platform/sdk.json')['languageVersion'], '3.12');
  });

  test('different notes sources rewrite toolchain.json only', () async {
    await sync(DateTime.utc(2026, 10, 1)).run(project);
    final edited = CuratedNotes.parse({
      ...bundledNotes,
      'stores.yaml': bundledNotes['stores.yaml']!.replaceFirst(
        'iOS 15 or later',
        'iOS 15 or later (edited)',
      ),
    });
    expect(edited.inputs, isNot(CuratedNotes.bundled().inputs));
    final report = await PlatformSync(
      environment: fakeEnvironment({'FLUTTER_ROOT': sdk}),
      appsteinVersion: '0.1.0-dev',
      notes: edited,
      clock: () => DateTime.utc(2026, 10, 2),
    ).run(project);
    expect(report.files, {
      'platform/sdk.json': false,
      'platform/toolchain.json': true,
    });
  });

  test('a different Appstein version rewrites both files', () async {
    await sync(DateTime.utc(2026, 10, 1)).run(project);
    final report = await PlatformSync(
      environment: fakeEnvironment({'FLUTTER_ROOT': sdk}),
      appsteinVersion: '0.2.0-dev',
      clock: () => DateTime.utc(2026, 10, 2),
    ).run(project);
    expect(report.files.values, everyElement(isTrue));
  });

  test('damaged or deleted knowledge is rewritten (Review Focus 5)', () async {
    await sync(DateTime.utc(2026, 10, 1)).run(project);
    knowledge('platform/sdk.json').writeAsStringSync('{"meta": null');
    knowledge('platform/toolchain.json').deleteSync();
    final report = await sync(DateTime.utc(2026, 10, 2)).run(project);
    expect(report.files.values, everyElement(isTrue));
    expect(json('platform/sdk.json')['flutter'], '3.47.5');
  });

  test('a toolchain fallback is reported', () async {
    File(
      p.joinAll([sdk, ...ToolchainFiles.iosTemplate.split('/')]),
    ).deleteSync();
    final report = await sync(DateTime.utc(2026, 10, 1)).run(project);
    expect(report.fallbacks.single, startsWith('iOS: '));
    expect(
      Toolchain.fromJson(json('platform/toolchain.json')).ios?.source,
      ToolchainSource.notes,
    );
  });

  test('an explicit SDK detection is used as given', () async {
    final detection = SdkDetector(
      fakeEnvironment({'FLUTTER_ROOT': sdk}),
    ).detect(projectRoot: project);
    final report = await PlatformSync(
      environment: fakeEnvironment({}),
      appsteinVersion: '0.1.0-dev',
    ).run(project, sdk: detection);
    expect(report.sdk.flutterVersion, '3.47.5');
  });

  test('no Flutter SDK is a SyncException with a fix', () async {
    final noSdk = PlatformSync(
      environment: fakeEnvironment({}),
      appsteinVersion: '0.1.0-dev',
    );
    await expectLater(
      noSdk.run(project),
      throwsA(
        isA<SyncException>()
            .having((e) => e.problem, 'problem', isNotEmpty)
            .having((e) => e.fixHint, 'fixHint', isNotEmpty),
      ),
    );
    expect(Directory(p.join(project, '.appstein')).existsSync(), isFalse);
  });
}
