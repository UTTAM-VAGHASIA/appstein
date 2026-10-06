import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_flutter_sdk.dart';

DocsDone _done(List<DocChange> changes, {bool check = false}) => DocsDone(
  docsPath: 'docs/app',
  check: check,
  changes: changes,
  teamNotes: const [],
);

const _unchanged = [
  DocChange('README.md', DocChangeKind.unchanged),
  DocChange('architecture.md', DocChangeKind.unchanged),
];

void main() {
  group('formatDocs', () {
    test('says what was written and removed', () {
      expect(
        formatDocs(
          _done(const [
            ..._unchanged,
            DocChange(
              'features/booking.md',
              DocChangeKind.write,
              reason: DocStaleReason.handEdited,
              hadHandEdits: true,
            ),
            DocChange(
              'features/gone.md',
              DocChangeKind.remove,
              reason: DocStaleReason.notRendered,
              hadHandEdits: true,
            ),
            DocChange(
              'features/old.md',
              DocChangeKind.remove,
              reason: DocStaleReason.notRendered,
            ),
            DocChange(
              'native.md',
              DocChangeKind.write,
              reason: DocStaleReason.behind,
            ),
          ]),
        ),
        'Rendered docs/app/: 2 written, 2 removed, 2 unchanged.\n'
        '  features/booking.md  written (overwrote hand edits)\n'
        '  features/gone.md     removed (it had hand edits)\n'
        '  features/old.md      removed\n'
        '  native.md            written\n',
      );
    });

    test('a first run leaves out the counts that are zero', () {
      expect(
        formatDocs(
          _done(const [
            DocChange(
              'README.md',
              DocChangeKind.write,
              reason: DocStaleReason.missing,
            ),
          ]),
        ),
        'Rendered docs/app/: 1 written.\n  README.md  written\n',
      );
    });

    test('says so when nothing changed', () {
      const text = 'docs/app/ is up to date (2 pages).\n';
      expect(formatDocs(_done(_unchanged)), text);
      expect(formatDocs(_done(_unchanged, check: true)), text);
      expect(
        formatDocs(
          _done(const [DocChange('README.md', DocChangeKind.unchanged)]),
        ),
        'docs/app/ is up to date (1 page).\n',
      );
    });

    test('--check names each stale page and why', () {
      expect(
        formatDocs(
          _done(check: true, const [
            ..._unchanged,
            DocChange(
              'features/booking.md',
              DocChangeKind.write,
              reason: DocStaleReason.handEdited,
              hadHandEdits: true,
            ),
            DocChange(
              'features/home.md',
              DocChangeKind.write,
              reason: DocStaleReason.behind,
            ),
            DocChange(
              'features/old.md',
              DocChangeKind.remove,
              reason: DocStaleReason.notRendered,
            ),
            DocChange(
              'native.md',
              DocChangeKind.write,
              reason: DocStaleReason.missing,
            ),
          ]),
        ),
        'docs/app/ is behind the app: 4 of 6 pages.\n'
        '  features/booking.md  hand-edited\n'
        '  features/home.md     behind the app\n'
        '  features/old.md      no longer rendered\n'
        '  native.md            missing\n'
        'Run `appstein docs` to update them.\n',
      );
      expect(
        formatDocs(
          _done(check: true, const [
            DocChange(
              'native.md',
              DocChangeKind.write,
              reason: DocStaleReason.missing,
            ),
          ]),
        ),
        'docs/app/ is behind the app: 1 of 1 page.\n'
        '  native.md  missing\n'
        'Run `appstein docs` to update it.\n',
      );
    });

    test('a refusal says nothing was changed, why, and what to do', () {
      expect(
        formatDocs(
          const DocsRefused(
            docsPath: 'docs/app',
            problem:
                'the project map is missing (the packages could not be '
                'fetched)',
            fixHint: 'Run `flutter pub get`. Then run `appstein docs` again.',
          ),
        ),
        'Nothing in docs/app/ was changed: the project map is missing (the '
        'packages could not be fetched).\n'
        'Run `flutter pub get`. Then run `appstein docs` again.\n',
      );
      expect(
        formatDocs(
          const DocsRefused(
            docsPath: 'docs/app',
            problem: 'a file is in the way',
            details: ['`routes.md` is not an Appstein page. Move it.'],
          ),
        ),
        'Nothing in docs/app/ was changed: a file is in the way.\n'
        '  `routes.md` is not an Appstein page. Move it.\n',
      );
      expect(
        formatDocs(
          const DocsRefused(
            docsPath: 'docs/app',
            problem: 'the docs folder is a file, not a folder. Move it.',
          ),
        ),
        'Nothing in docs/app/ was changed: the docs folder is a file, not a '
        'folder. Move it.\n',
      );
    });

    test('says when the docs are turned off', () {
      expect(
        formatDocs(const DocsDisabled()),
        'Human docs are turned off (docs.enabled is false in '
        'appstein.yaml).\n',
      );
    });
  });

  group('appstein docs', () {
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

    Future<int> run(List<String> args, {String? workingDirectory}) =>
        runAppstein(
          args,
          out: out,
          err: err,
          environment: HostEnvironment(
            os: HostOs.current,
            variables: {'FLUTTER_ROOT': sdk},
            workingDirectory: workingDirectory ?? project,
          ),
        );

    test(
      'refuses, with exit 1, when the project map cannot be built',
      () async {
        for (final args in [
          ['docs'],
          ['docs', '--check'],
        ]) {
          out.clear();
          err.clear();
          expect(await run(args), ExitCodes.errorsFound, reason: '$args');
          expect(out.toString(), isEmpty);
          expect(
            err.toString(),
            startsWith(
              'Nothing in docs/app/ was changed: the project map is missing '
              '(the packages could not be fetched).\n',
            ),
          );
          expect(err.toString(), contains('`appstein docs` again.'));
          expect(Directory(p.join(project, 'docs')).existsSync(), isFalse);
        }
      },
    );

    test('does nothing, with exit 0, when docs are turned off', () async {
      File(
        p.join(project, 'appstein.yaml'),
      ).writeAsStringSync('appstein: 1\ndocs:\n  enabled: false\n');
      for (final args in [
        ['docs'],
        ['docs', '--check'],
      ]) {
        out.clear();
        expect(await run(args), ExitCodes.ok);
        expect(
          out.toString(),
          'Human docs are turned off (docs.enabled is false in '
          'appstein.yaml).\n',
        );
      }
      expect(err.toString(), isEmpty);
      expect(Directory(p.join(project, '.appstein')).existsSync(), isFalse);
    });

    test('names the docs folder from appstein.yaml', () async {
      File(
        p.join(project, 'appstein.yaml'),
      ).writeAsStringSync('appstein: 1\ndocs:\n  path: documentation\n');
      expect(await run(['docs']), ExitCodes.errorsFound);
      expect(
        err.toString(),
        startsWith('Nothing in documentation/ was changed: '),
      );
    });

    test('finds the project from --project', () async {
      expect(
        await run(['--project', project, 'docs'], workingDirectory: work.path),
        ExitCodes.errorsFound,
      );
      expect(err.toString(), contains('the project map is missing'));
    });

    test('fails, with exit 3, outside a project', () async {
      expect(
        await run(['docs'], workingDirectory: work.path),
        ExitCodes.appsteinFailed,
      );
      expect(
        err.toString(),
        startsWith('appstein docs needs a Flutter project, but there is no '),
      );
    });

    test('fails, with exit 3, for an invalid appstein.yaml', () async {
      File(
        p.join(project, 'appstein.yaml'),
      ).writeAsStringSync('appstein: 99\n');
      expect(await run(['docs']), ExitCodes.appsteinFailed);
      expect(
        err.toString(),
        contains('Fix appstein.yaml, then run `appstein docs` again.'),
      );
    });

    test('is in the help, with its --check flag', () async {
      expect(await run(['help']), ExitCodes.ok);
      expect(out.toString(), contains('  docs '));
      out.clear();
      expect(await run(['docs', '--help']), ExitCodes.ok);
      expect(out.toString(), contains('--check'));
    });
  });
}
