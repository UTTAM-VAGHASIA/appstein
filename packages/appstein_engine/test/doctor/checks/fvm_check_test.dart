import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/fake_process_runner.dart';
import '../../support/temp.dart';

void main() {
  late Directory project;
  late Directory tools;

  setUp(() {
    project = tempDir();
    tools = tempDir();
  });

  Future<CheckResult> run({bool pin = false, bool fvmInstalled = false}) {
    if (pin) {
      File(
        p.join(project.path, '.fvmrc'),
      ).writeAsStringSync('{"flutter": "3.47.5"}');
    }
    if (fvmInstalled) fakeExecutable(tools, 'fvm');
    return const FvmCheck().run(
      testContext(
        projectRoot: project.path,
        environment: fakeEnvironment({
          'PATH': tools.path,
          'PATHEXT': defaultPathExt,
        }),
      ),
    );
  }

  test('ok when the project pins a version and fvm is installed', () async {
    final result = await run(pin: true, fvmInstalled: true);
    expect(result.status, CheckStatus.ok);
    expect(result.summary, contains('3.47.5'));
  });

  test('warning when the project pins a version but fvm is missing', () async {
    expect((await run(pin: true)).status, CheckStatus.warning);
  });

  test('info when fvm is installed but the project has no pin', () async {
    expect((await run(fvmInstalled: true)).status, CheckStatus.info);
  });

  test('skipped when neither is present', () async {
    expect((await run()).status, CheckStatus.skipped);
  });

  test('a broken pin file is not a second error', () async {
    File(p.join(project.path, '.fvmrc')).writeAsStringSync('{oops');
    final result = await const FvmCheck().run(
      testContext(projectRoot: project.path),
    );
    expect(result.status, CheckStatus.info);
    expect(result.summary, contains('Flutter SDK'));
    expect(result.details.join(' '), contains('.fvmrc'));
  });

  test('a broken pin file counts as one error in a doctor run', () async {
    File(p.join(project.path, '.fvmrc')).writeAsStringSync('{oops');
    final report = await Doctor(
      environment: fakeEnvironment({}),
      runner: FakeProcessRunner(),
      checks: const [FlutterCheck(), FvmCheck()],
    ).run(projectRoot: project.path);
    final errors = report.entries.where(
      (entry) => entry.result.status == CheckStatus.error,
    );
    expect(errors.map((entry) => entry.check.id), ['doctor.flutter']);
  });

  test('finds a pin in a parent folder and shows where it is', () async {
    File(
      p.join(project.path, '.fvmrc'),
    ).writeAsStringSync('{"flutter": "3.47.5"}');
    fakeExecutable(tools, 'fvm');
    final member = Directory(p.join(project.path, 'packages', 'app'))
      ..createSync(recursive: true);
    final result = await const FvmCheck().run(
      testContext(
        projectRoot: member.path,
        environment: fakeEnvironment({
          'PATH': tools.path,
          'PATHEXT': defaultPathExt,
        }),
      ),
    );
    expect(result.status, CheckStatus.ok);
    expect(
      result.details,
      contains('pin file: ${p.join(project.path, '.fvmrc')}'),
    );
  });
}
