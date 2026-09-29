import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
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

  test('error when the pin file is broken', () async {
    File(p.join(project.path, '.fvmrc')).writeAsStringSync('{oops');
    final result = await const FvmCheck().run(
      testContext(projectRoot: project.path),
    );
    expect(result.status, CheckStatus.error);
  });
}
