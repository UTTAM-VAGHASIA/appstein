import 'package:appstein_engine/appstein_engine.dart';

/// A stand-in for the analysis server: it answers with what it was given,
/// and starts no process. The CLI's tests have a copy.
final class ScriptedCodeAnalysis implements CodeAnalysis {
  /// Creates the stand-in. It answers with [found], [pluginFailures],
  /// [notices], [analyzedFiles] and [unreadableFiles], or throws [failure]
  /// when that is set, as a server that can't answer does. [onAsked] is
  /// called at the start of every [read]. [canDartFix] answers true for the
  /// diagnostics in [fixable].
  ScriptedCodeAnalysis({
    this.found = const [],
    this.pluginFailures = const [],
    this.notices = const [],
    this.analyzedFiles = const [],
    this.unreadableFiles = const {},
    this.fixable = const {},
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

  /// The files [read] says the server analyzed, from the project root.
  List<String> analyzedFiles;

  /// The files [read] says could not be read, with why.
  Map<String, String> unreadableFiles;

  /// The diagnostics [canDartFix] says `dart fix` can fix.
  Set<CodeDiagnostic> fixable;

  /// What [read] throws instead, when set.
  CodeAnalysisException? failure;

  /// Called each time [read] is asked, before it answers.
  Future<void> Function()? onAsked;

  /// How often [read] was asked.
  int asked = 0;

  /// The diagnostics [canDartFix] was asked about, in order.
  final askedFixes = <CodeDiagnostic>[];

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
      analyzedFiles: analyzedFiles,
      unreadableFiles: unreadableFiles,
    );
  }

  /// Called each time [canDartFix] is asked, before it answers.
  Future<void> Function()? onFixAsked;

  /// What [canDartFix] throws, when set; [read] still answers.
  Object? fixFailure;

  @override
  Future<bool> canDartFix(CodeDiagnostic diagnostic) async {
    askedFixes.add(diagnostic);
    await onFixAsked?.call();
    if (failure case final failure?) throw failure;
    if (fixFailure case final failure?) throw failure;
    return fixable.contains(diagnostic);
  }
}
