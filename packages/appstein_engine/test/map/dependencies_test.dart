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

  test('a missing lock file is an error, not an empty result', () async {
    final app = copyFixtureApp();
    final analysis = await analyze(app);
    expect(
      () => buildDeps(analysis, lockFile: p.join(app, 'nowhere.lock')),
      throwsA(
        isA<DependenciesException>().having(
          (e) => e.message,
          'message',
          allOf(contains('nowhere.lock'), contains('could not be read')),
        ),
      ),
    );
  });

  test('a lock file with merge-conflict markers throws, naming the '
      'line', () async {
    final app = copyFixtureApp();
    final analysis = await analyze(app);
    final lock = File(p.join(app, 'pubspec.lock'));
    final lines = lock.readAsLinesSync();
    lines.insertAll(2, ['<<<<<<< HEAD']);
    lock.writeAsStringSync('${lines.join('\n')}\n');
    expect(
      () => buildDeps(analysis, lockFile: lock.path),
      throwsA(
        isA<DependenciesException>().having(
          (e) => e.message,
          'message',
          matches(RegExp(r'^pubspec\.lock is not valid YAML \(line \d+\)')),
        ),
      ),
    );
  });

  test('a lock file that is not valid UTF-8 throws', () async {
    final app = copyFixtureApp();
    final analysis = await analyze(app);
    final lock = File(p.join(app, 'pubspec.lock'))
      ..writeAsBytesSync([0xff, 0xfe, 0xfd]);
    expect(
      () => buildDeps(analysis, lockFile: lock.path),
      throwsA(isA<DependenciesException>()),
    );
  });

  test('a pubspec.yaml that is not a map throws', () async {
    final app = copyFixtureApp();
    final analysis = await analyze(app);
    File(p.join(app, 'pubspec.yaml')).writeAsStringSync('- just\n- a list\n');
    expect(
      () => buildDeps(analysis, lockFile: p.join(app, 'pubspec.lock')),
      throwsA(
        isA<DependenciesException>().having(
          (e) => e.message,
          'message',
          'pubspec.yaml is not a YAML map',
        ),
      ),
    );
  });
}
