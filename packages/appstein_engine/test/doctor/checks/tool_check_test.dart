import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/fake_process_runner.dart';
import '../../support/temp.dart';

void main() {
  test('ok with the first line of --version', () async {
    final bin = tempDir();
    final git = fakeExecutable(bin, 'git');
    final runner = FakeProcessRunner()
      ..when(git, [
        '--version',
      ], const RunResult(exitCode: 0, stdout: 'git version 2.47.1\n'));
    final result = await gitCheck.run(
      testContext(
        environment: fakeEnvironment({
          'PATH': bin.path,
          'PATHEXT': defaultPathExt,
        }),
        runner: runner,
      ),
    );
    expect(result.status, CheckStatus.ok);
    expect(result.summary, 'git version 2.47.1');
  });

  test('missing is a warning that says why and how to install', () async {
    final result = await ripgrepCheck.run(testContext());
    expect(result.status, CheckStatus.warning);
    expect(result.summary, contains('Dart MCP server'));
    expect(result.fixHint, isNotEmpty);
  });
}
