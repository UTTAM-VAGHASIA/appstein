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
    this.onAsked,
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

  /// Called each time [read] is asked, before it answers: a test makes the
  /// analysis slow by waiting here.
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

  /// What [pendingFixes] answers with.
  PendingFixes pending = const PendingFixes();

  @override
  Future<PendingFixes> pendingFixes({required Duration within}) async {
    if (failure case final failure?) throw failure;
    return pending;
  }

  /// What [applyFixesAndFormat] does: by default it writes nothing and
  /// answers with [applied]. A test may write files in it.
  Future<List<String>> Function(
    Future<bool> Function(String file) leaveUnformatted,
  )?
  onApply;

  /// What [applyFixesAndFormat] answers with when [onApply] is not set.
  List<String> applied = const [];

  /// How often [applyFixesAndFormat] was asked.
  int applyAsked = 0;

  /// The files [applyFixesAndFormat] says it left as they were, with why.
  Map<String, String> leftAlone = const {};

  @override
  Future<AppliedChanges> applyFixesAndFormat({
    required Future<bool> Function(String file) leaveUnformatted,
    required Duration within,
  }) async {
    applyAsked++;
    if (failure case final failure?) throw failure;
    return AppliedChanges(
      written: await onApply?.call(leaveUnformatted) ?? applied,
      leftAlone: leftAlone,
    );
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
