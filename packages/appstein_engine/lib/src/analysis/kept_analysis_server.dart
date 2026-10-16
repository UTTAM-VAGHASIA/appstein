import 'dart:async';

import 'code_analysis.dart';

/// How long an analysis server that `appstein mcp` keeps may go unused
/// before it is stopped (decision record 0001, "Memory"). A server holds
/// 0.6 GB or more for a 200-file app, so a session that has stopped
/// verifying gives it back; the next `verify` call starts it again.
const analysisIdleStop = Duration(minutes: 10);

/// One project's analysis server, kept between uses: what gives the
/// `verify` MCP tool its warm analysis (slice 1d.2).
///
/// - **Nothing is started when it is created.** The first use that asks
///   starts the server, so an owner that never verifies holds none.
/// - **Uses come one at a time** ([use]). One that arrives while the server
///   is starting, or while another is being answered, waits. So two uses
///   never start two servers.
/// - **The server stays between uses**, and each reading takes in what
///   changed on disk first (`AnalysisServer.read`).
/// - **It is stopped, with its guard, when no use has ended or begun for
///   [idleStop].** The time is counted from the end of the last use, and
///   never runs during one, so a slow start or a long run is never cut off.
///   The next use starts a new server.
/// - **[close] stops it for good**, when its owner stops.
final class KeptAnalysisServer<S extends StoppableCodeAnalysis> {
  /// Keeps [server], which this object then owns: nothing else may stop or
  /// close it. [idleStop] is [analysisIdleStop] unless a test shortens it,
  /// and [newTimer] makes the timer that counts it; a test passes one it
  /// fires itself.
  KeptAnalysisServer(
    this.server, {
    this.idleStop = analysisIdleStop,
    this.newTimer = Timer.new,
  });

  /// The server that is kept.
  final S server;

  /// How long the server may go unused before it is stopped.
  final Duration idleStop;

  /// Makes the timer that counts the idle time.
  final Timer Function(Duration time, void Function() then) newTimer;

  Future<void> _last = Future.value();
  Timer? _idle;
  var _closed = false;

  /// Runs [body] with the project's code analysis, after every use before
  /// it has ended, and after an idle stop that is under way. It is a
  /// `CodeAnalysisScope`: pass `kept.use` where one is wanted. The server
  /// is left running when [body] ends, and the idle time starts again.
  ///
  /// Throws a [CodeAnalysisException] when this was closed before the
  /// use's turn came. A use already under way when [close] comes keeps
  /// going, and each question it asks afterwards fails with the same
  /// [CodeAnalysisException]: an analysis that can't answer, never the
  /// server's `StateError` for a question after its owner closed it.
  Future<T> use<T>(Future<T> Function(CodeAnalysis analysis) body) =>
      _inTurn(() async {
        if (_closed) throw _closedError;
        _idle?.cancel();
        _idle = null;
        try {
          return await body(_InUse(server, () => _closed));
        } finally {
          if (!_closed) _idle = newTimer(idleStop, _stopIdle);
        }
      });

  /// Stops the server because nothing used it for [idleStop]. It takes a
  /// turn like a use, so a use that arrives meanwhile waits until the
  /// server has ended, and then starts a new one.
  void _stopIdle() {
    _idle = null;
    unawaited(_inTurn(server.stop));
  }

  /// Runs [action] after every action before it has ended.
  Future<T> _inTurn<T>(Future<T> Function() action) {
    final result = _last.then((_) => action());
    _last = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Stops the server and its guard for good, at once, and returns when
  /// both have ended, also when an idle stop was under way. A use that is
  /// waiting for the server, or for its turn, fails with a
  /// [CodeAnalysisException], as a later one does.
  Future<void> close() async {
    _closed = true;
    _idle?.cancel();
    _idle = null;
    await server.close();
    // An idle stop that had begun, and the uses that lost to this.
    await _last;
  }
}

/// Why a use that loses to [KeptAnalysisServer.close] fails.
const _closedError = CodeAnalysisException(
  'it was closed, because Appstein is stopping',
);

/// The server as one use asks it: once its owner has closed it, a question
/// that fails fails with [_closedError].
final class _InUse implements CodeAnalysis {
  _InUse(this._server, this._closed);

  final CodeAnalysis _server;
  final bool Function() _closed;

  Future<T> _ask<T>(Future<T> Function() question) async {
    if (_closed()) throw _closedError;
    try {
      return await question();
    } on Object {
      if (_closed()) throw _closedError;
      rethrow;
    }
  }

  @override
  Future<CodeReading> read() => _ask(_server.read);

  @override
  Future<bool> canDartFix(
    CodeDiagnostic diagnostic, {
    required Duration within,
  }) => _ask(() => _server.canDartFix(diagnostic, within: within));

  @override
  Future<FormatAnswers> formatChanges(
    List<String> files, {
    required Duration within,
  }) => _ask(() => _server.formatChanges(files, within: within));

  @override
  Future<PendingFixes> pendingFixes({required Duration within}) =>
      _ask(() => _server.pendingFixes(within: within));

  @override
  Future<AppliedChanges> applyFixesAndFormat({
    required Future<bool> Function(String file) leaveUnformatted,
    required Duration within,
  }) => _ask(
    () => _server.applyFixesAndFormat(
      leaveUnformatted: leaveUnformatted,
      within: within,
    ),
  );
}
