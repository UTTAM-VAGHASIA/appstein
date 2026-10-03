import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import '../support/temp.dart';
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

  KnowledgeSync sync({List<String> agents = const ['claude', 'codex']}) =>
      KnowledgeSync(
        environment: fakeEnvironment({'FLUTTER_ROOT': sdk}),
        appsteinVersion: '0.1.0-dev',
        packs: const [OfficialMvvmPack()],
        runner: runner,
        clock: () => DateTime.utc(2026, 10, 1, 9),
        agents: agents,
      );

  List<String> skillsArgs(String project, List<String> agents) => [
    'run',
    'skills@1.0.3',
    '-C',
    project,
    'get',
    '--all',
    for (final agent in agents) ...['--agent', agent],
  ];

  void answerSkills(List<String> agents, RunResult result) => runner.when(
    dartCommand(sdk, HostOs.current),
    skillsArgs(app, agents),
    result,
  );

  List<String> skillsCalls() =>
      runner.calls.where((call) => call.contains('skills@')).toList();

  const installed = 'Installed 0 skill(s) for claude at .claude/skills.\n';

  test('with no agent set up, the first sync says so and later ones say '
      'nothing', () async {
    final first = await sync().run(app, dartSdkPath: testDartSdk);
    expect(first.packageSkills?.outcome, PackageSkillsOutcome.noAgents);
    final second = await sync().run(app, dartSdkPath: testDartSdk);
    expect(second.packageSkills, isNull);
    expect(skillsCalls(), isEmpty);
  });

  test('a sync runs package:skills after writing the knowledge, and the '
      'record holds the hashes the map read', () async {
    Directory(p.join(app, '.claude')).createSync();
    answerSkills(['claude'], const RunResult(exitCode: 0, stdout: installed));
    final report = await sync().run(app, dartSdkPath: testDartSdk);
    expect(report.packageSkills?.outcome, PackageSkillsOutcome.refreshed);
    expect(skillsCalls(), hasLength(1));
    expect(report.timings.keys, contains('package skills'));
    final record = PackageSkillsRecord.read(app)!;
    expect(record.pubspec, isNotNull);
    expect(record.lock, isNotNull);
    expect(File(p.join(app, '.appstein', 'INDEX.md')).existsSync(), isTrue);
  });

  test(
    'a failed run is a warning; the sync and its files are unaffected',
    () async {
      Directory(p.join(app, '.claude')).createSync();
      answerSkills(['claude'], const RunResult(exitCode: 255));
      final report = await sync().run(app, dartSdkPath: testDartSdk);
      expect(report.packageSkills?.outcome, PackageSkillsOutcome.failed);
      expect(report.files[indexPath], isTrue);
    },
  );

  test(
    'a current detect retries nothing after a failure; a full sync does',
    () async {
      Directory(p.join(app, '.claude')).createSync();
      answerSkills(['claude'], const RunResult(exitCode: 255));
      await sync().run(app, dartSdkPath: testDartSdk);
      final detected = await sync().detect(app, dartSdkPath: testDartSdk);
      expect(detected.current, isTrue);
      expect(detected.packageSkills, isNull);
      expect(detected.timings.keys, contains('package skills'));
      expect(skillsCalls(), hasLength(1));
      final full = await sync().run(app, dartSdkPath: testDartSdk);
      expect(full.packageSkills?.outcome, PackageSkillsOutcome.failed);
      expect(skillsCalls(), hasLength(2));
    },
  );

  test('a current detect runs it when an agent was set up since', () async {
    await sync().run(app, dartSdkPath: testDartSdk);
    Directory(p.join(app, '.claude')).createSync();
    answerSkills(['claude'], const RunResult(exitCode: 0, stdout: installed));
    final detected = await sync().detect(app, dartSdkPath: testDartSdk);
    expect(detected.current, isTrue);
    expect(detected.packageSkills?.outcome, PackageSkillsOutcome.refreshed);
  });

  test('a detect that rebuilds for a pubspec change runs it again', () async {
    Directory(p.join(app, '.claude')).createSync();
    answerSkills(['claude'], const RunResult(exitCode: 0, stdout: installed));
    await sync().run(app, dartSdkPath: testDartSdk);
    // An edited pubspec.yaml makes the packages stale, so the rebuild runs
    // `flutter pub get` first; the stub packages are still in place.
    runner.when(flutterCommand(sdk), const [
      'pub',
      'get',
    ], const RunResult(exitCode: 0));
    File(
      p.join(app, 'pubspec.yaml'),
    ).writeAsStringSync('\n# a comment\n', mode: FileMode.append);
    final detected = await sync().detect(app, dartSdkPath: testDartSdk);
    expect(detected.current, isFalse);
    expect(detected.packageSkills?.outcome, PackageSkillsOutcome.refreshed);
    expect(skillsCalls(), hasLength(2));
  });

  test('only agents in integrations.agents count', () async {
    Directory(p.join(app, '.claude')).createSync();
    final report = await sync(
      agents: const ['codex'],
    ).run(app, dartSdkPath: testDartSdk);
    expect(report.packageSkills?.outcome, PackageSkillsOutcome.noAgents);
    expect(skillsCalls(), isEmpty);
  });

  test('a failed pub get fails package skills without running them', () async {
    final project = p.join(tempDir().path, 'app');
    Directory(p.join(project, '.claude')).createSync(recursive: true);
    File(
      p.join(project, 'pubspec.yaml'),
    ).writeAsStringSync('name: sample\nenvironment:\n  sdk: ^3.12.0\n');
    // flutter pub get isn't faked, so it "fails to start".
    final report = await sync().run(project, dartSdkPath: testDartSdk);
    expect(report.map?.packages, PackagesAction.fetchFailed);
    expect(report.packageSkills?.outcome, PackageSkillsOutcome.failed);
    expect(report.packageSkills?.reason, 'the packages could not be fetched');
    expect(skillsCalls(), isEmpty);
  });
}
