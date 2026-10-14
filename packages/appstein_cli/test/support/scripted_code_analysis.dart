import 'package:appstein_engine/appstein_engine.dart';

/// A stand-in for the analysis server: it answers with what it was given,
/// and starts no process. The same definition as the engine's tests have.
final class ScriptedCodeAnalysis implements CodeAnalysis {
  /// Creates the stand-in. It answers with [found], [pluginFailures] and
  /// [notices], or throws [failure] when that is set, as a server that
  /// can't answer does.
  ScriptedCodeAnalysis({
    this.found = const [],
    this.pluginFailures = const [],
    this.notices = const [],
    this.failure,
  });

  /// The diagnostics [read] answers with.
  List<CodeDiagnostic> found;

  /// The plugin failures [read] answers with.
  List<String> pluginFailures;

  /// The notices [read] answers with.
  List<String> notices;

  /// What [read] throws instead, when set.
  CodeAnalysisException? failure;

  /// How often [read] was asked.
  int asked = 0;

  /// A scope that gives every body this stand-in.
  Future<T> scope<T>(Future<T> Function(CodeAnalysis analysis) body) =>
      body(this);

  @override
  Future<CodeReading> read() async {
    asked++;
    if (failure case final failure?) throw failure;
    return CodeReading(
      diagnostics: found,
      pluginFailures: pluginFailures,
      notices: notices,
    );
  }
}
