import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_process_runner.dart';
import '../support/temp.dart';

void main() {
  late String project;

  setUp(() {
    project = p.join(tempDir().path, 'my app');
    Directory(p.join(project, '.dart_tool')).createSync(recursive: true);
    File(p.join(project, 'pubspec.yaml')).writeAsStringSync('name: my_app\n');
  });

  /// Writes what `flutter pub get` leaves behind, after an older pubspec.
  void writeFetched(
    String root, {
    String version = '3.47.5',
    String generator = 'pub',
    String? pubspecFolder,
  }) {
    File(
      p.join(pubspecFolder ?? root, 'pubspec.yaml'),
    ).setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
    File(p.join(root, 'pubspec.lock')).writeAsStringSync('packages: {}\n');
    File(p.join(root, '.dart_tool', 'package_config.json'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': <Object>[],
          'generator': generator,
        }),
      );
    File(p.join(root, '.dart_tool', 'version')).writeAsStringSync(version);
  }

  PackagesStatus check() => checkPackages(project, flutterVersion: '3.47.5');

  test('packages fetched by this Flutter after the last pubspec change are '
      'fresh', () {
    writeFetched(project);
    final status = check();
    expect(status.fresh, isTrue);
    expect(status.reason, 'they are up to date');
    expect(status.workspaceRoot, project);
  });

  test('no package config means pub get', () {
    final status = check();
    expect(status.fresh, isFalse);
    expect(
      status.reason,
      'they had not been fetched (there was no '
      '.dart_tool/package_config.json)',
    );
  });

  test('a package config another tool wrote is used as it is', () {
    writeFetched(project, generator: 'bazel');
    File(p.join(project, 'pubspec.lock')).deleteSync();
    final status = check();
    expect(status.fresh, isTrue);
    expect(status.reason, contains('written by bazel'));
  });

  test('no pubspec.lock means pub get', () {
    writeFetched(project);
    File(p.join(project, 'pubspec.lock')).deleteSync();
    expect(check().reason, 'there was no pubspec.lock');
  });

  test('a pubspec.yaml changed after the fetch means pub get', () {
    writeFetched(project);
    File(
      p.join(project, 'pubspec.yaml'),
    ).setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
    final status = check();
    expect(status.fresh, isFalse);
    expect(status.reason, 'pubspec.yaml changed after they were fetched');
  });

  test('packages fetched by another Flutter mean pub get', () {
    writeFetched(project, version: '3.44.9');
    expect(check().reason, 'they were fetched with Flutter 3.44.9, not 3.47.5');
  });

  test('the version must match exactly, as in Flutter', () {
    writeFetched(project, version: '3.47.5\n');
    expect(check().fresh, isFalse);
  });

  test('no .dart_tool/version means pub get', () {
    writeFetched(project);
    File(p.join(project, '.dart_tool', 'version')).deleteSync();
    expect(
      check().reason,
      'they were not fetched by Flutter (there was no .dart_tool/version)',
    );
  });

  test("a pub workspace member reads the workspace root's files", () {
    final root = p.join(tempDir().path, 'work space');
    final member = p.join(root, 'packages', 'app');
    Directory(p.join(member, '.dart_tool', 'pub')).createSync(recursive: true);
    File(p.join(member, 'pubspec.yaml')).writeAsStringSync('name: app\n');
    File(
      p.join(member, '.dart_tool', 'pub', 'workspace_ref.json'),
    ).writeAsStringSync(
      jsonEncode({'workspaceRoot': p.join('..', '..', '..', '..')}),
    );
    writeFetched(root, pubspecFolder: member);
    final status = checkPackages(member, flutterVersion: '3.47.5');
    expect(status.fresh, isTrue, reason: status.reason);
    expect(status.workspaceRoot, p.normalize(root));
  });

  test('a damaged workspace reference falls back to the project', () {
    Directory(p.join(project, '.dart_tool', 'pub')).createSync();
    File(
      p.join(project, '.dart_tool', 'pub', 'workspace_ref.json'),
    ).writeAsStringSync('{not json');
    writeFetched(project);
    final status = check();
    expect(status.fresh, isTrue);
    expect(status.workspaceRoot, project);
  });

  test('a pubspec.yaml that cannot be read means pub get, with the '
      'reason', () {
    writeFetched(project);
    File(p.join(project, 'pubspec.yaml')).deleteSync();
    final status = check();
    expect(status.fresh, isFalse);
    expect(status.reason, startsWith('they could not be checked ('));
  });

  test('a workspace reference without workspaceRoot falls back to the '
      'project', () {
    Directory(p.join(project, '.dart_tool', 'pub')).createSync();
    File(
      p.join(project, '.dart_tool', 'pub', 'workspace_ref.json'),
    ).writeAsStringSync(jsonEncode({'other': 1}));
    writeFetched(project);
    final status = check();
    expect(status.fresh, isTrue);
    expect(status.workspaceRoot, project);
  });

  group('fetchPackages', () {
    final flutter = p.join(
      'sdk',
      'bin',
      Platform.isWindows ? 'flutter.bat' : 'flutter',
    );

    Future<String?> fetch(FakeProcessRunner runner) => fetchPackages(
      project,
      flutterRoot: 'sdk',
      os: HostOs.current,
      runner: runner,
    );

    test('runs flutter pub get in the project', () async {
      final runner = FakeProcessRunner()
        ..when(flutter, ['pub', 'get'], const RunResult(exitCode: 0));
      writeFetched(project);
      expect(await fetch(runner), isNull);
      expect(runner.calls, ['$flutter pub get']);
      expect(runner.workingDirectories, [project]);
    });

    test('a failed pub get says so, with the end of its output', () async {
      final output = [for (var i = 1; i <= 15; i++) 'e${'$i'.padLeft(2, '0')}'];
      final runner = FakeProcessRunner()
        ..when(flutter, [
          'pub',
          'get',
        ], RunResult(exitCode: 69, stderr: output.join('\n')));
      final failure = await fetch(runner);
      expect(
        failure,
        startsWith('`flutter pub get` failed with exit code 69:'),
      );
      expect(failure, contains('e06\n'));
      expect(failure, endsWith('e15'));
      expect(failure, isNot(contains('e05')));
    });

    test('a Flutter that cannot start is reported', () async {
      expect(
        await fetch(FakeProcessRunner()),
        startsWith('Flutter could not be started'),
      );
    });

    test('a pub get that runs too long is reported', () async {
      final runner = FakeProcessRunner()
        ..when(flutter, [
          'pub',
          'get',
        ], const RunResult.timedOut(stdout: '', stderr: ''));
      expect(
        await fetch(runner),
        '`flutter pub get` did not finish within 5 minutes',
      );
    });

    test('the timeout is worded in whole minutes or in seconds', () async {
      final runner = FakeProcessRunner()
        ..when(flutter, [
          'pub',
          'get',
        ], const RunResult.timedOut(stdout: '', stderr: ''));
      Future<String?> within(Duration timeout) => fetchPackages(
        project,
        flutterRoot: 'sdk',
        os: HostOs.current,
        runner: runner,
        timeout: timeout,
      );
      expect(
        await within(const Duration(seconds: 30)),
        '`flutter pub get` did not finish within 30 seconds',
      );
      expect(
        await within(const Duration(minutes: 1)),
        '`flutter pub get` did not finish within 1 minute',
      );
      expect(
        await within(const Duration(seconds: 90)),
        '`flutter pub get` did not finish within 90 seconds',
      );
    });

    test('a pub get that leaves no package config is a failure', () async {
      final runner = FakeProcessRunner()
        ..when(flutter, ['pub', 'get'], const RunResult(exitCode: 0));
      expect(
        await fetch(runner),
        '`flutter pub get` finished but did not create '
        '.dart_tool/package_config.json',
      );
    });

    test("in a pub workspace member, the workspace root's package config "
        'counts', () async {
      final root = p.join(tempDir().path, 'work space');
      final member = p.join(root, 'packages', 'app');
      Directory(
        p.join(member, '.dart_tool', 'pub'),
      ).createSync(recursive: true);
      File(
        p.join(member, '.dart_tool', 'pub', 'workspace_ref.json'),
      ).writeAsStringSync(
        jsonEncode({'workspaceRoot': p.join('..', '..', '..', '..')}),
      );
      final runner = FakeProcessRunner()
        ..when(flutter, ['pub', 'get'], const RunResult(exitCode: 0));
      Future<String?> fetchMember() => fetchPackages(
        member,
        flutterRoot: 'sdk',
        os: HostOs.current,
        runner: runner,
      );
      expect(
        await fetchMember(),
        '`flutter pub get` finished but did not create '
        '.dart_tool/package_config.json',
      );
      File(p.join(root, '.dart_tool', 'package_config.json'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{}');
      expect(await fetchMember(), isNull);
      expect(runner.workingDirectories, [member, member]);
    });
  });
}
