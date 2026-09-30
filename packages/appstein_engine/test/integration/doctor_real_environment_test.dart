@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const runner = SystemProcessRunner();
  final environment = HostEnvironment.current();
  // The Appstein repo is the folder whose .fvmrc pins its Flutter. The tests
  // run from packages/appstein_engine, so the pin is found above them.
  final repoRoot = readFvmPin(Directory.current.path)?.pinDirectory;
  Future<RunResult>? flutterDoctorRun;

  /// The `flutter` launcher of the SDK doctor finds for the repo, so both
  /// sides use the same SDK. When there is none, the test fails in CI and is
  /// skipped elsewhere, and this returns null.
  String? repoFlutter() {
    if (repoRoot == null) {
      fail(
        'No .fvmrc above ${Directory.current.path}. Run the integration '
        'tests from the Appstein repo.',
      );
    }
    final detection = SdkDetector(environment).detect(projectRoot: repoRoot);
    final root = detection.location?.root;
    if (detection.info == null || root == null) {
      final reason =
          'doctor finds no usable Flutter SDK for the repo: '
          '${detection.problem}';
      if (environment.variable('CI') != null) fail(reason);
      markTestSkipped(reason);
      return null;
    }
    return p.join(root, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter');
  }

  /// `flutter doctor -v`, run once and shared by the tests that read it.
  Future<RunResult> flutterDoctor(String flutter) => flutterDoctorRun ??= runner
      .run(flutter, ['doctor', '-v'], timeout: const Duration(minutes: 5));

  /// Appstein's doctor for the repo.
  Future<DoctorReport> appsteinDoctor() => Doctor(
    environment: environment,
    runner: runner,
  ).run(projectRoot: repoRoot);

  CheckResult resultOf(DoctorReport report, String id) =>
      report.entries.singleWhere((entry) => entry.check.id == id).result;

  test('doctor reports the same Flutter version as flutter itself', () async {
    final flutter = repoFlutter();
    if (flutter == null) return;
    final machine = await runner.run(flutter, [
      '--version',
      '--machine',
    ], timeout: const Duration(minutes: 3));
    expect(machine.ok, isTrue, reason: machine.stderr);
    final start = machine.stdout.indexOf('{');
    if (start < 0) {
      fail(
        '`flutter --version --machine` printed no JSON in output: '
        '${machine.stdout}',
      );
    }
    final json =
        jsonDecode(machine.stdout.substring(start)) as Map<String, Object?>;

    final report = await appsteinDoctor();
    expect(
      resultOf(report, 'doctor.flutter').summary,
      contains(json['frameworkVersion']),
    );
    for (final entry in report.entries) {
      expect(
        entry.result.summary,
        isNot(startsWith('The check itself failed')),
        reason: entry.check.id,
      );
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  // Compares Appstein's model of Flutter's JDK lookup with Flutter's own
  // answer on a real machine, where unit tests can only check the model.
  test('the Java check finds the JDK that flutter doctor -v reports', () async {
    final flutter = repoFlutter();
    if (flutter == null) return;
    final doctor = await flutterDoctor(flutter);
    final javaLine = RegExp(
      r'Java binary at: (.+)',
    ).firstMatch(doctor.stdout)?.group(1)?.trim();
    if (javaLine == null) {
      markTestSkipped('flutter doctor -v reports no Java binary');
      return;
    }

    final result = resultOf(await appsteinDoctor(), 'doctor.java');
    final pathLine = result.details
        .where((line) => line.startsWith('Path: '))
        .firstOrNull;
    expect(
      pathLine,
      isNotNull,
      reason: 'The Java check found no JDK: ${result.summary}',
    );
    final appsteinJdk = _jdkHome(pathLine!.substring('Path: '.length));
    expect(
      p.equals(appsteinJdk, _jdkHome(javaLine)),
      isTrue,
      reason: 'Appstein: $appsteinJdk\nflutter doctor -v: $javaLine',
    );
  }, timeout: const Timeout(Duration(minutes: 7)));

  // The same comparison for the Android SDK: which platform is newest, and
  // which build-tools Flutter pairs with it.
  test('the Android SDK check names the platform and build-tools flutter '
      'doctor -v reports', () async {
    final flutter = repoFlutter();
    if (flutter == null) return;
    final doctor = await flutterDoctor(flutter);
    final line = RegExp(
      r'Platform (\S+), build-tools (\S+)',
    ).firstMatch(doctor.stdout);
    if (line == null) {
      markTestSkipped('flutter doctor -v reports no Android SDK');
      return;
    }
    final result = resultOf(await appsteinDoctor(), 'doctor.android_sdk');
    expect(
      result.summary,
      contains('platform ${line[1]}, build-tools ${line[2]}'),
      reason: 'flutter doctor -v: ${line[0]}',
    );
  }, timeout: const Timeout(Duration(minutes: 7)));
}

/// [path] without a trailing `bin/java` or `bin/java.exe`.
String _jdkHome(String path) {
  final name = p.basename(path).toLowerCase();
  final parent = p.dirname(path);
  return (name == 'java' || name == 'java.exe') && p.basename(parent) == 'bin'
      ? p.dirname(parent)
      : path;
}
