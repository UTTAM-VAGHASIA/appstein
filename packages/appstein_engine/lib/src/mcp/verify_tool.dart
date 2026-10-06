import 'package:appstein_protocol/appstein_protocol.dart';

import '../verify/verify_check.dart';
import 'tool_answer.dart';

String _count(int count, String one, String many) =>
    '$count ${count == 1 ? one : many}';

/// The `verify` tool's answer (spec §8): [result] as `appstein verify
/// --format json` prints it, and a sentence with the counts for [mode] that
/// says what did not run, what is suppressed, and that errors block the
/// task.
///
/// The result has a `summary` of its own (the counts, spec §9.3), so the
/// sentence is in the reply's text only.
ToolAnswer verifyAnswer(VerifyResult result, {required VerifyMode mode}) {
  final sentences = [
    '${mode == VerifyMode.fast ? 'Fast' : 'Full'} verify: '
        '${_count(result.errors, 'error', 'errors')}, '
        '${_count(result.warnings, 'warning', 'warnings')}, '
        '${result.info} info.',
    if (result.notRun.isNotEmpty)
      '${_count(result.notRun.length, 'check', 'checks')} did not run.',
    if (result.suppressed > 0)
      '${_count(result.suppressed, 'finding is', 'findings are')} '
          'suppressed.',
    if (result.errors > 0)
      'Fix the ${result.errors == 1 ? 'error' : 'errors'} before the task '
          'is done.',
  ];
  return ToolReply(result.toJson(), sentences.join(' '));
}
