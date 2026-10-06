import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

Finding _f(
  String id, {
  Severity severity = Severity.warning,
  String? file,
  int? line,
  String message = 'm',
}) => Finding(
  id: id,
  severity: severity,
  file: file,
  line: line,
  message: message,
);

void main() {
  test('sortFindings: no file first, then file, severity, line, id', () {
    final sorted = sortFindings([
      _f('z.z', file: 'b.dart', line: 12),
      _f('a.a', file: 'b.dart', line: 3),
      _f('b.b', file: 'b.dart'),
      _f('c.c', file: 'b.dart', severity: Severity.info),
      _f('d.d', file: 'b.dart', severity: Severity.error, line: 99),
      _f('e.e', file: 'a.dart'),
      _f('f.f'),
      _f('a.b', file: 'b.dart', line: 3),
      _f('a.a', file: 'b.dart', line: 3, message: 'a'),
    ]);
    expect(
      [
        for (final f in sorted)
          '${f.file ?? '-'} ${f.severity.name} ${f.line ?? '-'} ${f.id} '
              '${f.message}',
      ],
      [
        '- warning - f.f m',
        'a.dart warning - e.e m',
        'b.dart error 99 d.d m',
        'b.dart warning - b.b m',
        'b.dart warning 3 a.a a',
        'b.dart warning 3 a.a m',
        'b.dart warning 3 a.b m',
        'b.dart warning 12 z.z m',
        'b.dart info - c.c m',
      ],
    );
  });

  final result = VerifyResult(
    findings: [
      _f('a.a', severity: Severity.error),
      _f('b.b', file: 'x.md'),
      _f('c.c', file: 'y.md'),
    ],
    suppressed: 3,
    activeSuppressions: 2,
    notRun: const [
      CheckNotRun(id: 'docs.stale', reason: 'the map is not up to date'),
    ],
  );

  test('counts findings by severity', () {
    expect(result.errors, 1);
    expect(result.warnings, 2);
    expect(result.info, 0);
  });

  test('the JSON form is what --format json prints', () {
    expect(result.toJson(), {
      'findings': [
        {'id': 'a.a', 'severity': 'error', 'message': 'm'},
        {'id': 'b.b', 'severity': 'warning', 'file': 'x.md', 'message': 'm'},
        {'id': 'c.c', 'severity': 'warning', 'file': 'y.md', 'message': 'm'},
      ],
      'summary': {'errors': 1, 'warnings': 2, 'info': 0},
      'suppressed': 3,
      'activeSuppressions': 2,
      'notRun': [
        {'id': 'docs.stale', 'reason': 'the map is not up to date'},
      ],
    });
    expect(VerifyResult.fromJson(result.toJson()).toJson(), result.toJson());
  });

  test('an empty result', () {
    expect(const VerifyResult(findings: []).toJson(), {
      'findings': <Object?>[],
      'summary': {'errors': 0, 'warnings': 0, 'info': 0},
      'suppressed': 0,
      'activeSuppressions': 0,
      'notRun': <Object?>[],
    });
  });
}
