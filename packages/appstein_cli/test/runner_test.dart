import 'dart:io';

import 'package:appstein_cli/appstein_cli.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _Check implements DoctorCheck {
  const _Check(this.result);

  final CheckResult result;

  @override
  String get id => 'test.check';

  @override
  String get title => 'Test check';

  @override
  Future<CheckResult> run(DoctorContext context) async => result;
}

final class _CrashCommand extends Command<int> {
  @override
  String get name => 'crash';

  @override
  String get description => 'Throws, for tests.';

  @override
  Future<int> run() async => throw StateError('simulated crash');
}

void main() {
  late StringBuffer out;
  late StringBuffer err;
  late Directory work;

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
    work = Directory.systemTemp.createTempSync('appstein cli tëst ');
    addTearDown(() => work.deleteSync(recursive: true));
  });

  Future<int> run(
    List<String> args, {
    List<DoctorCheck>? checks,
    List<Command<int>> extra = const [],
  }) => runAppstein(
    args,
    out: out,
    err: err,
    environment: HostEnvironment(
      os: HostOs.current,
      variables: const {},
      workingDirectory: work.path,
    ),
    doctorChecks: checks,
    extraCommands: extra,
  );

  test('--version prints the versions and exits 0', () async {
    expect(await run(['--version']), ExitCodes.ok);
    expect(out.toString(), contains('appstein $appsteinVersion'));
    expect(out.toString(), contains('protocol 1'));
    expect(out.toString(), contains('flutter >=3.44.0'));
  });

  test('an unknown option exits 3 and shows usage', () async {
    expect(await run(['--nope']), ExitCodes.appsteinFailed);
    expect(err.toString(), contains('Could not find an option named'));
    expect(err.toString(), contains('Usage'));
  });

  for (final args in [
    ['--help'],
    ['help', 'doctor'],
    ['doctor', '--help'],
  ]) {
    test(
      '${args.join(' ')} prints usage to out, exits 0, and leaves err empty',
      () async {
        expect(await run(args), ExitCodes.ok);
        expect(out.toString(), contains('Usage'));
        expect(out.toString(), contains('doctor'));
        expect(err.toString(), isEmpty);
      },
    );
  }

  test('a failure while building the environment exits 3', () async {
    final code = await runAppstein(
      ['doctor'],
      out: out,
      err: err,
      environmentFactory: () => throw const FileSystemException('cwd gone'),
    );
    expect(code, ExitCodes.appsteinFailed);
    expect(err.toString(), contains('cwd gone'));
    expect(err.toString(), contains('appstein doctor'));
  });

  test('doctor exits 1 when a check finds an error', () async {
    final code = await run(
      ['doctor'],
      checks: [const _Check(CheckResult.error('broken', fixHint: 'fix it'))],
    );
    expect(code, ExitCodes.errorsFound);
    expect(out.toString(), contains('[error] Test check: broken'));
    expect(out.toString(), contains('Fix: fix it'));
  });

  test('doctor exits 0 with only warnings', () async {
    final code = await run(
      ['doctor'],
      checks: [const _Check(CheckResult.warning('meh'))],
    );
    expect(code, ExitCodes.ok);
  });

  test('--project must point at a folder with pubspec.yaml', () async {
    final code = await run([
      '--project',
      p.join(work.path, 'missing'),
      'doctor',
    ], checks: const []);
    expect(code, ExitCodes.appsteinFailed);
    expect(err.toString(), contains('No pubspec.yaml'));
  });

  test('--project accepts a relative path with spaces', () async {
    Directory(p.join(work.path, 'my app')).createSync();
    File(
      p.join(work.path, 'my app', 'pubspec.yaml'),
    ).writeAsStringSync('name: a');
    final code = await run(['--project', 'my app', 'doctor'], checks: const []);
    expect(code, ExitCodes.ok);
    expect(out.toString(), contains(p.join(work.path, 'my app')));
  });

  test('a crash exits 3 and says what to do', () async {
    final code = await run(['crash'], extra: [_CrashCommand()]);
    expect(code, ExitCodes.appsteinFailed);
    expect(err.toString(), contains('simulated crash'));
    expect(err.toString(), contains('appstein doctor'));
  });
}
