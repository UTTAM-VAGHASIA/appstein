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
    this.offset,
  });

  /// Where it starts in the file, in UTF-16 code units from the file's
  /// start: what [CodeAnalysis.canDartFix] asks the server about. The
  /// analysis server always gives it; null only from a test's stand-in.
  final int? offset;

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
    this.analyzedFiles = const [],
    this.unreadableFiles = const {},
  });

  /// Each Dart file of the project the analysis covers that could not be
  /// opened and read when this reading was taken (on Windows, one another
  /// program holds locked), by its path from the project root with `/`,
  /// with why. The analysis server reads such a file as empty and reports no
  /// diagnostic for it, so nothing in it was checked: a check must never
  /// take it for clean (`dart.unreadable`).
  final Map<String, String> unreadableFiles;

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

  /// Every file of the project the analyzer analyzed for this reading, with
  /// or without a diagnostic, from the project root, with `/` on every
  /// system, sorted. It includes a part file whose name doesn't end in
  /// `.dart` and the files that aren't Dart (`analysis_options.yaml`,
  /// `pubspec.yaml`), and leaves out what `analysis_options.yaml` excludes.
  ///
  /// A check that reads source files itself reads these, so it covers
  /// exactly what the analyzer covered.
  final List<String> analyzedFiles;
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

  /// Whether the analysis server offers a data-driven fix for [diagnostic]
  /// (`dart.fix.dataDriven`): a migration that the package which deprecated
  /// the API describes in its `fix_data.yaml`, the kind `dart fix` applies
  /// to a deprecated API's use. `dart fix --apply` applies it unless the
  /// package marks it for the IDE only (`bulkApply: false`), which the
  /// server's answer doesn't tell (checked with a real server). False means
  /// `dart fix` can't migrate it. [diagnostic] is one of the last [read]'s,
  /// which must have been taken first; a diagnostic without an `offset`
  /// can't be asked about and is not fixable.
  ///
  /// The question takes at most [within], counted from when it is asked of
  /// the server: the time a caller spends waiting for something else of its
  /// own (the MCP server's turn) is not part of it. When [within] runs out
  /// it throws a `TimeoutException`, and a caller says nothing about `dart
  /// fix`.
  ///
  /// Throws a [CodeAnalysisException] when the analysis can't answer; a
  /// caller then says nothing about `dart fix`.
  Future<bool> canDartFix(
    CodeDiagnostic diagnostic, {
    required Duration within,
  });

  /// Which of [files] the formatter of the project's SDK would change, as
  /// `dart format` would: the layout the project's own tools decide on,
  /// including the page width in the `formatter:` section of its
  /// `analysis_options.yaml`. Each of [files] is a Dart file from the
  /// project root, with `/` on every system, that the last [read] listed
  /// among its `CodeReading.analyzedFiles` (which must have been taken
  /// first). Nothing is written, on disk or in the server.
  ///
  /// The result says, for each file, one of three things
  /// ([FormatAnswers]): the formatter would change it or would not (a file
  /// whose source can't be parsed is answered "would not": it has no format,
  /// and its `dart.error` says why); the server refused to answer for that
  /// file, with why, or the file was not the text the last [read] saw by the
  /// time it was answered; or nothing, because [within] ran out. [within] is
  /// the time the whole question may take, counted from when it is asked of
  /// the server (as for [canDartFix]); a caller says a file that was
  /// refused or not answered was not checked, never that it is formatted.
  ///
  /// Throws a [CodeAnalysisException] when the analysis can't answer as a
  /// whole: no reading was taken from the running server, or the server
  /// failed meanwhile. That is Appstein failing (exit `3`), not a finding.
  Future<FormatAnswers> formatChanges(
    List<String> files, {
    required Duration within,
  });
}

/// How long past its `within` a question to the analysis may keep a caller
/// waiting before the caller stops waiting for it: the time a server that
/// is stuck on an earlier question is given before it is given up on.
const questionGrace = Duration(seconds: 1);

/// What `CodeAnalysis.formatChanges` found out about the files it was asked
/// about. A file is in at most one of the two maps; one in neither was not
/// answered in time.
final class FormatAnswers {
  /// Creates the answers.
  const FormatAnswers({this.changed = const {}, this.refused = const {}});

  /// The files that were answered: true when the formatter would change
  /// the file, false when it would not.
  final Map<String, bool> changed;

  /// The files the server could not answer for, with why in one line: it
  /// refused the question for that file, or the file changed (or could not be
  /// read again) while it was being answered, so the answer is not about the
  /// text the reading saw.
  final Map<String, String> refused;
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
  const CodeAnalysisException(this.reason, {this.refusalCode});

  /// Why it could not answer.
  final String reason;

  /// The server's own code for the error, when it refused one request and
  /// gave one (`FORMAT_WITH_ERRORS`); null for any other failure.
  final String? refusalCode;

  @override
  String toString() => 'The Dart analysis server could not answer: $reason.';
}
