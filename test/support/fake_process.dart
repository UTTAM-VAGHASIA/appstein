import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A process the test controls: nothing is started. It records what is
/// written to its stdin, ends with [exitCodeValue] after [exitAfter] (never,
/// when that is null), and closes its stdout and stderr, with [stdoutText]
/// and [stderrText], after [stdoutClosesAfter] and [stderrClosesAfter] (never,
/// when that is null), each counted from its start.
final class FakeProcess implements Process {
  /// Creates a process that starts running now.
  FakeProcess({
    this.exitCodeValue = 0,
    this.exitAfter = Duration.zero,
    this.stdoutText = '',
    this.stderrText = '',
    this.stdoutClosesAfter = Duration.zero,
    this.stderrClosesAfter = Duration.zero,
    this.stdoutFails = false,
    this.errorOnKill = false,
  }) : _exit = Completer<int>() {
    _stdout = StreamController<List<int>>();
    _stderr = StreamController<List<int>>();
    _stdin = IOSink(
      StreamController<List<int>>()
        ..stream.listen((bytes) => written.write(utf8.decode(bytes))),
    );
    _after(exitAfter, () => _exit.complete(exitCodeValue));
    _after(stdoutClosesAfter, () {
      if (stdoutFails) {
        _stdout.addError(const FileSystemException('the pipe broke'));
      } else {
        _stdout.add(utf8.encode(stdoutText));
      }
      _stdout.close();
    });
    _after(stderrClosesAfter, () {
      _stderr.add(utf8.encode(stderrText));
      _stderr.close();
    });
  }

  /// The exit code it ends with.
  final int exitCodeValue;

  /// When it ends; never when null.
  final Duration? exitAfter;

  /// What it writes to stdout when that closes.
  final String stdoutText;

  /// What it writes to stderr when that closes.
  final String stderrText;

  /// When its stdout closes; never when null.
  final Duration? stdoutClosesAfter;

  /// When its stderr closes; never when null.
  final Duration? stderrClosesAfter;

  /// Whether its stdout ends with an error (a pipe that broke) instead of its
  /// text.
  final bool stdoutFails;

  /// Whether killing it breaks its stdout: the stream gets an error and
  /// closes.
  final bool errorOnKill;

  /// Everything written to its stdin.
  final written = StringBuffer();

  /// Whether [kill] was called.
  var killed = false;

  final Completer<int> _exit;
  late final StreamController<List<int>> _stdout;
  late final StreamController<List<int>> _stderr;
  late final IOSink _stdin;
  final _timers = <Timer>[];

  void _after(Duration? delay, void Function() action) {
    if (delay == null) return;
    _timers.add(Timer(delay, action));
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 4242;

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    if (errorOnKill && !_stdout.isClosed) {
      _stdout
        ..addError(const FileSystemException('the pipe broke'))
        ..close();
      // A killed process closes its other pipe too.
      if (!_stderr.isClosed) _stderr.close();
    }
    if (!_exit.isCompleted) _exit.complete(-1);
    return true;
  }
}
