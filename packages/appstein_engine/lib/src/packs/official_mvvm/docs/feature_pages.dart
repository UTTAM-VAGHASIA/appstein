import 'package:appstein_protocol/appstein_protocol.dart';

import '../../../docs/doc_page.dart';
import '../../../docs/docs_knowledge.dart';
import '../../../docs/markdown_text.dart';

/// `features/<feature>.md` (spec §6.9): one page per feature, with its
/// screens, view models, repositories and services as a diagram and a
/// table, its routes and its tests. A feature in a nested folder keeps its
/// folders: `auth/login` is `features/auth/login.md`.
final class FeaturePages implements DocPage {
  /// Creates the page source.
  const FeaturePages();

  @override
  String get id => 'features';

  @override
  List<DocSection> sections(DocsKnowledge knowledge) {
    final names = knowledge.features.features.keys.toList()..sort();
    return [
      for (final name in names)
        _page(knowledge, name, knowledge.features.features[name]!),
    ];
  }

  DocSection _page(DocsKnowledge knowledge, String name, Feature feature) {
    final page = 'features/$name.md';
    String link(String target, {int? line}) => projectLink(
      docsPath: knowledge.docsPath,
      page: page,
      target: target,
      line: line,
    );

    // The kinds a diagram shows, in the order one uses the next.
    final chain = [
      (id: 'screens', node: 'screen', label: 'Screens', refs: feature.screens),
      (
        id: 'view_models',
        node: 'view_model',
        label: 'View models',
        refs: feature.viewModels,
      ),
      (
        id: 'repositories',
        node: 'repository',
        label: 'Repositories',
        refs: feature.repositories,
      ),
      (
        id: 'services',
        node: 'service',
        label: 'Services',
        refs: feature.services,
      ),
    ];
    final kinds = chain.where((kind) => kind.refs.isNotEmpty).toList();
    // Only the arrows the map supports, and only between kinds that are
    // both there: a screen is built with its view model, and the feature's
    // repositories and services are the ones its view models' constructors
    // take. Nothing says a repository uses one of these services, or that
    // a screen uses one directly, so no arrow claims it.
    final arrows = [
      for (final (from, to) in const [
        ('screens', 'view_models'),
        ('view_models', 'repositories'),
        ('view_models', 'services'),
      ])
        if (kinds.any((kind) => kind.id == from) &&
            kinds.any((kind) => kind.id == to))
          '  $from --> $to',
    ];
    final diagram = kinds.isEmpty
        ? null
        : [
            '```mermaid',
            'flowchart LR',
            for (final kind in kinds) ...[
              '  subgraph ${kind.id}[${mermaidLabel(kind.label)}]',
              for (final (index, ref) in kind.refs.indexed)
                '    ${mermaidId(kind.node, index)}[${mermaidLabel(ref.name)}]',
              '  end',
            ],
            ...arrows,
            '```',
          ].join('\n');

    MapSymbol? symbolOf(CodeRef ref) => knowledge.symbols.symbols
        .where((symbol) => symbol.name == ref.name && symbol.file == ref.file)
        .firstOrNull;
    List<String> row(CodeRef ref, String kind) {
      final symbol = symbolOf(ref);
      final summary = symbol?.summary?.trim() ?? '';
      return [
        mdCode(ref.name),
        kind,
        link(ref.file, line: symbol?.line),
        summary.isEmpty ? 'No description yet' : mdText(summary),
      ];
    }

    final classes = mdTable(
      const ['Class', 'Kind', 'Declared at', 'What it is for'],
      [
        for (final ref in feature.screens) row(ref, 'screen'),
        for (final ref in feature.viewModels) row(ref, 'view model'),
        for (final ref in feature.repositories) row(ref, 'repository'),
        for (final ref in feature.services) row(ref, 'service'),
        for (final ref in feature.models) row(ref, 'model'),
      ],
    ).trimRight();

    bool shows(MapRoute route) => feature.screens.any(
      (screen) =>
          screen.name == route.screen?.name &&
          screen.file == route.screen?.file,
    );
    final routes = mdTable(
      const ['Path', 'Name', 'Screen', 'Declared at'],
      [
        for (final route in knowledge.routes.routes)
          if (shows(route))
            [
              route.path == null ? 'unresolved' : mdCode(route.path!),
              mdCode(route.name ?? ''),
              mdCode(route.screen!.name),
              link(route.file, line: route.line),
            ],
      ],
    ).trimRight();

    final parts = <String>[
      mdCode(feature.folder),
      ?diagram,
      if (arrows.isNotEmpty)
        'The arrows show which kind of part uses which, not which class '
            'calls which.',
      '## Classes\n\n'
          '${classes.isEmpty ? 'No classes found in this feature.' : classes}',
      '## Routes\n\n'
          '${routes.isEmpty ? 'No route builds a screen of this feature.' : routes}',
      '## Tests\n\n'
          '${feature.tests.isEmpty ? 'No tests under ${mdCode('test/ui/$name/')} yet.' : feature.tests.map((test) => '- ${link(test)}').join('\n')}',
    ];
    return DocSection(
      path: page,
      title: 'Feature: $name',
      markdown: parts.join('\n\n'),
    );
  }
}
