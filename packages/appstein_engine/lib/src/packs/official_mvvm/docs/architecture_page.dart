import '../../../docs/doc_page.dart';
import '../../../docs/docs_knowledge.dart';
import '../../../docs/markdown_text.dart';
import '../layer_rules.dart';
import 'concepts.dart';

/// `architecture.md` (spec §6.9): the stack's parts in plain words, a
/// diagram of which layer may use which, and where each layer lives. The
/// diagram and the table are built from the pack's layer rules, so they
/// can't differ from what the `layer_imports` lint enforces.
final class ArchitecturePage implements DocPage {
  /// Creates the page source.
  const ArchitecturePage();

  /// The page's path inside the docs folder.
  static const path = 'architecture.md';

  // Tests may use everything, and a line from every layer to `test` would
  // hide the rest of the diagram.
  static const _test = 'test';

  @override
  String get id => 'architecture';

  @override
  List<DocSection> sections(DocsKnowledge knowledge) {
    const rules = officialMvvmLayerRules;
    final layers = [
      for (final layer in rules.layers.keys)
        if (layer != _test) layer,
    ];
    final ids = {
      for (final (index, layer) in layers.indexed)
        layer: mermaidId('layer', index),
    };
    final diagram = [
      '```mermaid',
      'flowchart TD',
      for (final layer in layers) '  ${ids[layer]}[${mermaidLabel(layer)}]',
      for (final MapEntry(key: from, value: targets) in rules.allow.entries)
        for (final to in targets)
          if (ids.containsKey(from) && ids.containsKey(to))
            '  ${ids[from]} --> ${ids[to]}',
      for (final MapEntry(key: from, value: targets)
          in rules.interfaces.entries)
        for (final to in targets)
          if (ids.containsKey(from) && ids.containsKey(to))
            '  ${ids[from]} -.->|interfaces only| ${ids[to]}',
      '```',
    ].join('\n');
    final free = [
      for (final layer in layers)
        if (!rules.allow.containsKey(layer)) mdCode(layer),
    ];

    final files = knowledge.layers.files.values;
    final untagged = files.where((file) => file.layer == null).length;
    final table = mdTable(
      const ['Layer', 'Folders', 'Files in this app'],
      [
        for (final MapEntry(key: layer, value: globs) in rules.layers.entries)
          [
            mdCode(layer),
            globs.map(mdCode).join(', '),
            '${files.where((file) => file.layer == layer).length}',
          ],
      ],
    ).trimRight();

    final violations = mdTable(
      const ['File', 'Imports', 'From layer', 'To layer'],
      [
        for (final violation in knowledge.layers.violations)
          [
            projectLink(
              docsPath: knowledge.docsPath,
              page: path,
              target: violation.file,
              line: violation.line,
            ),
            mdCode(violation.import),
            mdCode(violation.from),
            mdCode(violation.to),
          ],
      ],
    ).trimRight();

    final parts = <String>[
      "This app follows Flutter's recommended architecture, MVVM (the "
          '${mdCode(knowledge.stack)} stack).',
      '## The parts\n\n'
          '${[for (final MapEntry(:key, :value) in mvvmConcepts.entries) '- **$key.** $value'].join('\n')}',
      '## Which layer may use which\n\n$diagram\n\n'
          'A solid arrow means "may use". A dotted arrow means "may use only '
          'the interfaces of".'
          '${free.isEmpty ? ' The tests may use any layer.' : ' ${_list(free)} may use any layer, and so may the tests.'}',
      '## Where each layer lives\n\n$table'
          '${untagged == 0 ? '' : '\n\n${untagged == 1 ? '1 file is' : '$untagged files are'} in no layer.'}',
      if (violations.isNotEmpty) '## Rule breaks right now\n\n$violations',
    ];
    return [
      DocSection(
        path: path,
        title: 'Architecture',
        markdown: parts.join('\n\n'),
      ),
    ];
  }

  String _list(List<String> items) => items.length == 1
      ? items.single
      : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
}
