import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../../../docs/support/docs_support.dart';

const _file = 'lib/routing/router.dart';

String _link(int line) => '[$_file:$line](../../$_file#L$line)';

String _render(RoutesMap routes) {
  final sections = const RoutesPage().sections(sampleKnowledge(routes: routes));
  expect(sections.single.path, 'routes.md');
  expect(sections.single.title, 'Routes');
  return sections.single.markdown;
}

MapRoute _route(
  String? path,
  int line, {
  String? name,
  String? screen,
  String? parent,
  bool redirect = false,
  String? redirectTo,
  bool unresolved = false,
  String? reason,
}) => MapRoute(
  path: path,
  name: name,
  screen: screen == null ? null : CodeRef(name: screen, file: 'lib/s.dart'),
  parent: parent,
  redirect: redirect,
  redirectTo: redirectTo,
  file: _file,
  line: line,
  unresolved: unresolved,
  reason: reason,
);

void main() {
  test('draws the routes as a tree', () {
    expect(
      _render(
        RoutesMap(
          routes: [
            _route('/settings', 40, screen: 'SettingsScreen'),
            _route('/', 10, redirect: true, redirectTo: '/home'),
            _route('/home', 14, name: 'home', screen: 'HomeScreen'),
            _route(
              '/home/booking/:id',
              18,
              screen: 'BookingScreen',
              parent: '/home',
              redirect: true,
            ),
            _route('/home/about', 30, parent: '/home'),
            _route(
              '/home/booking/:id/edit',
              22,
              screen: 'EditScreen',
              parent: '/home/booking/:id',
            ),
          ],
          routers: const [
            MapRouter(file: _file, line: 8, redirect: true),
            MapRouter(file: 'lib/routing/other.dart', line: 3, redirect: false),
          ],
        ),
      ),
      '## Routers\n'
      '\n'
      '- [lib/routing/other.dart:3](../../lib/routing/other.dart#L3)\n'
      '- ${_link(8)}, with a redirect that runs before every route\n'
      '\n'
      '## Route tree\n'
      '\n'
      '- `/` redirects to `/home` (${_link(10)})\n'
      '- `/home`, named `home`, shows `HomeScreen` (${_link(14)})\n'
      '  - `/home/about` has no screen of its own (${_link(30)})\n'
      '  - `/home/booking/:id` shows `BookingScreen` and redirects (decided '
      'in code) (${_link(18)})\n'
      '    - `/home/booking/:id/edit` shows `EditScreen` (${_link(22)})\n'
      '- `/settings` shows `SettingsScreen` (${_link(40)})',
    );
  });

  test('a route whose parent is not listed is shown at the top', () {
    expect(
      _render(
        RoutesMap(
          routes: [_route('/a/b', 5, screen: 'B', parent: '/a')],
          routers: const [],
        ),
      ),
      '## Route tree\n\n- `/a/b` shows `B` (${_link(5)})',
    );
  });

  test('two routes with one path are both shown, children under the first', () {
    final text = _render(
      RoutesMap(
        routes: [
          _route('/a', 5, screen: 'A'),
          _route('/a', 9, screen: 'Other'),
          _route('/a/b', 7, screen: 'B', parent: '/a'),
        ],
        routers: const [],
      ),
    );
    expect(
      text,
      '## Route tree\n'
      '\n'
      '- `/a` shows `A` (${_link(5)})\n'
      '  - `/a/b` shows `B` (${_link(7)})\n'
      '- `/a` shows `Other` (${_link(9)})',
    );
  });

  test('a route that names itself as its parent is shown once', () {
    expect(
      _render(
        RoutesMap(
          routes: [_route('/a', 5, screen: 'A', parent: '/a')],
          routers: const [],
        ),
      ),
      '## Route tree\n\n- `/a` shows `A` (${_link(5)})',
    );
  });

  test('never guesses a route it could not resolve', () {
    expect(
      _render(
        RoutesMap(
          routes: [
            _route(
              null,
              12,
              unresolved: true,
              reason: 'the path is built from a variable',
            ),
            _route(
              null,
              14,
              screen: 'SettingsScreen',
              unresolved: true,
              reason: 'the path is not a constant string',
            ),
            _route(
              '/x',
              16,
              unresolved: true,
              reason: 'the builder returns different widgets',
            ),
          ],
          routers: const [],
        ),
      ),
      '## Route tree\n'
      '\n'
      '- `/x` has no screen Appstein could resolve (${_link(16)})\n'
      '\n'
      '## Unresolved\n'
      '\n'
      'Appstein reads routes from the code without running it, and never '
      'guesses. Read these in the code:\n'
      '\n'
      '- A route whose path is unknown: the path is built from a variable '
      '(${_link(12)})\n'
      '- A route whose path is unknown, which shows `SettingsScreen`: the '
      'path is not a constant string (${_link(14)})\n'
      '- `/x`: the builder returns different widgets (${_link(16)})',
    );
  });

  test('says so when the app has no routes', () {
    expect(
      _render(const RoutesMap(routes: [], routers: [])),
      'No go_router routes were found in this app.',
    );
  });
}
