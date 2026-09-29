import 'package:appstein_engine/appstein_engine.dart';

/// A [ProcessRunner] that returns canned results and records every call.
///
/// A command that wasn't set up with [when] "fails to start", just as a
/// missing tool would.
final class FakeProcessRunner implements ProcessRunner {
  final Map<String, RunResult> _results = {};

  /// Every command run, as `executable arg1 arg2`.
  final List<String> calls = [];

  /// Makes [executable] with [arguments] return [result].
  void when(String executable, List<String> arguments, RunResult result) {
    _results[_key(executable, arguments)] = result;
  }

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? environment,
  }) async {
    final key = _key(executable, arguments);
    calls.add(key);
    return _results[key] ?? RunResult.notStarted('not faked: $key');
  }

  static String _key(String executable, List<String> arguments) =>
      [executable, ...arguments].join(' ');
}
