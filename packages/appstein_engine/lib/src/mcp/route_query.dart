import 'package:appstein_protocol/appstein_protocol.dart';

import 'tool_answer.dart';

/// `route` (spec §8): the go_router route for [path], with its screen,
/// feature, parent, nested routes and whether it redirects.
///
/// [path] may come without its leading slash, with a trailing slash, or
/// with a query or fragment, which are ignored. An exact path wins;
/// otherwise a concrete path matches a pattern (`/booking/42` matches
/// `/booking/:id`). Routes whose path couldn't be resolved are never
/// matched. The map records that a route or its router redirects, not
/// where to, and the reply says so.
ToolAnswer routeInfo(
  String path, {
  required RoutesMap routes,
  required FeaturesMap features,
}) {
  var wanted = path.trim();
  final cut = wanted.indexOf(RegExp('[?#]'));
  if (cut >= 0) wanted = wanted.substring(0, cut);
  if (!wanted.startsWith('/')) wanted = '/$wanted';
  if (wanted.length > 1 && wanted.endsWith('/')) {
    wanted = wanted.substring(0, wanted.length - 1);
  }
  final known = [
    for (final route in routes.routes)
      if (route.path != null) route,
  ];
  var match = 'exact';
  var matched = [
    for (final route in known)
      if (route.path == wanted) route,
  ];
  if (matched.isEmpty) {
    match = 'pattern';
    matched = [
      for (final route in known)
        if (_matchesPattern(route.path!, wanted)) route,
    ];
  }
  if (matched.isEmpty) {
    final paths = {for (final route in known) route.path!}.toList()..sort();
    final unresolved = routes.routes.where((r) => r.path == null).length;
    return ToolRefusal(
      [
        'No route matches "$path".',
        if (paths.isEmpty)
          'No route has a known path.'
        else
          'Routes with a known path: ${paths.take(20).join(', ')}'
              '${paths.length > 20 ? ', …' : ''}.',
        if (unresolved > 0)
          '$unresolved '
              '${unresolved == 1 ? 'route has a path' : 'routes have paths'} '
              'Appstein could not resolve; see `.appstein/map/routes.json`.',
      ].join(' '),
    );
  }

  String? featureOfScreen(CodeRef? screen) =>
      screen == null ? null : features.featureOf(screen.file);

  Map<String, Object?> describe(MapRoute route) {
    final children = [
      for (final child in routes.routes)
        if (child.parent == route.path) child,
    ];
    return {
      'path': route.path,
      'name': ?route.name,
      'screen': ?route.screen?.toJson(),
      'feature': ?featureOfScreen(route.screen),
      'parent': ?route.parent,
      'children': [for (final child in children) ?child.path]..sort(),
      'unresolvedChildren': children.where((c) => c.path == null).length,
      'redirect': route.redirect,
      'file': route.file,
      'line': route.line,
      if (route.unresolved) 'unresolved': true,
      'reason': ?route.reason,
    };
  }

  final first = matched.first;
  final firstFeature = featureOfScreen(first.screen);
  return ToolReply(
    {
      'path': wanted,
      'match': match,
      'routes': [for (final route in matched) describe(route)],
      'routerRedirects': routes.routers.any((router) => router.redirect),
      'redirectNote':
          'The map records that a route or its router redirects, not where '
          'to.',
    },
    [
      'Route `${first.path}`'
          '${match == 'pattern' ? ' (a pattern matching `$wanted`)' : ''}:',
      if (first.screen case final screen?)
        'screen `${screen.name}`'
            '${firstFeature == null ? '' : ' in feature `$firstFeature`'}.'
      else
        'no screen recorded'
            '${first.reason == null ? '' : ' (${first.reason})'}.',
      if (first.redirect) 'It redirects.',
      if (matched.length > 1) '${matched.length} routes match.',
    ].join(' '),
  );
}

/// Whether [path] matches the go_router [pattern]: the same number of
/// segments, each equal or matched by a `:parameter` segment.
bool _matchesPattern(String pattern, String path) {
  final expected = pattern.split('/');
  final actual = path.split('/');
  if (expected.length != actual.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (expected[i].startsWith(':')) {
      if (actual[i].isEmpty) return false;
    } else if (expected[i] != actual[i]) {
      return false;
    }
  }
  return true;
}
