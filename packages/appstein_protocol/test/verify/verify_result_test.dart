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
      'applied': <Object?>[],
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
      'applied': <Object?>[],
    });
  });

  test('applied: always in the JSON form, empty without --apply, read back, '
      'kept by withNotices, and a result written without the field reads as '
      'having none', () {
    const plain = VerifyResult(findings: []);
    expect(plain.applied, isEmpty);
    final applied = plain.withApplied(const ['lib/a.dart', 'lib/b.dart']);
    expect(applied.toJson()['applied'], ['lib/a.dart', 'lib/b.dart']);
    expect(VerifyResult.fromJson(applied.toJson()).applied, applied.applied);
    expect(applied.withNotices(const ['Note.']).applied, applied.applied);
    expect(
      VerifyResult.fromJson(plain.toJson()..remove('applied')).applied,
      isEmpty,
    );
  });

  test('notices: in the JSON form only when there are any, read back, and '
      'a result written without the field reads as having none', () {
    const plain = VerifyResult(findings: []);
    expect(plain.notices, isEmpty);
    expect(plain.toJson().containsKey('notices'), isFalse);
    expect(VerifyResult.fromJson(plain.toJson()).notices, isEmpty);
    expect(plain.withNotices(const []), same(plain));

    final told = plain.withNotices(const ['Process 7 was left running.']);
    expect(told.toJson()['notices'], ['Process 7 was left running.']);
    expect(VerifyResult.fromJson(told.toJson()).notices, told.notices);
    // They are no findings: the counts stay.
    expect(told.errors + told.warnings + told.info, 0);
    expect(told.withNotices(const ['Another.']).notices, [
      'Process 7 was left running.',
      'Another.',
    ]);
  });
}
