import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import '../decisions/decision_file.dart';
import '../decisions/decision_store.dart';
import '../knowledge/knowledge_lock.dart';
import '../knowledge/knowledge_write_exception.dart';
import '../knowledge/plain_text.dart';
import 'decisions_query.dart';
import 'tool_answer.dart';

const _fromProject = 'Give paths from the project folder, such as `lib/ui/**`.';

/// The `record_decision` tool (spec §6.7, §8): checks [arguments], then
/// adds a decision, replaces one, or accepts a proposed one in the project
/// at [projectRoot]. [today] is the date a new decision gets.
///
/// Anything it can't do is a [ToolRefusal] that says why, and then nothing
/// was written.
Future<ToolAnswer> recordDecision(
  String projectRoot,
  Map<String, Object?> arguments, {
  required String today,
  Duration lockTimeout = const Duration(seconds: 10),
}) async {
  final DecisionRequest request;
  try {
    request = _request(arguments);
  } on DecisionRefused catch (refusal) {
    return ToolRefusal(refusal.message);
  }
  final DecisionWritten written;
  try {
    written = await writeDecision(
      projectRoot,
      request,
      today: today,
      lockTimeout: lockTimeout,
    );
  } on DecisionRefused catch (refusal) {
    return ToolRefusal(refusal.message);
  } on KnowledgeLockTimeout catch (error) {
    return ToolRefusal('$error');
  } on KnowledgeWriteException catch (error) {
    return ToolRefusal('$error');
  }

  final decision = written.decision;
  final number = decision.record.numberText!;
  final where = decisionPath(decision.record.file);
  return ToolReply(
    {
      'action': written.action,
      'decision': decisionJson(decision),
      if (written.superseded case final superseded?)
        'superseded': decisionJson(superseded),
      'warning': ?written.warning,
    },
    [
      if (written.action == 'accepted')
        'Decision $number is now accepted.'
      else
        'Recorded decision $number as ${decision.status.jsonName} in $where.',
      if (written.action != 'accepted' &&
          decision.status == DecisionStatus.proposed)
        'It binds once the user agrees: then call record_decision with '
            'accept: "$number".',
      if (written.superseded?.record.numberText case final old?)
        'It replaces $old, which is now superseded.',
      ?written.warning,
    ].join(' '),
  );
}

/// The request [arguments] make, or a [DecisionRefused] that says what is
/// wrong with them.
DecisionRequest _request(Map<String, Object?> arguments) {
  final given = <String, Object>{
    for (final MapEntry(:key, :value) in arguments.entries) key: ?value,
  };
  if (given['accept'] case final accept?) {
    if (given.length > 1) {
      throw const DecisionRefused(
        'Pass `accept` alone, or the fields of a new decision (`title`, '
        '`why`), not both.',
      );
    }
    return AcceptDecision(_number(accept));
  }
  final title = given['title'];
  final why = given['why'];
  if (title is! String || why is! String) {
    throw const DecisionRefused(
      'Pass `title` and `why` to record a decision, or `accept` with the '
      'number of a proposed decision.',
    );
  }
  final line = oneLine(title);
  if (line.isEmpty) {
    throw const DecisionRefused(
      'The title is empty. Say in one line what was decided.',
    );
  }
  if (line.runes.length > decisionTitleLength) {
    throw DecisionRefused(
      'The title has ${line.runes.length} characters; keep it to '
      '$decisionTitleLength and put the detail in `why`.',
    );
  }
  final reason = why.trim().replaceFirst(
    RegExp(r'^why:\s*', caseSensitive: false),
    '',
  );
  if (reason.isEmpty) {
    throw const DecisionRefused(
      'The reason (`why`) is empty. A decision is recorded with its reason.',
    );
  }
  final status = switch (given['status']) {
    null || 'proposed' => DecisionStatus.proposed,
    'accepted' => DecisionStatus.accepted,
    final other => throw DecisionRefused(
      'The status of a new decision is `proposed` or `accepted`, not '
      '`$other`.',
    ),
  };
  final checks = _list(given['checks'], 'checks');
  for (final check in checks) {
    if (!decisionChecks.contains(check)) {
      throw DecisionRefused(
        '`$check` is not a decision check. The checks are '
        '${decisionChecks.map((check) => '`$check`').join(' and ')}.',
      );
    }
  }
  return AddDecision(
    title: line,
    why: reason,
    status: status,
    paths: [for (final path in _list(given['paths'], 'paths')) _path(path)],
    checks: checks,
    supersedes: switch (given['supersedes']) {
      null => null,
      final number => _number(number),
    },
  );
}

int _number(Object value) {
  final number = switch (value) {
    final int number => number,
    final String digits when RegExp(r'^\d+$').hasMatch(digits.trim()) =>
      int.parse(digits.trim()),
    _ => 0,
  };
  if (number < 1) {
    throw DecisionRefused(
      '`$value` is not a decision number. Give it as `0002` or `2`.',
    );
  }
  return number;
}

List<String> _list(Object? value, String name) => switch (value) {
  null => const [],
  final List<Object?> items when items.every((item) => item is String) =>
    items.cast<String>(),
  _ => throw DecisionRefused('`$name` is a list of strings.'),
};

/// [raw] as a path pattern from the project folder, with `/` separators.
String _path(String raw) {
  var path = raw.trim().replaceAll(r'\', '/');
  if (path.isEmpty) {
    throw const DecisionRefused('A path in `paths` is empty.');
  }
  if (path.startsWith('/') || RegExp('^[A-Za-z]:').hasMatch(path)) {
    throw DecisionRefused('`$raw` is an absolute path. $_fromProject');
  }
  while (path.startsWith('./')) {
    path = path.substring(2);
  }
  if (path.split('/').contains('..')) {
    throw DecisionRefused('`$raw` leaves the project folder. $_fromProject');
  }
  try {
    Glob(path, context: p.posix);
  } on FormatException catch (error) {
    throw DecisionRefused(
      '`$raw` is not a valid path pattern (${error.message}).',
    );
  }
  return path;
}
