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
    expect(text, contains('Curated notes cover Flutter 3.47 and earlier.'));
    // The fake SDK has no toolchain files, so each part is a fallback.
    expect(text, contains('toolchain.fallback (info): Android: '));
    for (final path in [
      'platform/sdk.json',
      'platform/toolchain.json',
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

  test('help lists sync', () async {
    await run(['--help']);
    expect(
      out.toString(),
      contains('Regenerate the knowledge Appstein keeps in .appstein/.'),
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
