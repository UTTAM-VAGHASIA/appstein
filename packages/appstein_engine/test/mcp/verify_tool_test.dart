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

  test('notices are in the result, which still matches the schema, and in '
      'the sentence', () {
    const notice = 'Process 7 (dart.exe) may be an analysis server.';
    final reply = answer(
      const VerifyResult(findings: []).withNotices(const [notice]),
    );
    expect(reply.result['notices'], [notice]);
    expectMatchesSchema(toolOutputSchema(ToolSchemas.verifyResult), {
      ...reply.result,
      'freshness': const FreshnessReport.current().toJson(),
    });
    expect(reply.summary, 'Full verify: 0 errors, 0 warnings, 0 info. $notice');
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

  test('the input is a scope: fast or full, and optional files that the '
      'schema says are for a fast run', () {
    expectMatchesSchema(ToolSchemas.verifyInput, {'scope': 'fast'});
    expectMatchesSchema(ToolSchemas.verifyInput, {'scope': 'full'});
    expectMatchesSchema(ToolSchemas.verifyInput, {
      'scope': 'fast',
      'files': ['lib/a.dart', 'lib/my file.dart'],
    });
    final files =
        (ToolSchemas.verifyInput['properties']! as Map)['files']! as Map;
    expect(
      files['description'],
      allOf(
        contains('`scope: fast` only'),
        contains('outside the project'),
        contains('project root'),
      ),
    );
    expectMatchesSchema(ToolSchemas.verifyInput, {
      'scope': 'full',
      'apply': true,
    });
    final apply =
        (ToolSchemas.verifyInput['properties']! as Map)['apply']! as Map;
    expect(
      apply['description'],
      allOf(
        contains('`scope: full` only'),
        contains('`applied`'),
        contains('read those again'),
        contains('`scope: fast` is refused'),
      ),
    );
    for (final bad in [
      <String, Object?>{},
      {'scope': 'all'},
      {'scope': 3},
      {'scope': 'fast', 'files': 'lib/a.dart'},
      {
        'scope': 'fast',
        'files': [3],
      },
      {'scope': 'full', 'apply': 'yes'},
    ]) {
      expect(
        Schema.fromMap(ToolSchemas.verifyInput).validate(bad),
        isNotEmpty,
        reason: '$bad',
      );
    }
  });

  test('the files apply rewrote are in `applied`, which the schema requires '
      'and describes, and the sentence starts by naming them', () {
    final reply = answer(
      const VerifyResult(
        findings: [],
      ).withApplied(const ['lib/a.dart', 'lib/b.dart']),
    );
    expect(reply.result['applied'], ['lib/a.dart', 'lib/b.dart']);
    expectMatchesSchema(toolOutputSchema(ToolSchemas.verifyResult), {
      ...reply.result,
      'freshness': const FreshnessReport.current().toJson(),
    });
    expect(
      reply.summary,
      '`apply` rewrote 2 files (lib/a.dart, lib/b.dart): read them again '
      'before you edit them. Full verify: 0 errors, 0 warnings, 0 info.',
    );
    final schema = toolOutputSchema(ToolSchemas.verifyResult);
    expect(schema['required'], contains('applied'));
    expect(
      ((schema['properties']! as Map)['applied']! as Map)['description'],
      contains('Read these files again'),
    );
    // Without apply the list is there, empty, and the sentence says nothing.
    final plain = answer(const VerifyResult(findings: []));
    expect(plain.result['applied'], isEmpty);
    expect(plain.summary, 'Full verify: 0 errors, 0 warnings, 0 info.');
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
