import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/child_processes.dart';

void main() {
  /// Runs the harness, which throws from a timer, as the process for
  /// [arguments].
  Future<ProcessResult> harness(List<String> arguments) {
    final script = p.join(
      Directory.current.path,
      'test',
      'support',
      'async_error_harness.dart',
    );
    return Process.run(Platform.resolvedExecutable, [script, ...arguments]);
  }

  test(
    'an uncaught async error exits 3 with the crash message',
    // It starts a process, and other files' tests count this process's
    // children: one at a time.
    () => withChildProcessesToItself(() async {
      final result = await harness([]);
      expect(result.exitCode, 3, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stderr, contains('Appstein failed unexpectedly'));
      expect(result.stderr, contains('async boom'));
    }),
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'in a Claude Code hook an uncaught async error is exit 0, told in JSON '
    'to the agent and the developer, with the trace on stderr',
    () => withChildProcessesToItself(() async {
      final result = await harness(['verify', '--fast', '--hook', 'claude']);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final json = jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(json.keys.toSet(), {'hookSpecificOutput', 'systemMessage'});
      expect(json['systemMessage'], contains('async boom'));
      expect(json['systemMessage'], contains('run `appstein doctor`'));
      expect(result.stderr, contains('Appstein failed unexpectedly'));
      expect(result.stderr, contains('async boom'));
      expect(result.stderr, contains('#0'));
    }),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
