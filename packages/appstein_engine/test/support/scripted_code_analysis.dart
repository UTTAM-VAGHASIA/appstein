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

  /// The time each [canDartFix] was given, in order.
  final fixWithin = <Duration>[];

  @override
  Future<bool> canDartFix(
    CodeDiagnostic diagnostic, {
    required Duration within,
  }) async {
    askedFixes.add(diagnostic);
    fixWithin.add(within);
    // Like the analysis server: gives up with a `TimeoutException` when the
    // time it was given runs out.
    await Future.sync(() => onFixAsked?.call()).timeout(within);
    if (failure case final failure?) throw failure;
    if (fixFailure case final failure?) throw failure;
    return fixable.contains(diagnostic);
  }

  /// The files [formatChanges] says the formatter would change.
  Set<String> unformatted = {};

  /// The files [formatChanges] never answers about, as a server that is too
  /// slow within the time it was given.
  Set<String> formatSilent = {};

  /// Called each time [formatChanges] is asked, before it answers.
  Future<void> Function()? onFormatAsked;

  /// What [formatChanges] throws, when set; [read] still answers.
  Object? formatFailure;

  /// The files each [formatChanges] was asked about, in order.
  final askedFormats = <List<String>>[];

  /// The time each [formatChanges] was given, in order.
  final formatWithin = <Duration>[];

  /// The files [formatChanges] says the server refused to format, with why.
  Map<String, String> formatRefused = {};

  @override
  Future<FormatAnswers> formatChanges(
    List<String> files, {
    required Duration within,
  }) async {
    askedFormats.add(files);
    formatWithin.add(within);
    // Like the analysis server: when the time it was given runs out it
    // answers with nothing.
    var inTime = true;
    await Future.sync(
      () => onFormatAsked?.call(),
    ).timeout(within, onTimeout: () => inTime = false);
    if (!inTime) return const FormatAnswers();
    if (failure case final failure?) throw failure;
    if (formatFailure case final failure?) throw failure;
    return FormatAnswers(
      changed: {
        for (final file in files)
          if (!formatSilent.contains(file) && !formatRefused.containsKey(file))
            file: unformatted.contains(file),
      },
      refused: {for (final file in files) file: ?formatRefused[file]},
    );
  }
}
