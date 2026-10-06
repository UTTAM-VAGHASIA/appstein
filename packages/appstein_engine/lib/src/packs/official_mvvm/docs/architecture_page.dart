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
    // Layers that share a first name, such as `data.repository` and
    // `data.service`, are drawn as one box when each may use all the
    // others: an arrow for every pair would hide the diagram. The table
    // below the diagram lists every rule.
    final boxes = <String, List<String>>{};
    for (final layer in layers) {
      if (layer.contains('.')) {
        (boxes[layer.split('.').first] ??= []).add(layer);
      }
    }
    boxes.removeWhere(
      (_, members) =>
          members.length < 2 ||
          !members.every(
            (from) => members.every(
              (to) => from == to || (rules.allow[from]?.contains(to) ?? false),
            ),
          ),
    );
    final boxIds = {
      for (final (index, name) in boxes.keys.indexed)
        name: mermaidId('group', index),
    };
    String? boxOf(String layer) => boxes.entries
        .where((box) => box.value.contains(layer))
        .firstOrNull
        ?.key;
    // What every layer of a box may use, outside the box.
    final shared = {
      for (final MapEntry(key: name, value: members) in boxes.entries)
        name: [
          for (final to in rules.allow[members.first]!)
            if (ids.containsKey(to) &&
                !members.contains(to) &&
                members.every((from) => rules.allow[from]!.contains(to)))
              to,
        ],
    };

    final drawn = <String>{};
    final diagram = [
      '```mermaid',
      'flowchart TD',
      for (final layer in layers)
        if (boxOf(layer) case final box?)
          if (drawn.add(box)) ...[
            '  subgraph ${boxIds[box]}[${mermaidLabel(box)}]',
            for (final member in boxes[box]!)
              '    ${ids[member]}[${mermaidLabel(member)}]',
            '  end',
          ] else
            ...const <String>[]
        else
          '  ${ids[layer]}[${mermaidLabel(layer)}]',
      for (final from in layers)
        if (boxOf(from) case final box?) ...[
          if (boxes[box]!.first == from)
            for (final to in shared[box]!) '  ${boxIds[box]} --> ${ids[to]}',
          for (final to in rules.allow[from]!)
            if (ids.containsKey(to) &&
                !boxes[box]!.contains(to) &&
                !shared[box]!.contains(to))
              '  ${ids[from]} --> ${ids[to]}',
        ] else
          for (final to in rules.allow[from] ?? const <String>[])
            if (ids.containsKey(to)) '  ${ids[from]} --> ${ids[to]}',
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
    final rulesTable = mdTable(
      const ['Layer', 'May use', 'May use only the interfaces of'],
      [
        for (final layer in layers)
          [
            mdCode(layer),
            switch (rules.allow[layer]) {
              null => 'any layer',
              final targets =>
                targets.where(ids.containsKey).map(mdCode).join(', '),
            },
            (rules.interfaces[layer] ?? const <String>[])
                .where(ids.containsKey)
                .map(mdCode)
                .join(', '),
          ],
      ],
    ).trimRight();

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
          '${boxes.keys.map((box) => ' The layers in the ${mdCode(box)} box may use each other.').join()}'
          '${free.isEmpty ? ' The tests may use any layer.' : ' ${_list(free)} may use any layer, and so may the tests.'}'
          '\n\n$rulesTable',
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
