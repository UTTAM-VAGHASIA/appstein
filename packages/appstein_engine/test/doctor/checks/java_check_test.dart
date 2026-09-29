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

  RunResult javaVersion(String version) =>
      RunResult(exitCode: 0, stderr: 'openjdk version "$version" 2025-01-21');

  Future<CheckResult> run(Map<String, String> vars) => const JavaCheck().run(
    testContext(environment: fakeEnvironment(vars), runner: runner),
  );

  test('ok for a working JDK 17+ set with flutter config', () async {
    const home = 'configured jdk';
    runner.when(javaIn(home), ['-version'], javaVersion('21.0.2'));
    final result = await run(settings({'jdk-dir': home}));
    expect(result.status, CheckStatus.ok);
    expect(result.summary, contains('JDK 21'));
  });

  test("ok for Android Studio's JDK, which runs only once", () async {
    final studio = fakeStudio(tempDir());
    final java = javaIn(studioJdkHome(studio));
    runner.when(java, ['-version'], javaVersion('21.0.6'));
    final result = await run(settings({'android-studio-dir': studio}));
    expect(result.status, CheckStatus.ok);
    expect(result.summary, contains('Android Studio'));
    expect(runner.calls.where((call) => call.startsWith(java)), hasLength(1));
  });

  // The development machine on 2026-09-29: a broken Android Studio JBR. Flutter
  // skips a Studio whose JDK does not run and uses JAVA_HOME instead.
  test('a broken Android Studio JDK is skipped for JAVA_HOME', () async {
    final studio = fakeStudio(tempDir());
    runner.when(javaIn(studioJdkHome(studio)), [
      '-version',
    ], const RunResult(exitCode: 1, stderr: "Error: could not open `jvm.cfg'"));
    runner.when(javaIn('jdk 21'), ['-version'], javaVersion('21.0.2'));
    final result = await run(
      settings({'android-studio-dir': studio}, {'JAVA_HOME': 'jdk 21'}),
    );
    expect(result.status, CheckStatus.ok);
    expect(result.summary, contains('JAVA_HOME'));
    expect(
      result.details,
      contains(
        'Android Studio at $studio has a JDK that does not run; '
        'Flutter skips it.',
      ),
    );
  });

  test('error for a JDK older than 17', () async {
    runner.when(javaIn('old jdk'), ['-version'], javaVersion('11.0.20'));
    final result = await run(settings({}, {'JAVA_HOME': 'old jdk'}));
    expect(result.status, CheckStatus.error);
    expect(result.summary, contains('17'));
  }, skip: studioInstalledReason());

  test('error when the JDK Flutter uses does not run', () async {
    runner.when(javaIn('configured jdk'), [
      '-version',
    ], const RunResult(exitCode: 1, stderr: 'Error: broken'));
    final result = await run(settings({'jdk-dir': 'configured jdk'}));
    expect(result.status, CheckStatus.error);
    expect(result.summary, contains('does not run'));
  });

  group('JAVA_HOME and the JDK Flutter uses', () {
    late String studio;

    setUp(() {
      studio = fakeStudio(tempDir());
      runner.when(javaIn(studioJdkHome(studio)), [
        '-version',
      ], javaVersion('21.0.6'));
    });

    test('warning when JAVA_HOME is another JDK whose version is '
        'unknown', () async {
      final result = await run(
        settings({'android-studio-dir': studio}, {'JAVA_HOME': 'jdk-17'}),
      );
      expect(result.status, CheckStatus.warning);
      expect(result.summary, contains('JAVA_HOME'));
    });

    test('info when JAVA_HOME is another JDK of the same major', () async {
      runner.when(javaIn('jdk-21'), ['-version'], javaVersion('21.0.2'));
      final result = await run(
        settings({'android-studio-dir': studio}, {'JAVA_HOME': 'jdk-21'}),
      );
      expect(result.status, CheckStatus.info);
      expect(result.summary, contains('JAVA_HOME'));
    });

    test('warning when JAVA_HOME is a JDK of another major', () async {
      runner.when(javaIn('jdk-17'), ['-version'], javaVersion('17.0.9'));
      final result = await run(
        settings({'android-studio-dir': studio}, {'JAVA_HOME': 'jdk-17'}),
      );
      expect(result.status, CheckStatus.warning);
      expect(result.summary, contains('JAVA_HOME'));
      expect(result.summary, contains('JDK 17'));
    });

    test('no JAVA_HOME result when JAVA_HOME is the same JDK', () async {
      final result = await run(
        settings(
          {'android-studio-dir': studio},
          {'JAVA_HOME': studioJdkHome(studio)},
        ),
      );
      expect(result.status, CheckStatus.ok);
    });
  });

  test('ok for java on PATH', () async {
    final bin = tempDir();
    final java = fakeExecutable(bin, 'java');
    runner.when(java, ['-version'], javaVersion('21.0.2'));
    final result = await run(
      settings({}, {'PATH': bin.path, 'PATHEXT': defaultPathExt}),
    );
    expect(result.status, CheckStatus.ok);
    expect(result.summary, contains('on PATH'));
  }, skip: studioInstalledReason());

  test('error when there is no JDK at all', () async {
    final result = await run(settings({}));
    expect(result.status, CheckStatus.error);
  }, skip: studioInstalledReason());
}
