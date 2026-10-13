import 'dart:io';

import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../analysis/support/analysis_support.dart';
import '../knowledge/support/sync_harness.dart';
import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';

const _packs = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];

// `runVerify` on the fixture app with a real analysis server (slice 1d.2,
// seam 1). A start costs seconds, so each group starts one server for its
// app and every test of the group reads from it; no test edits a file.
void main() {
  Future<VerifyResult> verify(
    String app,
    CodeAnalysis analysis, {
    VerifyMode mode = VerifyMode.full,
    AppsteinConfig config = const AppsteinConfig(),
  }) => runVerify(
    projectRoot: app,
    config: config,
    packs: _packs,
    sync: knowledgeSync(
      flutterRoot: fakeFlutter(),
      runner: FakeProcessRunner(),
      packs: _packs,
      packageSkills: false,
    ),
    mode: mode,
    checks: checksFor(_packs),
    codeAnalysis: analysis,
    dartSdkPath: testDartSdk,
  );

  List<Finding> dart(VerifyResult result) => [
    for (final finding in result.findings)
      if (finding.id.startsWith('dart.')) finding,
  ];

  group('an app whose code has errors', () {
    late String app;
    late AnalysisServer server;

    setUpAll(() {
      app = copyFixtureApp();
      writeProjectFile(
        app,
        'lib/my folder/broken.dart',
        '/// Wrong on purpose.\nint wrong() => \'text\';\n',
      );
      // `Shape` lost its `sides`, which another file still reads.
      writeProjectFile(app, 'lib/shape.dart', '''
/// A shape.
class Shape {
  /// How many corners it has.
  int corners = 0;
}
''');
      writeProjectFile(app, 'lib/uses_shape.dart', '''
import 'shape.dart';

/// Reads what is gone.
int sidesOf(Shape shape) => shape.sides;
''');
      // A warning, which this check leaves alone.
      writeProjectFile(app, 'lib/unused.dart', '''
import 'dart:math';

/// One.
int one() => 1;
''');
      server = realAnalysisServer(app);
    });

    tearDownAll(() => server.stop());

    for (final mode in VerifyMode.values) {
      test('${mode.name}: each error is a dart.error with its file, line, '
          'message and code; the warning is not reported', () async {
        final result = await verify(app, server, mode: mode);
        final found = dart(result);
        expect(
          [for (final finding in found) (finding.id, finding.file)],
          [
            ('dart.error', 'lib/my folder/broken.dart'),
            ('dart.error', 'lib/uses_shape.dart'),
          ],
        );
        final [broken, uses] = found;
        expect(broken.severity, Severity.error);
        expect(broken.line, 2);
        expect(broken.message, contains("'String'"));
        expect(broken.message, endsWith(' (`return_of_invalid_type`)'));
        expect(broken.pack, isNull);
        // The class was broken in `shape.dart`; the error is where it is
        // used.
        expect(uses.line, 4);
        expect(uses.message, contains("'sides'"));
        expect(uses.message, endsWith(' (`undefined_getter`)'));
        expect(uses.fixHint, isNotNull);
        expect(result.errors, greaterThanOrEqualTo(2));
      });
    }

    test('a suppression hides one, and verify.severity changes the '
        'other', () async {
      final result = await verify(
        app,
        server,
        mode: VerifyMode.fast,
        config: const AppsteinConfig(
          verify: VerifyConfig(severity: {'dart.error': Severity.warning}),
          suppressions: [
            SuppressionEntry(
              id: 'dart.error',
              path: 'lib/my folder',
              reason: 'Broken on purpose.',
              line: 3,
            ),
          ],
        ),
      );
      expect(
        [for (final finding in dart(result)) (finding.file, finding.severity)],
        [('lib/uses_shape.dart', Severity.warning)],
      );
      expect(result.suppressed, 1);
      expect(result.activeSuppressions, 1);
      expect(result.errors, 0);
    });
  });

  // The stale case a project can really be in: its packages are not
  // fetched (and can't be here), so the map can't be built and no import of
  // a package resolves.
  group('an app whose packages are not fetched', () {
    late String app;
    late AnalysisServer server;

    setUpAll(() {
      app = copyFixtureApp();
      File(p.join(app, '.dart_tool', 'package_config.json')).deleteSync();
      server = realAnalysisServer(app);
    });

    tearDownAll(() => server.stop());

    for (final mode in VerifyMode.values) {
      test('${mode.name}: the knowledge is stale, and the errors of the code '
          'that doesn\'t resolve are reported beside it', () async {
        final result = await verify(app, server, mode: mode);
        expect(result.findings.first.id, 'knowledge.stale');
        final found = dart(result);
        expect(found, isNotEmpty);
        expect({for (final finding in found) finding.id}, {'dart.error'});
        expect([
          for (final finding in found) finding.message,
        ], contains(endsWith(' (`uri_does_not_exist`)')));
        expect([
          for (final check in result.notRun) check.id,
        ], isNot(contains('dart.error')));
      });
    }
  });

  group('the same app without the errors', () {
    late String app;
    late AnalysisServer server;

    setUpAll(() {
      app = copyFixtureApp();
      server = realAnalysisServer(app);
    });

    tearDownAll(() => server.stop());

    for (final mode in VerifyMode.values) {
      test('${mode.name}: nothing is reported for the check', () async {
        final result = await verify(app, server, mode: mode);
        expect(dart(result), isEmpty);
        expect(result.errors, 0);
        expect(result.notRun, isEmpty);
        // The server answered: it was started and is running.
        expect(server.processes, isNotNull);
      });
    }
  });
}
