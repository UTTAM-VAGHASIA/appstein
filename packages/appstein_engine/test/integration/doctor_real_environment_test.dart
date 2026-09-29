@Tags(['integration'])
library;

import 'dart:convert';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  test('doctor reports the same Flutter version as flutter itself', () async {
    final environment = HostEnvironment.current();
    final flutter = findExecutable('flutter', environment);
    if (flutter == null) {
      markTestSkipped('flutter is not on PATH');
      return;
    }
    const runner = SystemProcessRunner();
    final machine = await runner.run(flutter, [
      '--version',
      '--machine',
    ], timeout: const Duration(minutes: 3));
    expect(machine.ok, isTrue, reason: machine.stderr);
    final json =
        jsonDecode(machine.stdout.substring(machine.stdout.indexOf('{')))
            as Map<String, Object?>;

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
}
