import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../knowledge/support/sync_harness.dart';
import '../support/fixture_app.dart';
import 'support/mcp_client.dart';

void main() {
  test('over real stdio in a new process, in a folder with a space and an '
      'umlaut: every tool answers and stdout holds only protocol '
      'messages', () async {
    final sdk = fakeFlutter();
    final app = copyFixtureApp();
    final engine = p.dirname(p.dirname(p.dirname(fixtureAppsDir)));
    // The script itself, not `dart run`: pub never runs, so nothing but the
    // server can write to the child's stdout.
    final process = await Process.start(Platform.resolvedExecutable, [
      p.join(engine, 'test', 'mcp', 'support', 'stdio_server.dart'),
      app,
      sdk,
      testDartSdk,
    ], workingDirectory: engine);
    final errors = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(errors.write);
    final lines = <String>[];
    final incoming = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map((line) {
          lines.add(line);
          return line;
        });
    final outgoing = StreamController<String>();
    unawaited(
      outgoing.stream
          .map<List<int>>((message) => utf8.encode('$message\n'))
          .pipe(process.stdin),
    );
    final server = await connectTo(StreamChannel(incoming, outgoing.sink));

    final tools = (await server.listTools()).tools;
    expect(tools, hasLength(7), reason: '$errors');
    const calls = {
      'overview': <String, Object?>{},
      'where_is': {'query': 'login screen'},
      'feature': {'name': 'booking'},
      'route': {'path': '/booking/42'},
      'check_api': {'name': 'WillPopScope'},
      'what_changed': <String, Object?>{},
      'toolchain': <String, Object?>{},
    };
    for (final MapEntry(key: tool, value: arguments) in calls.entries) {
      final result = await call(server, tool, arguments);
      expect(
        result.isError,
        isNot(isTrue),
        reason: '$tool: ${textOf(result)}\n$errors',
      );
    }
    await server.shutdown();
    await outgoing.close();
    expect(
      await process.exitCode.timeout(const Duration(seconds: 30)),
      0,
      reason: '$errors',
    );
    for (final line in lines) {
      final message = jsonDecode(line);
      expect(message, isA<Map<String, Object?>>(), reason: line);
      expect((message as Map)['jsonrpc'], '2.0', reason: line);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
