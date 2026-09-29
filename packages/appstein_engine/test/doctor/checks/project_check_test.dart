import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/temp.dart';

void main() {
  late Directory project;

  setUp(() {
    project = tempDir();
    File(
      p.join(project.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: a\nenvironment:\n  sdk: ^3.9.0\n');
  });

  Future<CheckResult> run() =>
      const ProjectCheck().run(testContext(projectRoot: project.path));

  test('skipped outside a project', () async {
    final result = await const ProjectCheck().run(testContext());
    expect(result.status, CheckStatus.skipped);
  });

  test('info without appstein.yaml, and shows the language version', () async {
    final result = await run();
    expect(result.status, CheckStatus.info);
    expect(result.details.join('\n'), contains('3.9'));
  });

  test('ok with a valid appstein.yaml', () async {
    File(
      p.join(project.path, 'appstein.yaml'),
    ).writeAsStringSync('appstein: 1\n');
    final result = await run();
    expect(result.status, CheckStatus.ok);
    expect(result.details.join('\n'), contains('official_mvvm'));
  });

  test('error with an invalid appstein.yaml, pointing at the line', () async {
    File(
      p.join(project.path, 'appstein.yaml'),
    ).writeAsStringSync('appstein: 1\nbogus: true\n');
    final result = await run();
    expect(result.status, CheckStatus.error);
    expect(result.summary, contains(':2:'));
    expect(result.summary, contains('Unknown key "bogus"'));
  });
}
