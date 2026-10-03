import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/temp.dart';

/// Real package:skills 1.0.3 output, captured on Windows (see the plan).
const _installedBoth =
    '  [claude] Installed skill-pkg-demo\n'
    'Installed 1 skill(s) for claude at .claude/skills.\n'
    '  [generic] Installed skill-pkg-demo\n'
    'Installed 1 skill(s) for generic at .agents/skills.\n';

const _claudeOnly =
    '  [claude] Installed skill-pkg-demo\n'
    'Installed 1 skill(s) for claude at .claude/skills.\n';

/// After a package that shipped skills was removed: its skills are pruned.
const _removedPackage =
    'Installed 0 skill(s) for claude at .claude/skills.\n'
    'Installed 0 skill(s) for generic at .agents/skills.\n';

/// When no dependency ships skills (most apps): it stops before installing.
const _noSkillsFound = 'No skills found.\n';

const _badAgent =
    '"nosuch" is not an allowed value for option "--agent".\n'
    '\n'
    'Usage: skills get [arguments]\n'
    '-h, --help       Print this usage information.\n';

const _pubGetFailed =
    'Running dart.exe pub get...\n'
    'dart.exe pub get failed:\n'
    'The current Dart SDK version is 3.4.1.\n'
    '\n'
    'Failed to run pub get.\n'
    '\n'
    'Install skills from package dependencies.\n'
    '\n'
    'Usage: skills get [arguments]\n';

void main() {
  group('setUpAgents', () {
    late String project;

    setUp(() => project = tempDir().path);

    test('no agent folder means no agent', () {
      expect(setUpAgents(project, ['claude', 'codex']), isEmpty);
    });

    test('claude needs .claude/', () {
      Directory(p.join(project, '.claude')).createSync();
      expect(setUpAgents(project, ['claude', 'codex']), ['claude']);
    });

    test('codex needs .agents/ or AGENTS.md', () {
      Directory(p.join(project, '.agents')).createSync();
      expect(setUpAgents(project, ['claude', 'codex']), ['codex']);
      final other = tempDir().path;
      File(p.join(other, 'AGENTS.md')).writeAsStringSync('# Agents\n');
      expect(setUpAgents(other, ['claude', 'codex']), ['codex']);
    });

    test('a file named .claude or .agents does not count', () {
      File(p.join(project, '.claude')).writeAsStringSync('');
      File(p.join(project, '.agents')).writeAsStringSync('');
      expect(setUpAgents(project, ['claude', 'codex']), isEmpty);
    });

    test('only configured agents, in the configured order, once each', () {
      Directory(p.join(project, '.claude')).createSync();
      Directory(p.join(project, '.agents')).createSync();
      expect(setUpAgents(project, ['codex', 'claude', 'codex']), [
        'codex',
        'claude',
      ]);
      expect(setUpAgents(project, ['claude']), ['claude']);
      expect(setUpAgents(project, []), isEmpty);
    });
  });

  group('PackageSkillsRecord', () {
    late String project;

    setUp(() => project = tempDir().path);

    const record = PackageSkillsRecord(
      pubspec: 'aa',
      lock: null,
      agents: ['claude', 'codex'],
      version: '1.0.3',
      succeeded: true,
    );

    void writeRecord(String text) => File(packageSkillsRecordPath(project))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);

    test('lives in .dart_tool/appstein/', () {
      expect(
        packageSkillsRecordPath(project),
        p.join(project, '.dart_tool', 'appstein', 'package_skills.json'),
      );
    });

    test('reads back what toText wrote, a null lock included', () {
      writeRecord(record.toText());
      final read = PackageSkillsRecord.read(project)!;
      expect(read.pubspec, 'aa');
      expect(read.lock, isNull);
      expect(read.agents, ['claude', 'codex']);
      expect(read.version, '1.0.3');
      expect(read.succeeded, isTrue);
      expect(jsonDecode(record.toText()), record.toJson());
    });

    test('a missing, damaged or foreign record reads as none', () {
      expect(PackageSkillsRecord.read(project), isNull);
      for (final text in [
        'not json',
        '[]',
        '{"pubspec": "aa"}',
        '{"pubspec": 1, "lock": null, "agents": [], "version": "1.0.3", '
            '"succeeded": true}',
        '{"pubspec": "aa", "lock": null, "agents": [1], "version": "1.0.3", '
            '"succeeded": true}',
        '{"pubspec": "aa", "lock": null, "agents": [], "version": "1.0.3", '
            '"succeeded": "yes"}',
      ]) {
        writeRecord(text);
        expect(PackageSkillsRecord.read(project), isNull, reason: text);
      }
    });

    test('a folder where the record should be reads as none', () {
      Directory(packageSkillsRecordPath(project)).createSync(recursive: true);
      expect(PackageSkillsRecord.read(project), isNull);
    });

    test('sameInputs compares everything but succeeded', () {
      expect(record.sameInputs(record.withSucceeded(false)), isTrue);
      for (final other in [
        const PackageSkillsRecord(
          pubspec: 'bb',
          lock: null,
          agents: ['claude', 'codex'],
          version: '1.0.3',
          succeeded: true,
        ),
        const PackageSkillsRecord(
          pubspec: 'aa',
          lock: 'cc',
          agents: ['claude', 'codex'],
          version: '1.0.3',
          succeeded: true,
        ),
        const PackageSkillsRecord(
          pubspec: 'aa',
          lock: null,
          agents: ['claude'],
          version: '1.0.3',
          succeeded: true,
        ),
        const PackageSkillsRecord(
          pubspec: 'aa',
          lock: null,
          agents: ['codex', 'claude'],
          version: '1.0.3',
          succeeded: true,
        ),
        const PackageSkillsRecord(
          pubspec: 'aa',
          lock: null,
          agents: ['claude', 'codex'],
          version: '1.0.4',
          succeeded: true,
        ),
      ]) {
        expect(record.sameInputs(other), isFalse);
      }
    });
  });

  group('packageSkillsFailure', () {
    test('a run that installed for every agent worked', () {
      expect(
        packageSkillsFailure(
          const RunResult(exitCode: 0, stdout: _installedBoth),
          ['claude', 'codex'],
        ),
        isNull,
      );
    });

    test('installing nothing after a package was removed worked', () {
      expect(
        packageSkillsFailure(
          const RunResult(exitCode: 0, stdout: _removedPackage),
          ['claude', 'codex'],
        ),
        isNull,
      );
    });

    test('no dependency shipping skills worked: nothing to install', () {
      expect(
        packageSkillsFailure(
          const RunResult(exitCode: 0, stdout: _noSkillsFound),
          ['claude', 'codex'],
        ),
        isNull,
      );
      // Only on a clean exit, and only as the whole line.
      expect(
        packageSkillsFailure(
          const RunResult(exitCode: 1, stdout: _noSkillsFound),
          ['claude'],
        ),
        startsWith('it failed with exit code 1'),
      );
      expect(
        packageSkillsFailure(
          const RunResult(
            exitCode: 0,
            stdout: 'No skills found in the given source package:x.\n',
          ),
          ['claude'],
        ),
        startsWith('it did not report installing skills for claude'),
      );
    });

    test('codex is the line package:skills prints as generic', () {
      const codexOnly = 'Installed 1 skill(s) for generic at .agents/skills.\n';
      expect(
        packageSkillsFailure(const RunResult(exitCode: 0, stdout: codexOnly), [
          'codex',
        ]),
        isNull,
      );
      expect(
        packageSkillsFailure(const RunResult(exitCode: 0, stdout: codexOnly), [
          'claude',
        ]),
        startsWith('it did not report installing skills for claude'),
      );
    });

    test('a usage error that exits 0 failed, with its first lines', () {
      final failure = packageSkillsFailure(
        const RunResult(exitCode: 0, stdout: _badAgent),
        ['claude'],
      );
      expect(failure, startsWith('it did not report installing skills for '));
      expect(failure, contains('is not an allowed value'));
    });

    test('a failed internal pub get that exits 0 failed', () {
      final failure = packageSkillsFailure(
        const RunResult(exitCode: 0, stdout: _pubGetFailed),
        ['claude', 'codex'],
      );
      expect(failure, contains('claude, codex'));
      expect(failure, contains('Failed to run pub get.'));
    });

    test('a non-zero exit failed, with what it printed on stderr', () {
      final failure = packageSkillsFailure(
        const RunResult(
          exitCode: 255,
          stderr:
              'Got socket error trying to find package skills at '
              'https://pub.dev.\n',
        ),
        ['claude'],
      );
      expect(failure, startsWith('it failed with exit code 255:'));
      expect(failure, contains('Got socket error'));
    });

    test('a run that did not start or timed out failed, saying so', () {
      expect(
        packageSkillsFailure(
          const RunResult.notStarted('The system cannot find the file'),
          ['claude'],
        ),
        'Dart could not be started (The system cannot find the file)',
      );
      expect(
        packageSkillsFailure(
          const RunResult.timedOut(stdout: '', stderr: 'Timed out'),
          ['claude'],
        ),
        'it did not finish within 120 s',
      );
    });

    test('only the first 10 lines of output are quoted', () {
      final long = [for (var i = 1; i <= 30; i++) 'line $i'].join('\n');
      final failure = packageSkillsFailure(
        RunResult(exitCode: 1, stdout: long),
        ['claude'],
      )!;
      expect(failure, contains('line 10'));
      expect(failure, isNot(contains('line 11')));
    });
  });

  group('PackageSkills.refresh', () {
    late String project;
    late String flutter;
    late FakeProcessRunner runner;

    setUp(() {
      project = tempDir().path;
      flutter = p.join(tempDir().path, 'flutter');
      runner = FakeProcessRunner();
    });

    String dart() => dartCommand(flutter, HostOs.current);

    List<String> args(List<String> agents) => [
      'run',
      'skills@1.0.3',
      '-C',
      project,
      'get',
      '--all',
      for (final agent in agents) ...['--agent', agent],
    ];

    void answer(List<String> agents, RunResult result) =>
        runner.when(dart(), args(agents), result);

    Future<PackageSkillsReport?> refresh({
      List<String> configured = const ['claude', 'codex'],
      String? pubspec = 'p1',
      String? lock = 'l1',
      bool packagesReady = true,
      bool retryFailure = true,
    }) => PackageSkills(runner: runner, os: HostOs.current).refresh(
      project,
      flutterRoot: flutter,
      configuredAgents: configured,
      pubspecHash: pubspec,
      lockHash: lock,
      packagesReady: packagesReady,
      retryFailure: retryFailure,
    );

    void setUpClaude() => Directory(p.join(project, '.claude')).createSync();

    test("the command is the SDK's own dart", () {
      expect(
        dartCommand(r'C:\fl utter', HostOs.windows),
        p.join(r'C:\fl utter', 'bin', 'dart.bat'),
      );
      expect(
        dartCommand('/opt/flutter', HostOs.linux),
        p.join('/opt/flutter', 'bin', 'dart'),
      );
    });

    test('with no agent set up, it runs nothing, creates no agent folder, '
        'and says so once', () async {
      final first = await refresh();
      expect(first?.outcome, PackageSkillsOutcome.noAgents);
      expect(runner.calls, isEmpty);
      expect(Directory(p.join(project, '.claude')).existsSync(), isFalse);
      expect(Directory(p.join(project, '.agents')).existsSync(), isFalse);
      expect(await refresh(), isNull);
      expect(runner.calls, isEmpty);
    });

    test('a first run installs for the set-up agents and records it', () async {
      setUpClaude();
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      final report = await refresh();
      expect(report?.outcome, PackageSkillsOutcome.refreshed);
      expect(report?.agents, ['claude']);
      expect(report?.recordError, isNull);
      expect(runner.calls, [
        [
          dart(),
          ...args(['claude']),
        ].join(' '),
      ]);
      expect(runner.workingDirectories, [project]);
      final record = PackageSkillsRecord.read(project)!;
      expect(record.succeeded, isTrue);
      expect(record.agents, ['claude']);
      expect(record.pubspec, 'p1');
      expect(record.lock, 'l1');
      expect(record.version, packageSkillsVersion);
    });

    test('unchanged inputs run nothing', () async {
      setUpClaude();
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      await refresh();
      expect(await refresh(), isNull);
      expect(await refresh(retryFailure: false), isNull);
      expect(runner.calls, hasLength(1));
    });

    test(
      'a changed pubspec.yaml, pubspec.lock or agent list runs again',
      () async {
        setUpClaude();
        answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
        await refresh();
        await refresh(pubspec: 'p2');
        await refresh(pubspec: 'p2', lock: 'l2');
        expect(runner.calls, hasLength(3));
        File(p.join(project, 'AGENTS.md')).writeAsStringSync('# Agents\n');
        answer([
          'claude',
          'codex',
        ], const RunResult(exitCode: 0, stdout: _installedBoth));
        final report = await refresh(pubspec: 'p2', lock: 'l2');
        expect(report?.agents, ['claude', 'codex']);
        expect(runner.calls, hasLength(4));
      },
    );

    test(
      'a failure is a warning with the reason, recorded as failed',
      () async {
        setUpClaude();
        answer(['claude'], const RunResult(exitCode: 0, stdout: _badAgent));
        final report = await refresh();
        expect(report?.outcome, PackageSkillsOutcome.failed);
        expect(report?.reason, contains('is not an allowed value'));
        expect(PackageSkillsRecord.read(project)!.succeeded, isFalse);
      },
    );

    test('a full sync retries a failure; detect does not', () async {
      setUpClaude();
      answer([
        'claude',
      ], const RunResult(exitCode: 255, stderr: 'Got socket error'));
      await refresh();
      expect(await refresh(retryFailure: false), isNull);
      expect(runner.calls, hasLength(1));
      final again = await refresh();
      expect(again?.outcome, PackageSkillsOutcome.failed);
      expect(runner.calls, hasLength(2));
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      expect((await refresh())?.outcome, PackageSkillsOutcome.refreshed);
      expect(await refresh(), isNull);
      expect(runner.calls, hasLength(3));
    });

    test('detect still runs when the inputs changed after a failure', () async {
      setUpClaude();
      answer(['claude'], const RunResult(exitCode: 1));
      await refresh();
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      final report = await refresh(lock: 'l2', retryFailure: false);
      expect(report?.outcome, PackageSkillsOutcome.refreshed);
    });

    test('packages that could not be fetched fail without a run', () async {
      setUpClaude();
      final report = await refresh(packagesReady: false);
      expect(report?.outcome, PackageSkillsOutcome.failed);
      expect(report?.reason, 'the packages could not be fetched');
      expect(runner.calls, isEmpty);
      expect(PackageSkillsRecord.read(project)!.succeeded, isFalse);
    });

    test('while another sync holds the lock, it prints nothing and runs '
        'nothing, without waiting', () async {
      setUpClaude();
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      final held = await KnowledgeLock.acquire(
        p.dirname(packageSkillsRecordPath(project)),
      );
      addTearDown(held.release);
      final watch = Stopwatch()..start();
      expect(await refresh(), isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(runner.calls, isEmpty);
      held.release();
      expect((await refresh())?.outcome, PackageSkillsOutcome.refreshed);
    });

    test(
      'a record that cannot be saved is reported with the outcome',
      () async {
        setUpClaude();
        answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
        // A folder where the record file goes makes the rename fail.
        Directory(packageSkillsRecordPath(project)).createSync(recursive: true);
        final report = await refresh();
        expect(report?.outcome, PackageSkillsOutcome.refreshed);
        expect(report?.recordError, isNotNull);
      },
    );

    test('a damaged record means one more run', () async {
      setUpClaude();
      answer(['claude'], const RunResult(exitCode: 0, stdout: _claudeOnly));
      await refresh();
      File(packageSkillsRecordPath(project)).writeAsStringSync('{');
      expect((await refresh())?.outcome, PackageSkillsOutcome.refreshed);
      expect(runner.calls, hasLength(2));
    });
  });
}
