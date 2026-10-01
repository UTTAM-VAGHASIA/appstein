import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/temp.dart';

void main() {
  Future<ProjectAnalysis> analyze(String project) async {
    final analysis = await ProjectAnalysis.analyze(
      project,
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    return analysis;
  }

  AnalyzedLibrary library(ProjectAnalysis analysis, String path) =>
      analysis.libraries.singleWhere((l) => l.path == path);

  test("the tests' Dart SDK has dart:core", () {
    expect(
      File(p.join(testDartSdk, 'lib', 'core', 'core.dart')).existsSync(),
      isTrue,
    );
  });

  test('analyzes lib/, test/ and testing/, sorted, with the package '
      'name', () async {
    final analysis = await analyze(copyFixtureApp());
    expect(analysis.packageName, 'fixture_app');
    final paths = [for (final l in analysis.libraries) l.path];
    expect(paths, hasLength(31));
    expect(
      paths,
      containsAll([
        'lib/main.dart',
        'test/ui/home/widgets/home_screen_test.dart',
        'testing/fakes/fake_booking_repository.dart',
      ]),
    );
    expect(paths, orderedEquals([...paths]..sort()));
  });

  test('names resolve through the stand-in packages, and locations are '
      'project-relative and 1-based', () async {
    final app = copyFixtureApp();
    final analysis = await analyze(app);
    const file = 'lib/ui/home/view_models/home_viewmodel.dart';
    final viewModel = library(analysis, file).result.element.classes.single;
    expect(
      viewModel.allSupertypes.map((t) => t.element.name),
      contains('ChangeNotifier'),
    );
    final location = analysis.locationOf(viewModel.firstFragment)!;
    expect(location.file, file);
    expect(location.line, lineOf(app, file, 'class HomeViewModel'));
  });

  test('imports of project files resolve to project paths, package: URIs '
      'included', () async {
    final app = copyFixtureApp();
    final analysis = await analyze(app);
    const file = 'test/ui/home/widgets/home_screen_test.dart';
    final unit = library(analysis, file).result.units.single;
    final imports = analysis.importsOf(unit);
    // package:flutter_test is outside the project, so it isn't listed.
    expect(
      [for (final i in imports) i.file],
      ['lib/ui/home/widgets/home_screen.dart'],
    );
    expect(imports.single.line, lineOf(app, file, 'home_screen.dart'));
    expect(imports.single.library.classes.single.name, 'HomeScreen');
  });

  test('code with errors still resolves', () async {
    final app = copyFixtureApp();
    File(p.join(app, 'lib', 'broken.dart')).writeAsStringSync(
      "import 'nowhere.dart';\n\nclass Broken extends Missing {}\n",
    );
    final analysis = await analyze(app);
    final broken = library(analysis, 'lib/broken.dart').result;
    expect(broken.units.single.diagnostics, isNotEmpty);
    expect(broken.element.classes.single.name, 'Broken');
  });

  test('a project without lib/, test/ or testing/ has no libraries', () async {
    final project = p.join(tempDir().path, 'empty app');
    Directory(project).createSync();
    File(
      p.join(project, 'pubspec.yaml'),
    ).writeAsStringSync('name: empty_app\n');
    final analysis = await analyze(project);
    expect(analysis.libraries, isEmpty);
    expect(analysis.packageName, 'empty_app');
  });

  test('an incomplete Dart SDK is a ProjectAnalysisException', () async {
    final sdk = p.join(tempDir().path, 'dart-sdk');
    Directory(sdk).createSync();
    await expectLater(
      ProjectAnalysis.analyze(copyFixtureApp(), dartSdkPath: sdk),
      throwsA(
        isA<ProjectAnalysisException>().having(
          (e) => e.message,
          'message',
          contains('lib/core/core.dart'),
        ),
      ),
    );
  });

  test('relativePath uses / and rejects files outside the project', () async {
    final app = copyFixtureApp();
    final analysis = await analyze(app);
    expect(
      analysis.relativePath(p.join(app, 'lib', 'routing', 'router.dart')),
      'lib/routing/router.dart',
    );
    expect(analysis.relativePath(p.join(app, '..', 'stubs')), isNull);
  });
}
