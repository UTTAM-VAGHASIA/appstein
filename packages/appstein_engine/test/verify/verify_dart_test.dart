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
import '../support/flutter_test_output.dart';

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
        expect(one.fixHint, contains('`dart fix --dry-run`'));
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

  // Why a file `verify` can't read may be left out of the source reading:
  // the analysis server can't read it either, and then reports the file as
  // analyzed, with no diagnostic. On Windows a lock another handle holds
  // makes a file unreadable.
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

    test('the server reports no diagnostic for it, and verify nothing: '
        'neither the use nor the comment', () async {
      final reading = await server.read();
      expect(reading.analyzedFiles, contains(locked));
      expect([
        for (final diagnostic in reading.diagnostics)
          if (diagnostic.file == locked) diagnostic.code,
      ], isEmpty);

      final result = await verify(app, server, mode: VerifyMode.fast);
      expect([
        for (final finding in result.findings)
          if (finding.file == locked) finding.id,
      ], isEmpty);
    });
  }, testOn: 'windows');
}
