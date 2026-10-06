import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../../decisions/decision_store.dart';
import '../../knowledge/plain_text.dart';
import '../decision_check.dart';
import '../verify_check.dart';

const _drift = 'decision.drift';
const _unreadable = 'decision.unreadable';
const _duplicate = 'decision.duplicate';
const _folder = '.appstein/decisions';
const _driftFix =
    'Bring the code back in line, or replace the decision with a new one '
    '(`record_decision` with `supersedes`).';

/// `decision.drift`, `decision.unreadable` and `decision.duplicate` (spec
/// §6.7), all warnings:
///
/// - **drift:** an accepted decision names a check that no longer holds, or
///   one no pack of the project provides. Proposed and superseded decisions
///   are never checked, and "superseded" is the readers' status: a decision
///   another one replaces, whatever its own status line says.
/// - **unreadable:** a decision file, or the folder, can't be read, or
///   decisions supersede each other in a circle.
/// - **duplicate:** two files have the same number.
///
/// It runs without the project map. A decision check that reads the map is
/// skipped while the map can't be read: the run reports `knowledge.stale`
/// then, and a guess from an old map would be worse than no answer.
final class DecisionsCheck implements VerifyCheck {
  /// Creates the check with every decision check of the project.
  const DecisionsCheck(this.decisionChecks);

  /// The checks a decision can name: the engine's and each pack's.
  final List<DecisionCheck> decisionChecks;

  @override
  List<String> get ids => const [_drift, _unreadable, _duplicate];

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    final decisions = context.decisions;
    Finding finding(
      String id,
      String file,
      String message, {
      int? line,
      String? fixHint,
      String? knowledgeRef,
    }) => Finding(
      id: id,
      severity: Severity.warning,
      file: file,
      line: line,
      message: message,
      fixHint: fixHint,
      knowledgeRef: knowledgeRef,
    );

    final findings = <Finding>[
      if (decisions.folderProblem case final problem?)
        finding(
          _unreadable,
          _folder,
          'The decisions folder could not be listed ($problem).',
        ),
      for (final file in decisions.unreadable)
        finding(
          _unreadable,
          decisionPath(file.file),
          "The decision can't be read: ${file.problem}.",
          fixHint:
              'Fix its front matter (spec format: id, title, status, date, '
              'paths, checks), or delete the file.',
        ),
      for (final sentence in decisions.problems)
        finding(_unreadable, _folder, sentence),
    ];

    final next = decisionNumberText(decisions.nextNumber);
    for (final MapEntry(key: number, value: files)
        in decisions.duplicates.entries) {
      for (final file in files) {
        final others = [
          for (final other in files)
            if (other != file) '`$other`',
        ];
        findings.add(
          finding(
            _duplicate,
            decisionPath(file),
            'Decision ${decisionNumberText(number)} is also '
            '${others.join(' and ')}.',
            fixHint: 'Rename one of them to the next free number, $next.',
          ),
        );
      }
    }

    final mapReady = context.knowledge.mapProblem == null;
    for (final entry in decisions.entries) {
      if (entry.status != DecisionStatus.accepted) continue;
      final record = entry.record;
      final path = decisionPath(record.file);
      final bytes = decisions.bytes[record.file];
      int? lineOf(String key) => bytes == null ? null : _keyLine(bytes, key);

      for (final name in record.checks.toSet()) {
        DecisionCheck? check;
        for (final candidate in decisionChecks) {
          if (candidate.id == name) check = candidate;
        }
        if (check == null) {
          findings.add(
            finding(
              _drift,
              path,
              'The decision names the check `$name`, which no pack of this '
              'project provides.',
              line: lineOf('checks'),
              fixHint:
                  'Remove the name from `checks:`, or add the pack that '
                  'provides it to `appstein.yaml`.',
              knowledgeRef: path,
            ),
          );
          continue;
        }
        if (check.needsMap && !mapReady) continue;
        final line = lineOf(name == 'paths.exist' ? 'paths' : 'checks');
        for (final sentence in check.problems(entry, context)) {
          findings.add(
            finding(
              _drift,
              path,
              sentence,
              line: line,
              fixHint: _driftFix,
              knowledgeRef: path,
            ),
          );
        }
      }
    }
    return findings;
  }
}

/// The 1-based line of [key] in the front matter of a decision file with
/// these [bytes]; null when it has none. The same line whatever the file's
/// line endings are and whether it starts with a byte order mark.
int? _keyLine(List<int> bytes, String key) {
  final lines = [
    for (final line in withoutBom(
      utf8.decode(bytes, allowMalformed: true),
    ).split('\n'))
      line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
  ];
  if (lines.isEmpty || lines.first.trimRight() != '---') return null;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trimRight() == '---') return null;
    if (lines[i].startsWith('$key:')) return i + 1;
  }
  return null;
}
