import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_engine/src/packs/official_mvvm/features.dart';
import 'package:appstein_engine/src/packs/official_mvvm/routes.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/fixture_app.dart';

void main() {
  Future<FeaturesMap> featuresOf(String app) async {
    final analysis = await ProjectAnalysis.analyze(
      app,
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    return readFeatures(
      analysis,
      routes: readRoutes(analysis),
      matcher: LayerMatcher(officialMvvmLayerRules),
    );
  }

  Map<String, Object?> ref(String name, String file) =>
      CodeRef(name: name, file: file).toJson();

  test("the fixture's features", () async {
    final features = await featuresOf(copyFixtureApp());
    expect(features.toJson(), {
      'features': {
        'auth/login': {
          'folder': 'lib/ui/auth/login',
          'viewModels': [
            ref(
              'LoginViewModel',
              'lib/ui/auth/login/view_models/login_viewmodel.dart',
            ),
          ],
          'screens': [
            ref('LoginScreen', 'lib/ui/auth/login/widgets/login_screen.dart'),
          ],
          'repositories': [
            ref(
              'AuthRepository',
              'lib/data/repositories/auth/auth_repository.dart',
            ),
          ],
          'services': <Object>[],
          'models': <Object>[],
          'tests': <String>[],
          'files': [
            'lib/ui/auth/login/view_models/login_viewmodel.dart',
            'lib/ui/auth/login/widgets/login_screen.dart',
          ],
        },
        'booking': {
          'folder': 'lib/ui/booking',
          // BaseViewModel is abstract, so it isn't a view model (P3).
          'viewModels': [
            ref(
              'BookingViewModel',
              'lib/ui/booking/view_models/booking_viewmodel.dart',
            ),
          ],
          'screens': [
            ref('BookingScreen', 'lib/ui/booking/widgets/booking_screen.dart'),
          ],
          'repositories': [
            ref(
              'BookingRepository',
              'lib/data/repositories/booking/booking_repository.dart',
            ),
          ],
          'services': <Object>[],
          // The view model imports the use case too, but use cases aren't
          // models (P4).
          'models': [ref('Booking', 'lib/domain/models/booking.dart')],
          'tests': ['test/ui/booking/view_models/booking_viewmodel_test.dart'],
          'files': [
            'lib/ui/booking/view_models/base_view_model.dart',
            'lib/ui/booking/view_models/booking_viewmodel.dart',
            'lib/ui/booking/widgets/booking_screen.dart',
          ],
        },
        'home': {
          'folder': 'lib/ui/home',
          'viewModels': [
            ref('HomeViewModel', 'lib/ui/home/view_models/home_viewmodel.dart'),
          ],
          'screens': [
            ref('HomeScreen', 'lib/ui/home/widgets/home_screen.dart'),
          ],
          'repositories': [
            ref(
              'BookingRepository',
              'lib/data/repositories/booking/booking_repository.dart',
            ),
          ],
          'services': [
            ref('AnalyticsService', 'lib/data/services/analytics_service.dart'),
          ],
          'models': [ref('Booking', 'lib/domain/models/booking.dart')],
          'tests': ['test/ui/home/widgets/home_screen_test.dart'],
          'files': [
            'lib/ui/home/view_models/home_viewmodel.dart',
            'lib/ui/home/widgets/booking_tile.dart',
            'lib/ui/home/widgets/home_screen.dart',
          ],
        },
        'profile': {
          'folder': 'lib/ui/profile',
          'viewModels': <Object>[],
          'screens': [
            ref('ProfileScreen', 'lib/ui/profile/widgets/profile_screen.dart'),
          ],
          'repositories': <Object>[],
          'services': <Object>[],
          'models': <Object>[],
          'tests': <String>[],
          'files': ['lib/ui/profile/widgets/profile_screen.dart'],
        },
        'settings': {
          'folder': 'lib/ui/settings',
          'viewModels': <Object>[],
          // From the route whose path isn't constant: its screen is known.
          'screens': [
            ref(
              'SettingsScreen',
              'lib/ui/settings/widgets/settings_screen.dart',
            ),
          ],
          'repositories': <Object>[],
          'services': <Object>[],
          'models': <Object>[],
          'tests': <String>[],
          'files': ['lib/ui/settings/widgets/settings_screen.dart'],
        },
      },
    });
  });

  test('a feature folder inside another owns only its own files', () async {
    final app = copyFixtureApp();
    File(p.join(app, 'lib', 'ui', 'auth', 'widgets', 'auth_shell.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        "import 'package:flutter/widgets.dart';\n\n"
        'class AuthShell extends StatelessWidget {\n'
        '  const AuthShell({super.key});\n\n'
        '  @override\n'
        "  Widget build(BuildContext context) => const Text('auth');\n"
        '}\n',
      );
    final features = (await featuresOf(app)).features;
    expect(features['auth']!.files, ['lib/ui/auth/widgets/auth_shell.dart']);
    expect(features['auth']!.screens, isEmpty);
    expect(features['auth/login']!.files, hasLength(2));
  });

  test('ui/core is shared UI, not a feature', () async {
    final features = await featuresOf(copyFixtureApp());
    expect(features.features.keys, isNot(contains('core')));
    expect(features.featureOf('lib/ui/core/ui/app_button.dart'), isNull);
  });
}
