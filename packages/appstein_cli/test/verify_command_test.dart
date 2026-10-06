import 'dart:convert';
import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_flutter_sdk.dart';

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
        '1 error, 2 warnings, 0 info. 1 finding suppressed.\n',
      );
    });

    test('with nothing found, it is the summary line alone', () {
      expect(
        formatVerify(const VerifyResult(findings: [])),
        '0 errors, 0 warnings, 0 info. No findings suppressed.\n',
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
          const VerifyResult(findings: [_noTest, info, info], suppressed: 2),
        ),
        endsWith('0 errors, 1 warning, 2 info. 2 findings suppressed.\n'),
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

  // The fake Flutter SDK has no Dart SDK, so the project map can't be built
  // here: every run reports `knowledge.stale`. The runs on a whole project
  // are in the engine's `verify_fixture_test.dart`, and with the real binary
  // in `tool/measure_sync.dart`.
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
    }) => runAppstein(
      args,
      out: out,
      err: err,
      environment: HostEnvironment(
        os: HostOs.current,
        variables: {'FLUTTER_ROOT': sdk},
        workingDirectory: workingDirectory ?? project,
      ),
      verifyChecks: verifyChecks,
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
      expect(json.keys, ['findings', 'summary', 'suppressed', 'notRun']);
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
