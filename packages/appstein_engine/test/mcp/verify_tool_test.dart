import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:dart_mcp/server.dart';
import 'package:test/test.dart';

import 'support/mcp_support.dart';

Finding _finding(Severity severity) => Finding(
  id: 'a.b',
  severity: severity,
  file: 'lib/a.dart',
  line: 3,
  message: 'm',
  fixHint: 'f',
);

void main() {
  ToolReply answer(VerifyResult result, {VerifyMode mode = VerifyMode.full}) =>
      verifyAnswer(result, mode: mode) as ToolReply;

  test('the result is what `appstein verify --format json` prints, and '
      'matches the schema with a freshness', () {
    final result = VerifyResult(
      findings: [_finding(Severity.error), _finding(Severity.info)],
      suppressed: 2,
      notRun: const [CheckNotRun(id: 'docs.stale', reason: 'r')],
    );
    final reply = answer(result);
    expect(reply.result, result.toJson());
    expectMatchesSchema(toolOutputSchema(ToolSchemas.verifyResult), {
      ...reply.result,
      'freshness': const FreshnessReport.current().toJson(),
    });
  });

  test('the output schema keeps the counts as `summary`', () {
    final schema = toolOutputSchema(ToolSchemas.verifyResult);
    final summary = (schema['properties']! as Map)['summary']! as Map;
    expect(summary['type'], 'object');
    expect(schema['required'], containsAll(['summary', 'freshness']));
    expect(
      (schema['required']! as List).where((name) => name == 'summary'),
      hasLength(1),
    );
  });

  test('the input is a scope: fast or full', () {
    expectMatchesSchema(ToolSchemas.verifyInput, {'scope': 'fast'});
    expectMatchesSchema(ToolSchemas.verifyInput, {'scope': 'full'});
    for (final bad in [
      <String, Object?>{},
      {'scope': 'all'},
      {'scope': 3},
    ]) {
      expect(
        Schema.fromMap(ToolSchemas.verifyInput).validate(bad),
        isNotEmpty,
        reason: '$bad',
      );
    }
  });

  group('the sentence', () {
    test('names the mode and the counts', () {
      expect(
        answer(const VerifyResult(findings: [])).summary,
        'Full verify: 0 errors, 0 warnings, 0 info.',
      );
      expect(
        answer(
          VerifyResult(findings: [_finding(Severity.warning)]),
          mode: VerifyMode.fast,
        ).summary,
        'Fast verify: 0 errors, 1 warning, 0 info.',
      );
    });

    test('says that errors block the task', () {
      expect(
        answer(VerifyResult(findings: [_finding(Severity.error)])).summary,
        'Full verify: 1 error, 0 warnings, 0 info. Fix the error before the '
        'task is done.',
      );
      expect(
        answer(
          VerifyResult(
            findings: [_finding(Severity.error), _finding(Severity.error)],
          ),
        ).summary,
        endsWith('Fix the errors before the task is done.'),
      );
    });

    test('says what did not run and what is suppressed', () {
      expect(
        answer(
          const VerifyResult(
            findings: [],
            suppressed: 1,
            notRun: [CheckNotRun(id: 'a.b', reason: 'r')],
          ),
        ).summary,
        'Full verify: 0 errors, 0 warnings, 0 info. 1 check did not run. '
        '1 finding is suppressed.',
      );
      expect(
        answer(
          VerifyResult(
            findings: [_finding(Severity.error)],
            suppressed: 3,
            notRun: const [
              CheckNotRun(id: 'a.b', reason: 'r'),
              CheckNotRun(id: 'a.c', reason: 'r'),
            ],
          ),
        ).summary,
        'Full verify: 1 error, 0 warnings, 0 info. 2 checks did not run. '
        '3 findings are suppressed. Fix the error before the task is done.',
      );
    });
  });
}
