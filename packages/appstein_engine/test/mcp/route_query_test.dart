import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/mcp_support.dart';

void main() {
  final routes = RoutesMap.fromJson(golden('routes.json'));
  final features = FeaturesMap.fromJson(golden('features.json'));

  ToolReply ask(String path) =>
      routeInfo(path, routes: routes, features: features) as ToolReply;

  Map<String, Object?> only(ToolReply reply) =>
      (reply.result['routes']! as List).single as Map<String, Object?>;

  test('an exact path: screen, feature and parent', () {
    final reply = ask('/login');
    expect(reply.result['match'], 'exact');
    final route = only(reply);
    expect(route['screen'], {
      'name': 'LoginScreen',
      'file': 'lib/ui/auth/login/widgets/login_screen.dart',
    });
    expect(route['feature'], 'auth/login');
    expect(route['redirect'], isFalse);
    expect(reply.result['routerRedirects'], isTrue);
    expectMatchesSchema(ToolSchemas.routeResult, withoutNulls(reply.result));
  });

  test('a concrete path matches a pattern', () {
    final reply = ask('/booking/42');
    expect(reply.result['match'], 'pattern');
    final route = only(reply);
    expect(route['path'], '/booking/:id');
    expect(route['redirect'], isTrue);
    expect(route['screen'], isNull);
    expect(route['parent'], '/booking');
    expect(
      reply.result['redirectNote'],
      'The map records that a route or its router redirects, not where to.',
    );
  });

  test('nested routes, counting children whose path is unresolved', () {
    expect(only(ask('/booking'))['children'], ['/booking/:id']);
    final root = only(ask('/'));
    expect(root['children'], ['/booking']);
    expect(root['unresolvedChildren'], 1);
  });

  test('the forms an agent sends: no slash, a trailing slash, a query', () {
    expect(only(ask('login'))['path'], '/login');
    expect(only(ask('/profile/'))['path'], '/profile');
    expect(only(ask('/booking/7?tab=2#top'))['path'], '/booking/:id');
  });

  test('an unknown path lists the known ones', () {
    expect(
      (routeInfo('/nope', routes: routes, features: features) as ToolRefusal)
          .message,
      'No route matches "/nope". Routes with a known path: /, /about, '
      '/booking, /booking/:id, /login, /profile, /settings. 1 route has a '
      'path Appstein could not resolve; see `.appstein/map/routes.json`.',
    );
  });
}
