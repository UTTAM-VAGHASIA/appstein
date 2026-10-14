import 'package:appstein_engine/appstein_engine.dart';

/// A stand-in for the analysis server: it answers with what it was given,
/// and starts no process. The CLI's tests have a copy.
final class ScriptedCodeAnalysis implements CodeAnalysis {
  /// Creates the stand-in. It answers with [found] and [pluginFailures], or
  /// throws [failure] when that is set, as a server that can't answer does.
  /// [onAsked] is called at the start of every [read].
  ScriptedCodeAnalysis({
    this.found = const [],
    this.pluginFailures = const [],
    this.notices = const [],
    this.failure,
    this.onAsked,
  });

  /// The notices [read] answers with.
  List<String> notices;

  /// The diagnostics [read] answers with. A test may replace them between
  /// asks.
  List<CodeDiagnostic> found;

  /// The plugin failures [read] answers with.
  List<String> pluginFailures;

  /// What [read] throws instead, when set.
  CodeAnalysisException? failure;

  /// Called each time [read] is asked, before it answers.
  Future<void> Function()? onAsked;

  /// How often [read] was asked.
  int asked = 0;

  /// A scope that gives every body this stand-in.
  Future<T> scope<T>(Future<T> Function(CodeAnalysis analysis) body) =>
      body(this);

  @override
  Future<CodeReading> read() async {
    asked++;
    await onAsked?.call();
    if (failure case final failure?) throw failure;
    return CodeReading(
      diagnostics: found,
      pluginFailures: pluginFailures,
      notices: notices,
    );
  }
}
