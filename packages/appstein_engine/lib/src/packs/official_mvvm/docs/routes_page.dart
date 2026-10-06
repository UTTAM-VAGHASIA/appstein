import 'package:appstein_protocol/appstein_protocol.dart';

import '../../../docs/doc_page.dart';
import '../../../docs/docs_knowledge.dart';
import '../../../docs/markdown_text.dart';

/// `routes.md` (spec §6.9): the go_router route tree. A route Appstein
/// couldn't resolve from the code is listed as unresolved with its reason,
/// never guessed (§6.5).
final class RoutesPage implements DocPage {
  /// Creates the page source.
  const RoutesPage();

  /// The page's path inside the docs folder.
  static const path = 'routes.md';

  @override
  String get id => 'routes';

  @override
  List<DocSection> sections(DocsKnowledge knowledge) {
    final map = knowledge.routes;
    String link(String file, int line) => projectLink(
      docsPath: knowledge.docsPath,
      page: path,
      target: file,
      line: line,
    );

    int byPlace(MapRoute a, MapRoute b) {
      final byPath = (a.path ?? '').compareTo(b.path ?? '');
      if (byPath != 0) return byPath;
      final byFile = a.file.compareTo(b.file);
      return byFile != 0 ? byFile : a.line.compareTo(b.line);
    }

    final placed = [
      for (final route in map.routes)
        if (route.path != null) route,
    ]..sort(byPlace);
    // The first route with a path owns the routes that name it as parent.
    final owners = <String, MapRoute>{};
    for (final route in placed) {
      owners.putIfAbsent(route.path!, () => route);
    }
    bool atTop(MapRoute route) =>
        route.parent == null ||
        route.parent == route.path ||
        !owners.containsKey(route.parent);

    final tree = <String>[];
    final shown = <MapRoute>{};
    void add(MapRoute route, int depth) {
      if (!shown.add(route)) return;
      final does = [
        if (route.screen case final screen?) 'shows ${mdCode(screen.name)}',
        if (route.redirectTo case final target?)
          'redirects to ${mdCode(target)}'
        else if (route.redirect)
          'redirects (decided in code)',
      ];
      final what = does.isNotEmpty
          ? does.join(' and ')
          : route.unresolved
          ? 'has no screen Appstein could resolve'
          : 'has no screen of its own';
      tree.add(
        '${'  ' * depth}- ${mdCode(route.path!)}'
        '${route.name == null ? '' : ', named ${mdCode(route.name!)},'} '
        '$what (${link(route.file, route.line)})',
      );
      if (owners[route.path] != route) return;
      for (final child in placed) {
        if (child.parent == route.path && !atTop(child)) add(child, depth + 1);
      }
    }

    for (final route in placed) {
      if (atTop(route)) add(route, 0);
    }
    // A circle of parents has no top: show what is left, flat.
    for (final route in placed) {
      add(route, 0);
    }

    final routers = [...map.routers]
      ..sort((a, b) {
        final byFile = a.file.compareTo(b.file);
        return byFile != 0 ? byFile : a.line.compareTo(b.line);
      });
    final unresolved = [
      for (final route in map.routes)
        if (route.unresolved) route,
    ]..sort(byPlace);

    final parts = <String>[
      if (map.routes.isEmpty && routers.isEmpty)
        'No go_router routes were found in this app.',
      if (routers.isNotEmpty)
        '## Routers\n\n'
            '${[for (final router in routers) '- ${link(router.file, router.line)}${router.redirect ? ', with a redirect that runs before every route' : ''}'].join('\n')}',
      if (tree.isNotEmpty) '## Route tree\n\n${tree.join('\n')}',
      if (unresolved.isNotEmpty)
        '## Unresolved\n\n'
            'Appstein reads routes from the code without running it, and '
            'never guesses. Read these in the code:\n\n'
            '${[for (final route in unresolved) '- ${route.path == null ? 'A route whose path is unknown' : mdCode(route.path!)}: ${mdText(route.reason ?? 'no reason was recorded')} (${link(route.file, route.line)})'].join('\n')}',
    ];
    return [
      DocSection(path: path, title: 'Routes', markdown: parts.join('\n\n')),
    ];
  }
}
