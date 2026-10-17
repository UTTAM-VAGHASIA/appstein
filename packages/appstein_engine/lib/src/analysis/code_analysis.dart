import 'package:appstein_protocol/appstein_protocol.dart';

// The answers are data the analysis host sends too, so they live in the
// protocol (`code_reading.dart`); every user of this file still gets them
// from here.
export 'package:appstein_protocol/appstein_protocol.dart'
    show
        AppliedChanges,
        CodeDiagnostic,
        CodeReading,
        DiagnosticLevel,
        FormatAnswers,
        PendingFixes;

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

  /// The fixes `dart fix --dry-run` of the project's SDK would list for the
  /// project as the last [read] saw it (which must have been taken first):
  /// how many of each code, in each file.
  ///
  /// They are found as `dart fix` finds them, in passes: the server is asked
  /// for every fix it would apply in bulk, the fixes are applied to an
  /// overlay of each file they change, in the server's memory, and it is
  /// asked again, until a pass finds none or four passes have found fixes
  /// (`dart fix` of the pinned SDK stops there too; that is finished, not
  /// cut short). **Nothing is written to disk**, and the overlays are
  /// removed when the passes end, also when they fail or [within] runs out,
  /// so the next [read] is of the files on disk. A file of the project that
  /// is a link to a file outside it is left out, as it is from the writes of
  /// [applyFixesAndFormat].
  ///
  /// [within] is the time all the passes may take, counted from when the
  /// server is asked (as for [canDartFix]). When it runs out, or the server
  /// refuses a pass or an overlay, the answer is what the passes before
  /// found, marked incomplete with why ([PendingFixes.unfinished]).
  ///
  /// Throws a [CodeAnalysisException] when the analysis can't answer as a
  /// whole: no reading was taken from the running server, the server failed
  /// meanwhile, or it did not answer an overlay's change in time (the
  /// server is then given up, so no overlay outlives it).
  Future<PendingFixes> pendingFixes({required Duration within});

  /// Rewrites the project's files on disk as `dart fix --apply` and then
  /// `dart format` of the project's SDK would: the fixes are found in passes,
  /// as [pendingFixes] finds them, then each Dart file the last [read] listed
  /// is formatted (the fixed text where it was fixed) unless [leaveUnformatted]
  /// says it must not be (a generated file). Each file is written once, with
  /// its final text, only when that differs from the text on disk, and
  /// whole: a new file beside it takes its place.
  ///
  /// A file is left as it is, and named in [AppliedChanges.leftAlone] with
  /// why, when its text on disk is not the one the last [read] saw (or the
  /// reading could not tell which text it saw), when it isn't valid UTF-8,
  /// when it is outside the project (a link), or when it can't be written:
  /// an edit made meanwhile is never lost, and what the file needs stays
  /// pending for the checks that follow.
  ///
  /// [within] is the time the server's part may take (as for
  /// [pendingFixes]); when it runs out, what was found by then is written and
  /// the rest stays pending. Each request to the server has a limit of its
  /// own, and the server's part as a whole one too ([fixQuestionLimit]):
  /// past it the server is given up, the call fails and nothing is written.
  /// The writes come after the server's part has ended (the overlays are
  /// removed), need no server and have no limit: once they begin, the call
  /// returns what they wrote.
  ///
  /// Throws a [CodeAnalysisException] as [pendingFixes] does, only ever
  /// before anything is written. A file that can't be written is reported in
  /// [AppliedChanges.leftAlone], never thrown.
  Future<AppliedChanges> applyFixesAndFormat({
    required Future<bool> Function(String file) leaveUnformatted,
    required Duration within,
  });
}

/// The least time each request of the fix passes and of the rewrite of
/// `--apply` is given, whatever is left of the budget: a server that has
/// not answered a change of an overlay by then is taken for one that will
/// not, and is given up.
const fixRequestFloor = Duration(seconds: 5);

/// How long a caller waits for `CodeAnalysis.pendingFixes` or
/// `CodeAnalysis.applyFixesAndFormat` given [within]: the budget, an
/// overlay's change and its removal at their floor ([fixRequestFloor]),
/// and [questionGrace] for a server stuck on an earlier question.
Duration fixQuestionLimit(Duration within) =>
    within + fixRequestFloor * 2 + questionGrace;

/// [time] in seconds, as a reason says it: `120 s`, `1.5 s`.
String secondsText(Duration time) =>
    '${time.inMilliseconds / 1000} s'.replaceFirst('.0 s', ' s');

/// How long past its `within` a question to the analysis may keep a caller
/// waiting before the caller stops waiting for it: the time a server that
/// is stuck on an earlier question is given before it is given up on.
const questionGrace = Duration(seconds: 1);

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
