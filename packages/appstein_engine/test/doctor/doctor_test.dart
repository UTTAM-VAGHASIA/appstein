import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/temp.dart';

final class _StaticCheck implements DoctorCheck {
  _StaticCheck(this.id, this.result);

  @override
  final String id;

  final CheckResult result;

  @override
  String get title => id;

  @override
  Future<CheckResult> run(DoctorContext context) async => result;
}

final class _ThrowingCheck implements DoctorCheck {
  @override
  String get id => 'boom';

  @override
  String get title => 'Boom';

  @override
  Future<CheckResult> run(DoctorContext context) async =>
      throw StateError('kaboom');
}

void main() {
  Doctor doctorWith(List<DoctorCheck> checks) => Doctor(
    environment: fakeEnvironment({}),
    runner: FakeProcessRunner(),
    checks: checks,
  );

  test('runs every check and keeps their order', () async {
    final report = await doctorWith([
      _StaticCheck('a', const CheckResult.ok('fine')),
      _StaticCheck('b', const CheckResult.warning('hmm')),
    ]).run();
    expect(report.entries.map((e) => e.check.id), ['a', 'b']);
    expect(report.hasErrors, isFalse);
  });

  test('an error result makes the report have errors', () async {
    final report = await doctorWith([
      _StaticCheck('a', const CheckResult.error('broken')),
    ]).run();
    expect(report.hasErrors, isTrue);
  });

  test('a check that throws becomes an error, not a crash', () async {
    final report = await doctorWith([_ThrowingCheck()]).run();
    expect(report.entries.single.result.status, CheckStatus.error);
    expect(report.entries.single.result.summary, contains('kaboom'));
  });
}
