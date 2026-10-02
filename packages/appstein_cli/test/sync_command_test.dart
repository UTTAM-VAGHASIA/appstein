import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_flutter_sdk.dart';

void main() {
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
    Map<String, String>? variables,
  }) => runAppstein(
    args,
    out: out,
    err: err,
    environment: HostEnvironment(
      os: HostOs.current,
      variables: variables ?? {'FLUTTER_ROOT': sdk},
      workingDirectory: workingDirectory ?? project,
    ),
  );

  String row(String path, String state) =>
      '  ${path.padRight('platform/toolchain.json'.length)}  $state';

  test('writes the platform layer and says what it did', () async {
    expect(await run(['sync']), ExitCodes.ok, reason: '$err');
    final text = out.toString();
    expect(
      text,
      startsWith(
        'Synced .appstein/ for Flutter 3.47.5 (Dart 3.13.4, stable channel).\n',
      ),
    );
    expect(text, contains(row('platform/sdk.json', 'written')));
    expect(text, contains(row('platform/toolchain.json', 'written')));
    expect(text, contains(row('platform/delta.md', 'written')));
    expect(text, contains(row('map/native.json', 'written')));
    expect(
      text,
      contains(
        'Native config: android absent: no android/ folder; ios absent: no '
        'ios/ folder.\n',
      ),
    );
    expect(text, contains('Curated notes cover Flutter 3.47 and earlier.'));
    expect(
      text,
      contains('Project map skipped: the packages could not be fetched.'),
    );
    expect(
      text,
      contains(
        'Run `flutter pub get` in the project to see the whole error, then '
        '`appstein sync` again.',
      ),
    );
    // The fake SDK has no toolchain files, so each part is a fallback.
    expect(text, contains('toolchain.fallback (info): Android: '));
    for (final path in [
      'platform/sdk.json',
      'platform/toolchain.json',
      'platform/delta.md',
      'state.json',
    ]) {
      expect(
        File(
          p.joinAll([project, '.appstein', ...path.split('/')]),
        ).existsSync(),
        isTrue,
        reason: path,
      );
    }
  });

  test('a second run changes nothing', () async {
    await run(['sync']);
    out.clear();
    expect(await run(['sync']), ExitCodes.ok);
    expect(out.toString(), contains(row('platform/sdk.json', 'unchanged')));
    expect(
      out.toString(),
      contains(row('platform/toolchain.json', 'unchanged')),
    );
  });

  test('--project works from another folder', () async {
    expect(
      await run(['--project', 'my app', 'sync'], workingDirectory: work.path),
      ExitCodes.ok,
      reason: '$err',
    );
    expect(
      File(p.join(project, '.appstein', 'state.json')).existsSync(),
      isTrue,
    );
  });

  test('outside a project it exits 3 and says why', () async {
    final outside = Directory(p.join(work.path, 'outside'))..createSync();
    expect(
      await run(['sync'], workingDirectory: outside.path),
      ExitCodes.appsteinFailed,
    );
    expect(err.toString(), contains('needs a Flutter project'));
  });

  test('without a Flutter SDK it exits 3 with the fix', () async {
    expect(await run(['sync'], variables: {}), ExitCodes.appsteinFailed);
    expect(err.toString().trim(), isNotEmpty);
    expect(Directory(p.join(project, '.appstein')).existsSync(), isFalse);
  });

  test('a .appstein that is a file exits 3, names it and says what to '
      'do', () async {
    File(p.join(project, '.appstein')).writeAsStringSync('in the way');
    expect(await run(['sync']), ExitCodes.appsteinFailed);
    final text = err.toString();
    expect(text, contains('.appstein'));
    expect(text, contains('Check that the project folder is writable'));
    expect(text, contains('appstein sync'));
  });

  test('help lists sync', () async {
    await run(['--help']);
    expect(
      out.toString(),
      contains('Regenerate the knowledge Appstein keeps in .appstein/.'),
    );
  });

  test('a broken appstein.yaml exits 3 and says what to fix', () async {
    File(
      p.join(project, 'appstein.yaml'),
    ).writeAsStringSync('packs:\n  stack: nope\n');
    expect(await run(['sync']), ExitCodes.appsteinFailed);
    expect(err.toString(), contains('Fix appstein.yaml'));
    expect(Directory(p.join(project, '.appstein')).existsSync(), isFalse);
  });

  test("the delta's baseline comes from appstein.yaml", () async {
    File(
      p.join(project, 'appstein.yaml'),
    ).writeAsStringSync('delta:\n  baseline: "3.47"\n');
    expect(await run(['sync']), ExitCodes.ok, reason: '$err');
    final text = File(
      p.join(project, '.appstein', 'platform', 'delta.md'),
    ).readAsStringSync();
    expect(text, contains('since Flutter 3.47'));
    expect(text, isNot(contains('popscope-not-willpopscope')));
  });

  SyncReport reportWith(MapReport map) => SyncReport(
    sdk: const SdkInfo(
      flutterVersion: '3.47.5',
      dartVersion: '3.13.4',
      channel: 'stable',
      notesCoverage: NotesCoverage.complete,
    ),
    files: const {'platform/sdk.json': true, 'map/symbols.json': true},
    newestNotes: '3.47',
    fallbacks: const [],
    map: map,
  );

  test('the report says when the packages were fetched', () {
    final text = formatSyncReport(
      reportWith(
        const MapReport(
          packages: PackagesAction.fetched,
          packagesReason: 'pubspec.yaml changed after they were fetched',
        ),
      ),
    );
    expect(
      text,
      contains(
        'Fetched the packages with `flutter pub get`, because pubspec.yaml '
        'changed after they were fetched.',
      ),
    );
    expect(text, isNot(contains('Project map skipped')));
  });

  test('the report shows a failed fetch, indented, and what to run', () {
    final text = formatSyncReport(
      reportWith(
        const MapReport(
          packages: PackagesAction.fetchFailed,
          packagesReason:
              '`flutter pub get` failed with exit code 69:\nNo network.',
          skipped: 'the packages could not be fetched',
        ),
      ),
    );
    expect(
      text,
      contains(
        'Could not fetch the packages:\n'
        '  `flutter pub get` failed with exit code 69:\n'
        '  No network.\n'
        'Project map skipped: the packages could not be fetched.\n',
      ),
    );
  });

  test('a skip reason that ends in a full stop is not doubled', () {
    final text = formatSyncReport(
      reportWith(
        const MapReport(
          packages: PackagesAction.upToDate,
          packagesReason: 'they are up to date',
          skipped:
              'The Dart SDK at /x is incomplete: it has no '
              'lib/core/core.dart.',
        ),
      ),
    );
    expect(text, contains('lib/core/core.dart.\nFix that, then run'));
    expect(text, isNot(contains('core.dart..')));
  });

  test('a delta that could not be collected is reported as an internal '
      'error, with the whole error once', () {
    final text = formatSyncReport(
      reportWith(
        const MapReport(
          packages: PackagesAction.upToDate,
          packagesReason: 'they are up to date',
          deltaError: 'Bad state: x\nat line 2',
          deltaErrorType: 'StateError',
        ),
      ),
    );
    expect(
      text,
      contains(
        'Version delta: deprecated and removed APIs are missing because of '
        'an internal error in Appstein. Please report it, with this error:\n'
        '  Bad state: x\n'
        '  at line 2\n',
      ),
    );
    expect('version delta'.allMatches(text.toLowerCase()), hasLength(1));
    expect('Bad state: x'.allMatches(text), hasLength(1));
    expect(text, isNot(contains('Fix that')));
    expect(text, isNot(contains('Project map skipped')));
  });

  test('native config is one line, and an internal error is shown in full', () {
    const report = SyncReport(
      sdk: SdkInfo(
        flutterVersion: '3.47.5',
        dartVersion: '3.13.4',
        channel: 'stable',
        notesCoverage: NotesCoverage.complete,
      ),
      files: {'map/native.json': true},
      newestNotes: '3.47',
      fallbacks: [],
      native: NativeReport(
        sections: {
          'android': 'internal error (StateError)',
          'ios': 'absent: no ios/ folder',
        },
        errors: {'android': 'Bad state: boom\nmore'},
      ),
    );
    final text = formatSyncReport(report);
    expect(
      text,
      contains(
        'Native config: android internal error (StateError); ios absent: no '
        'ios/ folder.\n',
      ),
    );
    expect(
      text,
      contains(
        'Native config (android): missing because of an internal error in '
        'Appstein. Please report it, with this error:\n'
        '  Bad state: boom\n'
        '  more\n',
      ),
    );
  });

  test('unknown notes coverage is reported as possibly incomplete', () {
    const report = SyncReport(
      sdk: SdkInfo(
        flutterVersion: '3.47.5',
        dartVersion: '3.13.4',
        channel: 'stable',
      ),
      files: {'platform/sdk.json': true},
      newestNotes: '3.47',
      fallbacks: [],
    );
    expect(
      formatSyncReport(report),
      contains('Curated notes may be incomplete for Flutter 3.47'),
    );
  });

  test('a partial coverage line names the minor version', () {
    const report = SyncReport(
      sdk: SdkInfo(
        flutterVersion: '3.50.1',
        dartVersion: '3.14.0',
        channel: 'stable',
        notesCoverage: NotesCoverage.partial,
      ),
      files: {'platform/sdk.json': true},
      newestNotes: '3.47',
      fallbacks: [],
    );
    expect(
      formatSyncReport(report),
      contains(
        'Curated notes may be incomplete for Flutter 3.50: the newest notes '
        'are for 3.47.',
      ),
    );
  });
}
