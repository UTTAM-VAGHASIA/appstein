import 'package:appstein_protocol/appstein_protocol.dart';

import 'tool_answer.dart';

/// `route` (spec §8): the go_router route for [path], with its screen,
/// feature, parent, nested routes and whether it redirects.
///
/// [path] may come without its leading slash, with a trailing slash, or
/// with a query or fragment, which are ignored. An exact path wins;
/// otherwise a concrete path matches a pattern (`/booking/42` matches
/// `/booking/:id`). Routes whose path couldn't be resolved are never
/// matched.
///
/// A redirect is never left as a bare "it redirects": an agent stops
/// looking when the map answers. When the map knows where a route
/// redirects to, the reply gives that path with its screen and feature;
/// when it doesn't, and for a router's own redirect, the reply names the
/// file and line to read.
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

  // Where a route redirects to, with the screen and feature of the route at
  // that path when there is one.
  Map<String, Object?>? redirectsTo(MapRoute route) {
    final to = route.redirectTo;
    if (to == null) return null;
    final target = known.where((r) => r.path == to).firstOrNull;
    return {
      'path': to,
      'screen': ?target?.screen?.toJson(),
      'feature': ?featureOfScreen(target?.screen),
    };
  }

  String? redirectHint(MapRoute route) =>
      route.redirect && route.redirectTo == null
      ? 'The map does not know where this route redirects to: read '
            '${route.file}:${route.line}.'
      : null;

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
      'redirectsTo': ?redirectsTo(route),
      'redirectHint': ?redirectHint(route),
      'file': route.file,
      'line': route.line,
      if (route.unresolved) 'unresolved': true,
      'reason': ?route.reason,
    };
  }

  final first = matched.first;
  final firstFeature = featureOfScreen(first.screen);
  final firstTarget = redirectsTo(first);
  final redirecting = [
    for (final router in routes.routers)
      if (router.redirect) '${router.file}:${router.line}',
  ];
  final routersAt = redirecting.length == 1
      ? 'The router at ${redirecting.single}'
      : 'The routers at ${redirecting.join(' and ')}';
  return ToolReply(
    {
      'path': wanted,
      'match': match,
      'routes': [for (final route in matched) describe(route)],
      'routerRedirects': redirecting.isNotEmpty,
      if (redirecting.isNotEmpty)
        'redirectNote':
            '$routersAt ${redirecting.length == 1 ? 'has its' : 'have their'} '
            'own redirect, which can send any path elsewhere (to a sign-in '
            'page, for example). The map does not record when or where: '
            'read it.',
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
      if (firstTarget != null)
        'It redirects to `${firstTarget['path']}`'
            '${switch (firstTarget['screen']) {
              {'name': final String name} => ', which shows screen `$name`'
                  '${firstTarget['feature'] == null ? '' : ' in feature `${firstTarget['feature']}`'}',
              _ => '',
            }}.'
      else if (first.redirect)
        'It redirects, and the map does not know where to: read '
            '${first.file}:${first.line}.',
      if (redirecting.isNotEmpty)
        '$routersAt also '
            '${redirecting.length == 1 ? 'redirects' : 'redirect'} on '
            'conditions the map does not record.',
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
