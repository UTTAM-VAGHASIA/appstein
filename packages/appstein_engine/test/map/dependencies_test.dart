import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';

void main() {
  Future<ProjectAnalysis> analyze(String app) async {
    final analysis = await ProjectAnalysis.analyze(
      app,
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    return analysis;
  }

  test('every locked package, with its constraint and the files that '
      'import it', () async {
    final app = copyFixtureApp();
    final deps = buildDeps(
      await analyze(app),
      lockFile: p.join(app, 'pubspec.lock'),
    );
    expect(deps.toJson(), {
      'packages': {
        'collection': {
          'constraint': null,
          'version': '1.19.1',
          'dependency': 'transitive',
          'source': 'hosted',
          'usages': <String>[],
        },
        'flutter': {
          'constraint': null,
          'version': '0.0.0',
          'dependency': 'direct main',
          'source': 'sdk',
          'usages': [
            'lib/routing/router.dart',
            'lib/ui/auth/login/view_models/login_viewmodel.dart',
            'lib/ui/auth/login/widgets/login_screen.dart',
            'lib/ui/booking/view_models/base_view_model.dart',
            'lib/ui/booking/widgets/booking_screen.dart',
            'lib/ui/core/ui/app_button.dart',
            'lib/ui/home/view_models/home_viewmodel.dart',
            'lib/ui/home/widgets/booking_tile.dart',
            'lib/ui/home/widgets/home_screen.dart',
            'lib/ui/profile/widgets/profile_screen.dart',
            'lib/ui/settings/widgets/settings_screen.dart',
          ],
        },
        'flutter_test': {
          'constraint': null,
          'version': '0.0.0',
          'dependency': 'direct dev',
          'source': 'sdk',
          'usages': [
            'test/data/booking_repository_test.dart',
            'test/ui/booking/view_models/booking_viewmodel_test.dart',
            'test/ui/home/widgets/home_screen_test.dart',
          ],
        },
        'go_router': {
          'constraint': '^18.0.0',
          'version': '18.0.2',
          'dependency': 'direct main',
          'source': 'hosted',
          'usages': ['lib/routing/router.dart'],
        },
      },
    });
  });

  test('an override gives the constraint; a version inside a map is '
      'read', () async {
    final app = copyFixtureApp();
    final pubspec = File(p.join(app, 'pubspec.yaml'));
    pubspec.writeAsStringSync(
      '${pubspec.readAsStringSync()}\n'
      'dependency_overrides:\n'
      '  collection: 1.19.0\n',
    );
    final analysis = await analyze(app);
    final deps = buildDeps(analysis, lockFile: p.join(app, 'pubspec.lock'));
    expect(deps.packages['collection']!.constraint, '1.19.0');
  });

  test('a missing lock file gives no packages', () async {
    final app = copyFixtureApp();
    final deps = buildDeps(
      await analyze(app),
      lockFile: p.join(app, 'nowhere.lock'),
    );
    expect(deps.packages, isEmpty);
  });
}
