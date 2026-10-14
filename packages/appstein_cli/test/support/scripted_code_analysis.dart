import 'package:appstein_engine/appstein_engine.dart';

/// A stand-in for the analysis server: it answers with what it was given,
/// and starts no process. The same definition as the engine's tests have.
final class ScriptedCodeAnalysis implements CodeAnalysis {
  /// Creates the stand-in. It answers with [found], [pluginFailures],
  /// [notices], [analyzedFiles] and [unreadableFiles], or throws [failure]
  /// when that is set, as a server that can't answer does. [canDartFix]
  /// answers true for the diagnostics in [fixable].
  ScriptedCodeAnalysis({
    this.found = const [],
    this.pluginFailures = const [],
    this.notices = const [],
    this.analyzedFiles = const [],
    this.unreadableFiles = const {},
    this.fixable = const {},
    this.failure,
  });

  /// The diagnostics [read] answers with.
  List<CodeDiagnostic> found;

  /// The plugin failures [read] answers with.
  List<String> pluginFailures;

  /// The notices [read] answers with.
  List<String> notices;

  /// The files [read] says the server analyzed, from the project root.
  List<String> analyzedFiles;

  /// The files [read] says could not be read, with why.
  Map<String, String> unreadableFiles;

  /// The diagnostics [canDartFix] says `dart fix` can fix.
  Set<CodeDiagnostic> fixable;

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
      analyzedFiles: analyzedFiles,
      unreadableFiles: unreadableFiles,
    );
  }

  @override
  Future<bool> canDartFix(
    CodeDiagnostic diagnostic, {
    required Duration within,
  }) async {
    if (failure case final failure?) throw failure;
    return fixable.contains(diagnostic);
  }

  /// The files [formatChanges] says the formatter would change.
  Set<String> unformatted = {};

  /// What [formatChanges] throws, when set; [read] still answers.
  CodeAnalysisException? formatFailure;

  @override
  Future<FormatAnswers> formatChanges(
    List<String> files, {
    required Duration within,
  }) async {
    if (failure case final failure?) throw failure;
    if (formatFailure case final failure?) throw failure;
    return FormatAnswers(
      changed: {for (final file in files) file: unformatted.contains(file)},
    );
  }
}
