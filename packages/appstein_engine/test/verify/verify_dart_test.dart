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
import '../support/analyzer_warm_up.dart';
import '../support/fake_process_runner.dart';
import '../support/fixture_app.dart';
import '../support/flutter_test_output.dart';

const _packs = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];

// `runVerify` on the fixture app with a real analysis server (slice 1d.2,
// seam 1). A start costs seconds, so each group starts one server for its
// app and every test of the group reads from it; no test edits a file.
void main() {
  setUpAll(warmUpAnalyzer);

  Future<VerifyResult> verify(
    String app,
    CodeAnalysis analysis, {
    VerifyMode mode = VerifyMode.full,
    AppsteinConfig config = const AppsteinConfig(),
  }) {
    // The app's tests pass, where a full run gets as far as running them.
    final sdk = fakeFlutter();
    final runner = FakeProcessRunner();
    scriptFlutterTest(runner, sdk);
    return runVerify(
      projectRoot: app,
      config: config,
      packs: _packs,
      sync: knowledgeSync(
        flutterRoot: sdk,
        runner: runner,
        packs: _packs,
        packageSkills: false,
      ),
      mode: mode,
      checks: checksFor(_packs),
      codeAnalysis: analysis,
      dartSdkPath: testDartSdk,
    );
  }

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
          'message and code; the warning is not one', () async {
        final result = await verify(app, server, mode: mode);
        final found = [
          for (final finding in dart(result))
            if (finding.id == 'dart.error') finding,
        ];
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
        // The project's warnings too: in a full run everywhere, and in a fast
        // run on the unverified files, which are every file here (nothing
        // was ever verified, and a run with stale knowledge lets none leave).
        expect({
          for (final finding in found) finding.id,
        }, contains('dart.error'));
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

  group('an app that uses deprecated APIs', () {
    late String app;
    late AnalysisServer server;

    const uses = 'lib/uses_old.dart';
    const hides = 'lib/my folder/hides_old.dart';
    const wholeFile = 'test/hides_all_test.dart';
    const oddPart = 'lib/odd.part';
    const lintNames = 'lib/lint_names.dart';
    const allHints = 'lib/all_hints.dart';
    const legacyOptions = 'lib/legacy/analysis_options.yaml';
    const strict = 'lib/strict/uses.dart';

    List<Finding> deprecated(VerifyResult result) => [
      for (final finding in result.findings)
        if (finding.id == 'dart.deprecated') finding,
    ];

    setUpAll(() {
      app = copyFixtureApp();
      // A package of the app with deprecated members: the stand-in `flutter`
      // of this copy gets a library of its own.
      File(
        p.join(p.dirname(app), 'stubs', 'flutter', 'lib', 'old.dart'),
      ).writeAsStringSync('''
/// Old, with what replaces it.
@Deprecated('Use newWay instead.')
void oldWay() {}

/// Older, with no message.
@deprecated
void olderWay() {}

/// New.
void newWay() {}
''');
      // Using the app's own deprecated members is a lint, which a project
      // switches on.
      writeProjectFile(
        app,
        'analysis_options.yaml',
        'analyzer:\n  exclude:\n    - lib/generated/**\n'
            'linter:\n  rules:\n    - deprecated_member_use_from_same_package\n',
      );
      // Not analyzed, so never read.
      writeProjectFile(
        app,
        'lib/generated/api.dart',
        '// ignore_for_file: deprecated_member_use\n',
      );
      // A part file whose name doesn't end in `.dart` is analyzed too.
      writeProjectFile(app, 'lib/part_whole.dart', '''
import 'package:flutter/old.dart';

part 'odd.part';

/// Uses the new one.
void whole() => newWay();
''');
      writeProjectFile(app, oddPart, '''
// ignore_for_file: deprecated_member_use
part of 'part_whole.dart';

/// Uses the old one.
void inPart() => oldWay();
''');
      // `type=hint` hides the analyzer's diagnostic without naming it.
      writeProjectFile(app, allHints, '''
// ignore_for_file: type=hint
import 'package:flutter/old.dart';

/// Uses the old one.
void hinted() => oldWay();
''');
      // `type=lint` hides only the lint, and is not reported.
      writeProjectFile(app, 'lib/lints_off.dart', '''
// ignore_for_file: type=lint
import 'uses_old.dart';

/// Uses the app's old one.
void linted() => stale();
''');
      // A folder whose options switch the diagnostic off.
      writeProjectFile(
        app,
        legacyOptions,
        'analyzer:\n  errors:\n    deprecated_member_use: ignore\n',
      );
      writeProjectFile(app, 'lib/legacy/old_code.dart', '''
import 'package:flutter/old.dart';

/// Uses the old one.
void legacy() => oldWay();
''');
      // A folder whose options make it an error.
      writeProjectFile(
        app,
        'lib/strict/analysis_options.yaml',
        'analyzer:\n  errors:\n    deprecated_member_use: error\n',
      );
      writeProjectFile(app, strict, '''
import 'package:flutter/old.dart';

/// Uses the old one.
void strictly() => oldWay();
''');
      // The lint's two longer names hide it too: one per form.
      writeProjectFile(app, lintNames, '''
import 'uses_old.dart';

/// Deprecated in this app, with no message.
@deprecated
void bare() {}

/// Hides each use by the longer name of its form.
void lintNames() {
  // ignore: deprecated_member_use_from_same_package_with_message
  stale();
  // ignore: deprecated_member_use_from_same_package_without_message
  bare();
}
''');
      writeProjectFile(app, uses, '''
import 'package:flutter/old.dart';

/// Deprecated in this app.
@Deprecated('Use fresh instead.')
void stale() {}

/// Its replacement.
void fresh() {}

/// Uses the old ones, and the new ones.
void uses() {
  oldWay(); // use 1
  olderWay(); // use 2
  stale(); // use 3
  newWay();
  fresh();
}
''');
      // Every use here is hidden from the analyzer.
      writeProjectFile(app, hides, '''
import 'package:flutter/old.dart';

import '../uses_old.dart';

/// Hides each use.
void hides() {
  // ignore: deprecated_member_use
  oldWay();
  olderWay(); // ignore: unused_local_variable, deprecated_member_use
  // ignore: deprecated_member_use_from_same_package
  stale();
}
''');
      writeProjectFile(app, wholeFile, '''
import 'package:flutter/old.dart';

void main() {
  oldWay();
  olderWay();
}

// ignore_for_file: deprecated_member_use
''');
      // Nothing here hides anything: other codes, a string, a doc comment's
      // sample, and the replacements.
      writeProjectFile(app, 'lib/not_hiding.dart', r"""
// ignore_for_file: unused_local_variable, avoid_print
import 'package:flutter/old.dart';

import 'uses_old.dart';

/// Says how to hide it, which hides nothing.
///
/// ```dart
/// // ignore: deprecated_member_use
/// oldWay();
/// ```
const advice = '// ignore: deprecated_member_use';

/// More of it.
const more = '''
// ignore_for_file: deprecated_member_use
''';

/// Uses the replacements.
void notHiding() {
  // ignore: avoid_print
  print('$advice $more');
  newWay();
  fresh();
}
""");
      server = realAnalysisServer(app);
    });

    tearDownAll(() => server.stop());

    // What the source reading relies on: the server names every file it
    // analyzed, also one without a diagnostic and one whose only diagnostic
    // a comment hides.
    test('the reading names every file the server analyzed, and none it '
        'left out', () async {
      final reading = await server.read();
      final files = reading.analyzedFiles;
      expect(files, [...files]..sort());
      expect(
        files,
        containsAll([
          uses,
          hides,
          wholeFile,
          oddPart,
          lintNames,
          'lib/part_whole.dart',
          // No diagnostic at all.
          'lib/not_hiding.dart',
          'lib/main.dart',
          'analysis_options.yaml',
          // The options file of a folder below the root.
          legacyOptions,
          'pubspec.yaml',
        ]),
      );
      expect(files, isNot(contains('lib/generated/api.dart')));
      expect(files.where((file) => file.contains(r'\')), isEmpty);
      // Each of these has uses, and every one is hidden.
      expect({
        for (final diagnostic in reading.diagnostics) diagnostic.file,
      }, isNot(anyOf(contains(hides), contains(oddPart), contains(lintNames))));
    });

    for (final mode in VerifyMode.values) {
      test('${mode.name}: each use and each hiding comment is a '
          'dart.deprecated error on its line; the replacements and the '
          'texts that hide nothing are not reported', () async {
        final result = await verify(app, server, mode: mode);
        final all = deprecated(result);
        // The comments in the part file and under the lint's longer names:
        // each works, so only the comment is reported.
        expect(
          [
            for (final finding in all)
              if (finding.file == lintNames || finding.file == oddPart)
                (finding.file, finding.line, finding.message),
          ],
          [
            (
              lintNames,
              lineOf(app, lintNames, '_with_message'),
              'This `// ignore:` comment names '
                  '`deprecated_member_use_from_same_package_with_message`: '
                  'it tells the analyzer to hide the use of a deprecated '
                  'API.',
            ),
            (
              lintNames,
              lineOf(app, lintNames, '_without_message'),
              'This `// ignore:` comment names '
                  '`deprecated_member_use_from_same_package_without_message`'
                  ': it tells the analyzer to hide the use of a deprecated '
                  'API.',
            ),
            (
              oddPart,
              1,
              'This `// ignore_for_file:` comment names '
                  '`deprecated_member_use`: it tells the analyzer to hide '
                  'every use of a deprecated API in this file.',
            ),
          ],
        );
        // What hides it without naming it, or for a whole folder: the
        // `type=hint` comment and the options entry are reported, and the
        // uses they hide are not. The `type=lint` file gives nothing.
        expect(
          [
            for (final finding in result.findings)
              if (const {
                allHints,
                legacyOptions,
                'lib/legacy/old_code.dart',
                'lib/lints_off.dart',
              }.contains(finding.file))
                (finding.id, finding.file, finding.line, finding.message),
          ],
          [
            (
              'dart.deprecated',
              allHints,
              1,
              'This `// ignore_for_file:` comment says `type=hint`: it tells '
                  'the analyzer to hide every hint in this file, and the '
                  'use of a deprecated API is a hint.',
            ),
            (
              'dart.deprecated',
              legacyOptions,
              3,
              'This entry sets `deprecated_member_use` to `ignore`: it '
                  'tells the analyzer not to report the use of a deprecated '
                  'API in the files this options file covers.',
            ),
          ],
        );
        // A use the project raised to an error is reported once.
        expect(
          [
            for (final finding in result.findings)
              if (finding.file == strict)
                (finding.id, finding.severity, finding.line),
          ],
          [('dart.deprecated', Severity.error, lineOf(app, strict, 'oldWay'))],
        );
        final found = [
          for (final finding in all)
            if (const {uses, hides, wholeFile}.contains(finding.file)) finding,
        ];
        expect(
          [for (final finding in found) (finding.file, finding.line)],
          [
            (hides, lineOf(app, hides, '// ignore: deprecated_member_use')),
            (hides, lineOf(app, hides, 'olderWay(); // ignore:')),
            (hides, lineOf(app, hides, '_from_same_package')),
            (uses, lineOf(app, uses, 'use 1')),
            (uses, lineOf(app, uses, 'use 2')),
            (uses, lineOf(app, uses, 'use 3')),
            (wholeFile, lineOf(app, wholeFile, '// ignore_for_file:')),
          ],
        );
        expect(
          {for (final finding in found) finding.severity},
          {Severity.error},
        );
        expect({for (final finding in found) finding.pack}, {null});
        expect([
          for (final finding in found) finding.fixHint,
        ], everyElement(isNotEmpty));

        final [above, atEnd, samePackage, one, two, three, forFile] = found;
        // The uses: the analyzer's message and its code.
        expect(
          one.message,
          "'oldWay' is deprecated and shouldn't be used. Use newWay instead. "
          '(`deprecated_member_use`)',
        );
        expect(
          two.message,
          "'olderWay' is deprecated and shouldn't be used. "
          '(`deprecated_member_use`)',
        );
        expect(
          three.message,
          "'stale' is deprecated and shouldn't be used. Use fresh instead. "
          '(`deprecated_member_use_from_same_package`)',
        );
        // Every file is unverified (the first sync), and the stand-in package
        // has no `fix_data.yaml`.
        expect(one.fixHint, startsWith("`dart fix` can't migrate this use"));
        // The comments: what each hides, and the visible way out.
        expect(above.message, contains('`// ignore:` comment'));
        expect(above.message, contains('`deprecated_member_use`'));
        expect(atEnd.message, contains('`deprecated_member_use`'));
        expect(
          samePackage.message,
          contains('`deprecated_member_use_from_same_package`'),
        );
        expect(forFile.message, contains('`// ignore_for_file:` comment'));
        for (final comment in [above, atEnd, samePackage, forFile]) {
          expect(comment.message, contains('tells the analyzer to hide'));
          expect(
            comment.fixHint,
            allOf(
              contains('`suppressions:`'),
              contains('`reason`'),
              contains('`appstein.yaml`'),
            ),
          );
        }
        expect(result.errors, greaterThanOrEqualTo(10));
        expect([
          for (final check in result.notRun) check.id,
        ], isNot(contains('dart.deprecated')));
      });
    }

    test('a suppression with a reason hides the findings of one folder, and '
        'verify.severity changes the others', () async {
      final result = await verify(
        app,
        server,
        mode: VerifyMode.fast,
        config: const AppsteinConfig(
          verify: VerifyConfig(severity: {'dart.deprecated': Severity.warning}),
          suppressions: [
            SuppressionEntry(
              id: 'dart.deprecated',
              path: 'lib/my folder',
              reason: 'Migrated with the next Flutter upgrade.',
              line: 3,
            ),
          ],
        ),
      );
      expect(
        [
          for (final finding in deprecated(result))
            (finding.file, finding.severity),
        ],
        [
          (allHints, Severity.warning),
          (legacyOptions, Severity.warning),
          (lintNames, Severity.warning),
          (lintNames, Severity.warning),
          (oddPart, Severity.warning),
          (strict, Severity.warning),
          (uses, Severity.warning),
          (uses, Severity.warning),
          (uses, Severity.warning),
          (wholeFile, Severity.warning),
        ],
      );
      expect(result.suppressed, 3);
      expect(result.activeSuppressions, 1);
      expect(
        deprecated(result).where((f) => f.severity == Severity.error),
        isEmpty,
      );
    });
  });

  // The analyzer applies the nearest `analysis_options.yaml` above a project
  // that has none. The server doesn't list that file, and with its entry the
  // analyzer reports no use at all, so the check reads it itself.
  group('an app below a folder whose options switch the diagnostic off', () {
    late String app;
    late AnalysisServer server;

    setUpAll(() {
      app = copyFixtureApp();
      File(
        p.join(p.dirname(app), 'stubs', 'flutter', 'lib', 'old.dart'),
      ).writeAsStringSync('''
/// Old.
@Deprecated('Use something new.')
void oldWay() {}
''');
      writeProjectFile(app, 'lib/uses_old.dart', '''
import 'package:flutter/old.dart';

/// Uses the old one.
void uses() => oldWay();
''');
      File(p.join(p.dirname(app), 'analysis_options.yaml')).writeAsStringSync(
        '# Shared by the apps of this folder.\n'
        'analyzer:\n  errors:\n    deprecated_member_use: ignore\n',
      );
      server = realAnalysisServer(app);
    });

    tearDownAll(() => server.stop());

    test('the analyzer reports nothing, and verify reports the entry above '
        'the project', () async {
      final reading = await server.read();
      expect(reading.analyzedFiles, contains('lib/uses_old.dart'));
      expect(reading.analyzedFiles, isNot(contains('analysis_options.yaml')));
      expect(
        reading.analyzedFiles.where((file) => file.startsWith('..')),
        isEmpty,
      );
      expect([
        for (final diagnostic in reading.diagnostics) diagnostic.code,
      ], isNot(contains('deprecated_member_use')));

      final result = await verify(app, server, mode: VerifyMode.fast);
      expect(
        [
          for (final finding in dart(result))
            (finding.id, finding.severity, finding.file, finding.line),
        ],
        [('dart.deprecated', Severity.error, '../analysis_options.yaml', 4)],
      );
    });
  });

  // The analyzer follows an `include:` and applies the included file's
  // settings under the including file's own. A project whose options file is
  // only `include: ../analysis_options.yaml` gets the shared file's switch-off,
  // and the server lists no file above the project, so the check follows the
  // include itself. A setting of the project's file wins over the shared one.
  group('an app whose options file includes a shared one that switches the '
      'diagnostic off', () {
    late String hidden;
    late String shown;
    late AnalysisServer hiddenServer;
    late AnalysisServer shownServer;

    String appWithOptions(String options) {
      final app = copyFixtureApp();
      File(
        p.join(p.dirname(app), 'stubs', 'flutter', 'lib', 'old.dart'),
      ).writeAsStringSync('''
/// Old.
@Deprecated('Use something new.')
void oldWay() {}
''');
      writeProjectFile(app, 'lib/uses_old.dart', '''
import 'package:flutter/old.dart';

/// Uses the old one.
void uses() => oldWay();
''');
      File(p.join(p.dirname(app), 'analysis_options.yaml')).writeAsStringSync(
        '# Shared by the apps of this folder.\n'
        'analyzer:\n  errors:\n    deprecated_member_use: ignore\n',
      );
      writeProjectFile(app, 'analysis_options.yaml', options);
      return app;
    }

    setUpAll(() {
      hidden = appWithOptions('include: ../analysis_options.yaml\n');
      hiddenServer = realAnalysisServer(hidden);
      shown = appWithOptions(
        'include: ../analysis_options.yaml\n'
        'analyzer:\n  errors:\n    deprecated_member_use: info\n',
      );
      shownServer = realAnalysisServer(shown);
    });

    tearDownAll(() async {
      await hiddenServer.stop();
      await shownServer.stop();
    });

    test('the analyzer reports nothing, and verify reports the entry in the '
        'shared file', () async {
      final reading = await hiddenServer.read();
      expect(reading.analyzedFiles, contains('lib/uses_old.dart'));
      expect(reading.analyzedFiles, contains('analysis_options.yaml'));
      expect([
        for (final diagnostic in reading.diagnostics) diagnostic.code,
      ], isNot(contains('deprecated_member_use')));

      final result = await verify(hidden, hiddenServer, mode: VerifyMode.fast);
      expect(
        [
          for (final finding in dart(result))
            (finding.id, finding.severity, finding.file, finding.line),
        ],
        [('dart.deprecated', Severity.error, '../analysis_options.yaml', 4)],
      );
    });

    test('the project\'s file that sets the code back to info: the analyzer '
        'reports the use, and verify reports it and not the shared '
        'entry', () async {
      final reading = await shownServer.read();
      expect(
        [
          for (final diagnostic in reading.diagnostics)
            if (diagnostic.code == 'deprecated_member_use') diagnostic.file,
        ],
        ['lib/uses_old.dart'],
      );

      final result = await verify(shown, shownServer, mode: VerifyMode.fast);
      expect(
        [
          for (final finding in dart(result))
            (finding.id, finding.severity, finding.file, finding.line),
        ],
        [('dart.deprecated', Severity.error, 'lib/uses_old.dart', 4)],
      );
    });
  });

  // `// appstein:ignore` comments (slice 1d.2, ticket 09), against what a real
  // analysis server reports.
  group('an app with // appstein:ignore comments and analyzer errors', () {
    late String app;
    late AnalysisServer server;

    setUpAll(() {
      app = copyFixtureApp();
      writeProjectFile(app, 'lib/hidden.dart', '''
/// Wrong, and said so.
int wrong() => 'text'; // appstein:ignore dart.error — accepted for now

/// Wrong, hidden from the line above.
// appstein:ignore dart.error — accepted for now
int alsoWrong() => 'text';

/// Wrong, with a comment that names no reason.
int noReason() => 'text'; // appstein:ignore dart.error
''');
      writeProjectFile(app, 'lib/hidden_file.dart', '''
// appstein:ignore-file dart.error — a sketch kept for reference
/// Wrong.
int wrong() => 'text';

/// Wrong too.
int wrongToo() => 'text';
''');
      writeProjectFile(app, 'lib/shown.dart', '''
/// Wrong, and nothing hides it.
int wrong() => 'text';
''');
      // In a string: not a comment.
      writeProjectFile(app, 'lib/in_string.dart', r"""
/// Wrong, with the comment in a string.
int wrong() => '// appstein:ignore dart.error — in a string';
""");
      server = realAnalysisServer(app);
    });

    tearDownAll(() => server.stop());

    test('each comment hides the error on its line, the file comment those '
        'of its file, and the rest stay', () async {
      final result = await verify(app, server, mode: VerifyMode.fast);
      expect(
        [
          for (final finding in result.findings)
            if (finding.id.startsWith('dart.') ||
                finding.id.startsWith('suppression.'))
              (finding.id, finding.file, finding.line),
        ],
        [
          ('dart.error', 'lib/hidden.dart', 9),
          ('suppression.no_reason', 'lib/hidden.dart', 9),
          ('dart.error', 'lib/in_string.dart', 2),
          ('dart.error', 'lib/shown.dart', 2),
        ],
      );
      // Two errors in `hidden.dart` and the two of `hidden_file.dart`, by
      // three comments.
      expect(result.suppressed, 4);
      expect(result.activeSuppressions, 3);
    });
  });

  group('an app with // appstein:ignore comments on deprecated use', () {
    late String app;
    late AnalysisServer server;

    setUpAll(() {
      app = copyFixtureApp();
      File(
        p.join(p.dirname(app), 'stubs', 'flutter', 'lib', 'old.dart'),
      ).writeAsStringSync('''
/// Old.
@Deprecated('Use newWay instead.')
void oldWay() {}

/// New.
void newWay() {}
''');
      writeProjectFile(app, 'lib/uses_old.dart', '''
import 'package:flutter/old.dart';

/// Hides the analyzer's diagnostic.
void diagnostic() {
  // appstein:ignore dart.deprecated — migrated in the next release
  oldWay();
}

/// Hides an `// ignore:` comment that trails the use.
void trailing() {
  // appstein:ignore dart.deprecated — migrated in the next release
  oldWay(); // ignore: deprecated_member_use
}

/// Hides an `// ignore:` comment alone above the use.
void above() {
  // appstein:ignore dart.deprecated — migrated in the next release
  // ignore: deprecated_member_use
  oldWay();
}

/// Nothing hides this one.
void shown() => oldWay();

/// Nothing to hide here.
void clean() => newWay(); // appstein:ignore dart.deprecated — left behind
''');
      // A one-line comment does not hide the finding on a comment that
      // silences deprecated use in the whole file.
      writeProjectFile(app, 'lib/file_wide.dart', '''
// appstein:ignore dart.deprecated — r
// ignore_for_file: deprecated_member_use
import 'package:flutter/old.dart';

/// Uses the old one, which the file comment hides from the analyzer.
void fileWide() => oldWay();
''');
      server = realAnalysisServer(app);
    });

    tearDownAll(() => server.stop());

    test('a full run: the comment hides the diagnostic and the // ignore: '
        'comment, and an unused one is a warning', () async {
      final result = await verify(app, server);
      expect(
        [
          for (final finding in result.findings)
            if (finding.id.startsWith('dart.') ||
                finding.id.startsWith('suppression.'))
              (finding.id, finding.severity, finding.file, finding.line),
        ],
        [
          ('dart.deprecated', Severity.error, 'lib/file_wide.dart', 2),
          ('suppression.unused', Severity.warning, 'lib/file_wide.dart', 1),
          ('dart.deprecated', Severity.error, 'lib/uses_old.dart', 23),
          ('suppression.unused', Severity.warning, 'lib/uses_old.dart', 26),
        ],
      );
      expect(result.suppressed, 3);
      expect(result.activeSuppressions, 3);
    });
  });

  // The analysis server can't read a locked file either, and reports it as
  // analyzed, with no diagnostic: without `dart.unreadable` every code check
  // would read it as clean. On Windows a lock another handle holds makes a
  // file unreadable.
  group('a file that can\'t be read', () {
    late String app;
    late AnalysisServer server;

    const locked = 'lib/locked.dart';

    setUpAll(() {
      app = copyFixtureApp();
      File(
        p.join(p.dirname(app), 'stubs', 'flutter', 'lib', 'old.dart'),
      ).writeAsStringSync('''
/// Old.
@Deprecated('Use something new.')
void oldWay() {}
''');
      // One use nothing hides, and one a comment hides.
      writeProjectFile(app, locked, '''
import 'package:flutter/old.dart';

/// Uses the old one, twice.
void uses() {
  oldWay();
  // ignore: deprecated_member_use
  oldWay();
}
''');
      final held = File(
        p.joinAll([app, ...locked.split('/')]),
      ).openSync(mode: FileMode.append)..lockSync(FileLock.exclusive);
      // Registered after the temp folder's deletion, so it runs before it.
      addTearDown(() {
        held
          ..unlockSync()
          ..closeSync();
      });
      server = realAnalysisServer(app);
    });

    tearDownAll(() => server.stop());

    test('the server reports no diagnostic for it, and verify reports '
        'dart.unreadable on it, in fast and full runs; it stays '
        'unverified', () async {
      final reading = await server.read();
      expect(reading.analyzedFiles, contains(locked));
      expect([
        for (final diagnostic in reading.diagnostics)
          if (diagnostic.file == locked) diagnostic.code,
      ], isEmpty);
      expect(reading.unreadableFiles.keys, [locked]);

      for (final mode in VerifyMode.values) {
        final result = await verify(app, server, mode: mode);
        expect(
          [
            for (final finding in result.findings)
              if (finding.file == locked) (finding.id, finding.severity),
          ],
          [('dart.unreadable', Severity.error)],
          reason: mode.name,
        );
        expect(
          result.findings
              .firstWhere((finding) => finding.id == 'dart.unreadable')
              .message,
          allOf(
            startsWith('This file could not be read ('),
            endsWith('), so nothing in it was checked.'),
          ),
        );
        expect(
          KnowledgeStore(app).readState().state!.unverified,
          contains(locked),
        );
      }
    });
  }, testOn: 'windows');

  // A kept server: a file locked after a reading, and one created and
  // locked; once the lock is gone, the server reads the file again.
  group('a file locked while a server is kept', () {
    late String app;
    late AnalysisServer server;

    const later = 'lib/later.dart';
    const created = 'lib/created.dart';

    setUpAll(() {
      app = copyFixtureApp();
      writeProjectFile(app, later, 'int later() => \'text\';\n');
      server = realAnalysisServer(app);
    });

    tearDownAll(() => server.stop());

    test('each is dart.unreadable while it is locked; unlocked, its errors '
        'are reported again', () async {
      var reading = await server.read();
      expect(
        [
          for (final diagnostic in reading.diagnostics)
            if (diagnostic.file == later) diagnostic.code,
        ],
        ['return_of_invalid_type'],
      );
      writeProjectFile(app, created, 'int created() => \'text\';\n');
      final holds = [
        for (final file in [later, created])
          File(
            p.joinAll([app, ...file.split('/')]),
          ).openSync(mode: FileMode.append)..lockSync(FileLock.exclusive),
      ];
      reading = await server.read();
      expect(reading.unreadableFiles.keys, [created, later]);
      final result = await verify(app, server, mode: VerifyMode.fast);
      expect(
        [
          for (final finding in result.findings)
            if (finding.id == 'dart.unreadable') finding.file,
        ],
        [created, later],
      );
      for (final held in holds) {
        held
          ..unlockSync()
          ..closeSync();
      }
      reading = await server.read();
      expect(reading.unreadableFiles, isEmpty);
      expect(
        {
          for (final diagnostic in reading.diagnostics)
            if (diagnostic.file == later || diagnostic.file == created)
              (diagnostic.file, diagnostic.code),
        },
        {
          (later, 'return_of_invalid_type'),
          (created, 'return_of_invalid_type'),
        },
      );
    });
  }, testOn: 'windows');

  // Fix round 1 of ticket 06: a lock past the first byte, a lock taken
  // between the look and the server's read, and files behind a junction.
  group('locks the first look can miss, and files behind a link', () {
    late String app;
    late AnalysisServer server;
    late String shared;
    Future<void> Function()? afterLook;

    const partial = 'lib/partial.dart';
    const late = 'lib/late_lock.dart';

    File fileOf(String relative) =>
        File(p.joinAll([app, ...relative.split('/')]));

    setUpAll(() async {
      app = copyFixtureApp();
      shared = p.join(p.dirname(app), 'shared');
      File(p.join(shared, 'behind.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('/// Behind the link.\nint behind() => 1;\n');
      // On Windows a junction, which needs no admin rights.
      Link(p.join(app, 'lib', 'linked')).createSync(shared);
      writeProjectFile(app, partial, '/// Fine.\nint partial() => 1;\n');
      writeProjectFile(app, late, '/// Fine.\nint late() => 1;\n');
      server = AnalysisServer(
        projectRoot: app,
        guardCommand: testGuardCommand,
        dartExecutable: () => testDart,
        afterLook: () async => afterLook?.call(),
      );
      await server.read();
    });

    tearDownAll(() => server.stop());

    test('a link to a Dart file is analyzed under the link\'s name, and an '
        'edit of its target is in the next reading at once', () async {
      final target = File(p.join(shared, 'target.dart'))
        ..writeAsStringSync('/// Fine.\nint target() => 1;\n');
      try {
        Link(p.join(app, 'lib', 'file_link.dart')).createSync(target.path);
      } on FileSystemException catch (error) {
        markTestSkipped('No file link could be made here: ${error.message}');
        return;
      }
      var reading = await server.read();
      expect(reading.analyzedFiles, contains('lib/file_link.dart'));
      target.writeAsStringSync('/// Broken.\nint target() => "x";\n');
      reading = await server.read();
      expect(
        [
          for (final diagnostic in reading.diagnostics)
            if (diagnostic.file == 'lib/file_link.dart') diagnostic.code,
        ],
        ['return_of_invalid_type'],
      );
    });

    test('a file behind a junction is analyzed by its path through the link, '
        'and an edit there is in the next reading at once', () async {
      var reading = await server.read();
      expect(reading.analyzedFiles, contains('lib/linked/behind.dart'));
      File(
        p.join(shared, 'behind.dart'),
      ).writeAsStringSync('/// Broken.\nint behind() => "text";\n');
      reading = await server.read();
      expect(
        [
          for (final diagnostic in reading.diagnostics)
            if (diagnostic.file == 'lib/linked/behind.dart') diagnostic.code,
        ],
        ['return_of_invalid_type'],
      );
      File(
        p.join(shared, 'behind.dart'),
      ).writeAsStringSync('/// Behind the link.\nint behind() => 1;\n');
      reading = await server.read();
      expect(
        reading.diagnostics.where(
          (diagnostic) => diagnostic.file == 'lib/linked/behind.dart',
        ),
        isEmpty,
      );
    });

    test('an edited file locked past its first byte is dart.unreadable, and '
        'stays unverified', () async {
      fileOf(partial).writeAsStringSync('/// Broken.\nint partial() => "x";\n');
      final held = fileOf(partial).openSync(mode: FileMode.append)
        ..lockSync(FileLock.exclusive, 5);
      try {
        final result = await verify(app, server, mode: VerifyMode.fast);
        expect(
          [
            for (final finding in result.findings)
              if (finding.file == partial) finding.id,
          ],
          ['dart.unreadable'],
        );
        expect(
          KnowledgeStore(app).readState().state!.unverified,
          contains(partial),
        );
      } finally {
        held
          ..unlockSync(5)
          ..closeSync();
      }
      final reading = await server.read();
      expect(reading.unreadableFiles, isEmpty);
      expect(
        [
          for (final diagnostic in reading.diagnostics)
            if (diagnostic.file == partial) diagnostic.code,
        ],
        ['return_of_invalid_type'],
      );
    });

    test('a file locked after the look, before the server reads it, and '
        'still locked after the reading, is dart.unreadable, not clean, and '
        'does not leave', () async {
      fileOf(late).writeAsStringSync('/// Broken.\nint late() => "x";\n');
      RandomAccessFile? held;
      afterLook = () async {
        held ??= fileOf(late).openSync(mode: FileMode.append)
          ..lockSync(FileLock.exclusive);
      };
      try {
        final result = await verify(app, server, mode: VerifyMode.fast);
        expect(
          [
            for (final finding in result.findings)
              if (finding.file == late) finding.id,
          ],
          ['dart.unreadable'],
        );
        expect(
          KnowledgeStore(app).readState().state!.unverified,
          contains(late),
        );
      } finally {
        afterLook = null;
        held
          ?..unlockSync()
          ..closeSync();
      }
      final reading = await server.read();
      expect(
        [
          for (final diagnostic in reading.diagnostics)
            if (diagnostic.file == late) diagnostic.code,
        ],
        ['return_of_invalid_type'],
      );
    });
  }, testOn: 'windows');

  // Ticket 06 with a real server and the real refresh: the files that
  // change on disk join the unverified files, and a fast run reports their
  // warnings and lints only.
  group('warnings, lints and the unverified files', () {
    late String app;
    late AnalysisServer server;

    const a = 'lib/a.dart';
    const b = 'lib/b.dart';
    const old = 'lib/old.dart';

    List<(String, String?)> found(VerifyResult result) => [
      for (final finding in result.findings)
        if (finding.id.startsWith('dart.')) (finding.id, finding.file),
    ];

    setUpAll(() async {
      app = copyFixtureApp();
      // A lint the fixture's options don't switch on.
      writeProjectFile(
        app,
        'analysis_options.yaml',
        'linter:\n  rules:\n    - prefer_single_quotes\n',
      );
      // An old warning and an old lint in a file nobody touches.
      writeProjectFile(app, old, '''
import 'dart:math';

/// Old.
String old() => "old";
''');
      writeProjectFile(app, a, '/// A.\nint a() => 1;\n');
      writeProjectFile(app, b, '/// B.\nint b() => 2;\n');
      server = realAnalysisServer(app);
      // The first run records every file; none is unverified.
      await verify(app, server, mode: VerifyMode.fast);
    });

    tearDownAll(() => server.stop());

    test(
      'a full run reports the old warning and lint; a fast run doesn\'t',
      () async {
        final full = await verify(app, server);
        expect(
          found(full),
          containsAll([('dart.warning', old), ('dart.lint', old)]),
        );
        final warning = full.findings.firstWhere(
          (finding) => finding.id == 'dart.warning',
        );
        expect(warning.severity, Severity.warning);
        expect(warning.line, 1);
        expect(warning.message, endsWith(' (`unused_import`)'));
        final lint = full.findings.firstWhere(
          (finding) => finding.id == 'dart.lint',
        );
        expect(lint.severity, Severity.info);
        expect(lint.line, 4);
        expect(lint.message, endsWith(' (`prefer_single_quotes`)'));
        final fast = await verify(app, server, mode: VerifyMode.fast);
        expect(found(fast), isEmpty);
      },
    );

    test('the scenario from the interview: A broken, then B edited '
        'correctly; A stays unverified and its findings stay', () async {
      writeProjectFile(app, a, '''
import 'dart:io';

/// A, broken.
int a() => "text";
''');
      var fast = await verify(app, server, mode: VerifyMode.fast);
      expect(found(fast), [
        ('dart.error', a),
        ('dart.warning', a),
        ('dart.lint', a),
      ]);
      expect(KnowledgeStore(app).readState().state!.unverified, [a]);

      writeProjectFile(app, b, '/// B, edited.\nint b() => 3;\n');
      fast = await verify(app, server, mode: VerifyMode.fast);
      expect(found(fast), [
        ('dart.error', a),
        ('dart.warning', a),
        ('dart.lint', a),
      ]);
      expect(KnowledgeStore(app).readState().state!.unverified, [a]);

      // A fixed: its lint and warning go with the error, and it leaves.
      writeProjectFile(app, a, '/// A, fixed.\nint a() => 1;\n');
      fast = await verify(app, server, mode: VerifyMode.fast);
      expect(found(fast), isEmpty);
      expect(KnowledgeStore(app).readState().state!.unverified, isEmpty);
    });

    test('a test file that changes joins them too', () async {
      writeProjectFile(app, 'test/extra_test.dart', '''
import 'dart:math';

void main() {}
''');
      final fast = await verify(app, server, mode: VerifyMode.fast);
      expect(found(fast), [('dart.warning', 'test/extra_test.dart')]);
      File(p.join(app, 'test', 'extra_test.dart')).deleteSync();
      await verify(app, server, mode: VerifyMode.fast);
      expect(KnowledgeStore(app).readState().state!.unverified, isEmpty);
    });

    test('verify.severity raises dart.warning and a suppression hides '
        'dart.lint', () async {
      final result = await verify(
        app,
        server,
        config: const AppsteinConfig(
          verify: VerifyConfig(severity: {'dart.warning': Severity.error}),
          suppressions: [
            SuppressionEntry(
              id: 'dart.lint',
              path: old,
              reason: 'Kept as it was.',
              line: 3,
            ),
          ],
        ),
      );
      expect(
        [
          for (final finding in result.findings)
            if (finding.file == old) (finding.id, finding.severity),
        ],
        [('dart.warning', Severity.error)],
      );
      expect(result.suppressed, 1);
    });
  });

  // `dart fix` can migrate a use when the package that deprecated the API
  // describes the migration in its `fix_data.yaml`.
  group('deprecated use with and without a data-driven fix', () {
    late String app;
    late AnalysisServer server;

    const uses = 'lib/uses_old.dart';
    const before = 'lib/before.dart';

    setUpAll(() async {
      app = copyFixtureApp();
      final stub = p.join(p.dirname(app), 'stubs', 'flutter', 'lib');
      File(p.join(stub, 'old.dart')).writeAsStringSync('''
/// Old, with a migration.
@Deprecated('Use newWay instead.')
void oldWay() {}

/// Old, with a migration for the IDE only.
@Deprecated('Use newIde instead.')
void oldIde() {}

/// Old, with none.
@Deprecated('Rewrite it.')
void otherWay() {}

/// New.
void newWay() {}

/// New, for the IDE's migration.
void newIde() {}
''');
      File(p.join(stub, 'fix_data.yaml')).writeAsStringSync('''
version: 1
transforms:
  - title: 'Rename to newWay'
    date: 2026-01-01
    element:
      uris: ['old.dart']
      function: 'oldWay'
    changes:
      - kind: 'rename'
        newName: 'newWay'
  - title: 'Rename to newIde'
    date: 2026-01-01
    bulkApply: false
    element:
      uris: ['old.dart']
      function: 'oldIde'
    changes:
      - kind: 'rename'
        newName: 'newIde'
''');
      writeProjectFile(app, before, '''
import 'package:flutter/old.dart';

/// Uses the old one.
void before() => oldWay();
''');
      server = realAnalysisServer(app);
      await verify(app, server, mode: VerifyMode.fast);
      // As if a run had verified it earlier: `before` is not unverified.
      final store = KnowledgeStore(app);
      final now = store.readState().state!;
      await store.locked(
        () => store.writeState(now.copyWith(unverified: const [])),
      );
      writeProjectFile(app, uses, '''
import 'package:flutter/old.dart';

/// Uses all three.
void uses() {
  oldWay();
  oldIde();
  otherWay();
}
''');
    });

    tearDownAll(() => server.stop());

    test('a kept answer belongs to the text the reading was taken from: an '
        'edit between the reading and the question files nothing under the '
        'new text', () async {
      const swap = 'lib/swap.dart';
      addTearDown(() => deleteProjectFile(app, swap));
      writeProjectFile(app, swap, '''
import 'package:flutter/old.dart';

/// Swapped.
void swap() {
  oldWay();
}
''');
      var reading = await server.read();
      final migratable = reading.diagnostics.singleWhere(
        (diagnostic) => diagnostic.file == swap,
      );
      // The same offset and code, with a use that has no migration.
      writeProjectFile(app, swap, '''
import 'package:flutter/old.dart';

/// Swapped.
void swap() {
  otherWay();
}
''');
      // Asked after the edit, about the reading before it. The server
      // usually still answers for the old text (true); its own file watcher
      // may have taken the edit in already (false). Either way the answer
      // must not be kept for the new text.
      final first = await server.canDartFix(migratable);
      reading = await server.read();
      final other = reading.diagnostics.singleWhere(
        (diagnostic) => diagnostic.file == swap,
      );
      expect((other.offset, other.code), (migratable.offset, migratable.code));
      expect(await server.canDartFix(other), isFalse, reason: 'first: $first');
    });

    test('on an unverified file the hint says whether dart fix can migrate '
        'it; elsewhere it stays general; an answer is asked once', () async {
      final reading = await server.read();
      final [migrated, ideOnly, rewritten] = [
        for (final diagnostic in reading.diagnostics)
          if (diagnostic.file == uses) diagnostic,
      ];
      expect(migrated.offset, isNotNull);
      final asked = Stopwatch()..start();
      expect(await server.canDartFix(migrated), isTrue);
      final first = asked.elapsedMicroseconds;
      // A migration the package marks for the IDE only is offered the same
      // way: the server's answer doesn't tell the two apart, so the hint
      // says only what holds.
      expect(await server.canDartFix(ideOnly), isTrue);
      expect(await server.canDartFix(rewritten), isFalse);
      final three = asked.elapsedMicroseconds;
      asked.reset();
      for (var i = 0; i < 10; i++) {
        expect(await server.canDartFix(migrated), isTrue);
      }
      final kept = asked.elapsedMicroseconds / 10;
      // ignore: avoid_print
      print(
        'canDartFix on the fixture app: first question '
        '${(first / 1000).toStringAsFixed(1)} ms, three questions '
        '${(three / 1000).toStringAsFixed(1)} ms, a kept answer '
        '${(kept / 1000).toStringAsFixed(2)} ms',
      );

      String? hint(VerifyResult result, String file, String name) => result
          .findings
          .firstWhere(
            (finding) =>
                finding.id == 'dart.deprecated' &&
                finding.file == file &&
                finding.message.contains("'$name'"),
          )
          .fixHint;

      for (final mode in VerifyMode.values) {
        final result = await verify(app, server, mode: mode);
        for (final name in ['oldWay', 'oldIde']) {
          expect(
            hint(result, uses, name),
            startsWith('The package that deprecated this API describes a '),
          );
        }
        expect(hint(result, uses, 'otherWay'), startsWith("`dart fix` can't"));
        expect(
          hint(result, before, 'oldWay'),
          contains('`dart fix --dry-run`'),
        );
        // A deprecated use is an error: the file stays unverified.
        expect(KnowledgeStore(app).readState().state!.unverified, [uses]);
      }
    });
  });
}
