import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/child_processes.dart';

void main() {
  test(
    'an uncaught async error exits 3 with the crash message',
    // It starts a process, and other files' tests count this process's
    // children: one at a time.
    () => withChildProcessesToItself(() async {
      final harness = p.join(
        Directory.current.path,
        'test',
        'support',
        'async_error_harness.dart',
      );
      final result = await Process.run(Platform.resolvedExecutable, [harness]);
      expect(result.exitCode, 3, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stderr, contains('Appstein failed unexpectedly'));
      expect(result.stderr, contains('async boom'));
    }),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
