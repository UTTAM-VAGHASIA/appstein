import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/fake_process_runner.dart';
import '../../support/temp.dart';

void main() {
  late FakeProcessRunner runner;
  setUp(() => runner = FakeProcessRunner());

  Future<CheckResult> xcode(HostOs os) => const XcodeCheck().run(
    testContext(
      environment: fakeEnvironment({}, os: os),
      runner: runner,
    ),
  );

  test('skipped outside macOS', () async {
    expect((await xcode(HostOs.windows)).status, CheckStatus.skipped);
  });

  test('ok for Xcode 26', () async {
    runner.when(
      'xcodebuild',
      ['-version'],
      const RunResult(
        exitCode: 0,
        stdout: 'Xcode 26.0\nBuild version 17A324\n',
      ),
    );
    final result = await xcode(HostOs.macos);
    expect(result.status, CheckStatus.ok);
    expect(result.summary, 'Xcode 26.0');
  });

  test('error for Xcode older than 26', () async {
    runner.when(
      'xcodebuild',
      ['-version'],
      const RunResult(exitCode: 0, stdout: 'Xcode 16.4\nBuild version 16F6\n'),
    );
    expect((await xcode(HostOs.macos)).status, CheckStatus.error);
  });

  test('error when Xcode is missing', () async {
    expect((await xcode(HostOs.macos)).status, CheckStatus.error);
  });

  test('CocoaPods missing on macOS is only a warning', () async {
    final result = await const CocoaPodsCheck().run(
      testContext(
        environment: fakeEnvironment({}, os: HostOs.macos),
        runner: runner,
      ),
    );
    expect(result.status, CheckStatus.warning);
    expect(result.summary, contains('2026-12-02'));
  });
}
