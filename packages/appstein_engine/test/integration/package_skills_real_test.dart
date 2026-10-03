@Tags(['integration'])
library;

import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/machine_sdk.dart';
import '../support/temp.dart';

void main() {
  final environment = HostEnvironment.current();

  test("the real package:skills installs a path dependency's skill for Claude "
      'Code and Codex, in a folder with a space and an umlaut, and a second '
      'refresh runs nothing', () async {
    final sdk = machineSdk(environment);
    if (sdk == null) return;
    final root = tempDir().path;
    final package = p.join(root, 'skill_pkg');
    final app = p.join(root, 'my äpp');
    void write(String path, String text) => File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
    write(
      p.join(package, 'pubspec.yaml'),
      'name: skill_pkg\nversion: 0.1.0\nenvironment:\n  sdk: ^3.10.0\n',
    );
    write(p.join(package, 'lib', 'skill_pkg.dart'), 'int answer() => 42;\n');
    write(
      p.join(package, 'skills', 'skill-pkg-demo', 'SKILL.md'),
      '---\nname: skill-pkg-demo\ndescription: Demo skill shipped by '
      'skill_pkg.\n---\nUse answer().\n',
    );
    write(
      p.join(app, 'pubspec.yaml'),
      'name: probe_app\nenvironment:\n  sdk: ^3.10.0\ndependencies:\n'
      '  skill_pkg:\n    path: ../skill_pkg\n',
    );
    write(p.join(app, 'lib', 'main.dart'), 'void main() {}\n');
    Directory(p.join(app, '.claude')).createSync();
    write(p.join(app, 'AGENTS.md'), '# Agents\n');

    final flutterRoot = sdk.location!.root;
    const runner = SystemProcessRunner();
    final fetch = await fetchPackages(
      app,
      flutterRoot: flutterRoot,
      os: environment.os,
      runner: runner,
    );
    expect(fetch, isNull, reason: 'flutter pub get: $fetch');

    Future<PackageSkillsReport?> refresh() =>
        PackageSkills(runner: runner, os: environment.os).refresh(
          app,
          flutterRoot: flutterRoot,
          configuredAgents: const ['claude', 'codex'],
          pubspecHash: 'p',
          lockHash: 'l',
          packagesReady: true,
          retryFailure: true,
        );

    final first = await refresh();
    expect(
      first?.outcome,
      PackageSkillsOutcome.refreshed,
      reason: first?.reason,
    );
    for (final folder in ['.claude', '.agents']) {
      expect(
        File(
          p.join(app, folder, 'skills', 'skill-pkg-demo', 'SKILL.md'),
        ).existsSync(),
        isTrue,
        reason: folder,
      );
    }
    expect(PackageSkillsRecord.read(app)?.succeeded, isTrue);
    expect(await refresh(), isNull);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('a project whose dependencies ship no skills is refreshed, not a '
      'failure, and a second refresh runs nothing', () async {
    final sdk = machineSdk(environment);
    if (sdk == null) return;
    final app = p.join(tempDir().path, 'plain äpp');
    File(p.join(app, 'pubspec.yaml'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('name: plain_app\nenvironment:\n  sdk: ^3.10.0\n');
    Directory(p.join(app, '.claude')).createSync();
    final flutterRoot = sdk.location!.root;
    const runner = SystemProcessRunner();
    final fetch = await fetchPackages(
      app,
      flutterRoot: flutterRoot,
      os: environment.os,
      runner: runner,
    );
    expect(fetch, isNull, reason: 'flutter pub get: $fetch');

    Future<PackageSkillsReport?> refresh() =>
        PackageSkills(runner: runner, os: environment.os).refresh(
          app,
          flutterRoot: flutterRoot,
          configuredAgents: const ['claude', 'codex'],
          pubspecHash: 'p',
          lockHash: 'l',
          packagesReady: true,
          retryFailure: true,
        );

    final first = await refresh();
    expect(
      first?.outcome,
      PackageSkillsOutcome.refreshed,
      reason: first?.reason,
    );
    expect(PackageSkillsRecord.read(app)?.succeeded, isTrue);
    expect(await refresh(), isNull);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
