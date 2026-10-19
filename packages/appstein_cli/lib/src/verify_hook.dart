import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart' show loopGuardLimit;
import 'package:appstein_protocol/appstein_protocol.dart';

import 'exit_codes.dart';
import 'failure.dart';
import 'finding_text.dart';

/// What Claude Code tells a hook on stdin (spec §5.3): the session's ID, the
/// event's name and, at Stop, whether the agent is already continuing because
/// of a Stop hook. Every field is null (or false) when the input did not give
/// it.
final class HookInput {
  /// Creates the input.
  const HookInput({
    this.sessionId,
    this.eventName,
    this.stopHookActive = false,
  });

  /// The agent session's ID (`session_id`); null counts as no session.
  final String? sessionId;

  /// The event that fired the hook (`hook_event_name`), such as
  /// `PostToolUse`.
  final String? eventName;

  /// Whether the agent is already continuing because a Stop hook blocked it
  /// (`stop_hook_active`). Missing, or not exactly `true`, counts as not
  /// continuing.
  final bool stopHookActive;
}

/// Reads the hook input from [text]: input that is empty or not a JSON object
/// is no session, a field that is not a non-empty string is left out, and
/// `stop_hook_active` is true only when it is the JSON `true`.
HookInput parseHookInput(String text) {
  // A pipe from Windows PowerShell may start with a byte order mark, which
  // the JSON parser refuses.
  final body = text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF
      ? text.substring(1)
      : text;
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return const HookInput();
  }
  if (decoded is! Map<String, Object?>) return const HookInput();
  final fields = decoded;
  String? field(String name) {
    final value = fields[name];
    return value is String && value.isNotEmpty ? value : null;
  }

  return HookInput(
    sessionId: field('session_id'),
    eventName: field('hook_event_name'),
    stopHookActive: fields['stop_hook_active'] == true,
  );
}

/// How long a hook waits for its input to end before it goes on without it.
const hookInputLimit = Duration(seconds: 2);

/// Reads stdin (or [source]) to its end as text, for the hook's input. Claude
/// Code writes the input and closes the pipe at once; the wait is limited to
/// [limit] only to protect against a caller that never does, and the input is
/// then taken as missing. It is also empty when stdin is a terminal (nobody
/// is piping a hook's input to it), closed, or unreadable.
Future<String> readStdinText({
  Stream<List<int>>? source,
  Duration limit = hookInputLimit,
}) async {
  try {
    if (source == null && stdin.hasTerminal) return '';
    final bytes = <int>[];
    final ended = Completer<void>();
    final subscription = (source ?? stdin).listen(
      bytes.addAll,
      onDone: () {
        if (!ended.isCompleted) ended.complete();
      },
      onError: (Object _) {
        if (!ended.isCompleted) ended.complete();
      },
      cancelOnError: true,
    );
    try {
      await ended.future.timeout(limit);
    } on TimeoutException {
      return '';
    } finally {
      // Without this a pipe that is still open keeps the process alive.
      await subscription.cancel();
    }
    return utf8.decode(bytes, allowMalformed: true);
  } on Object {
    return '';
  }
}

/// The two events of Claude Code that `appstein verify --hook claude`
/// answers, which differ in what reaches whom (spec §5.4, §9.5).
enum HookKind {
  /// The PostToolUse hook, after an edit: errors block with exit 2, warnings
  /// are context for the agent, and the run may stay silent when nothing
  /// changed.
  afterEdit,

  /// The Stop hook, when the agent says it is done: errors block with exit 2,
  /// but warnings and everything else go to the developer only, since context
  /// for the agent would keep it going. The loop guard belongs to it.
  stop,
}

/// What kind of hook run [arguments] ask for, or null when they do not ask for
/// `appstein verify` in Claude Code's hook mode (`--hook claude`, or
/// `--hook=claude`). The flags decide: a `--fast` run is [HookKind.afterEdit]
/// and any other, a full run, is [HookKind.stop]. This is what is known before
/// any input is read, so a failure of Appstein in such a run is told the
/// hook's way, wherever in the process it happens; once the input is read,
/// [hookKindOf] has the final say. Arguments after `--` are not options, so
/// they never make a run a hook run.
HookKind? claudeHookKind(List<String> arguments) {
  final options = _optionsOf(arguments);
  if (!options.contains('verify')) return null;
  for (var i = 0; i < options.length; i++) {
    if (options[i] == '--hook=claude' ||
        (options[i] == '--hook' &&
            i + 1 < options.length &&
            options[i + 1] == 'claude')) {
      return options.contains('--fast') ? HookKind.afterEdit : HookKind.stop;
    }
  }
  return null;
}

/// What kind of hook run this is, decided in this one place: the event the
/// input names ([HookInput.eventName]) when it names one, `Stop` being the
/// Stop hook and any other event the after-edit hook; the flags ([fast]: the
/// run was given `--fast`) when the input names none (it is missing,
/// unreadable, or has no event). A hook that Claude Code fires for another
/// event than the one its flags suit (a PostToolUse hook set up without
/// `--fast`) is answered as the event it is, and so never reads or saves the
/// Stop hook's loop guard.
HookKind hookKindOf(HookInput input, {required bool fast}) =>
    switch (input.eventName) {
      null => fast ? HookKind.afterEdit : HookKind.stop,
      'Stop' => HookKind.stop,
      _ => HookKind.afterEdit,
    };

/// The arguments before `--`: the words after it are not options.
List<String> _optionsOf(List<String> arguments) {
  final end = arguments.indexOf('--');
  return end < 0 ? arguments : arguments.sublist(0, end);
}

/// What a hook run sends back to Claude Code: the exit code, the text for
/// stdout (the JSON of exit 0) and the text for stderr (what exit 2 shows the
/// agent).
final class HookReply {
  /// Creates the reply.
  const HookReply({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.isFailure = false,
  });

  /// Whether this is the reply to a failure of Appstein itself, whose
  /// [stderr] holds the details of the failure.
  final bool isFailure;

  /// The process exit code: 0, or 2 to block with [stderr].
  final int exitCode;

  /// What goes to stdout; empty for nothing.
  final String stdout;

  /// What goes to stderr; empty for nothing.
  final String stderr;
}

/// The one answer a hook run may give Claude Code. A hook's output is read
/// as one JSON document and one exit code, but a run can have two writers: the
/// command with its result, and the failure handlers (`runAppstein`'s catch,
/// `runGuarded`'s zone) for an error raised outside every future, which can
/// fire while the command is still running. Every writer goes through
/// [write], so only the first speaks:
/// - the first reply is written whole and its exit code stands;
/// - a later one writes nothing to stdout, and only the details of a failure
///   to stderr, and nothing at all once the first reply was exit 2, whose
///   stderr is what the agent reads, so a late crash's trace cannot push
///   past the agent's limit;
/// - the exit code it returns is always the first one's.
final class HookAnswer {
  /// Creates an answer that nothing has been written to.
  HookAnswer();

  static final Object _zoneKey = Object();

  /// The answer of the run in the current zone, if `runGuarded` made one.
  static HookAnswer? get current => Zone.current[_zoneKey] as HookAnswer?;

  /// The zone values that make this answer the [current] one.
  Map<Object?, Object?> get zoneValues => {_zoneKey: this};

  int? _exitCode;

  /// Whether a reply was written.
  bool get answered => _exitCode != null;

  /// The exit code of the reply written first, or null before any.
  int? get exitCode => _exitCode;

  /// Writes [reply] to [out] and [err] if it is the first, and returns the
  /// exit code that stands.
  int write(HookReply reply, StringSink out, StringSink err) {
    final first = _exitCode;
    if (first == null) {
      _exitCode = reply.exitCode;
      out.write(reply.stdout);
      err.write(reply.stderr);
      return reply.exitCode;
    }
    if (first != ExitCodes.hookBlocked && reply.isFailure) {
      err.write(reply.stderr);
    }
    return first;
  }
}

/// The most findings a hook run lists before it says how many more there are.
const maxHookFindings = 30;

/// The most characters Claude Code takes of a hook's context or message:
/// longer text is saved to a file and the agent gets only a preview of it.
const maxHookContextLength = 10000;

// What every text of a hook may be, whatever it holds: a little under the
// limit.
const _textLimit = maxHookContextLength - 100;

// What the findings may take of a text: the rest is for the sentence around
// them and the checks that did not run.
const _findingsBudget = 9000;

// What the list of checks that did not run may take, and a failure's reason.
const _notRunLimit = 2500;
const _reasonLimit = 4000;

// What one finding's texts may be, so that a single long message cannot
// push the text over the limit.
const _fieldLimit = 1500;
const _nameLimit = 500;

/// Marks a text that was cut short.
const _cutMarker = '…(cut)';

/// The reply to Claude Code's PostToolUse hook for [result], the answer of a
/// fast run (spec §9.5):
/// - an error: exit 2 and the errors on stderr, which Claude Code shows the
///   agent;
/// - a warning and no error: exit 0 and JSON on stdout with the warnings as
///   context for the agent;
/// - only info findings: nothing, unless a check did not run, which is told
///   as context so silence never hides an unchecked edit.
///
/// The notices of the run (an analysis server a stop could not end, and how
/// to end it by hand) go to the developer as the JSON `systemMessage`, in
/// every case but the failure.
///
/// Findings are listed grouped by file as the text output groups them, with
/// the fix hint and the knowledge reference, cut at [maxHookFindings]. Every
/// text is also cut so that none passes [maxHookContextLength]: each
/// finding's fields, the list of checks that did not run, and the whole,
/// with `…(cut)` where something was left out.
///
/// At exit 2 the checks that did not run are on stderr with the errors, the
/// channel Claude Code documents as reaching the agent on that code ("shows
/// stderr to Claude; the tool already ran"). The docs also say a hook that
/// exits 2 and prints valid JSON has its JSON read, which is how the notices
/// reach the developer there, but they name stderr for the agent.
HookReply claudePostToolUseReply(VerifyResult result) {
  final sections = _ReplySections(result);
  if (sections.errors.isNotEmpty) return sections.blocked();
  final notice = sections.notice;
  if (sections.warnings.isEmpty && sections.notRun.isEmpty && notice == null) {
    return const HookReply(exitCode: ExitCodes.ok);
  }
  final forAgent = _cut(
    [
      if (sections.warnings.isNotEmpty)
        sections.warningsText(
          'Appstein checked the project after your change',
          _findingsBudget - sections.notRun.length,
        ),
      if (sections.notRun.isNotEmpty) sections.notRun,
    ].join('\n'),
    _textLimit,
  );
  return HookReply(
    exitCode: ExitCodes.ok,
    stdout: _json({
      if (forAgent.isNotEmpty)
        'hookSpecificOutput': {
          'hookEventName': 'PostToolUse',
          'additionalContext': forAgent,
        },
      'systemMessage': ?notice,
    }),
  );
}

/// What both replies of a run are made of, cut to what they may take: the
/// errors and the warnings, the files `--apply` rewrote, the checks that did
/// not run and the notices. The after-edit reply and the Stop reply put the
/// same parts to different readers.
final class _ReplySections {
  /// Cuts the parts of [result]: the list of checks that did not run, and the
  /// files rewritten (by their number and length), at [_notRunLimit]; the
  /// notices at [_textLimit].
  _ReplySections(VerifyResult result)
    : notRun = _cut(_notRunSection(result.notRun), _notRunLimit),
      notice = result.notices.isEmpty
          ? null
          : _cut('Appstein note: ${result.notices.join(' ')}', _textLimit),
      errors = _of(result, Severity.error),
      warnings = _of(result, Severity.warning),
      applied = _appliedSection(result.applied);

  /// The checks that did not run, or empty.
  final String notRun;

  /// The notices of the run for the developer, or null.
  final String? notice;

  /// The findings that are errors, and those that are warnings.
  final List<Finding> errors, warnings;

  /// The files `--apply` rewrote, to be read again before they are edited, or
  /// empty.
  final String applied;

  /// The reply that blocks: exit 2 with the files `--apply` rewrote, the
  /// errors and the checks that did not run on stderr, which Claude Code shows
  /// the agent, and the notices for the developer on stdout. The same at
  /// "done" and after an edit (a fast run rewrites no file, so it names none).
  HookReply blocked() => HookReply(
    exitCode: ExitCodes.hookBlocked,
    stdout: notice == null ? '' : _json({'systemMessage': notice}),
    stderr: _cut(
      applied +
          _list(errors, _findingsBudget - notRun.length - applied.length) +
          (notRun.isEmpty ? '' : '\n$notRun'),
      _textLimit,
    ),
  );

  /// The sentence that says "no errors, N warnings" after [subject], and the
  /// warnings listed within [budget] characters.
  String warningsText(String subject, int budget) =>
      '$subject: no errors, ${warnings.length} '
      '${warnings.length == 1 ? 'warning' : 'warnings'}.\n\n'
      '${_list(warnings, budget)}';
}

/// The files `--apply` rewrote, as the text output names them: to be read
/// again before they are edited. At most [maxHookFindings] are named, then how
/// many more; empty when there are none.
String _appliedSection(List<String> applied) {
  if (applied.isEmpty) return '';
  final header = applied.length == 1
      ? 'Rewritten by --apply (read this file again before you edit it):'
      : 'Rewritten by --apply (read these files again before you edit them):';
  // Names are added while they fit the section's share of the text; the line
  // that says how many are left out has room reserved.
  final named = <String>[];
  var length = header.length;
  for (final file in applied.take(maxHookFindings)) {
    final line = '  ${_cut(file, _nameLimit)}';
    if (length + line.length + 1 > _notRunLimit - 40) break;
    named.add(line);
    length += line.length + 1;
  }
  final left = applied.length - named.length;
  return [
    header,
    ...named,
    if (left > 0) '  …and $left more',
    '',
    '',
  ].join('\n');
}

/// The reply to Claude Code's Stop hook for [result], the answer of a full
/// run when the agent says it is done (spec §5.4, §9.5). What reaches whom
/// differs from [claudePostToolUseReply]: context for the agent at Stop would
/// keep it going, so only a block speaks to the agent, and everything else
/// goes to the developer as the JSON `systemMessage`:
/// - an error: exit 2 and the errors on stderr, as after an edit, headed by
///   the files `--apply` rewrote when it rewrote any (the agent reads them
///   again before it edits them);
/// - an error, but [letGo] (the loop guard: the same errors have blocked the
///   agent [loopGuardLimit] times in a row): exit 0, and a message for the
///   developer listing the remaining errors;
/// - a warning and no error: exit 0 and a message for the developer listing
///   the warnings;
/// - only info findings, or nothing: nothing at all, unless a check did not
///   run or the run has a notice, which are told to the developer so silence
///   never hides an unchecked project.
///
/// The notices of the run join the developer's message, or go beside the
/// errors of exit 2 as in [claudePostToolUseReply]. Every text is cut as
/// there, so none passes [maxHookContextLength].
HookReply claudeStopReply(VerifyResult result, {bool letGo = false}) {
  final sections = _ReplySections(result);
  final errors = sections.errors;
  if (errors.isNotEmpty && !letGo) return sections.blocked();
  // The notice shares the message with the findings, so it is cut shorter
  // than when it is alone, and the findings get what is left.
  final notice = sections.notice == null
      ? null
      : _cut(sections.notice!, _notRunLimit);
  final budget =
      _findingsBudget - sections.notRun.length - (notice?.length ?? 0);
  final parts = [
    if (errors.isNotEmpty)
      'Appstein let the agent stop with ${errors.length} '
          '${errors.length == 1 ? 'error' : 'errors'} left: the same '
          '${errors.length == 1 ? 'error has' : 'errors have'} blocked it '
          '$loopGuardLimit times in a row in this session. The remaining '
          '${errors.length == 1 ? 'error' : 'errors'}:\n\n'
          '${_list(errors, budget)}'
    else if (sections.warnings.isNotEmpty)
      sections.warningsText('Appstein checked the project', budget),
    if (sections.notRun.isNotEmpty) sections.notRun,
    ?notice,
  ];
  if (parts.isEmpty) return const HookReply(exitCode: ExitCodes.ok);
  return HookReply(
    exitCode: ExitCodes.ok,
    stdout: _json({'systemMessage': _cut(parts.join('\n'), _textLimit)}),
  );
}

/// Whether a hook run completed its checks, so that the next run with nothing
/// changed may stay silent (spec §9.1): none of its checks is named as not
/// run (an analysis server that was still starting, a part cut short by a cap),
/// and it reports neither `knowledge.stale` (the knowledge could not be
/// brought up to date) nor `dart.plugin_failed` (a plugin's rules were not
/// checked). It is not the rule by which `verify` lets no file leave the
/// unverified files (the engine's `partial`): that one looks at those two
/// findings before the suppressions are applied and only at a code check named
/// as not run, while this one looks at the result, after the suppressions, and
/// at every check named as not run. Errors found do not make a run
/// incomplete: they are reported, and stay in the unverified files.
bool hookRunCompleted(VerifyResult result) =>
    result.notRun.isEmpty &&
    !result.findings.any(
      (finding) =>
          finding.id == 'knowledge.stale' || finding.id == 'dart.plugin_failed',
    );

/// The reply when Appstein itself failed with [reason] (what is exit 3 in the
/// terminal): exit 0 so the agent is never blocked by it, a context telling
/// the agent its edit is unchecked and why, and a message telling the
/// developer the same with the way to repair it (spec §9.5). [details] (the
/// failure as the terminal would show it, a crash's trace included) goes to
/// stderr, which Claude Code keeps only in its debug log at exit 0, so a bug
/// report has it.
///
/// At Stop ([HookKind.stop]) the developer's message is all there is: context
/// for the agent at Stop would keep it going, so a broken tool never does
/// (spec §9.5).
HookReply claudeFailureReply(
  String reason, {
  required HookKind kind,
  String details = '',
}) {
  final why = _sentence(reason);
  return HookReply(
    exitCode: ExitCodes.ok,
    stdout: _json(switch (kind) {
      HookKind.stop => {
        'systemMessage':
            'Appstein could not check the project at "done", so it is '
            'unchecked. $why You can run `appstein doctor` to check '
            'your setup.',
      },
      HookKind.afterEdit => {
        'hookSpecificOutput': {
          'hookEventName': 'PostToolUse',
          'additionalContext':
              'Appstein verify could not run, so your last change is '
              'unchecked: $why Do not take the project for free of '
              'errors.',
        },
        'systemMessage':
            'Appstein could not check an edit. $why You can run '
            '`appstein doctor` to check your setup.',
      },
    }),
    stderr: details,
    isFailure: true,
  );
}

/// Writes the hook's answer to a failure of Appstein ([claudeFailureReply])
/// to [out] and [err] through [answer], and returns the exit code that
/// stands: 0 when this is the first answer, since in hook mode a failure
/// never blocks the agent, wherever in the process it happens; the first
/// answer's when there was one ([HookAnswer.write]). The failure of a
/// [HookKind.stop] run is told to the developer only.
int answerHookFailure(
  StringSink out,
  StringSink err,
  FailureDescription failure,
  HookAnswer answer, {
  required HookKind kind,
}) => answer.write(
  claudeFailureReply(failure.reason, details: failure.text, kind: kind),
  out,
  err,
);

List<Finding> _of(VerifyResult result, Severity severity) => [
  for (final finding in result.findings)
    if (finding.severity == severity) finding,
];

/// [reason] on one line, cut to [_reasonLimit], ending with a full stop.
String _sentence(String reason) {
  final line = _cut(
    reason.trim().replaceAll(RegExp(r'\s*\n\s*'), ' '),
    _reasonLimit,
  );
  return line.endsWith('.') || line.endsWith(_cutMarker) ? line : '$line.';
}

String _json(Map<String, Object?> value) => '${jsonEncode(value)}\n';

/// [text] if it is at most [limit] characters long, else its start with
/// [_cutMarker] after it, within [limit].
String _cut(String text, int limit) {
  if (text.length <= limit) return text;
  var end = limit - _cutMarker.length;
  // Not between the two halves of a character outside the basic plane.
  if (end > 0 && (text.codeUnitAt(end - 1) & 0xFC00) == 0xD800) end--;
  return '${text.substring(0, end)}$_cutMarker';
}

/// [finding] with each text cut, so that one long message cannot fill the
/// whole answer.
Finding _shortened(Finding finding) => Finding(
  id: _cut(finding.id, _nameLimit),
  severity: finding.severity,
  file: finding.file == null ? null : _cut(finding.file!, _nameLimit),
  line: finding.line,
  message: _cut(finding.message, _fieldLimit),
  fixHint: finding.fixHint == null ? null : _cut(finding.fixHint!, _fieldLimit),
  knowledgeRef: finding.knowledgeRef == null
      ? null
      : _cut(finding.knowledgeRef!, _nameLimit),
);

String _notRunSection(List<CheckNotRun> notRun) => notRun.isEmpty
    ? ''
    : [
        'These checks did not run, so your change is not checked by them:',
        for (final check in notRun)
          '  ${_cut(check.id, _nameLimit)}: ${_cut(check.reason, _fieldLimit)}',
        '',
      ].join('\n');

/// [findings] grouped by file with fix hints and knowledge references, the
/// first [maxHookFindings] of them that fit in [budget] characters, then
/// how many more there are.
String _list(List<Finding> findings, int budget) {
  final ordered = [for (final f in orderedFindings(findings)) _shortened(f)];
  String listing(int count) => findingLines(
    ordered.take(count).toList(),
    knowledge: true,
  ).join('\n').trimRight();
  var count = ordered.length < maxHookFindings
      ? ordered.length
      : maxHookFindings;
  // The line that says how many are left out, with room for a big number.
  const more = 90;
  while (count > 1 &&
      listing(count).length + (count < ordered.length ? more : 0) > budget) {
    count--;
  }
  final left = ordered.length - count;
  return '${listing(count)}\n'
      '${left == 0 ? '' : '\n…and $left more: call the `verify` tool for '
                'all\n'}';
}
