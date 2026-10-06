import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../../../docs/support/docs_support.dart';

String _render({LayersMap? layers}) {
  final sections = const ArchitecturePage().sections(
    sampleKnowledge(layers: layers),
  );
  expect(sections.single.path, 'architecture.md');
  expect(sections.single.title, 'Architecture');
  return sections.single.markdown;
}

String _diagram(String text) {
  final start = text.indexOf('```mermaid\n');
  return text.substring(start, text.indexOf('\n```', start));
}

void main() {
  test('explains the parts in plain words', () {
    final text = _render();
    expect(
      text,
      startsWith(
        "This app follows Flutter's recommended architecture, MVVM (the "
        '`official_mvvm` stack).\n\n## The parts\n\n- **Screen.** ',
      ),
    );
    for (final part in [
      'Screen',
      'View model',
      'Repository',
      'Service',
      'Domain model and use case',
    ]) {
      expect(text, contains('- **$part.** '));
    }
  });

  test('draws the layers, with the data layers as one box', () {
    expect(
      _diagram(_render()),
      '```mermaid\n'
      'flowchart TD\n'
      '  layer_0["ui"]\n'
      '  subgraph group_0["data"]\n'
      '    layer_1["data.repository"]\n'
      '    layer_2["data.service"]\n'
      '    layer_3["data.model"]\n'
      '  end\n'
      '  layer_4["domain"]\n'
      '  layer_5["routing"]\n'
      '  layer_6["config"]\n'
      '  layer_7["utils"]\n'
      '  layer_0 --> layer_4\n'
      '  layer_0 --> layer_5\n'
      '  layer_0 --> layer_6\n'
      '  layer_0 --> layer_7\n'
      '  group_0 --> layer_4\n'
      '  group_0 --> layer_5\n'
      '  group_0 --> layer_6\n'
      '  group_0 --> layer_7\n'
      '  layer_4 --> layer_7\n'
      '  layer_0 -.->|interfaces only| layer_1\n'
      '  layer_0 -.->|interfaces only| layer_2\n'
      '  layer_4 -.->|interfaces only| layer_1',
    );
  });

  test('the diagram says exactly what the layer rules allow', () {
    final diagram = _diagram(_render());
    final labels = <String, String>{};
    final members = <String, List<String>>{};
    String? group;
    for (final line in diagram.split('\n')) {
      if (RegExp(r'^  subgraph (\w+)\[').firstMatch(line) case final open?) {
        group = open[1];
        members[group!] = [];
      } else if (line == '  end') {
        group = null;
      } else if (RegExp(r'^\s+(\w+)\["([^"]+)"\]$').firstMatch(line)
          case final node?) {
        labels[node[1]!] = node[2]!;
        if (group != null) members[group]!.add(node[2]!);
      }
    }
    List<String> layersOf(String id) => members[id] ?? [labels[id]!];
    Set<String> edges(RegExp pattern) => {
      for (final match in pattern.allMatches(diagram))
        for (final from in layersOf(match[1]!))
          for (final to in layersOf(match[2]!)) '$from > $to',
    };
    const rules = officialMvvmLayerRules;
    expect(labels.values, [
      for (final layer in rules.layers.keys)
        if (layer != 'test') layer,
    ]);
    expect(
      {
        ...edges(RegExp(r'^  (\w+) --> (\w+)$', multiLine: true)),
        // A box means its layers may use each other.
        for (final box in members.values)
          for (final from in box)
            for (final to in box)
              if (from != to) '$from > $to',
      },
      {
        for (final MapEntry(key: from, value: targets) in rules.allow.entries)
          for (final to in targets)
            if (to != 'test') '$from > $to',
      },
    );
    expect(
      edges(
        RegExp(r'^  (\w+) -\.->\|interfaces only\| (\w+)$', multiLine: true),
      ),
      {
        for (final MapEntry(key: from, value: targets)
            in rules.interfaces.entries)
          for (final to in targets) '$from > $to',
      },
    );
  });

  test('explains the arrows and gives the rules as a table', () {
    expect(
      _render(),
      contains(
        'A solid arrow means "may use". A dotted arrow means "may use only '
        'the interfaces of". The layers in the `data` box may use each '
        'other. `routing`, `config` and `utils` may use any layer, and so '
        'may the tests.\n'
        '\n'
        '| Layer | May use | May use only the interfaces of |\n'
        '|---|---|---|\n'
        '| `ui` | `domain`, `routing`, `config`, `utils` | '
        '`data.repository`, `data.service` |\n'
        '| `data.repository` | `data.service`, `data.model`, `domain`, '
        '`routing`, `config`, `utils` |  |\n'
        '| `data.service` | `data.repository`, `data.model`, `domain`, '
        '`routing`, `config`, `utils` |  |\n'
        '| `data.model` | `data.repository`, `data.service`, `domain`, '
        '`routing`, `config`, `utils` |  |\n'
        '| `domain` | `utils` | `data.repository` |\n'
        '| `routing` | any layer |  |\n'
        '| `config` | any layer |  |\n'
        '| `utils` | any layer |  |\n'
        '\n'
        '## Where each layer lives',
      ),
    );
  });

  test('says where each layer lives and how many files it has', () {
    final text = _render(
      layers: const LayersMap(
        files: {
          'lib/ui/home/widgets/home_screen.dart': MapFileEntry(
            layer: 'ui',
            imports: [],
          ),
          'lib/ui/core/ui/app_button.dart': MapFileEntry(
            layer: 'ui',
            imports: [],
          ),
          'lib/domain/models/user.dart': MapFileEntry(
            layer: 'domain',
            imports: [],
          ),
          'lib/main.dart': MapFileEntry(imports: []),
        },
        violations: [],
      ),
    );
    expect(
      text,
      contains(
        '## Where each layer lives\n'
        '\n'
        '| Layer | Folders | Files in this app |\n'
        '|---|---|---|\n'
        '| `test` | `test/**`, `testing/**` | 0 |\n'
        '| `ui` | `lib/ui/**` | 2 |\n'
        '| `data.repository` | `lib/data/repositories/**` | 0 |\n',
      ),
    );
    expect(text, contains('| `domain` | `lib/domain/**` | 1 |\n'));
    expect(text, contains('1 file is in no layer.'));
    expect(text, isNot(contains('## Rule breaks right now')));
  });

  test('lists the imports that break the rules', () {
    final text = _render(
      layers: const LayersMap(
        files: {},
        violations: [
          LayerViolation(
            file: 'lib/ui/home/view_models/home_viewmodel.dart',
            line: 3,
            import: 'lib/data/services/api/api_client.dart',
            from: 'ui',
            to: 'data.service',
          ),
        ],
      ),
    );
    expect(
      text,
      endsWith(
        '## Rule breaks right now\n'
        '\n'
        '| File | Imports | From layer | To layer |\n'
        '|---|---|---|---|\n'
        '| [lib/ui/home/view_models/home_viewmodel.dart:3]'
        '(../../lib/ui/home/view_models/home_viewmodel.dart#L3) | '
        '`lib/data/services/api/api_client.dart` | `ui` | `data.service` |',
      ),
    );
  });
}
