import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  const runner = SystemProcessRunner();

  test('runs a program and captures its output', () async {
    final result = await runner.run(Platform.resolvedExecutable, ['--version']);
    expect(result.ok, isTrue);
    expect(result.stdout + result.stderr, contains('Dart SDK version'));
  });

  test('runs a script whose path and argument contain spaces', () async {
    final dir = tempDir();
    final String script;
    if (Platform.isWindows) {
      script = (File(
        p.join(dir.path, 'echo arg.bat'),
      )..writeAsStringSync('@echo off\r\necho %~1\r\n')).path;
    } else {
      script = (File(
        p.join(dir.path, 'echo arg'),
      )..writeAsStringSync('#!/bin/sh\necho "\$1"\n')).path;
      Process.runSync('chmod', ['+x', script]);
    }
    final result = await runner.run(script, ['hello world']);
    expect(result.stdout.trim(), 'hello world');
  });

  test('reports a program that cannot start instead of throwing', () async {
    final result = await runner.run('appstein-no-such-tool-xyz', []);
    expect(result.started, isFalse);
    expect(result.ok, isFalse);
  });

  test('kills a program that runs past the timeout', () async {
    final script = File(p.join(tempDir().path, 'sleep.dart'))
      ..writeAsStringSync(
        "import 'dart:io';\n"
        'void main() => sleep(const Duration(seconds: 30));\n',
      );
    final watch = Stopwatch()..start();
    final result = await runner.run(Platform.resolvedExecutable, [
      script.path,
    ], timeout: const Duration(seconds: 3));
    expect(result.timedOut, isTrue);
    expect(result.ok, isFalse);
    expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
  });

  test('decodes output that is not valid UTF-8 without throwing', () async {
    final script = File(p.join(tempDir().path, 'bytes.dart'))
      ..writeAsStringSync(
        "import 'dart:io';\n"
        'void main() { stdout.add([0xff, 0xfe, 0x41, 0x0a]); }\n',
      );
    final result = await runner.run(Platform.resolvedExecutable, [script.path]);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('A'));
  });
}
