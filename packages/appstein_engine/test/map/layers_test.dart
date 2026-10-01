import 'dart:io';

import 'package:analyzer/dart/element/element.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';

void main() {
  // official_mvvm's shape, written out here so this test doesn't depend on
  // the pack (Task 9).
  final rules = LayerRules.fromJson({
    'layers': {
      'test': ['test/**', 'testing/**'],
      'ui': ['lib/ui/**'],
      'data.repository': ['lib/data/repositories/**'],
      'data.service': ['lib/data/services/**'],
      'domain': ['lib/domain/**'],
    },
    'allow': {
      'ui': ['domain'],
      'domain': <String>[],
    },
    'interfaces': {
      'ui': ['data.repository', 'data.service'],
      'domain': ['data.repository'],
    },
  });

  late String app;
  late ProjectAnalysis analysis;

  setUp(() async {
    app = copyFixtureApp();
    File(
      p.join(app, 'lib', 'only_functions.dart'),
    ).writeAsStringSync('int one() => 1;\n');
    analysis = await ProjectAnalysis.analyze(app, dartSdkPath: testDartSdk);
    addTearDown(analysis.dispose);
  });

  LibraryElement library(String path) =>
      analysis.libraries.singleWhere((l) => l.path == path).result.element;

  test('an interface file is one whose classes are all abstract', () {
    expect(
      isInterfaceLibrary(
        library('lib/data/repositories/booking/booking_repository.dart'),
      ),
      isTrue,
    );
    expect(
      isInterfaceLibrary(
        library('lib/data/repositories/auth/auth_repository.dart'),
      ),
      isTrue,
    );
    expect(
      isInterfaceLibrary(
        library('lib/data/repositories/booking/booking_repository_remote.dart'),
      ),
      isFalse,
    );
    expect(isInterfaceLibrary(library('lib/only_functions.dart')), isFalse);
  });

  test('every file gets its tag, feature and project imports, and the one '
      'forbidden import is reported', () {
    final layers = buildLayers(
      analysis,
      rules: rules,
      featureOf: (file) => file.contains('/home/') ? 'home' : null,
    );
    expect(layers.files, hasLength(32));
    expect(layers.files.keys, orderedEquals([...layers.files.keys]..sort()));
    expect(
      layers.files['test/ui/home/widgets/home_screen_test.dart']!.toJson(),
      {
        'layer': 'test',
        'feature': 'home',
        'imports': ['lib/ui/home/widgets/home_screen.dart'],
      },
    );
    expect(layers.files['lib/main.dart']!.toJson(), {
      'layer': null,
      'feature': null,
      'imports': ['lib/config/dependencies.dart', 'lib/routing/router.dart'],
    });
    const screen = 'lib/ui/booking/widgets/booking_screen.dart';
    expect(
      [for (final v in layers.violations) v.toJson()],
      [
        {
          'file': screen,
          'line': lineOf(app, screen, 'booking_repository_remote.dart'),
          'import':
              'lib/data/repositories/booking/booking_repository_remote.dart',
          'from': 'ui',
          'to': 'data.repository',
        },
      ],
    );
  });

  test('without layer rules, files have no tags and nothing is '
      'forbidden', () {
    final layers = buildLayers(analysis, rules: null, featureOf: (_) => null);
    expect(layers.files.values.map((f) => f.layer), everyElement(isNull));
    expect(layers.violations, isEmpty);
    expect(
      layers.files['lib/ui/booking/widgets/booking_screen.dart']!.imports,
      [
        'lib/data/repositories/booking/booking_repository_remote.dart',
        'lib/ui/booking/view_models/booking_viewmodel.dart',
      ],
    );
  });
}
