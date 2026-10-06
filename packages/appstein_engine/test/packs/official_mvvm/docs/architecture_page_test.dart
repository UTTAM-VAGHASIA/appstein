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

  test('draws exactly the pairs the layer rules allow', () {
    final diagram = _diagram(_render());
    expect(diagram, startsWith('```mermaid\nflowchart TD\n'));
    final labels = {
      for (final match in RegExp(
        r'^  (\w+)\["([^"]+)"\]$',
        multiLine: true,
      ).allMatches(diagram))
        match[1]!: match[2]!,
    };
    const rules = officialMvvmLayerRules;
    expect(labels.values, [
      for (final layer in rules.layers.keys)
        if (layer != 'test') layer,
    ]);
    Set<String> edges(RegExp pattern) => {
      for (final match in pattern.allMatches(diagram))
        '${labels[match[1]]} > ${labels[match[2]]}',
    };
    expect(edges(RegExp(r'^  (\w+) --> (\w+)$', multiLine: true)), {
      for (final MapEntry(key: from, value: targets) in rules.allow.entries)
        for (final to in targets)
          if (to != 'test') '$from > $to',
    });
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

  test('names the layers without a rule', () {
    expect(
      _render(),
      contains(
        'A solid arrow means "may use". A dotted arrow means "may use only '
        'the interfaces of". `routing`, `config` and `utils` may use any '
        'layer, and so may the tests.',
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
