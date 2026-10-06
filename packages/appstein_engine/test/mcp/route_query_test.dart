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
  });

  test('a redirect the map knows: the path it goes to, and that path\'s '
      'screen and feature', () {
    final reply = ask('/booking/42');
    expect(only(reply)['redirectsTo'], {
      'path': '/booking',
      'screen': {
        'name': 'BookingScreen',
        'file': 'lib/ui/booking/widgets/booking_screen.dart',
      },
      'feature': 'booking',
    });
    expect(only(reply).containsKey('redirectHint'), isFalse);
    expect(
      reply.summary,
      contains(
        'It redirects to `/booking`, which shows screen `BookingScreen` in '
        'feature `booking`.',
      ),
    );
    expectMatchesSchema(ToolSchemas.routeResult, withoutNulls(reply.result));
  });

  test('a redirect the map does not know says which line to read, and so '
      'does a router that redirects', () {
    const map = RoutesMap(
      routes: [
        MapRoute(path: '/old', redirect: true, file: 'lib/r.dart', line: 7),
        MapRoute(
          path: '/gone',
          redirect: true,
          redirectTo: '/nowhere',
          file: 'lib/r.dart',
          line: 9,
        ),
        MapRoute(path: '/plain', file: 'lib/r.dart', line: 11),
      ],
      routers: [MapRouter(file: 'lib/r.dart', line: 3, redirect: true)],
    );
    ToolReply at(String path) =>
        routeInfo(path, routes: map, features: features) as ToolReply;

    final unknown = at('/old');
    expect(only(unknown).containsKey('redirectsTo'), isFalse);
    expect(
      only(unknown)['redirectHint'],
      'The map does not know where this route redirects to: read '
      'lib/r.dart:7.',
    );
    expect(unknown.summary, contains('read lib/r.dart:7'));
    expect(
      unknown.result['redirectNote'],
      'The router at lib/r.dart:3 has its own redirect, which can send any '
      'path elsewhere (to a sign-in page, for example). The map does not '
      'record when or where: read it.',
    );
    expect(unknown.summary, contains('The router at lib/r.dart:3 also'));
    expectMatchesSchema(ToolSchemas.routeResult, withoutNulls(unknown.result));

    // A target no route has: the path alone.
    expect(only(at('/gone'))['redirectsTo'], {'path': '/nowhere'});
    expect(at('/gone').summary, contains('It redirects to `/nowhere`.'));

    // No redirect of its own: no hint, but the router's note stays.
    expect(only(at('/plain')).containsKey('redirectHint'), isFalse);
    expect(at('/plain').result['redirectNote'], isNotNull);
  });

  test('without a router redirect there is no note', () {
    const map = RoutesMap(
      routes: [MapRoute(path: '/plain', file: 'lib/r.dart', line: 11)],
      routers: [MapRouter(file: 'lib/r.dart', line: 3, redirect: false)],
    );
    final reply =
        routeInfo('/plain', routes: map, features: features) as ToolReply;
    expect(reply.result['routerRedirects'], isFalse);
    expect(reply.result.containsKey('redirectNote'), isFalse);
    expectMatchesSchema(ToolSchemas.routeResult, withoutNulls(reply.result));
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
