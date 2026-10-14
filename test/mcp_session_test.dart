import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/mcp_session.dart';

final _server = p.join('test', 'support', 'fake_mcp_server.dart');

const _short = Duration(milliseconds: 600);

Future<McpSession> startWith(
  List<String> flags, {
  Duration callTimeout = const Duration(seconds: 120),
}) async {
  final session = await McpSession.start(
    Platform.resolvedExecutable,
    [_server, ...flags],
    clientName: 'mcp_session_test',
    callTimeout: callTimeout,
  );
  addTearDown(session.close);
  return session;
}

Future<McpSession> start([List<String> flags = const []]) => startWith(flags);

void main() {
  test('initializes, skips notifications, and answers a tool call with the '
      'result and the time it took', () async {
    final session = await start();
    final call = await session.call('echo', {'a': 1});
    expect(call.isError, isFalse);
    expect(call.result['structuredContent'], {
      'echo': {'a': 1},
    });
    expect(call.elapsed, greaterThan(Duration.zero));
  });

  test(
    'a reply with isError is returned by call, and thrown by time',
    () async {
      final session = await start();
      final call = await session.call('fail', const {});
      expect(call.isError, isTrue);
      await expectLater(
        session.time('fail', const {}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('fail'), contains('It failed.')),
          ),
        ),
      );
      expect(await session.time('echo', const {}), greaterThan(Duration.zero));
    },
  );

  test('a server that ends before it answers is a StateError', () async {
    final session = await start();
    await expectLater(
      session.call('die', const {}),
      throwsA(isA<StateError>()),
    );
  });

  test('a request that gets no answer fails with the request and the time, '
      'and close still ends the server', () async {
    final session = await startWith(const [], callTimeout: _short);
    final error = await session
        .call('hang', const {})
        .then<Object>((_) => 'answered', onError: (Object error) => error);
    expect(error, isA<StateError>());
    final message = (error as StateError).message;
    expect(message, contains('tools/call hang'));
    expect(message, contains('no answer'));
    expect(message, matches(RegExp(r'after \d{3,} ms')));
    expect(await session.close(), isTrue);
  });

  test('the call timeout does not apply to initialize, which waits for the '
      'process to start', () async {
    // Starting a Dart program from source takes far longer than 20 ms.
    final session = await startWith(
      const [],
      callTimeout: const Duration(milliseconds: 20),
    );
    expect(session.pid, isPositive);
    await expectLater(
      session.call('hang', const {}),
      throwsA(isA<StateError>()),
    );
  });

  test('a line that is not JSON is a StateError that shows it', () async {
    final session = await start();
    await expectLater(
      session.call('garbage', const {}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('not JSON'), contains('this is not json')),
        ),
      ),
    );
  });

  test('a result that is not an object is a StateError, not a type '
      'error', () async {
    final session = await start();
    await expectLater(
      session.call('badresult', const {}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('tools/call badresult'), contains('not an object')),
        ),
      ),
    );
  });

  test('a server that never answers initialize fails start with a '
      'StateError', () async {
    await expectLater(
      McpSession.start(Platform.resolvedExecutable, [
        p.join('test', 'support', 'hold_open.dart'),
      ], startTimeout: _short),
      throwsA(isA<StateError>()),
    );
  });

  test('close ends a server by closing its input, and says so', () async {
    final session = await start();
    final id = session.pid;
    expect(await session.close(), isTrue, reason: 'ended by itself');
    expect(await listsProcess(id), isFalse);
  });

  test('close kills a server that ignores its input closing, and says '
      'so', () async {
    final session = await start(['--stubborn']);
    final id = session.pid;
    expect(
      await session.close(patience: const Duration(milliseconds: 500)),
      isFalse,
    );
    expect(await listsProcess(id), isFalse);
  });
}

/// Whether a process with this ID is running.
Future<bool> listsProcess(int id) async {
  // The OS may take a moment to drop a process that was just killed.
  for (var i = 0; i < 20; i++) {
    final alive = Platform.isWindows
        ? '${(await Process.run('tasklist', ['/FI', 'PID eq $id', '/FO', 'CSV', '/NH'])).stdout}'
              .contains('"$id"')
        : (await Process.run('ps', ['-p', '$id'])).exitCode == 0;
    if (!alive) return false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return true;
}
