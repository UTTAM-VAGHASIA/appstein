import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

final class _Named implements DoctorCheck {
  const _Named(this.title);

  @override
  final String title;

  @override
  String get id => 'x';

  @override
  Future<CheckResult> run(DoctorContext context) => throw UnimplementedError();
}

void main() {
  test('prints aligned ASCII labels, details, fixes and a summary', () {
    final text = formatDoctorReport(
      const DoctorReport([
        DoctorEntry(
          _Named('Flutter SDK'),
          CheckResult.ok('Flutter 3.47.5 (stable)', details: ['Found']),
        ),
        DoctorEntry(
          _Named('JDK'),
          CheckResult.error('broken', fixHint: 'repair it'),
        ),
        DoctorEntry(_Named('git'), CheckResult.warning('old')),
      ]),
      projectRoot: '/work/app',
    );
    expect(text, contains('Project: /work/app'));
    expect(text, contains('[ok]    Flutter SDK: Flutter 3.47.5 (stable)'));
    expect(text, contains('        Found'));
    expect(text, contains('[error] JDK: broken'));
    expect(text, contains('        Fix: repair it'));
    expect(text, contains('Summary: 1 error, 1 warning.'));
    expect(text.codeUnits.every((c) => c < 128), isTrue);
  });

  test('says so when nothing is wrong, and when there is no project', () {
    final text = formatDoctorReport(const DoctorReport([]));
    expect(text, contains('Project: none found here'));
    expect(text, contains('No problems found.'));
  });
}
