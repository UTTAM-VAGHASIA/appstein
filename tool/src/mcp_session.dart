import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The answer to one `tools/call`: its `result` and the time it took.
final class McpCall {
  /// Creates an answer.
  const McpCall(this.result, this.elapsed);

  /// The JSON-RPC result: `content`, `structuredContent` and `isError`.
  final Map<String, Object?> result;

  /// From sending the request to reading the answer.
  final Duration elapsed;

  /// Whether the tool answered with an error.
  bool get isError => result['isError'] == true;
}

/// One MCP server process and a minimal JSON-RPC client over its stdin and
/// stdout: enough to time tool calls as an agent makes them. One message per
/// line, as `appstein mcp` speaks.
final class McpSession {
  McpSession._(this._process, this._lines, this._callTimeout);

  final Process _process;
  final StreamIterator<String> _lines;
  final Duration _callTimeout;
  var _id = 0;
  Future<bool>? _closing;

  /// Starts [executable] with [arguments] (and [environment], added to this
  /// process's) and initializes it as a client called [clientName]. A
  /// request that gets no answer within [callTimeout] is a [StateError]: a
  /// server that hangs must fail a run, not hold it until the job's limit.
  /// The first request, `initialize`, has [startTimeout] of its own, since
  /// it also waits for the process to start (a program run from source
  /// takes a quarter of a second on a desktop and several times that on a
  /// CI runner).
  static Future<McpSession> start(
    String executable,
    List<String> arguments, {
    Map<String, String> environment = const {},
    String clientName = 'measure',
    Duration callTimeout = const Duration(seconds: 120),
    Duration startTimeout = const Duration(seconds: 120),
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
    );
    // An unread stderr would fill its pipe and block the server.
    unawaited(process.stderr.drain<void>());
    final session = McpSession._(
      process,
      StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      callTimeout,
    );
    try {
      await session._request('initialize', {
        'protocolVersion': '2025-11-25',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': clientName, 'version': '1'},
      }, timeout: startTimeout);
    } on Object {
      await session.close();
      rethrow;
    }
    session._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    return session;
  }

  /// The server process's ID.
  int get pid => _process.pid;

  void _send(Map<String, Object?> message) =>
      _process.stdin.writeln(jsonEncode(message));

  /// Sends a request and returns its result. Every way it can go wrong is a
  /// [StateError] that says what happened: no answer within the session's
  /// timeout, a line that isn't JSON, a message or a result that isn't an
  /// object, a JSON-RPC error, a server that ended. [what] names the request
  /// in them.
  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params, {
    String? what,
    Duration? timeout,
  }) {
    final id = ++_id;
    final name = what ?? method;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    final watch = Stopwatch()..start();
    // The timeout leaves the wait for the answer running; the session is not
    // used again after it, and `close` ends the wait.
    return _answer(id, name).timeout(
      timeout ?? _callTimeout,
      onTimeout: () => throw StateError(
        'the MCP server gave no answer to $name after '
        '${watch.elapsed.inMilliseconds} ms',
      ),
    );
  }

  Future<Map<String, Object?>> _answer(int id, String name) async {
    while (await _lines.moveNext()) {
      final line = _lines.current;
      final Object? message;
      try {
        message = jsonDecode(line);
      } on FormatException {
        final shown = line.length > 200 ? '${line.substring(0, 200)}...' : line;
        throw StateError(
          'the MCP server wrote a line that is not JSON while $name was '
          'asked: $shown',
        );
      }
      if (message is! Map<String, Object?>) {
        throw StateError(
          'the MCP server wrote a message that is not an object while $name '
          'was asked: $message',
        );
      }
      // Notifications, and the answers to nothing this client asked.
      if (message['id'] != id) continue;
      if (message['error'] case final error?) {
        throw StateError('$name failed: $error');
      }
      final result = message['result'];
      if (result is! Map<String, Object?>) {
        throw StateError(
          'the MCP server answered $name with a result that is not an '
          'object: $result',
        );
      }
      return result;
    }
    throw StateError('the MCP server exited before answering $name');
  }

  /// Calls [tool] and returns its answer, an error reply included. Throws a
  /// [StateError] when the server answers with a JSON-RPC error, answers
  /// with something that isn't a result, gives no answer within the
  /// session's timeout, or ends.
  Future<McpCall> call(String tool, Map<String, Object?> arguments) async {
    final watch = Stopwatch()..start();
    final result = await _request('tools/call', {
      'name': tool,
      'arguments': arguments,
    }, what: 'tools/call $tool');
    watch.stop();
    return McpCall(result, watch.elapsed);
  }

  /// How long [tool] took to answer; throws a [StateError] with the reply's
  /// text when it answered with an error.
  Future<Duration> time(String tool, Map<String, Object?> arguments) async {
    final answer = await call(tool, arguments);
    if (answer.isError) {
      throw StateError(
        '$tool answered with an error: ${jsonEncode(answer.result['content'])}',
      );
    }
    return answer.elapsed;
  }

  /// Ends the server by closing its input, as an agent does, and kills it
  /// when it has not ended after [patience] (30 s by default: a slow CI
  /// runner must not be taken for a server that won't end). Returns whether
  /// it ended by itself; the caller reports a kill and fails the run. Safe
  /// to call twice.
  ///
  /// The iterator is cancelled too: between reads it holds its subscription
  /// to the server's stdout paused, and a paused subscription keeps this
  /// process alive after `main` returns.
  Future<bool> close({Duration patience = const Duration(seconds: 30)}) =>
      _closing ??= _close(patience);

  Future<bool> _close(Duration patience) async {
    var byItself = true;
    try {
      await _process.stdin.close();
    } on Object {
      // The server is already gone.
    }
    await _process.exitCode.timeout(
      patience,
      onTimeout: () {
        byItself = false;
        _process.kill();
        return _process.exitCode;
      },
    );
    await _lines.cancel();
    return byItself;
  }
}
