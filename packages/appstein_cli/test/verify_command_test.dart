import 'dart:convert';
import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/child_processes.dart';
import 'support/dart_sdk.dart';
import 'support/fake_flutter_sdk.dart';
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
        variables: {'FLUTTER_ROOT': sdk},
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
      ]);
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
        expect(command, hasLength(3));
        expect(command.first, Platform.resolvedExecutable);
        expect(p.split(command[1]).sublist(p.split(command[1]).length - 3), [
          'appstein_cli',
          'bin',
          'appstein.dart',
        ]);
        expect(File(command[1]).existsSync(), isTrue);
        expect(command.last, analysisGuardCommandName);
      });
    });

    group('on a healthy project', () {
      setUp(() async {
        // The project's packages count as fresh, so the knowledge can be
        // built without `flutter pub get`. Its docs are rendered, as
        // `appstein docs` does, so none is stale.
        File(p.join(project, 'lib', 'main.dart'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('void main() {}\n');
        File(p.join(project, '.dart_tool', 'package_config.json'))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(
            jsonEncode({
              'configVersion': 2,
              'packages': [
                {
                  'name': 'my_app',
                  'rootUri': '../',
                  'packageUri': 'lib/',
                  'languageVersion': '3.12',
                },
              ],
              'generator': 'pub',
            }),
          );
        File(
          p.join(project, '.dart_tool', 'version'),
        ).writeAsStringSync('3.47.5');
        File(
          p.join(project, 'pubspec.lock'),
        ).writeAsStringSync('packages: {}\n');
        final now = DateTime.now();
        File(
          p.join(project, 'pubspec.yaml'),
        ).setLastModifiedSync(now.subtract(const Duration(hours: 1)));
        File(p.join(project, 'pubspec.lock')).setLastModifiedSync(now);
        File(
          p.join(project, '.dart_tool', 'package_config.json'),
        ).setLastModifiedSync(now);

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
          check: false,
          dartSdkPath: testDartSdk,
        );
        expect(outcome, isA<DocsDone>());
      });

      test('prints the summary alone, with exit 0', () async {
        expect(await run(['verify'], dartSdkPath: testDartSdk), ExitCodes.ok);
        expect(err.toString(), isEmpty);
        expect(
          out.toString(),
          '0 errors, 0 warnings, 0 info. No findings suppressed.\n',
        );
      });

      // The whole path: the command starts the guard (`dart bin/appstein.dart
      // analysis-server-guard`), the guard starts the analysis server of the
      // SDK that runs the tests, and both are gone when the command returns.
      // The scope is the command's own, wrapped only to note the process IDs
      // the guard named, since a server left behind by a guard that has
      // ended is no longer a child of this process.
      test(
        'with a real analysis server: a compile error is a dart.error with '
        'exit 1, in a fast and a full run; without it, exit 0; no process '
        'is left',
        () => withChildProcessesToItself(() async {
          // Alone among the tests that start processes: the mcp command's
          // tests, in another file, run at the same time in this process.
          final before = await childProcesses();
          final own = terminalCodeAnalysis(
            projectRoot: project,
            environment: HostEnvironment(
              os: HostOs.current,
              variables: {'FLUTTER_ROOT': sdk},
              workingDirectory: project,
            ),
            dartSdkPath: testDartSdk,
          );
          final started = <({int guard, int server})>[];
          Future<T> noting<T>(Future<T> Function(CodeAnalysis analysis) body) =>
              own<T>((analysis) async {
                try {
                  return await body(analysis);
                } finally {
                  final processes = (analysis as AnalysisServer).processes;
                  if (processes != null) {
                    started.add(processes);
                    // While they run: Windows gives an ended process's ID to
                    // a new one, which must not be taken for one of these.
                    await recordProcesses([processes.guard, processes.server]);
                  }
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
          // Three runs, each with a guard and a server of its own, all gone.
          expect(started, hasLength(3));
          for (final (:guard, :server) in started) {
            expect(await processAlive(guard), isFalse, reason: 'guard $guard');
            expect(
              await processAlive(server),
              isFalse,
              reason: 'server $server',
            );
          }
        }),
        timeout: const Timeout(Duration(minutes: 10)),
      );

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
      for (final flag in ['--fast', '--full', '--format']) {
        expect(out.toString(), contains(flag));
      }
      expect(out.toString(), contains('[text (default), json]'));
    });
  });
}
