import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/fake_android.dart';
import '../../support/fake_process_runner.dart';
import '../../support/temp.dart';

void main() {
  late Directory settingsDir;
  late FakeProcessRunner runner;

  setUp(() {
    settingsDir = tempDir();
    runner = FakeProcessRunner();
  });

  Map<String, String> settings(
    Map<String, Object?> values, [
    Map<String, String> extra = const {},
  ]) {
    File(p.join(settingsDir.path, '.flutter_settings')).writeAsStringSync(
      '{${values.entries.map((e) => '"${e.key}": "${e.value}"').join(', ')}}'
          .replaceAll(r'\', r'\\'),
    );
    return {
      if (Platform.isWindows)
        'APPDATA': settingsDir.path
      else
        'HOME': settingsDir.path,
      ...extra,
    };
  }

  String javaIn(String home) =>
      p.join(home, 'bin', Platform.isWindows ? 'java.exe' : 'java');

  Future<CheckResult> run(Map<String, String> vars) => const JavaCheck().run(
    testContext(environment: fakeEnvironment(vars), runner: runner),
  );

  test('ok for a working JDK 17+ set with flutter config', () async {
    const home = 'configured jdk';
    runner.when(
      javaIn(home),
      ['-version'],
      const RunResult(
        exitCode: 0,
        stderr: 'openjdk version "21.0.2" 2024-01-16',
      ),
    );
    final result = await run(settings({'jdk-dir': home}));
    expect(result.status, CheckStatus.ok);
    expect(result.summary, contains('JDK 21'));
  });

  // The development machine on 2026-09-29: a broken Android Studio JBR.
  test("error when Android Studio's JDK does not run", () async {
    final studio = fakeStudio(tempDir());
    final home = studioJdkHome(studio);
    runner.when(javaIn(home), [
      '-version',
    ], const RunResult(exitCode: 1, stderr: "Error: could not open `jvm.cfg'"));
    final result = await run(
      settings({'android-studio-dir': studio}, {'JAVA_HOME': 'some other jdk'}),
    );
    expect(result.status, CheckStatus.error);
    expect(result.summary, contains('Android Studio'));
    expect(result.summary, contains('could not open'));
    expect(result.fixHint, contains('flutter config --jdk-dir'));
  });

  test('error for a JDK older than 17', () async {
    runner.when(
      javaIn('old jdk'),
      ['-version'],
      const RunResult(
        exitCode: 0,
        stderr: 'openjdk version "11.0.20" 2023-07-18',
      ),
    );
    final result = await run(settings({}, {'JAVA_HOME': 'old jdk'}));
    expect(result.status, CheckStatus.error);
    expect(result.summary, contains('17'));
  }, skip: studioInstalledReason());

  test('warning when Flutter uses a different JDK than JAVA_HOME', () async {
    final studio = fakeStudio(tempDir());
    final home = studioJdkHome(studio);
    runner.when(
      javaIn(home),
      ['-version'],
      const RunResult(
        exitCode: 0,
        stderr: 'openjdk version "21.0.6" 2025-01-21',
      ),
    );
    final result = await run(
      settings({'android-studio-dir': studio}, {'JAVA_HOME': 'jdk-17'}),
    );
    expect(result.status, CheckStatus.warning);
    expect(result.summary, contains('JAVA_HOME'));
  });

  test('error when there is no JDK at all', () async {
    final result = await run(settings({}));
    expect(result.status, CheckStatus.error);
  }, skip: studioInstalledReason());
}
