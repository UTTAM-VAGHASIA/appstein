import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/analysis_hosts.dart';
import 'support/child_processes.dart';
import 'support/dart_sdk.dart';
import 'support/fake_flutter_sdk.dart';
import 'support/healthy_project.dart';
import 'support/scripted_code_analysis.dart';

const _stale = Finding(
  id: 'knowledge.stale',
  severity: Severity.error,
  message: 'The knowledge could not be brought up to date: no packages.',
  fixHint: 'Run `flutter pub get`. Then run `appstein verify` again.',
);

const _drift = Finding(
  id: 'decision.drift',
  severity: Severity.warning,
  file: '.appstein/decisions/0002-state.md',
  line: 7,
  message:
      '2 files under lib/ import `flutter_riverpod`: lib/a.dart, lib/b.dart.',
  fixHint: 'Bring the code back in line.',
);

const _noTest = Finding(
  id: 'verify.test_required',
  severity: Severity.warning,
  file: 'lib/ui/profile',
  message: 'The feature `profile` has no test.',
  fixHint: 'Add a test under `test/ui/profile/`.',
);

/// Whether the process [id] is a Windows console host ([isConsoleHost]).
bool _isConsoleHostProcess(int id) => switch (lookUpProcess(id)) {
  ProcessRunning(:final identity) => isConsoleHost(identity.image),
  _ => false,
};

/// A check that throws, as a broken check of a pack would.
final class _ThrowingCheck implements VerifyCheck {
  const _ThrowingCheck();

  @override
  List<String> get ids => const ['boom.check'];

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) =>
      throw StateError('it broke');
}

void main() {
  group('formatVerify', () {
    test('groups the findings by file, lists what did not run, and ends '
        'with the summary', () {
      expect(
        formatVerify(
          const VerifyResult(
            findings: [_stale, _drift, _noTest],
            suppressed: 1,
            activeSuppressions: 1,
            notRun: [
              CheckNotRun(
                id: 'docs.stale',
                reason: 'the project map is not up to date',
              ),
              CheckNotRun(
                id: 'verify.test_required',
                reason: 'the project map is not up to date',
              ),
            ],
          ),
        ),
        '(project)\n'
        '  error knowledge.stale: The knowledge could not be brought up to '
        'date: no packages.\n'
        '    fix: Run `flutter pub get`. Then run `appstein verify` again.\n'
        '\n'
        '.appstein/decisions/0002-state.md\n'
        '  warning decision.drift (line 7): 2 files under lib/ import '
        '`flutter_riverpod`: lib/a.dart, lib/b.dart.\n'
        '    fix: Bring the code back in line.\n'
        '\n'
        'lib/ui/profile\n'
        '  warning verify.test_required: The feature `profile` has no test.\n'
        '    fix: Add a test under `test/ui/profile/`.\n'
        '\n'
        'Not run:\n'
        '  docs.stale: the project map is not up to date\n'
        '  verify.test_required: the project map is not up to date\n'
        '\n'
        '1 error, 2 warnings, 0 info. 1 finding suppressed by 1 '
        'suppression.\n',
      );
    });

    test('the files --apply rewrote come first, in a section of their own; '
        'with none there is no section', () {
      expect(
        formatVerify(
          const VerifyResult(
            findings: [_noTest],
          ).withApplied(const ['lib/a.dart', 'lib/b.dart']),
        ),
        'Rewritten by --apply (read these files again before you edit '
        'them):\n'
        '  lib/a.dart\n'
        '  lib/b.dart\n'
        '\n'
        'lib/ui/profile\n'
        '  warning verify.test_required: The feature `profile` has no test.\n'
        '    fix: Add a test under `test/ui/profile/`.\n'
        '\n'
        '0 errors, 1 warning, 0 info. No findings suppressed.\n',
      );
      expect(
        formatVerify(const VerifyResult(findings: []).withApplied(const [])),
        '0 errors, 0 warnings, 0 info. No findings suppressed.\n',
      );
      expect(
        formatVerify(
          const VerifyResult(findings: []).withApplied(const ['lib/a.dart']),
        ),
        startsWith(
          'Rewritten by --apply (read this file again before you edit it):\n'
          '  lib/a.dart\n\n',
        ),
      );
    });

    test('with nothing found, it is the summary line alone', () {
      expect(
        formatVerify(const VerifyResult(findings: [])),
        '0 errors, 0 warnings, 0 info. No findings suppressed.\n',
      );
    });

    test('notices are printed under `Note:`, before the summary, and '
        'change no count', () {
      expect(
        formatVerify(
          const VerifyResult(findings: []).withNotices(const [
            'Process 7 (dart.exe) may be an analysis server that Appstein '
                'started and could not stop.',
          ]),
        ),
        'Note:\n'
        '  Process 7 (dart.exe) may be an analysis server that Appstein '
        'started and could not stop.\n'
        '\n'
        '0 errors, 0 warnings, 0 info. No findings suppressed.\n',
      );
      expect(
        verifyExitCode(
          const VerifyResult(findings: []).withNotices(const ['x']),
        ),
        ExitCodes.ok,
      );
    });

    test('counts in the singular and the plural', () {
      const info = Finding(
        id: 'memory.lessons_long',
        severity: Severity.info,
        file: 'a.md',
        message: 'm',
      );
      expect(
        formatVerify(
          const VerifyResult(
            findings: [_noTest, info, info],
            suppressed: 5,
            activeSuppressions: 2,
          ),
        ),
        endsWith(
          '0 errors, 1 warning, 2 info. 5 findings suppressed by 2 '
          'suppressions.\n',
        ),
      );
      expect(
        formatVerify(
          const VerifyResult(
            findings: [],
            suppressed: 4,
            activeSuppressions: 1,
          ),
        ),
        '0 errors, 0 warnings, 0 info. 4 findings suppressed by 1 '
        'suppression.\n',
      );
      expect(
        formatVerify(const VerifyResult(findings: [_stale, _stale])),
        endsWith('2 errors, 0 warnings, 0 info. No findings suppressed.\n'),
      );
    });

    test('a finding without a fix hint has no fix line', () {
      expect(
        formatVerify(
          const VerifyResult(
            findings: [
              Finding(
                id: 'docs.stale',
                severity: Severity.warning,
                file: 'docs/app',
                message: 'Something is in the way.',
              ),
            ],
          ),
        ),
        'docs/app\n'
        '  warning docs.stale: Something is in the way.\n'
        '\n'
        '0 errors, 1 warning, 0 info. No findings suppressed.\n',
      );
    });

    test('a file with an error comes before a file without one, whatever '
        'their names; the project group leads its half', () {
      Finding at(String? file, Severity severity) =>
          Finding(id: 'x.y', severity: severity, file: file, message: 'm');
      final text = formatVerify(
        VerifyResult(
          findings: sortFindings([
            at(null, Severity.warning),
            at('a.dart', Severity.warning),
            at('b.dart', Severity.info),
            at('b.dart', Severity.error),
            at('z.dart', Severity.error),
          ]),
        ),
      );
      expect(
        [
          for (final line in const LineSplitter().convert(text))
            if (line.isNotEmpty && !line.startsWith(' ')) line,
        ],
        [
          'b.dart',
          'z.dart',
          '(project)',
          'a.dart',
          '2 errors, 2 warnings, 1 info. No findings suppressed.',
        ],
      );
      // Inside a file, the error is first.
      expect(text, startsWith('b.dart\n  error x.y: m\n  info x.y: m\n\n'));
    });
  });

  group('verifyExitCode', () {
    test('is 1 only when there is an error', () {
      expect(verifyExitCode(const VerifyResult(findings: [])), ExitCodes.ok);
      expect(
        verifyExitCode(const VerifyResult(findings: [_drift, _noTest])),
        ExitCodes.ok,
      );
      expect(
        verifyExitCode(
          const VerifyResult(
            findings: [
              Finding(id: 'a.b', severity: Severity.info, message: 'm'),
            ],
            notRun: [CheckNotRun(id: 'a.c', reason: 'r')],
          ),
        ),
        ExitCodes.ok,
      );
      expect(
        verifyExitCode(const VerifyResult(findings: [_drift, _stale])),
        ExitCodes.errorsFound,
      );
    });
  });

  // The fake Flutter SDK has no Dart SDK, so unless a run is given one
  // (`dartSdkPath: testDartSdk`) the project map can't be built: it reports
  // `knowledge.stale`. The runs on the fixture app are in the engine's
  // `verify_fixture_test.dart`, and with the real binary in
  // `tool/measure_sync.dart`.
  group('appstein verify', () {
    late StringBuffer out;
    late StringBuffer err;
    late Directory work;
    late String project;
    late String sdk;
    late String cache;

    /// The folder this test's runs look for an analysis host in: its own, so
    /// that a host of the machine's user is never met.
    late String hosts;

    setUp(() {
      out = StringBuffer();
      err = StringBuffer();
      work = Directory.systemTemp.createTempSync('appstein cli tëst ');
      addTearDown(() => work.deleteSync(recursive: true));
      project = p.join(work.path, 'my app');
      Directory(project).createSync();
      File(
        p.join(project, 'pubspec.yaml'),
      ).writeAsStringSync('name: my_app\nenvironment:\n  sdk: ^3.12.0\n');
      sdk = createFakeFlutterSdk(p.join(work.path, 'flutter'));
      cache = testAnalysisCache();
      hosts = p.join(work.path, 'host folder');
    });

    Future<int> run(
      List<String> args, {
      String? workingDirectory,
      List<({VerifyCheck check, String? pack})> Function(List<Pack> packs)?
      verifyChecks,
      String? dartSdkPath,
      ScriptedCodeAnalysis? analysis,
      bool realServer = false,
      CodeAnalysisScope? scope,
    }) => runAppstein(
      // The fake SDK has no `dart` to run an analysis server with, so a run
      // gets a scripted answer (nothing found) unless it asks for the real
      // server, which is then the one of `dartSdkPath`, or gives a scope.
      codeAnalysis:
          scope ??
          (realServer ? null : (analysis ?? ScriptedCodeAnalysis()).scope),
      args,
      out: out,
      err: err,
      environment: HostEnvironment(
        os: HostOs.current,
        variables: {
          'FLUTTER_ROOT': sdk,
          analysisCacheVariable: cache,
          analysisHostFolderVariable: hosts,
        },
        workingDirectory: workingDirectory ?? project,
      ),
      verifyChecks: verifyChecks,
      dartSdkPath: dartSdkPath,
    );

    void config(String text) =>
        File(p.join(project, 'appstein.yaml')).writeAsStringSync(text);

    void decision() =>
        File(p.join(project, '.appstein', 'decisions', '0001-state.md'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            '---\n'
            'title: State lives in view models\n'
            'status: accepted\n'
            'date: 2026-10-01\n'
            'paths: [lib/gone.dart]\n'
            'checks: [paths.exist]\n'
            '---\n'
            'Why: because.\n',
          );

    test('reports stale knowledge as an error, with exit 1, and names the '
        'checks it could not run', () async {
      expect(await run(['verify']), ExitCodes.errorsFound);
      expect(err.toString(), isEmpty);
      final text = out.toString();
      expect(
        text,
        startsWith(
          '(project)\n'
          '  error knowledge.stale: The knowledge could not be brought up to '
          'date: ',
        ),
      );
      expect(text, contains('\n    fix: '));
      expect(text, contains('`appstein verify` again.'));
      expect(
        text,
        endsWith(
          '\n'
          'Not run:\n'
          '  docs.stale: the project map is not up to date\n'
          '  verify.test_required: the project map is not up to date\n'
          '\n'
          '1 error, 0 warnings, 0 info. No findings suppressed.\n',
        ),
      );
    });

    test('builds the knowledge of a project that has none', () async {
      expect(Directory(p.join(project, '.appstein')).existsSync(), isFalse);
      await run(['verify']);
      expect(
        File(p.join(project, '.appstein', 'INDEX.md')).existsSync(),
        isTrue,
      );
    });

    test('--fast runs no full check, so none is named as not run', () async {
      expect(await run(['verify', '--fast']), ExitCodes.errorsFound);
      expect(out.toString(), isNot(contains('Not run:')));
      expect(
        out.toString(),
        endsWith('\n\n1 error, 0 warnings, 0 info. No findings suppressed.\n'),
      );
    });

    test('--full is the default', () async {
      await run(['verify']);
      final byDefault = out.toString();
      out.clear();
      await run(['verify', '--full']);
      expect(out.toString(), byDefault);
    });

    test('--format json prints the result as JSON', () async {
      decision();
      expect(await run(['verify', '--format', 'json']), ExitCodes.errorsFound);
      expect(err.toString(), isEmpty);
      expect(out.toString(), endsWith('}\n'));
      final json = jsonDecode(out.toString()) as Map<String, Object?>;
      expect(json.keys, [
        'findings',
        'summary',
        'suppressed',
        'activeSuppressions',
        'notRun',
        'applied',
      ]);
      // Without --apply, nothing was rewritten.
      expect(json['applied'], isEmpty);
      expect(json['summary'], {'errors': 1, 'warnings': 1, 'info': 0});
      final result = VerifyResult.fromJson(json);
      expect(
        [for (final finding in result.findings) finding.id],
        ['knowledge.stale', 'decision.drift'],
      );
      expect(result.findings.last.file, '.appstein/decisions/0001-state.md');
      expect(result.findings.last.line, 5);
      expect(
        [for (final check in result.notRun) check.id],
        ['docs.stale', 'verify.test_required'],
      );
    });

    test('a decision that drifted is a warning in its own group', () async {
      decision();
      await run(['verify']);
      expect(
        out.toString(),
        contains(
          '\n'
          '.appstein/decisions/0001-state.md\n'
          '  warning decision.drift (line 5): The path `lib/gone.dart` '
          'matches no file.\n'
          '    fix: Bring the code back in line, or replace the decision '
          'with a new one (`record_decision` with `supersedes`).\n',
        ),
      );
      expect(out.toString(), contains('1 error, 1 warning, 0 info.'));
    });

    test('verify.severity in appstein.yaml makes it an error', () async {
      decision();
      config('appstein: 1\nverify:\n  severity:\n    decision.drift: error\n');
      await run(['verify']);
      expect(
        out.toString(),
        contains('\n  error decision.drift (line 5): The path'),
      );
      expect(out.toString(), contains('2 errors, 0 warnings, 0 info.'));
    });

    test('a suppression without a reason is an error on its line of '
        'appstein.yaml', () async {
      config(
        'appstein: 1\n'
        'suppressions:\n'
        '  - id: docs.stale\n'
        '    path: docs/app\n',
      );
      expect(await run(['verify']), ExitCodes.errorsFound);
      expect(
        out.toString(),
        contains(
          '\n'
          'appstein.yaml\n'
          '  error suppression.no_reason (line 3): The suppression of '
          '`docs.stale` on `docs/app` has no reason, so it hides nothing.\n'
          '    fix: Add `reason:` saying why this finding is accepted.\n',
        ),
      );
    });

    test('finds the project from --project', () async {
      expect(
        await run([
          '--project',
          project,
          'verify',
        ], workingDirectory: work.path),
        ExitCodes.errorsFound,
      );
      expect(out.toString(), contains('knowledge.stale'));
    });

    test('fails, with exit 3, outside a project', () async {
      expect(
        await run(['verify'], workingDirectory: work.path),
        ExitCodes.appsteinFailed,
      );
      expect(out.toString(), isEmpty);
      expect(
        err.toString(),
        startsWith('appstein verify needs a Flutter project, but there is no '),
      );
      expect(
        err.toString(),
        contains('Run it inside the project, or pass --project <path>.'),
      );
    });

    test('fails, with exit 3, for an invalid appstein.yaml', () async {
      config('appstein: 99\n');
      expect(await run(['verify']), ExitCodes.appsteinFailed);
      expect(out.toString(), isEmpty);
      expect(
        err.toString(),
        contains('Fix appstein.yaml, then run `appstein verify` again.'),
      );
    });

    test('fails, with exit 3, for --fast with --full', () async {
      expect(
        await run(['verify', '--fast', '--full']),
        ExitCodes.appsteinFailed,
      );
      expect(err.toString(), startsWith('Pass --fast or --full, not both.\n'));
      expect(Directory(p.join(project, '.appstein')).existsSync(), isFalse);
    });

    group('--apply', () {
      test('fails, with exit 3, with --fast, and rewrites nothing', () async {
        final analysis = ScriptedCodeAnalysis();
        expect(
          await run(['verify', '--fast', '--apply'], analysis: analysis),
          ExitCodes.appsteinFailed,
        );
        expect(
          err.toString(),
          startsWith(
            '--apply works with a full run only: run `appstein verify '
            '--apply` without --fast. A fast run never rewrites files.\n',
          ),
        );
        expect(analysis.applyAsked, 0);
        expect(Directory(p.join(project, '.appstein')).existsSync(), isFalse);
      });

      test('a run that fails after the rewrite still names the files it '
          'rewrote, on stderr, and exits 3; a file left as it was is a '
          'note', () async {
        final analysis = ScriptedCodeAnalysis()
          ..applied = ['lib/a.dart', 'lib/b.dart'];
        await expectLater(
          run(
            ['verify', '--apply'],
            analysis: analysis,
            verifyChecks: (_) => [(check: const _ThrowingCheck(), pack: null)],
          ),
          completion(ExitCodes.appsteinFailed),
        );
        expect(
          err.toString(),
          startsWith(
            '--apply rewrote these files before the run failed (read them '
            'again before you edit them):\n'
            '  lib/a.dart\n'
            '  lib/b.dart\n',
          ),
        );
        expect(err.toString(), contains('boom.check'));
        expect(
          rewrittenBeforeFailure(['lib/a.dart']),
          '--apply rewrote this file before the run failed (read it again '
          'before you edit it):\n'
          '  lib/a.dart',
        );

        err.clear();
        out.clear();
        analysis.leftAlone = {
          'lib/linked/x.dart':
              'it is outside the project once links are followed',
        };
        await run(['verify', '--apply'], analysis: analysis);
        expect(
          out.toString(),
          contains(
            'Note:\n'
            '  Applying fixes and formatting left `lib/linked/x.dart` as it '
            'was: it is outside the project once links are followed. What it '
            'needs is still reported.\n',
          ),
        );
      });

      test('rewrites before the knowledge is brought up to date, and names '
          'the files it rewrote: in `applied` and in a section before the '
          'findings', () async {
        bool? knowledgeBefore;
        final analysis = ScriptedCodeAnalysis()
          ..onApply = (_) async {
            knowledgeBefore = File(
              p.join(project, '.appstein', 'INDEX.md'),
            ).existsSync();
            return ['lib/a.dart', 'lib/b c.dart'];
          };
        await run(['verify', '--apply'], analysis: analysis);
        // The project had no knowledge: the run built it after the rewrite.
        expect(knowledgeBefore, isFalse);
        expect(
          out.toString(),
          startsWith(
            'Rewritten by --apply (read these files again before you edit '
            'them):\n'
            '  lib/a.dart\n'
            '  lib/b c.dart\n'
            '\n'
            '(project)\n',
          ),
        );
        out.clear();
        await run([
          'verify',
          '--apply',
          '--format',
          'json',
        ], analysis: analysis);
        final json = jsonDecode(out.toString()) as Map<String, Object?>;
        expect(json['applied'], ['lib/a.dart', 'lib/b c.dart']);
        expect(analysis.applyAsked, 2);
      });

      test('without it nothing is asked to rewrite, and there is no '
          'section', () async {
        final analysis = ScriptedCodeAnalysis()..applied = ['lib/a.dart'];
        await run(['verify'], analysis: analysis);
        expect(analysis.applyAsked, 0);
        expect(out.toString(), isNot(contains('Rewritten by --apply')));
      });
    });

    group('--files', () {
      CodeDiagnostic warning(String file) => CodeDiagnostic(
        file: file,
        line: 1,
        code: 'unused_import',
        message: 'Unused import.',
        level: DiagnosticLevel.warning,
      );

      test('fails, with exit 3, with a full run', () async {
        for (final args in [
          ['verify', '--files', 'lib/a.dart'],
          ['verify', '--full', '--files', 'lib/a.dart'],
        ]) {
          err.clear();
          expect(await run(args), ExitCodes.appsteinFailed);
          expect(
            err.toString(),
            startsWith(
              '--files works with a fast run only: pass --fast with it. A '
              'full run checks every file.\n',
            ),
          );
        }
        expect(Directory(p.join(project, '.appstein')).existsSync(), isFalse);
      });

      test('fails, with exit 3, for a path outside the project, relative or '
          'absolute', () async {
        final outside = p.join(work.path, 'elsewhere', 'a.dart');
        for (final path in ['../a.dart', 'lib/../../a.dart', outside]) {
          err.clear();
          expect(
            await run(['verify', '--fast', '--files', path]),
            ExitCodes.appsteinFailed,
          );
          expect(
            err.toString(),
            startsWith(
              'The path `$path` given to --files is outside the project '
              '(${p.normalize(p.absolute(project))}).',
            ),
          );
        }
        expect(Directory(p.join(project, '.appstein')).existsSync(), isFalse);
      });

      test('adds the files for a fast run: relative from the project root '
          'wherever verify runs, absolute inside the project, with spaces, '
          'deleted or not Dart', () async {
        File(p.join(project, 'lib', 'a.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('int a = 1;\n');
        final analysis = ScriptedCodeAnalysis(
          found: [
            warning('lib/a.dart'),
            warning('lib/my file.dart'),
            warning('lib/other.dart'),
            warning('pubspec.yaml'),
          ],
        );
        expect(
          await run(
            [
              'verify',
              '--fast',
              '--files',
              'lib/a.dart,lib/gone.dart,pubspec.yaml',
              '--files',
              p.join(project, 'lib', 'my file.dart'),
            ],
            analysis: analysis,
            // Relative paths are still taken from the project root.
            workingDirectory: p.join(project, 'lib'),
          ),
          ExitCodes.errorsFound, // knowledge.stale
        );
        final text = out.toString();
        expect(text, contains('\nlib/a.dart\n  warning dart.warning (line 1)'));
        expect(text, contains('\nlib/my file.dart\n  warning dart.warning'));
        expect(text, contains('\npubspec.yaml\n  warning dart.warning'));
        expect(text, isNot(contains('lib/other.dart')));
      });

      test('on Windows a path in another letter case names the file on '
          'disk', () async {
        File(p.join(project, 'lib', 'Home.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('int a = 1;\n');
        await run([
          'verify',
          '--fast',
          '--files',
          'LIB/home.DART',
        ], analysis: ScriptedCodeAnalysis(found: [warning('lib/Home.dart')]));
        expect(out.toString(), contains('\nlib/Home.dart\n  warning'));
      }, testOn: 'windows');
    });

    test('fails, with exit 3, for a format it does not have', () async {
      expect(
        await run(['verify', '--format', 'xml']),
        ExitCodes.appsteinFailed,
      );
      expect(err.toString(), contains('"xml" is not an allowed value'));
    });

    test(
      'fails, with exit 3, when a check throws, and names the check',
      () async {
        expect(
          await run(
            ['verify', '--fast'],
            verifyChecks: (_) => const [
              (check: _ThrowingCheck(), pack: 'boom'),
            ],
          ),
          ExitCodes.appsteinFailed,
        );
        expect(out.toString(), isEmpty);
        expect(err.toString(), contains('The check `boom.check` failed'));
        expect(err.toString(), contains('it broke'));
        expect(err.toString(), contains('appstein doctor'));
      },
    );

    group('the Dart checks, with a scripted analysis', () {
      const error = CodeDiagnostic(
        file: 'lib/ui/home screen.dart',
        line: 12,
        code: 'undefined_method',
        message: "The method 'go' isn't defined for the type 'Home'.",
        level: DiagnosticLevel.error,
        correction: "Try correcting the name, or defining a method 'go'.",
      );

      test('an analyzer error is a dart.error in its file\'s group, beside '
          'knowledge.stale, with exit 1', () async {
        expect(
          await run([
            'verify',
            '--fast',
          ], analysis: ScriptedCodeAnalysis(found: const [error])),
          ExitCodes.errorsFound,
        );
        expect(err.toString(), isEmpty);
        expect(out.toString(), contains('  error knowledge.stale: '));
        expect(
          out.toString(),
          contains(
            '\n'
            'lib/ui/home screen.dart\n'
            "  error dart.error (line 12): The method 'go' isn't defined for "
            "the type 'Home'. (`undefined_method`)\n"
            "    fix: Try correcting the name, or defining a method 'go'.\n",
          ),
        );
        expect(
          out.toString(),
          endsWith('2 errors, 0 warnings, 0 info. No findings suppressed.\n'),
        );
      });

      test('--format json carries the file, the line and the code', () async {
        await run([
          'verify',
          '--format',
          'json',
        ], analysis: ScriptedCodeAnalysis(found: const [error]));
        final result = VerifyResult.fromJson(
          jsonDecode(out.toString()) as Map<String, Object?>,
        );
        final found = result.findings.singleWhere(
          (finding) => finding.id == 'dart.error',
        );
        expect(found.file, 'lib/ui/home screen.dart');
        expect(found.line, 12);
        expect(found.severity, Severity.error);
        expect(found.message, endsWith('(`undefined_method`)'));
      });

      test('an analyzer plugin that failed is an error on the project, with '
          'exit 1', () async {
        expect(
          await run(
            ['verify', '--fast'],
            analysis: ScriptedCodeAnalysis(
              pluginFailures: const [
                'An error occurred while setting up the analyzer plugin: '
                    'version solving failed',
              ],
            ),
          ),
          ExitCodes.errorsFound,
        );
        expect(
          out.toString(),
          contains(
            '  error dart.plugin_failed: An analyzer plugin failed, so its '
            'rules were not checked: An error occurred while setting up the '
            'analyzer plugin: version solving failed.\n'
            '    fix: Check the plugin\'s entry under `plugins:` in '
            '`analysis_options.yaml`, and run `appstein doctor`.\n',
          ),
        );
      });

      test('a suppression and verify.severity in appstein.yaml work on '
          'dart.error', () async {
        config(
          'appstein: 1\n'
          'verify:\n'
          '  severity:\n'
          '    dart.error: warning\n'
          'suppressions:\n'
          '  - id: dart.error\n'
          '    path: lib/legacy\n'
          '    reason: rewritten next month\n',
        );
        await run(
          ['verify', '--fast'],
          analysis: ScriptedCodeAnalysis(
            found: const [
              error,
              CodeDiagnostic(
                file: 'lib/legacy/old.dart',
                line: 1,
                code: 'undefined_method',
                message: 'Old.',
                level: DiagnosticLevel.error,
              ),
            ],
          ),
        );
        expect(out.toString(), contains('\n  warning dart.error (line 12): '));
        expect(out.toString(), isNot(contains('lib/legacy/old.dart')));
        expect(
          out.toString(),
          endsWith(
            '1 error, 1 warning, 0 info. 1 finding suppressed by 1 '
            'suppression.\n',
          ),
        );
      });

      test('a // appstein:ignore comment hides a dart.error and is counted '
          'with the appstein.yaml entries, in text and in JSON', () async {
        config(
          'appstein: 1\n'
          'suppressions:\n'
          '  - id: dart.error\n'
          '    path: lib/legacy\n'
          '    reason: rewritten next month\n',
        );
        File(p.join(project, 'lib', 'ui', 'home screen.dart'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            '${'// filler\n' * 11}'
            'void f() => g(); // appstein:ignore dart.error — accepted\n',
          );
        final analysis = ScriptedCodeAnalysis(
          analyzedFiles: const ['lib/ui/home screen.dart'],
          found: const [
            error,
            CodeDiagnostic(
              file: 'lib/legacy/old.dart',
              line: 1,
              code: 'undefined_method',
              message: 'Old.',
              level: DiagnosticLevel.error,
            ),
          ],
        );
        // The one error left is `knowledge.stale`: the project has no
        // packages. The two `dart.error` findings are hidden.
        await run(['verify', '--fast'], analysis: analysis);
        expect(
          out.toString(),
          endsWith(
            '1 error, 0 warnings, 0 info. 2 findings suppressed by 2 '
            'suppressions.\n',
          ),
        );
        expect(out.toString(), isNot(contains('dart.error')));
        out.clear();
        await run(['verify', '--fast', '--format', 'json'], analysis: analysis);
        final result = VerifyResult.fromJson(
          jsonDecode(out.toString()) as Map<String, Object?>,
        );
        expect(
          [for (final finding in result.findings) finding.id],
          ['knowledge.stale'],
        );
        expect(result.suppressed, 2);
        expect(result.activeSuppressions, 2);
      });

      test('fails, with exit 3, when the analysis server can\'t answer: the '
          'reason and `appstein doctor`, no finding and no check '
          'blamed', () async {
        expect(
          await run(
            ['verify', '--fast'],
            analysis: ScriptedCodeAnalysis(
              failure: const CodeAnalysisException(
                'its analysis was not done within 180 s',
              ),
            ),
          ),
          ExitCodes.appsteinFailed,
        );
        expect(out.toString(), isEmpty);
        expect(
          err.toString(),
          'The Dart analysis server could not answer: its analysis was not '
          'done within 180 s.\n'
          'Run `appstein doctor` to check your setup.\n',
        );
      });

      test('fails, with exit 3, when the analysis server fails while it '
          'answers the formatting question: the reason and `appstein '
          'doctor`, no finding', () async {
        File(p.join(project, 'lib', 'a.dart'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('int a( )=>1;\n');
        expect(
          await run(
            ['verify', '--fast', '--files', 'lib/a.dart'],
            analysis: ScriptedCodeAnalysis(analyzedFiles: ['lib/a.dart'])
              ..formatFailure = const CodeAnalysisException(
                'it ended by itself with exit code 1',
              ),
          ),
          ExitCodes.appsteinFailed,
        );
        expect(out.toString(), isEmpty);
        expect(
          err.toString(),
          'The Dart analysis server could not answer: it ended by itself '
          'with exit code 1.\n'
          'Run `appstein doctor` to check your setup.\n',
        );
      });

      test('fails, with exit 3, when the project\'s SDK has no Dart to run '
          'the server with', () async {
        // The real route, on the fake Flutter SDK: nothing is started.
        expect(
          await run(['verify', '--fast'], realServer: true),
          ExitCodes.appsteinFailed,
        );
        expect(out.toString(), isEmpty);
        expect(
          err.toString(),
          allOf(
            startsWith(
              'The Dart analysis server could not answer: there is no Dart '
              'executable at ',
            ),
            contains(p.join(sdk, 'bin', 'cache', 'dart-sdk', 'bin')),
            endsWith('Run `appstein doctor` to check your setup.\n'),
          ),
        );
      });
    });

    // The fake SDK's `flutter` is a real script here, which prints what a
    // test puts in a file beside it: the command runs it as a process.
    group('the tests of a project that has test files', () {
      /// Makes the fake SDK's `flutter` print [events] and exit with
      /// [exitCode], whatever it is asked.
      void flutterPrints(String events, {required int exitCode}) {
        File(p.join(sdk, 'bin', 'events.jsonl')).writeAsStringSync(events);
        File(
          p.join(sdk, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
        ).writeAsStringSync(
          Platform.isWindows
              ? '@echo off\r\ntype "%~dp0events.jsonl"\r\nexit /b $exitCode\r\n'
              : '#!/bin/sh\ncat "\$(dirname "\$0")/events.jsonl"\n'
                    'exit $exitCode\n',
        );
      }

      setUp(() {
        File(p.join(project, 'test', 'home_test.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void main() {}\n');
      });

      test('a failing test is a test.failed error in its file\'s group, '
          'with exit 1', () async {
        final root = project.replaceAll(r'\', '/');
        flutterPrints(
          [
            '{"suite":{"id":0,"platform":"vm",'
                '"path":"$root/test/home_test.dart"},"type":"suite","time":0}',
            '{"test":{"id":1,"name":"home shows the title","suiteID":0,'
                '"groupIDs":[],"line":7,"column":3,'
                '"url":"${Uri.file(p.join(project, 'test', 'home_test.dart'))}"'
                '},"type":"testStart","time":1}',
            '{"testID":1,"error":"Expected: <3>\\n  Actual: <2>\\n",'
                '"stackTrace":"","isFailure":true,"type":"error","time":2}',
            '{"testID":1,"result":"failure","skipped":false,"hidden":false,'
                '"type":"testDone","time":3}',
            '{"success":false,"type":"done","time":4}',
            '',
          ].join('\n'),
          exitCode: 1,
        );
        expect(await run(['verify']), ExitCodes.errorsFound);
        expect(err.toString(), isEmpty);
        expect(
          out.toString(),
          contains(
            '\n'
            'test/home_test.dart\n'
            '  error test.failed (line 7): The test `home shows the title` '
            'failed: Expected: <3> Actual: <2>\n'
            '    fix: Run `flutter test test/home_test.dart` to see the whole '
            'failure.\n',
          ),
        );
        expect(out.toString(), isNot(contains('  test.failed: ')));
      });

      test('passing tests: no test.failed, and the check is not named as '
          'not run', () async {
        flutterPrints('{"success":true,"type":"done","time":4}\n', exitCode: 0);
        await run(['verify']);
        expect(err.toString(), isEmpty);
        expect(out.toString(), isNot(contains('test.failed')));
      });

      test('with an analyzer error the tests are not run, and test.failed '
          'is named as not run with that reason, in text and in '
          'JSON', () async {
        // A `flutter` that would fail the run if it were started.
        File(
          p.join(sdk, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
        ).deleteSync();
        const error = CodeDiagnostic(
          file: 'lib/main.dart',
          line: 2,
          code: 'undefined_identifier',
          message: 'Undefined name.',
          level: DiagnosticLevel.error,
        );
        expect(
          await run([
            'verify',
          ], analysis: ScriptedCodeAnalysis(found: const [error])),
          ExitCodes.errorsFound,
        );
        expect(
          out.toString(),
          contains(
            '\n'
            'Not run:\n'
            '  docs.stale: the project map is not up to date\n'
            '  test.failed: the code has analyzer errors\n'
            '  verify.test_required: the project map is not up to date\n',
          ),
        );
        out.clear();
        await run([
          'verify',
          '--format',
          'json',
        ], analysis: ScriptedCodeAnalysis(found: const [error]));
        final json = jsonDecode(out.toString()) as Map<String, Object?>;
        expect(
          json['notRun'],
          contains(
            equals({
              'id': 'test.failed',
              'reason': 'the code has analyzer errors',
            }),
          ),
        );
      });

      test('fails, with exit 3, when there is no Flutter SDK to run the '
          'tests with: the reason and `appstein doctor`, and no '
          'finding', () async {
        // Without its `flutter`, the folder is no Flutter SDK.
        File(
          p.join(sdk, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
        ).deleteSync();
        expect(await run(['verify']), ExitCodes.appsteinFailed);
        expect(out.toString(), isEmpty);
        expect(
          err.toString(),
          allOf(
            startsWith(
              'The project\'s tests could not be run: the project has no '
              'usable Flutter SDK (No Flutter SDK found. ',
            ),
            endsWith(').\nRun `appstein doctor` to check your setup.\n'),
          ),
        );
        expect(err.toString(), isNot(contains('unexpectedly')));
      });

      test('finds one test.failed error, with exit 1 and not 3, when '
          '`flutter test` fails without naming a failing test: never "no '
          'test failed"', () async {
        flutterPrints('The Flutter tool broke.\n', exitCode: 64);
        expect(await run(['verify']), ExitCodes.errorsFound);
        expect(err.toString(), isEmpty);
        expect(
          out.toString(),
          allOf(
            contains(
              '  error test.failed: The tests gave no result: `flutter test` '
              'ended with exit code 64 and named no failing test (The Flutter '
              'tool broke).\n'
              '    fix: Run `flutter test` in the project to see the full '
              'output.\n',
            ),
            isNot(contains('appstein doctor')),
          ),
        );
      });

      test('--fast never starts the tests', () async {
        File(
          p.join(sdk, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
        ).deleteSync();
        expect(await run(['verify', '--fast']), ExitCodes.errorsFound);
        expect(err.toString(), isEmpty);
        expect(out.toString(), isNot(contains('test.failed')));
      });
    });

    group('the guard mode', () {
      test('is not in the help', () async {
        expect(await run(['help']), ExitCodes.ok);
        expect(out.toString(), isNot(contains('guard')));
      });

      test('fails, with exit 3, without the dart executable', () async {
        expect(await run([analysisGuardCommandName]), ExitCodes.appsteinFailed);
        expect(
          err.toString(),
          startsWith('Pass the dart executable that runs the server.\n'),
        );
      });

      test('is started with the running dart and this package\'s entry '
          'script, where Appstein is not a compiled binary', () {
        final command = analysisGuardCommand();
        expect(command, hasLength(4));
        expect(command.first, Platform.resolvedExecutable);
        // The package configuration of this run: a script in the pub cache
        // (`dart pub global activate`) has none beside it.
        expect(command[1], startsWith('--packages='));
        final config = command[1].substring('--packages='.length);
        expect(config, Isolate.packageConfigSync!.toFilePath());
        expect(File(config).existsSync(), isTrue);
        expect(p.split(command[2]).sublist(p.split(command[2]).length - 3), [
          'appstein_cli',
          'bin',
          'appstein.dart',
        ]);
        expect(File(command[2]).existsSync(), isTrue);
        expect(command.last, analysisGuardCommandName);
      });

      test('the command from what the running Dart says: a compiled binary '
          'starts itself, a script is started with its package '
          'configuration when there is one', () {
        final dart = p.join('sdk', 'bin', 'dart');
        final library = Uri.file(
          p.absolute('cache', 'appstein_cli-1.0.0', 'lib', 'appstein_cli.dart'),
        );
        final script = p.absolute(
          'cache',
          'appstein_cli-1.0.0',
          'bin',
          'appstein.dart',
        );
        final config = p.absolute('global', 'package_config.json');
        const guard = analysisGuardCommandName;
        expect(modeCommandFrom(guard, executable: dart), [dart, guard]);
        expect(
          modeCommandFrom(
            guard,
            executable: dart,
            library: library,
            packageConfig: Uri.file(config),
          ),
          [dart, '--packages=$config', script, guard],
        );
        expect(modeCommandFrom(guard, executable: dart, library: library), [
          dart,
          script,
          guard,
        ]);
        // The analysis host is started the same way, in its own mode.
        expect(
          modeCommandFrom(
            analysisHostCommandName,
            executable: dart,
            library: library,
          ),
          [dart, script, analysisHostCommandName],
        );
      });

      test('the analysis host is started with the folder of its address '
          'file, and for tests with the Dart SDK and its idle time', () {
        final command = analysisHostCommand(
          addressFolder: p.absolute('my hosts'),
          dartSdkPath: p.absolute('dart sdk'),
          idleStop: const Duration(seconds: 3),
        );
        expect(command.sublist(command.length - 4), [
          analysisHostCommandName,
          '--address-folder=${p.absolute('my hosts')}',
          '--dart-sdk=${p.absolute('dart sdk')}',
          '--idle-stop-seconds=3',
        ]);
        expect(
          analysisHostCommand(addressFolder: 'f').last,
          '--address-folder=f',
        );
      });
    });

    group('on a healthy project', () {
      setUp(() => createHealthyProject(project: project, sdk: sdk));

      test('prints the summary alone, with exit 0', () async {
        expect(await run(['verify'], dartSdkPath: testDartSdk), ExitCodes.ok);
        expect(err.toString(), isEmpty);
        expect(
          out.toString(),
          '0 errors, 0 warnings, 0 info. No findings suppressed.\n',
        );
      });

      group('--apply renders the human docs', () {
        const readme = 'README.md';

        String docsFile(String path) =>
            p.joinAll([project, 'docs', 'app', ...path.split('/')]);

        /// Every file of the docs folder with its bytes.
        Map<String, String> docsFolder() => {
          for (final entity in Directory(
            docsFile(''),
          ).listSync(recursive: true))
            if (entity is File)
              p.relative(entity.path, from: project): entity.readAsStringSync(),
        };

        /// A scripted `dart fix` that writes a new Dart file, which puts the
        /// human docs behind. [readmeWhenFixing] gets the README as it was
        /// when the fix ran.
        ScriptedCodeAnalysis fixThatWritesAFile({
          void Function(String readme)? readmeWhenFixing,
        }) => ScriptedCodeAnalysis()
          ..onApply = (_) async {
            readmeWhenFixing?.call(File(docsFile(readme)).readAsStringSync());
            File(
              p.join(project, 'lib', 'fixed.dart'),
            ).writeAsStringSync('/// Fixed.\nint fixed() => 1;\n');
            return ['lib/fixed.dart'];
          };

        Future<Map<String, Object?>> applyJson(
          ScriptedCodeAnalysis analysis,
        ) async {
          out.clear();
          await run(
            ['verify', '--apply', '--format', 'json'],
            analysis: analysis,
            dartSdkPath: testDartSdk,
          );
          return jsonDecode(out.toString()) as Map<String, Object?>;
        }

        List<Object?> ids(Map<String, Object?> json) => [
          for (final finding in json['findings']! as List)
            (finding as Map)['id'],
        ];

        Future<bool> docsStale() async {
          const config = AppsteinConfig();
          final packs = packsFor(config);
          final outcome = await runDocs(
            projectRoot: project,
            config: config,
            packs: packs,
            sync: KnowledgeSync(
              environment: HostEnvironment(
                os: HostOs.current,
                variables: {'FLUTTER_ROOT': sdk},
                workingDirectory: project,
              ),
              appsteinVersion: appsteinVersion,
              packs: packs,
              baseline: config.delta.baseline,
              agents: config.integrations.agents,
              packageSkills: false,
            ),
            check: true,
            dartSdkPath: testDartSdk,
          );
          return (outcome as DocsDone).stale;
        }

        test('renders the pages that are behind after the fixes, names '
            'each page written in `applied`, and the same run finds nothing '
            'stale', () async {
          String? readmeAtFix;
          final analysis = fixThatWritesAFile(
            readmeWhenFixing: (text) => readmeAtFix = text,
          );
          final before = docsFolder();

          final json = await applyJson(analysis);

          // The fix ran first: the pages were not touched before it.
          expect(
            readmeAtFix,
            before['docs${p.separator}app${p.separator}$readme'],
          );
          final applied = (json['applied']! as List).cast<String>();
          expect(applied.first, 'lib/fixed.dart');
          expect(applied.length, greaterThan(1));
          expect(applied.skip(1), everyElement(startsWith('docs/app/')));
          expect(applied.skip(1).toList(), [...applied.skip(1)]..sort());
          // The pages written are the pages that changed, no other.
          final after = docsFolder();
          expect({
            for (final key in after.keys)
              if (after[key] != before[key]) key.replaceAll(p.separator, '/'),
          }, applied.skip(1).toSet());
          expect(ids(json), isNot(contains('docs.stale')));
          expect(await docsStale(), isFalse);
          expect(err.toString(), isEmpty);
        });

        test('the text lists the pages with the files it rewrote, before '
            'the findings', () async {
          await run(
            ['verify', '--apply'],
            analysis: fixThatWritesAFile(),
            dartSdkPath: testDartSdk,
          );
          expect(
            out.toString(),
            startsWith(
              'Rewritten by --apply (read these files again before you edit '
              'them):\n'
              '  lib/fixed.dart\n'
              '  docs/app/',
            ),
          );
          expect(out.toString(), isNot(contains('docs.stale')));
        });

        test('a page that did not change is not listed: the run after it '
            'lists none', () async {
          await applyJson(fixThatWritesAFile());
          final settled = docsFolder();
          final json = await applyJson(ScriptedCodeAnalysis());
          expect(json['applied'], isEmpty);
          expect(docsFolder(), settled);
        });

        test('with docs.enabled false nothing is rendered and nothing is '
            'listed', () async {
          config('docs:\n  enabled: false\n');
          final before = docsFolder();
          final json = await applyJson(fixThatWritesAFile());
          expect(json['applied'], ['lib/fixed.dart']);
          expect(docsFolder(), before);
          expect(ids(json), isNot(contains('docs.stale')));
        });

        test('a person\'s file where a page goes is left alone, not listed, '
            'and docs.stale reports it; the run is not a failure', () async {
          final theirs = File(docsFile('routes.md'))
            ..writeAsStringSync('# Our routes\n\nWritten by a person.\n');
          final before = docsFolder();
          final json = await applyJson(fixThatWritesAFile());
          expect(json['applied'], ['lib/fixed.dart']);
          expect(docsFolder(), before);
          expect(
            theirs.readAsStringSync(),
            '# Our routes\n\nWritten by a person.\n',
          );
          expect(ids(json), contains('docs.stale'));
          expect(err.toString(), isEmpty);
          // A warning: the exit code is 0.
          out.clear();
          expect(
            await run(
              ['verify', '--apply'],
              analysis: ScriptedCodeAnalysis(),
              dartSdkPath: testDartSdk,
            ),
            ExitCodes.ok,
          );
        });

        test('a page edited by hand is rewritten and listed, and a note says '
            'its hand edits were overwritten', () async {
          final routes = File(docsFile('routes.md'));
          final rendered = routes.readAsStringSync();
          routes.writeAsStringSync(rendered.replaceFirst('# ', '# Our '));
          out.clear();
          await run(
            ['verify', '--apply', '--format', 'json'],
            analysis: ScriptedCodeAnalysis(),
            dartSdkPath: testDartSdk,
          );
          final json = jsonDecode(out.toString()) as Map<String, Object?>;
          expect(json['applied'], ['docs/app/routes.md']);
          expect(routes.readAsStringSync(), rendered);
          expect(json['notices'], [contains('`docs/app/routes.md`')]);
          expect(json['notices'], [contains('overwrote hand edits')]);
          expect(ids(json), isNot(contains('docs.stale')));
          // The text prints the note too.
          routes.writeAsStringSync(rendered.replaceFirst('# ', '# Our '));
          out.clear();
          await run(
            ['verify', '--apply'],
            analysis: ScriptedCodeAnalysis(),
            dartSdkPath: testDartSdk,
          );
          expect(out.toString(), contains('Note:\n  Rendering the human docs'));
          expect(out.toString(), contains('overwrote hand edits'));
        });

        test('without --apply nothing is written: the pages stay behind and '
            'docs.stale says so', () async {
          // The same new file, written by a person.
          File(
            p.join(project, 'lib', 'fixed.dart'),
          ).writeAsStringSync('/// Fixed.\nint fixed() => 1;\n');
          final before = docsFolder();
          out.clear();
          await run(['verify', '--format', 'json'], dartSdkPath: testDartSdk);
          final json = jsonDecode(out.toString()) as Map<String, Object?>;
          expect(json['applied'], isEmpty);
          expect(docsFolder(), before);
          expect(ids(json), contains('docs.stale'));
        });
      });

      test(
        'with a real analysis server: --apply formats the project, names '
        'the file it rewrote, and the run after it is clean; without '
        '--apply nothing is written',
        () => withChildProcessesToItself(() async {
          // In turn with the tests that count this process's children: its
          // analysis servers would be counted as theirs.
          final messy = File(p.join(project, 'lib', 'messy.dart'))
            ..writeAsStringSync('int messy( int x )=>x;\n');
          expect(
            await run(['verify'], realServer: true, dartSdkPath: testDartSdk),
            ExitCodes.ok,
          );
          expect(out.toString(), contains('warning dart.unformatted'));
          expect(out.toString(), isNot(contains('Rewritten by --apply')));
          expect(messy.readAsStringSync(), 'int messy( int x )=>x;\n');
          out.clear();
          expect(
            await run(
              ['verify', '--apply', '--format', 'json'],
              realServer: true,
              dartSdkPath: testDartSdk,
            ),
            ExitCodes.ok,
            reason: '$err',
          );
          final json = jsonDecode(out.toString()) as Map<String, Object?>;
          // The new file puts the human docs behind: `--apply` renders the
          // page after it formatted the file, and names it.
          expect(json['applied'], [
            'lib/messy.dart',
            'docs/app/architecture.md',
          ]);
          // No finding is left, the docs included.
          expect(json['findings'], isEmpty);
          expect(messy.readAsStringSync(), 'int messy(int x) => x;\n');
          out.clear();
          expect(
            await run(
              ['verify', '--apply'],
              realServer: true,
              dartSdkPath: testDartSdk,
            ),
            ExitCodes.ok,
          );
          // Nothing left to rewrite or render: no section, no finding.
          expect(
            out.toString(),
            '0 errors, 0 warnings, 0 info. No findings suppressed.\n',
          );
          // The servers' cache is the folder the machine names, not the one
          // the machine shares.
          expect(
            Directory(p.join(cache, analysisDriverFolder)).existsSync(),
            isTrue,
          );
          // Three runs, each starting a guard from source and a server.
        }),
        timeout: const Timeout(Duration(minutes: 10)),
      );

      // The whole path: the command starts the guard (`dart bin/appstein.dart
      // analysis-server-guard`), the guard starts the analysis server of the
      // SDK that runs the tests, and both are gone when the command returns.
      // The scope is the command's own, wrapped only to note the processes
      // that run under this one at the end of each body, before the scope
      // stops the server: with no host running, the run's own guard and
      // server. A server left behind by a guard that has ended is no longer
      // a child of this process, so the IDs are noted while they run.
      test(
        'with no host and a real analysis server: a compile error is a '
        'dart.error with exit 1, in a fast and a full run; without it, exit '
        '0; each run starts a server of its own and stops it, and no host, '
        'guard or server is left',
        () => withChildProcessesToItself(() async {
          // Alone among the tests that start processes: the mcp command's
          // tests, in another file, run at the same time in this process.
          final before = await childProcesses();
          final own = hostCodeAnalysis(
            startHost: false,
            projectRoot: project,
            environment: HostEnvironment(
              os: HostOs.current,
              variables: {
                'FLUTTER_ROOT': sdk,
                analysisCacheVariable: cache,
                analysisHostFolderVariable: hosts,
              },
              workingDirectory: project,
            ),
            dartSdkPath: testDartSdk,
          );
          final started = <Set<int>>[];
          Future<T> noting<T>(Future<T> Function(CodeAnalysis analysis) body) =>
              own<T>((analysis) async {
                try {
                  return await body(analysis);
                } finally {
                  // Not the test runner's own helpers, which ran before, and
                  // not the console hosts Windows gives a process.
                  final running = {
                    for (final id in await processesUnder(pid))
                      if (!before.containsKey(id) && !_isConsoleHostProcess(id))
                        id,
                  };
                  started.add(running);
                  // While they run: Windows gives an ended process's ID to
                  // a new one, which must not be taken for one of these.
                  await recordProcesses(running);
                }
              });
          final broken = File(p.join(project, 'lib', 'my folder', 'b.dart'))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('/// Wrong.\nint wrong() => \'text\';\n');
          for (final mode in ['--fast', '--full']) {
            out.clear();
            expect(
              await run(
                ['verify', mode],
                dartSdkPath: testDartSdk,
                scope: noting,
              ),
              ExitCodes.errorsFound,
              reason: '$mode\n$err',
            );
            expect(err.toString(), isEmpty);
            expect(
              out.toString(),
              allOf(
                contains('lib/my folder/b.dart\n  error dart.error (line 2): '),
                contains(' (`return_of_invalid_type`)\n'),
                contains('1 error, '),
              ),
            );
          }

          broken.deleteSync();
          out.clear();
          expect(
            await run(
              ['verify', '--fast'],
              dartSdkPath: testDartSdk,
              scope: noting,
            ),
            ExitCodes.ok,
            reason: '$err',
          );
          expect(
            out.toString(),
            '0 errors, 0 warnings, 0 info. No findings suppressed.\n',
          );

          final left = await childProcesses()
            ..removeWhere((id, _) => before.containsKey(id));
          expect(left, isEmpty);
          // Three runs, each with a guard and a server of its own (at least
          // two processes), all gone.
          expect(started, hasLength(3));
          for (final running in started) {
            expect(running.length, greaterThanOrEqualTo(2), reason: '$running');
            for (final id in running) {
              expect(await processAlive(id), isFalse, reason: 'process $id');
            }
          }
          // No host was started, and none was written.
          expect(hostProcess(hosts, project), isNull);
          expect(Directory(hosts).existsSync(), isFalse);
        }),
        timeout: const Timeout(Duration(minutes: 10)),
      );

      // A host of another Appstein version is left alone (slice 1d.7, ticket
      // 04): the run uses a server of its own, asks the host nothing and
      // sends it no stop. The host is a stand-in in this process, so the
      // lines it was sent can be read.
      for (final (host, side) in [
        ('0.0.1', 'an older'),
        ('999.0.0', 'a newer'),
      ]) {
        test(
          'with a host of $side Appstein: it is not used and not stopped, '
          'the run uses a server of its own and stops it',
          () => withChildProcessesToItself(() async {
            final before = await childProcesses();
            final standIn = await standInHost(hosts, project, version: host);
            File(p.join(project, 'lib', 'b.dart'))
              ..parent.createSync(recursive: true)
              ..writeAsStringSync('/// Wrong.\nint wrong() => \'text\';\n');
            expect(
              await run(
                ['verify', '--fast'],
                realServer: true,
                dartSdkPath: testDartSdk,
              ),
              ExitCodes.errorsFound,
              reason: '$err',
            );
            expect(out.toString(), contains('error dart.error (line 2): '));
            expect(err.toString(), isEmpty);
            // Nothing was asked of the host, and no stop was sent: it was
            // left as it was, with its address.
            expect(standIn.received, isEmpty);
            expect(
              readAnalysisHostAddress(
                analysisHostAddressFile(hosts, project),
              )?.appsteinVersion,
              host,
            );
            // The run's own guard and server are gone.
            final left = await childProcesses()
              ..removeWhere((id, _) => before.containsKey(id));
            expect(left, isEmpty);
          }),
          timeout: const Timeout(Duration(minutes: 10)),
        );
      }

      test('a host that stops answering during a run is Appstein failing: '
          'exit 3 with the reason and `appstein doctor`, no finding, and no '
          'host or server of its own is started', () async {
        // It welcomes the run and closes the connection at its question.
        final standIn = await standInHost(
          hosts,
          project,
          version: appsteinVersion,
          onQuestion: (socket, _) => socket.destroy(),
        );
        expect(
          await run(['verify', '--fast'], realServer: true),
          ExitCodes.appsteinFailed,
        );
        expect(out.toString(), isEmpty);
        expect(
          err.toString(),
          'The Dart analysis server could not answer: the analysis host '
          'ended, or closed the connection, before it answered.\n'
          'Run `appstein doctor` to check your setup.\n',
        );
        // The question was asked, once for each try, of the host that was
        // there; the fake SDK has no `dart`, so a server of the run's own,
        // or a host the run started, would have said so instead.
        expect(standIn.received, isNotEmpty);
      });

      test(
        '--format json has no findings and nothing that did not run',
        () async {
          expect(
            await run(['verify', '--format', 'json'], dartSdkPath: testDartSdk),
            ExitCodes.ok,
          );
          expect(err.toString(), isEmpty);
          final result = VerifyResult.fromJson(
            jsonDecode(out.toString()) as Map<String, Object?>,
          );
          expect(result.findings, isEmpty);
          expect(result.notRun, isEmpty);
          expect(result.suppressed, 0);
          expect(result.activeSuppressions, 0);
          expect(
            (jsonDecode(out.toString()) as Map<String, Object?>)['summary'],
            {'errors': 0, 'warnings': 0, 'info': 0},
          );
        },
      );
    });

    test('is in the help, with its flags', () async {
      expect(await run(['help']), ExitCodes.ok);
      expect(out.toString(), contains('  verify '));
      out.clear();
      expect(await run(['help', 'verify']), ExitCodes.ok);
      expect(
        out.toString(),
        startsWith('Check the project against its knowledge (fast or full).'),
      );
      for (final flag in ['--fast', '--full', '--format', '--files=<paths>']) {
        expect(out.toString(), contains(flag));
      }
      expect(out.toString(), contains('[text (default), json]'));
    });
  });
}
