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

  test(
    'an unreadable pubspec.yaml is a readable result, not a crash',
    () async {
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsBytesSync([0x6e, 0xff, 0xfe, 0x0a]);
      final result = await run();
      expect(result.status, CheckStatus.error);
      expect(result.summary, contains('pubspec.yaml'));
      expect(result.summary, isNot(contains('bug in Appstein')));
      expect(result.fixHint, isNot(contains('bug in Appstein')));
    },
  );

  test('an appstein.yaml that cannot be read gets a fix without a '
      'position', () async {
    File(
      p.join(project.path, 'appstein.yaml'),
    ).writeAsBytesSync([0x61, 0x3a, 0x20, 0xff, 0xfe, 0x0a]);
    final result = await run();
    expect(result.status, CheckStatus.error);
    expect(result.summary, contains('Could not read appstein.yaml'));
    expect(
      result.fixHint,
      'Make sure appstein.yaml is a readable UTF-8 text file.',
    );
  });
}
