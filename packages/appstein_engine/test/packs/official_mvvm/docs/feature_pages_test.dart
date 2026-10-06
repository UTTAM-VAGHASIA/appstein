import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import '../../../docs/support/docs_support.dart';

List<DocSection> _render({
  FeaturesMap? features,
  SymbolsMap? symbols,
  RoutesMap? routes,
}) => const FeaturePages().sections(
  sampleKnowledge(features: features, symbols: symbols, routes: routes),
);

Feature _feature(
  String folder, {
  List<CodeRef> screens = const [],
  List<CodeRef> viewModels = const [],
  List<CodeRef> repositories = const [],
  List<CodeRef> services = const [],
  List<CodeRef> models = const [],
  List<String> tests = const [],
}) => Feature(
  folder: folder,
  viewModels: viewModels,
  screens: screens,
  repositories: repositories,
  services: services,
  models: models,
  tests: tests,
  files: const [],
);

void main() {
  test('renders a feature with every kind of part', () {
    final section = _render().single;
    expect(section.path, 'features/booking.md');
    expect(section.title, 'Feature: booking');
    expect(
      section.markdown,
      '`lib/ui/booking`\n'
      '\n'
      '```mermaid\n'
      'flowchart LR\n'
      '  subgraph screens["Screens"]\n'
      '    screen_0["BookingScreen"]\n'
      '  end\n'
      '  subgraph view_models["View models"]\n'
      '    view_model_0["BookingViewModel"]\n'
      '  end\n'
      '  subgraph repositories["Repositories"]\n'
      '    repository_0["BookingRepository"]\n'
      '  end\n'
      '  subgraph services["Services"]\n'
      '    service_0["ApiClient"]\n'
      '  end\n'
      '  screens --> view_models\n'
      '  view_models --> repositories\n'
      '  repositories --> services\n'
      '```\n'
      '\n'
      'The arrows show which kind of part uses which, not which class calls '
      'which.\n'
      '\n'
      '## Classes\n'
      '\n'
      '| Class | Kind | Declared at | What it is for |\n'
      '|---|---|---|---|\n'
      '| `BookingScreen` | screen | '
      '[lib/ui/booking/widgets/booking_screen.dart:8]'
      '(../../../lib/ui/booking/widgets/booking_screen.dart#L8) | '
      'Shows one booking. |\n'
      '| `BookingViewModel` | view model | '
      '[lib/ui/booking/view_models/booking_viewmodel.dart:9]'
      '(../../../lib/ui/booking/view_models/booking_viewmodel.dart#L9) | '
      'No description yet |\n'
      '| `BookingRepository` | repository | '
      '[lib/data/repositories/booking/booking_repository.dart:4]'
      '(../../../lib/data/repositories/booking/booking_repository.dart#L4) | '
      'Loads and saves bookings. |\n'
      '| `ApiClient` | service | '
      '[lib/data/services/api/api_client.dart:6]'
      '(../../../lib/data/services/api/api_client.dart#L6) | '
      'Talks to the booking API. |\n'
      '| `Booking` | model | '
      '[lib/domain/models/booking.dart:2]'
      '(../../../lib/domain/models/booking.dart#L2) | One booking. |\n'
      '\n'
      '## Routes\n'
      '\n'
      '| Path | Name | Screen | Declared at |\n'
      '|---|---|---|---|\n'
      '| `/booking` | `booking` | `BookingScreen` | '
      '[lib/routing/router.dart:14]'
      '(../../../lib/routing/router.dart#L14) |\n'
      '\n'
      '## Tests\n'
      '\n'
      '- [test/ui/booking/view_models/booking_viewmodel_test.dart]'
      '(../../../test/ui/booking/view_models/booking_viewmodel_test.dart)',
    );
  });

  test('one page per feature, sorted, nested names keep their folders', () {
    final sections = _render(
      features: FeaturesMap(
        features: {
          'home': _feature('lib/ui/home'),
          'auth/login': _feature(
            'lib/ui/auth/login',
            screens: const [
              CodeRef(
                name: 'LoginScreen',
                file: 'lib/ui/auth/login/widgets/login_screen.dart',
              ),
            ],
          ),
        },
      ),
    );
    expect(
      [for (final section in sections) section.path],
      ['features/auth/login.md', 'features/home.md'],
    );
    expect(sections.first.title, 'Feature: auth/login');
    expect(
      sections.first.markdown,
      contains('(../../../../lib/ui/auth/login/widgets/login_screen.dart)'),
    );
  });

  test('a feature with only a screen has one box and no arrow', () {
    final text = _render(
      features: FeaturesMap(
        features: {
          'settings': _feature(
            'lib/ui/settings',
            screens: const [
              CodeRef(
                name: 'SettingsScreen',
                file: 'lib/ui/settings/widgets/settings_screen.dart',
              ),
            ],
          ),
        },
      ),
    ).single.markdown;
    expect(text, contains('  subgraph screens["Screens"]\n'));
    expect(text, isNot(contains('-->')));
    expect(text, isNot(contains('The arrows show')));
    expect(text, contains('No route builds a screen of this feature.'));
    expect(text, contains('No tests under `test/ui/settings/` yet.'));
  });

  test('skips a kind that is missing when it draws the arrows', () {
    final text = _render(
      features: FeaturesMap(
        features: {
          'home': _feature(
            'lib/ui/home',
            screens: const [CodeRef(name: 'HomeScreen', file: 'a.dart')],
            services: const [CodeRef(name: 'ApiClient', file: 'b.dart')],
          ),
        },
      ),
    ).single.markdown;
    expect(text, contains('  screens --> services\n'));
  });

  test('a feature with no classes says so and draws nothing', () {
    final text = _render(
      features: FeaturesMap(features: {'empty': _feature('lib/ui/empty')}),
    ).single.markdown;
    expect(text, isNot(contains('```mermaid')));
    expect(text, contains('## Classes\n\nNo classes found in this feature.'));
  });

  test('picks the summary of the class in the same file', () {
    const here = 'lib/ui/home/widgets/home_screen.dart';
    final text = _render(
      features: FeaturesMap(
        features: {
          'home': _feature(
            'lib/ui/home',
            screens: const [CodeRef(name: 'HomeScreen', file: here)],
          ),
        },
      ),
      symbols: const SymbolsMap(
        symbols: [
          MapSymbol(
            name: 'HomeScreen',
            kind: SymbolKind.classKind,
            file: 'lib/other/home_screen.dart',
            line: 1,
            summary: 'The wrong one.',
          ),
          MapSymbol(
            name: 'HomeScreen',
            kind: SymbolKind.classKind,
            file: here,
            line: 12,
            summary: 'Lists | the `bookings`.',
          ),
        ],
      ),
    ).single.markdown;
    expect(text, contains(r'#L12) | Lists \| the \`bookings\`. |'));
    expect(text, isNot(contains('The wrong one.')));
  });

  test('a class the symbols do not know is linked without a line', () {
    final text = _render(
      features: FeaturesMap(
        features: {
          'home': _feature(
            'lib/ui/home',
            screens: const [CodeRef(name: 'HomeScreen', file: 'lib/x y.dart')],
          ),
        },
      ),
      symbols: const SymbolsMap(symbols: []),
    ).single.markdown;
    expect(
      text,
      contains(
        '| `HomeScreen` | screen | [lib/x y.dart](../../../lib/x%20y.dart) | '
        'No description yet |',
      ),
    );
  });

  test('a route without a path or a name still has a row', () {
    const screen = CodeRef(name: 'HomeScreen', file: 'a.dart');
    final text = _render(
      features: FeaturesMap(
        features: {
          'home': _feature('lib/ui/home', screens: const [screen]),
        },
      ),
      routes: const RoutesMap(
        routes: [
          MapRoute(
            screen: screen,
            file: 'lib/routing/router.dart',
            line: 20,
            unresolved: true,
            reason: 'the path is computed',
          ),
        ],
        routers: [],
      ),
    ).single.markdown;
    expect(
      text,
      contains(
        '| unresolved |  | `HomeScreen` | [lib/routing/router.dart:20]'
        '(../../../lib/routing/router.dart#L20) |',
      ),
    );
  });

  test('no features, no pages', () {
    expect(_render(features: const FeaturesMap(features: {})), isEmpty);
  });
}
