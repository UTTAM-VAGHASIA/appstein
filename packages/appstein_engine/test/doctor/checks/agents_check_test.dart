import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/fake_process_runner.dart';
import '../../support/temp.dart';

void main() {
  test('warning when no supported agent CLI is installed', () async {
    final result = await const AgentsCheck().run(testContext());
    expect(result.status, CheckStatus.warning);
  });

  test('ok when one is installed, and it only asks for the version', () async {
    final bin = tempDir();
    final claude = fakeExecutable(bin, 'claude');
    final runner = FakeProcessRunner()
      ..when(claude, [
        '--version',
      ], const RunResult(exitCode: 0, stdout: '2.1.3 (Claude Code)\n'));
    final result = await const AgentsCheck().run(
      testContext(
        environment: fakeEnvironment({
          'PATH': bin.path,
          'PATHEXT': defaultPathExt,
        }),
        runner: runner,
      ),
    );
    expect(result.status, CheckStatus.ok);
    expect(result.details.join('\n'), contains('Codex: not installed'));
    // Never touch credentials: only `--version` may run.
    expect(runner.calls, everyElement(endsWith('--version')));
  });
}
