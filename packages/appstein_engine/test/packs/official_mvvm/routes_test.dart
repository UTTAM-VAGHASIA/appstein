import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/src/packs/official_mvvm/routes.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/fixture_app.dart';

void main() {
  const router = 'lib/routing/router.dart';

  Future<RoutesMap> routesOf(String app) async {
    final analysis = await ProjectAnalysis.analyze(
      app,
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    return readRoutes(analysis);
  }

  Map<String, Object?> route({
    required int line,
    String? path,
    String? name,
    (String, String)? screen,
    String? parent,
    bool redirect = false,
    String? reason,
  }) => MapRoute(
    path: path,
    name: name,
    screen: screen == null ? null : CodeRef(name: screen.$1, file: screen.$2),
    parent: parent,
    redirect: redirect,
    file: router,
    line: line,
    unresolved: reason != null,
    reason: reason,
  ).toJson();

  test("the fixture's routes, in source order", () async {
    final app = copyFixtureApp();
    // Each GoRoute( line comes just before its path: line.
    int at(String pathLine) => lineOf(app, router, pathLine) - 1;
    final routes = await routesOf(app);
    expect(
      [for (final r in routes.routes) r.toJson()],
      [
        route(
          line: at('path: Routes.login'),
          path: '/login',
          name: 'login',
          screen: (
            'LoginScreen',
            'lib/ui/auth/login/widgets/login_screen.dart',
          ),
        ),
        route(
          line: at('path: Routes.home'),
          path: '/',
          screen: ('HomeScreen', 'lib/ui/home/widgets/home_screen.dart'),
        ),
        route(
          line: at('path: Routes.bookingRelative'),
          path: '/booking',
          parent: '/',
          screen: (
            'BookingScreen',
            'lib/ui/booking/widgets/booking_screen.dart',
          ),
        ),
        route(
          line: at("path: ':id'"),
          path: '/booking/:id',
          parent: '/booking',
          redirect: true,
        ),
        route(
          line: at('path: _searchPath()'),
          parent: '/',
          screen: (
            'SettingsScreen',
            'lib/ui/settings/widgets/settings_screen.dart',
          ),
          reason: 'the path is not a constant string',
        ),
        route(
          line: at('path: Routes.settings'),
          path: '/settings',
          reason: 'the builder is not a single plain return',
        ),
        route(
          line: at('path: Routes.profile'),
          path: '/profile',
          screen: (
            'ProfileScreen',
            'lib/ui/profile/widgets/profile_screen.dart',
          ),
        ),
        route(
          line: at("path: '/about'"),
          path: '/about',
          reason:
              'the builder returns Text, which is not declared in this '
              'project',
        ),
      ],
    );
    expect(
      [for (final r in routes.routers) r.toJson()],
      [
        {
          'file': router,
          'line': lineOf(app, router, '=> GoRouter('),
          'redirect': true,
        },
      ],
    );
  });

  test('routes that cannot be read are recorded unresolved, never '
      'guessed', () async {
    final app = copyFixtureApp();
    const extra = 'lib/routing/extra_routes.dart';
    File(p.join(app, 'lib', 'routing', 'extra_routes.dart')).writeAsStringSync(
      r'''
import 'package:go_router/go_router.dart';

import '../ui/profile/widgets/profile_screen.dart';
import 'routes.dart';

final List<RouteBase> _more = [];
final String _notConst = '/not-const';

List<RouteBase> get $appRoutes => const [];

GoRouter typedRouter() => GoRouter(routes: $appRoutes);

GoRouter listRouter() => GoRouter(routes: _more);

GoRouter spreadRouter() => GoRouter(routes: [..._more, _route()]);

GoRouter configRouter() => GoRouter.routingConfig(routingConfig: Object());

GoRouter valuesRouter() => GoRouter(
  routes: [
    GoRoute(
      path: '/x/${Routes.bookingRelative}',
      builder: (context, state) => const ProfileScreen(),
    ),
    GoRoute(path: _notConst),
    GoRoute(
      path: _dynamic(),
      routes: [
        GoRoute(
          path: 'child',
          builder: (context, state) => const ProfileScreen(),
        ),
      ],
    ),
  ],
);

RouteBase _route() => const GoRoute(path: '/x');

String _dynamic() => '/dynamic';
''',
    );
    // A class named GoRouter that isn't go_router's is not a router.
    File(p.join(app, 'lib', 'routing', 'own_router.dart')).writeAsStringSync(
      'class GoRouter {\n'
      '  GoRouter({required List<Object> routes});\n'
      '}\n\n'
      'GoRouter ownRouter() => GoRouter(routes: const []);\n',
    );
    final routes = await routesOf(app);
    final extras = [
      for (final r in routes.routes)
        if (r.file == extra) r,
    ];
    expect(
      [for (final r in extras) (r.path, r.reason)],
      [
        (null, 'typed routes (go_router_builder) are not read yet'),
        (null, 'the routes are not a list literal'),
        (null, 'a spread or a condition in a routes list is not read'),
        (
          null,
          'the route is not a GoRoute, ShellRoute or StatefulShellRoute '
              'constructor call',
        ),
        (null, 'this GoRouter has no routes list'),
        ('/x/booking', null),
        (null, 'the path is not a constant string'),
        (null, 'the path is not a constant string'),
        (null, "the parent route's path is not a constant string"),
      ],
    );
    expect(
      [for (final r in extras) r.unresolved],
      [true, true, true, true, true, false, true, true, true],
    );
    expect(extras.last.screen?.name, 'ProfileScreen');
    expect(extras.last.parent, isNull);
    expect(routes.routers.map((r) => r.file).toSet(), {
      router,
      extra,
    }, reason: 'own_router.dart has no go_router GoRouter');
    expect(routes.routers.where((r) => r.file == extra), hasLength(5));
  });

  test('a CRLF router gives the same routes', () async {
    final lf = await routesOf(copyFixtureApp());
    final crlfApp = copyFixtureApp();
    final file = File(p.join(crlfApp, 'lib', 'routing', 'router.dart'));
    file.writeAsStringSync(file.readAsStringSync().replaceAll('\n', '\r\n'));
    final crlf = await routesOf(crlfApp);
    expect(crlf.toJson(), lf.toJson());
  });

  test('nested paths are joined as go_router joins them', () {
    expect(joinRoutePath(null, '/login'), '/login');
    expect(joinRoutePath('/', 'booking'), '/booking');
    expect(joinRoutePath('/booking', ':id'), '/booking/:id');
    expect(joinRoutePath('/', '/settings'), '/settings');
    expect(joinRoutePath('/a/', 'b/'), '/a/b');
  });
}
