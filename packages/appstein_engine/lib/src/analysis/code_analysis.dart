/// How serious the analyzer says a diagnostic is.
enum DiagnosticLevel {
  /// The code doesn't compile, or breaks a rule the project made an error.
  error,

  /// An analyzer warning.
  warning,

  /// An info-level diagnostic: most lints, and hints.
  info,
}

/// One diagnostic the analyzer reports for a file of the project.
final class CodeDiagnostic {
  /// Creates a diagnostic.
  const CodeDiagnostic({
    required this.file,
    required this.line,
    required this.code,
    required this.message,
    required this.level,
    this.correction,
  });

  /// The file it is in, from the project root, with `/` on every system.
  final String file;

  /// The 1-based line it starts on.
  final int line;

  /// The analyzer's own code, such as `unused_import`.
  final String code;

  /// The analyzer's message.
  final String message;

  /// How serious the analyzer says it is, after the project's
  /// `analysis_options.yaml`.
  final DiagnosticLevel level;

  /// What the analyzer suggests doing about it; null when it suggests
  /// nothing.
  final String? correction;
}

/// One reading of what the analyzer says about a project: everything in it
/// is from the same moment.
final class CodeReading {
  /// Creates a reading.
  const CodeReading({
    this.diagnostics = const [],
    this.pluginFailures = const [],
    this.notices = const [],
  });

  /// What the person or agent who runs `verify` must be told that is no
  /// finding about the project, one plain line each. Today that is one
  /// thing: a process that may be an analysis server Appstein started and
  /// could not show to be its own, so it did not end it, with the command
  /// to end it by hand. `runVerify` passes them on in the result.
  final List<String> notices;

  /// Every diagnostic `dart analyze` would show for the project, in file
  /// and line order. That includes the files the analyzer reads that aren't
  /// Dart (`analysis_options.yaml`, `pubspec.yaml`), and leaves out the
  /// `TODO` comments the analyzer notes at info level, which `dart analyze`
  /// hides too. A `TODO` the project raised to a warning or an error in
  /// `analysis_options.yaml` is included.
  final List<CodeDiagnostic> diagnostics;

  /// What the analysis server said about each analyzer plugin it could not
  /// load or run, one message each, on one line. While this isn't empty,
  /// [diagnostics] lacks that plugin's rules: "no diagnostics" then doesn't
  /// mean "no problems".
  final List<String> pluginFailures;
}

/// What `appstein verify` asks about a project's Dart code (slice 1d.2). It
/// is the only way a run reaches the analysis server, so a test can script
/// the answers.
///
/// A run asks and never starts or stops anything: whoever gave the run its
/// code analysis owns it (`CodeAnalysisScope`). Checks don't ask it at all:
/// `runVerify` takes one reading before it takes the knowledge lock and
/// hands it to every check (`VerifyGathering`).
abstract interface class CodeAnalysis {
  /// What the analyzer says about the project as its files are now. It
  /// waits until the analysis is done.
  ///
  /// Throws a [CodeAnalysisException] when the analysis can't answer.
  Future<CodeReading> read();
}

/// A code analysis that holds something its owner must stop: an analysis
/// server (`AnalysisServer`), or a test's stand-in for one. It is what
/// `KeptAnalysisServer` keeps.
abstract interface class StoppableCodeAnalysis implements CodeAnalysis {
  /// Stops what it holds, and returns when that has ended. A question
  /// asked afterwards starts it again.
  Future<void> stop();

  /// Stops it as [stop] does, for good: a question asked afterwards is
  /// refused.
  Future<void> close();
}

/// Runs [body] with the code analysis of one project, and releases what
/// that took when [body] ends, normally or with an error.
///
/// It decides how long an analysis server lives. `ownAnalysisServer` gives
/// each [body] a server of its own, which is what a terminal run does.
typedef CodeAnalysisScope =
    Future<T> Function<T>(Future<T> Function(CodeAnalysis analysis) body);

/// The code analysis could not answer: its analysis server didn't start,
/// stopped, or wasn't ready in time. That is Appstein failing (exit `3`,
/// spec §9.5), never a finding and never "no errors".
final class CodeAnalysisException implements Exception {
  /// Creates the error. [reason] completes "The Dart analysis server could
  /// not answer: " and ends without a full stop.
  const CodeAnalysisException(this.reason);

  /// Why it could not answer.
  final String reason;

  @override
  String toString() => 'The Dart analysis server could not answer: $reason.';
}
