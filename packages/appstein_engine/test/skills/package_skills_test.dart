import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

/// Real package:skills 1.0.3 output, captured on Windows (see the plan).
const _installedBoth =
    '  [claude] Installed skill-pkg-demo\n'
    'Installed 1 skill(s) for claude at .claude/skills.\n'
    '  [generic] Installed skill-pkg-demo\n'
    'Installed 1 skill(s) for generic at .agents/skills.\n';

const _nothingShipped =
    'Installed 0 skill(s) for claude at .claude/skills.\n'
    'Installed 0 skill(s) for generic at .agents/skills.\n';

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

    test('installing nothing still worked: no package ships skills', () {
      expect(
        packageSkillsFailure(
          const RunResult(exitCode: 0, stdout: _nothingShipped),
          ['claude', 'codex'],
        ),
        isNull,
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
}
