import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/fake_process_runner.dart';
import '../../support/temp.dart';

void main() {
  test('warning when appstein is not on PATH', () async {
    final result = await const AppsteinPathCheck().run(testContext());
    expect(result.status, CheckStatus.warning);
    expect(result.summary, contains('not on PATH'));
  });

  test('recognizes pub global snapshots', () {
    final env = fakeEnvironment({});
    expect(
      isPubSnapshot(
        p.join(
          'C:',
          'Users',
          'a',
          'AppData',
          'Local',
          'Pub',
          'Cache',
          'bin',
          'appstein.bat',
        ),
        env,
      ),
      isTrue,
    );
    expect(
      isPubSnapshot(p.join('home', 'a', '.pub-cache', 'bin', 'appstein'), env),
      isTrue,
    );
    expect(isPubSnapshot(p.join('opt', 'appstein', 'appstein'), env), isFalse);
  });

  test('reads the Path value from reg query output', () {
    const output =
        '\r\nHKEY_CURRENT_USER\\Environment\r\n'
        '    Path    REG_EXPAND_SZ    %USERPROFILE%\\bin;C:\\tools\r\n\r\n';
    expect(parseRegPathValue(output), r'%USERPROFILE%\bin;C:\tools');
    expect(parseRegPathValue('ERROR: not found'), isNull);
  });

  test('expands %VARIABLES% and keeps unknown ones', () {
    final env = fakeEnvironment({
      'USERPROFILE': r'C:\Users\a',
    }, os: HostOs.windows);
    expect(
      expandWindowsVariables(r'%USERPROFILE%\bin;%NOPE%\x', env),
      r'C:\Users\a\bin;%NOPE%\x',
    );
  });

  group('on Windows', () {
    late Directory bin;
    late FakeProcessRunner runner;

    setUp(() {
      bin = tempDir();
      File(p.join(bin.path, 'appstein.exe')).writeAsStringSync('');
      runner = FakeProcessRunner();
    });

    void savedUserPath(String value) => runner.when('reg', [
      'query',
      r'HKCU\Environment',
      '/v',
      'Path',
    ], RunResult(exitCode: 0, stdout: '    Path    REG_SZ    $value\r\n'));

    Future<CheckResult> run() => const AppsteinPathCheck().run(
      testContext(
        environment: fakeEnvironment({
          'PATH': bin.path,
          'PATHEXT': defaultPathExt,
        }),
        runner: runner,
      ),
    );

    test('ok when the folder is also on the saved PATH', () async {
      savedUserPath(bin.path);
      expect((await run()).status, CheckStatus.ok);
    });

    test('warning when only this terminal has it on PATH', () async {
      savedUserPath(r'C:\somewhere\else');
      final result = await run();
      expect(result.status, CheckStatus.warning);
      expect(result.summary, contains('saved'));
    });
  }, testOn: 'windows');
}
