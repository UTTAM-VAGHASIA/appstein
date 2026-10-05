import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
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

  test('with packageSkills off, a sync never runs package:skills, even with '
      'an agent set up', () async {
    Directory(p.join(app, '.claude')).createSync();
    final sync = knowledgeSync(
      flutterRoot: sdk,
      runner: runner,
      packageSkills: false,
    );
    final report = await sync.run(app, dartSdkPath: testDartSdk);
    expect(report.packageSkills, isNull);
    expect(runner.calls.where((call) => call.contains('skills@')), isEmpty);
    expect(PackageSkillsRecord.read(app), isNull);
  });

  test('a held cache is used from memory by the next sync, and the '
      'knowledge is the same as without it', () async {
    final held = HeldAnalyzerCache();
    KnowledgeSync sync() => knowledgeSync(
      flutterRoot: sdk,
      runner: runner,
      packageSkills: false,
      heldCache: held,
    );
    await sync().run(app, dartSdkPath: testDartSdk);
    // The file is gone, so a cache that loads must come from memory.
    File(analyzerCachePath(app)).deleteSync();
    final view = File(
      p.join(app, 'lib', 'ui', 'home', 'widgets', 'home_screen.dart'),
    );
    view.writeAsStringSync(
      '${view.readAsStringSync()}\n/// Extra.\nint extra = 1;\n',
    );
    final report = await sync().detect(app, dartSdkPath: testDartSdk);
    expect(report.current, isFalse);
    expect(report.analyzerCache!.load, AnalyzerCacheLoad.loaded);
    final withHeld = knowledgeFiles(app);

    final plain = copyFixtureApp();
    File(
      p.join(plain, 'lib', 'ui', 'home', 'widgets', 'home_screen.dart'),
    ).writeAsStringSync(view.readAsStringSync());
    await knowledgeSync(
      flutterRoot: sdk,
      runner: runner,
    ).run(plain, dartSdkPath: testDartSdk);
    final withoutHeld = knowledgeFiles(plain);
    for (final path in withHeld.keys.where((path) => path != 'state.json')) {
      expect(withHeld[path], withoutHeld[path], reason: path);
    }
  });
}
