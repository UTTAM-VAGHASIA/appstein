import 'package:appstein_protocol/appstein_protocol.dart';

import '../../decisions/decision_store.dart';
import '../doc_page.dart';
import '../docs_knowledge.dart';
import '../markdown_text.dart';

/// `decisions.md` (spec §6.9): every accepted decision with its reason,
/// then the proposed ones nobody has agreed to yet, then the superseded
/// ones, read by the rules of §6.7.
final class DecisionsPage implements DocPage {
  /// Creates the page source.
  const DecisionsPage();

  /// The page's path inside the docs folder.
  static const path = 'decisions.md';

  @override
  String get id => 'decisions';

  @override
  List<DocSection> sections(DocsKnowledge knowledge) {
    final set = knowledge.decisions;
    List<DecisionEntry> having(DecisionStatus status) => [
      for (final entry in set.entries)
        if (entry.status == status) entry,
    ];
    final accepted = having(DecisionStatus.accepted);
    final proposed = having(DecisionStatus.proposed);
    final superseded = having(DecisionStatus.superseded);
    final problems = [
      if (set.folderProblem case final problem?)
        "The decisions folder can't be read: ${mdText(problem)}.",
      for (final file in set.unreadable)
        "${mdCode(file.file)} can't be read: ${mdText(file.problem)}.",
      for (final MapEntry(key: number, value: files) in set.duplicates.entries)
        'The number $number is used by more than one file: '
            '${files.map(mdCode).join(', ')}.',
      for (final problem in set.problems) mdText(problem),
    ];

    final parts = <String>[
      'A decision is a choice that binds later work, with the reason for it. '
          'An agent proposes one; it counts once a person has agreed to it.',
      if (set.entries.isEmpty && problems.isEmpty)
        'No decisions are recorded yet.',
      if (accepted.isNotEmpty)
        '## Accepted\n\n'
            '${accepted.map((entry) => _decision(knowledge, entry)).join('\n\n')}',
      if (proposed.isNotEmpty)
        '## Proposed, not yet agreed\n\n'
            'Nobody has agreed to these yet. To accept one, ask the agent to '
            'accept it (`record_decision` with `accept`), or change its '
            '`status:` line to `accepted`.\n\n'
            '${proposed.map((entry) => _decision(knowledge, entry)).join('\n\n')}',
      if (superseded.isNotEmpty)
        '## Superseded\n\n'
            '${superseded.map((entry) => _supersededLine(knowledge, entry)).join('\n')}',
      if (problems.isNotEmpty)
        '## Problems\n\n${problems.map((line) => '- $line').join('\n')}',
    ];
    return [
      DocSection(path: path, title: 'Decisions', markdown: parts.join('\n\n')),
    ];
  }

  String _name(DecisionRecord record) {
    final number = record.number;
    return '${number == null ? '' : '${decisionNumberText(number)} '}'
        '${mdText(record.title)}';
  }

  String _record(DocsKnowledge knowledge, DecisionRecord record) => projectLink(
    docsPath: knowledge.docsPath,
    page: path,
    target: decisionPath(record.file),
    text: 'record',
  );

  String _decision(DocsKnowledge knowledge, DecisionEntry entry) {
    final record = entry.record;
    final why = record.why.trim();
    return [
      '### ${_name(record)}',
      '${record.date == null ? '' : 'Recorded ${mdText(record.date!)}. '}'
          'See the ${_record(knowledge, record)}.',
      if (record.paths.isNotEmpty)
        'Applies to: ${record.paths.map(mdCode).join(', ')}',
      if (why.isEmpty) 'No reason recorded.' else mdQuote(why),
    ].join('\n\n');
  }

  String _supersededLine(DocsKnowledge knowledge, DecisionEntry entry) {
    final by = entry.supersededBy;
    final replaced = switch (by?.number) {
      final number? => ', replaced by ${decisionNumberText(number)}',
      null when by != null => ', replaced by ${mdCode(by.file)}',
      null => '',
    };
    return '- ${_name(entry.record)}$replaced '
        '(${_record(knowledge, entry.record)})';
  }
}
