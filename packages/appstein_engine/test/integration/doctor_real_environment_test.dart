@Tags(['integration'])
library;

import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  const runner = SystemProcessRunner();

  test('doctor reports the same Flutter version as flutter itself', () async {
    final environment = HostEnvironment.current();
    final flutter = findExecutable('flutter', environment);
    if (flutter == null) {
      markTestSkipped('flutter is not on PATH');
      return;
    }
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

    final report = await Doctor(environment: environment, runner: runner).run();
    final flutterEntry = report.entries.singleWhere(
      (e) => e.check.id == 'doctor.flutter',
    );
    expect(flutterEntry.result.summary, contains(json['frameworkVersion']));
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
    final environment = HostEnvironment.current();
    final flutter = findExecutable('flutter', environment);
    if (flutter == null) {
      markTestSkipped('flutter is not on PATH');
      return;
    }
    final doctor = await runner.run(flutter, [
      'doctor',
      '-v',
    ], timeout: const Duration(minutes: 5));
    final javaLine = RegExp(
      r'Java binary at: (.+)',
    ).firstMatch(doctor.stdout)?.group(1)?.trim();
    if (javaLine == null) {
      markTestSkipped('flutter doctor -v reports no Java binary');
      return;
    }

    final report = await Doctor(environment: environment, runner: runner).run();
    final result = report.entries
        .singleWhere((e) => e.check.id == 'doctor.java')
        .result;
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
}

/// [path] without a trailing `bin/java` or `bin/java.exe`.
String _jdkHome(String path) {
  final name = p.basename(path).toLowerCase();
  final parent = p.dirname(path);
  return (name == 'java' || name == 'java.exe') && p.basename(parent) == 'bin'
      ? p.dirname(parent)
      : path;
}
