import 'dart:async';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../analysis/code_analysis.dart';
import '../decisions/decision_store.dart';
import '../mcp/knowledge_snapshot.dart';
import '../packs/pack.dart';
import 'deprecation_ignores.dart';
import 'formatting.dart';
import 'suppression_comments.dart';
import 'test_run.dart';
import 'unverified_files.dart';

/// When a check runs (spec §9.1, §9.2).
enum VerifyMode {
  /// After every change. A fast check also runs in full mode.
  fast,

  /// When the agent says "done": every check.
  full,
}

/// What a check may read: the project, its configuration, one reading of
/// its knowledge, taken while `verify` holds the knowledge lock, so every
/// check judges the same state (spec §9), and what was gathered for the run
/// before the lock was taken ([VerifyGathering]).
final class VerifyContext {
  /// Creates the context.
  const VerifyContext({
    required this.projectRoot,
    required this.config,
    required this.packs,
    required this.knowledge,
    required this.decisions,
    this.codeReader,
    this.deprecationIgnoresReader,
    this.staleProblem,
    this.onSkipped,
    this.testsReader,
    this.onNotRun,
    this.dartFixesReader,
    this.formattingReader,
    this._unverified,
    this.mode = VerifyMode.full,
  });

  /// The run's mode: a check that runs in both reports less in a fast run,
  /// such as `dart.warning`, which reports only on the [unverified] files.
  final VerifyMode mode;

  final UnverifiedFiles? _unverified;

  /// The run's unverified files (slice 1d.2, spec §9.1), read once before
  /// the knowledge lock, with the files the run was given: a fast run
  /// reports warnings, lints and formatting only on these. Every check of
  /// the run sees the same set, which `verify` gathered with it. It doesn't
  /// need the project map. None when the context was built without them.
  UnverifiedFiles get unverified => _unverified ?? UnverifiedFiles.none;

  /// Gives [dartFixes]. `runVerify` passes one that throws when the check
  /// that is running did not gather them. Null makes [dartFixes] throw.
  final Map<CodeDiagnostic, bool> Function()? dartFixesReader;

  /// Whether `dart fix` can fix each use of a deprecated API on the
  /// [unverified] files (`CodeAnalysis.canDartFix`), as the run asked the
  /// analysis server before the knowledge lock. A diagnostic of [code] that
  /// is not a key was not asked about.
  ///
  /// Only a check that asked for it in its own [GatheringCheck.gather] may
  /// read it; for any other check it throws a [StateError], as [code] does.
  Map<CodeDiagnostic, bool> get dartFixes =>
      (dartFixesReader ??
      (throw StateError(
        'This context has no answers about dart fix. $_howToGatherFixes',
      )))();

  /// Gives [formatting]. `runVerify` passes one that throws when the check
  /// that is running did not gather it. Null makes [formatting] throw.
  final FormatReading Function()? formattingReader;

  /// Which Dart files the formatter of the project's SDK would change: the
  /// run's one question to the analysis server, asked before the knowledge
  /// lock ([VerifyGathering.formatting]). A fast run asked about the
  /// [unverified] files only, a full run about every file.
  ///
  /// Only a check that asked for it in its own [GatheringCheck.gather] may
  /// read it; for any other check it throws a [StateError], as [code] does.
  FormatReading get formatting =>
      (formattingReader ??
      (throw StateError(
        'This context has no answers about formatting. '
        '$_howToGatherFormatting',
      )))();

  /// Gives [tests]: the run's one run of the project's tests. `runVerify`
  /// passes one that throws when the check that is running did not gather
  /// it. Null makes [tests] throw.
  final TestRun Function()? testsReader;

  /// What the project's tests gave: the one test run this run made, before
  /// the knowledge lock ([VerifyGathering.tests]). Only a check that asked
  /// for it in its own [GatheringCheck.gather] may read it; for any other
  /// check it throws a [StateError], as [code] does, so a run nobody made is
  /// never taken for "no test failed".
  TestRun get tests =>
      (testsReader ??
      (throw StateError('This context has no test run. $_howToGatherTests')))();

  /// Told each check that named itself as not run ([notRun]).
  final void Function(String id, String reason)? onNotRun;

  /// Says that the check named [id] did not run, for a [reason] of its own,
  /// in words that follow the ID and a colon. `verify` names it among the
  /// checks that did not run, so nothing is skipped silently, and a
  /// suppression of it is not reported as unused. A part left out because
  /// the map can't be used is reported with [skipped] instead.
  void notRun(String id, String reason) => onNotRun?.call(id, reason);

  /// Gives [code]: the run's one reading of the code analysis. `runVerify`
  /// passes one that throws when the check that is running did not gather
  /// the reading. Null, as in a context built for a check that never reads
  /// it, makes [code] throw.
  final CodeReading Function()? codeReader;

  /// What the analyzer says about the project's code: the one reading this
  /// run took, before the knowledge lock, which every check sees. It
  /// doesn't need the project map, so a check that reads only this runs
  /// while the knowledge is stale.
  ///
  /// Only a check that asked for it in its own [GatheringCheck.gather] may
  /// read it. For any other check it throws a [StateError] that names the
  /// check, also when another check of the run gathered the reading: a
  /// check that only works beside another one would read nothing in a run
  /// that leaves the other out, and must never take a reading nobody took
  /// for "no diagnostics".
  CodeReading get code =>
      (codeReader ??
      (throw StateError(
        'This context has no reading of the code analysis. $_howToGather',
      )))();

  /// Gives [deprecationIgnores]. `runVerify` passes one that throws when
  /// the check that is running did not gather them. Null makes
  /// [deprecationIgnores] throw.
  final List<DeprecationIgnore> Function()? deprecationIgnoresReader;

  /// What tells the analyzer not to report deprecated use (the `// ignore:`
  /// comments and the `analysis_options.yaml` entries), in the files the
  /// analysis server analyzed, as this run read them before the knowledge
  /// lock.
  ///
  /// Only a check that asked for them in its own [GatheringCheck.gather]
  /// may read them; for any other check it throws a [StateError], as [code]
  /// does.
  List<DeprecationIgnore> get deprecationIgnores =>
      (deprecationIgnoresReader ??
      (throw StateError(
        'This context has no reading of the project\'s ignore comments. '
        '$_howToGatherIgnores',
      )))();

  /// Why the knowledge could not be refreshed; null when it was, or when
  /// the context was built without a refresh.
  final String? staleProblem;

  /// Told each part a check left out ([skipped]).
  final void Function(String id)? onSkipped;

  /// Why the project map can't be used; null when it can. It is set when
  /// the knowledge could not be refreshed, even if old map files are still
  /// on disk and readable, and when a map file can't be read: nothing is
  /// judged against old knowledge (spec §9).
  ///
  /// A check with `needsMap` is never run while this is set. A check that
  /// only reads the map for part of its work asks here, and reports the
  /// part it left out with [skipped].
  String? get mapProblem => staleProblem ?? knowledge.mapProblem;

  /// Says that the part of this check named [id] was left out because the
  /// map can't be used. `verify` names it among the checks that did not
  /// run, so nothing is skipped silently.
  void skipped(String id) => onSkipped?.call(id);

  /// The project's folder.
  final String projectRoot;

  /// The project's `appstein.yaml`.
  final AppsteinConfig config;

  /// The project's packs.
  final List<Pack> packs;

  /// The knowledge files of `.appstein/`, each read on first use.
  final KnowledgeSnapshot knowledge;

  /// The decision records, read by the rules of spec §6.7.
  final DecisionSet decisions;
}

/// What a run gathers before it takes the knowledge lock: the answers that
/// take long, or that come from outside `.appstein/`. Under the lock a check
/// only judges what was gathered, so other Appstein processes never wait
/// for an analysis server.
///
/// Each kind of answer is gathered once per run, however many checks ask
/// for it, so every check judges the same one. Today there are five: the
/// code analysis's reading, the comments and settings that hide deprecated
/// use, whether `dart fix` can migrate each deprecated use on the
/// [unverified] files, which Dart files the formatter would change, and the
/// project's test run. A later check with slow work of its own (the pending
/// fixes) adds it here in the same way: a method the check calls from
/// [GatheringCheck.gather], and a getter on [VerifyContext] for what it
/// found.
final class VerifyGathering {
  /// Creates the gathering of one run, which asks [codeAnalysis], reads the
  /// source files of the project at [projectRoot], and runs the project's
  /// tests with `runTests` when a check asks for them. [unverified] are the
  /// run's unverified files, and [mode] the run's mode: a fast run asks about
  /// the formatting of the unverified files only.
  VerifyGathering(
    CodeAnalysis codeAnalysis, {
    this.projectRoot,
    this._runTests,
    UnverifiedFiles? unverified,
    this.mode = VerifyMode.full,
  }) : _codeAnalysis = codeAnalysis,
       unverified = unverified ?? UnverifiedFiles.none;

  /// The run's mode.
  final VerifyMode mode;

  Future<FormatReading>? _formatAsked;
  FormatReading? _formatting;
  final _formatAskers = <VerifyCheck?>{};

  /// Which Dart files the formatter of the project's SDK would change
  /// (`CodeAnalysis.formatChanges`), after the reading [code] takes: in a
  /// fast run those of the [unverified] files, in a full run every Dart file
  /// the analysis covers. The first call asks; later calls get the same
  /// answers.
  ///
  /// - **Left out, never asked about:** a file the reading could not read (the
  ///   server read it as empty), a file that is no longer on disk (the server
  ///   lists a deleted file until it notices), a file that starts with a
  ///   `GENERATED CODE - DO NOT MODIFY` header ([lookAtDartFile]), and, since
  ///   the reading lists only what the analysis covers, a file
  ///   `analysis_options.yaml` excludes.
  /// - **The cost is capped** by [formatBudgetFast] or [formatBudgetFull],
  ///   which the analysis holds on the question itself. A file not answered
  ///   by then, and a file the server refused or that changed while it was
  ///   answered, is in [FormatReading.unchecked] with why, and the check
  ///   names itself as not run for it. A server that is alive but slow, or
  ///   that refuses one file, does not fail the run.
  /// - **A server that fails does** (the owner's decision of 2026-10-15, spec
  ///   §9.5): the `CodeAnalysisException` is passed on as it is, as it is for
  ///   the reading, so the terminal exits 3 and the tool replies with an
  ///   error. Any other error is a bug, and fails the run too.
  ///
  /// Throws a `CodeAnalysisException` when the reading can't be taken or the
  /// analysis can't answer the formatting question, and a [StateError] when
  /// the gathering was created without a project.
  Future<FormatReading> formatting() {
    _formatAskers.add(_gatheringFor);
    return _formatAsked ??= _reading().then(_askFormatting);
  }

  Future<FormatReading> _askFormatting(CodeReading reading) async {
    final root =
        projectRoot ??
        (throw StateError('This gathering was created without a project.'));
    final everywhere = mode == VerifyMode.full;
    final files = <String>[];
    for (final file in reading.analyzedFiles) {
      if (!file.endsWith('.dart') ||
          reading.unreadableFiles.containsKey(file) ||
          !(everywhere || unverified.contains(file))) {
        continue;
      }
      final looked = await lookAtDartFile(root, file);
      if (!looked.exists || looked.generated) continue;
      files.add(file);
    }
    if (files.isEmpty) return _formatting = const FormatReading();
    final budget = everywhere ? formatBudgetFull : formatBudgetFast;
    // The budget is held by the analysis (`within`), on the question itself,
    // not here around the call (see `dartFixes`). A server that fails fails
    // the run: the `CodeAnalysisException` is passed on as it is.
    final answers = await _codeAnalysis.formatChanges(files, within: budget);
    final unanswered = [
      for (final file in files)
        if (!answers.changed.containsKey(file) &&
            !answers.refused.containsKey(file))
          file,
    ];
    final refused = [
      for (final file in files)
        if (answers.refused.containsKey(file)) file,
    ];
    final why = [
      if (refused.isNotEmpty)
        'the analysis server could not answer for ${_named(refused, answers)}',
      if (unanswered.isNotEmpty)
        'the analysis server did not answer within ${_seconds(budget)} for '
            '${unanswered.length} '
            '${unanswered.length == 1 ? 'file' : 'files'}',
    ];
    return _formatting = FormatReading(
      unformatted: [
        for (final file in files)
          if (answers.changed[file] ?? false) file,
      ],
      unchecked: [
        for (final file in files)
          if (!answers.changed.containsKey(file)) file,
      ],
      checked: files.length,
      why: why.isEmpty ? null : why.join('; '),
    );
  }

  /// [files] with the reason for each, the first three in full.
  static String _named(List<String> files, FormatAnswers answers) {
    final parts = [
      for (final file in files.take(3)) '$file (${answers.refused[file]})',
    ];
    final more = files.length - parts.length;
    return parts.join(', ') + (more > 0 ? ' and $more more' : '');
  }

  static String _seconds(Duration time) =>
      '${time.inMilliseconds / 1000} s'.replaceFirst('.0 s', ' s');

  /// What [formatting] found, for [check] when it runs.
  ///
  /// Throws a [StateError] that names [check] when it did not ask for it in
  /// its own `gather`.
  FormatReading formattingFor(VerifyCheck check) {
    final found = _formatting;
    if (found == null || !_formatAskers.contains(check)) {
      throw StateError(
        'The check `${check.ids.first}` read the formatting without '
        'gathering it. $_howToGatherFormatting',
      );
    }
    return found;
  }

  /// The run's unverified files, the same set every check judges
  /// ([VerifyContext.unverified]).
  final UnverifiedFiles unverified;

  /// The reading [code] took; null when no check asked for one. What the
  /// run itself reads afterwards: which files the reading covered, and
  /// which it could not read.
  CodeReading? get reading => _code;

  Future<Map<CodeDiagnostic, bool>>? _fixesAsked;
  Map<CodeDiagnostic, bool>? _dartFixes;
  final _fixAskers = <VerifyCheck?>{};

  /// Whether `dart fix` can fix each use of a deprecated API
  /// (`isDeprecatedUseCode`) on the [unverified] files: the analysis
  /// server is asked about each (`CodeAnalysis.canDartFix`), after the
  /// reading [code] takes. Uses elsewhere are not asked about. The first
  /// call asks; later calls get the same answers.
  ///
  /// The cost is capped: once [dartFixBudget] has passed no new question is
  /// asked, and a question still unanswered then is given up. A question the
  /// analysis can't answer (a `CodeAnalysisException`: the server died
  /// after its reading, another caller replaced it, the file can't be read)
  /// stops the asking too. A use that was not answered is not a key of the
  /// result, and its finding gets the general hint, which is still true.
  /// Neither ever fails the run; any other error is a bug, and fails it.
  ///
  /// Throws a `CodeAnalysisException` when the reading itself can't be
  /// taken.
  Future<Map<CodeDiagnostic, bool>> dartFixes() {
    _fixAskers.add(_gatheringFor);
    return _fixesAsked ??= _reading().then((reading) async {
      final answers = <CodeDiagnostic, bool>{};
      final spent = Stopwatch()..start();
      for (final diagnostic in reading.diagnostics) {
        if (!isDeprecatedUseCode(diagnostic.code) ||
            !unverified.contains(diagnostic.file)) {
          continue;
        }
        final left = dartFixBudget - spent.elapsed;
        if (left <= Duration.zero) break;
        try {
          // Each question is given the time that is left (`within`), and the
          // analysis holds it on the question itself: one still unanswered
          // when it runs out is given up. It is not held here, around the
          // call: in `appstein mcp` the call also waits for the calls' turn,
          // which is another call's time and no part of the analysis's. But
          // `spent` is wall time since the first question, so a wait for the
          // turn does shorten what is left for the questions after it. That
          // costs only hints (a use not asked about gets the general one),
          // never a partial run and never a wrong answer.
          answers[diagnostic] = await _codeAnalysis.canDartFix(
            diagnostic,
            within: left,
          );
        } on CodeAnalysisException {
          // The general hint for this use and the rest; see above.
          break;
        } on TimeoutException {
          break;
        }
      }
      return _dartFixes = answers;
    });
  }

  /// The answers [dartFixes] gathered, for [check] when it runs.
  ///
  /// Throws a [StateError] that names [check] when it did not ask for them
  /// in its own `gather`.
  Map<CodeDiagnostic, bool> dartFixesFor(VerifyCheck check) {
    final found = _dartFixes;
    if (found == null || !_fixAskers.contains(check)) {
      throw StateError(
        'The check `${check.ids.first}` read the answers about dart fix '
        'without gathering them. $_howToGatherFixes',
      );
    }
    return found;
  }

  /// The project whose source files it reads; null when it was created
  /// without one, and then [deprecationIgnores] can't be asked.
  final String? projectRoot;

  final Future<TestRun> Function()? _runTests;
  Future<TestRun>? _testsAsked;
  TestRun? _tests;

  /// The run's one run of the project's tests, which can take minutes. The
  /// first call starts it; later calls get the same run. A run of `verify`
  /// in which no check calls this starts no test.
  ///
  /// Throws a `TestRunException` when the tests can't be run.
  Future<TestRun> tests() {
    _testAskers.add(_gatheringFor);
    final runTests = _runTests;
    if (runTests == null) {
      throw StateError('This gathering was given no way to run the tests.');
    }
    return _testsAsked ??= runTests().then((run) => _tests = run);
  }

  final _testAskers = <VerifyCheck?>{};

  /// The test run [tests] made, for [check] when it runs.
  ///
  /// Throws a [StateError] that names [check] when it did not ask for the
  /// test run in its own `gather`, as [codeFor] does for the reading.
  TestRun testsFor(VerifyCheck check) {
    final run = _tests;
    if (run == null || !_testAskers.contains(check)) {
      throw StateError(
        'The check `${check.ids.first}` read the test run without gathering '
        'it. $_howToGatherTests',
      );
    }
    return run;
  }

  final CodeAnalysis _codeAnalysis;
  Future<CodeReading>? _asked;
  CodeReading? _code;

  /// The run's one reading of the code analysis. The first call asks the
  /// analysis, which starts its server when none is running; later calls
  /// get the same reading. A run in which no check calls this starts no
  /// server.
  ///
  /// Throws a `CodeAnalysisException` when the analysis can't answer.
  Future<CodeReading> code() {
    _codeAskers.add(_gatheringFor);
    return _reading();
  }

  /// What the code analysis said beside its reading that the run's reader
  /// must be told (`CodeReading.notices`); empty when it was not asked.
  List<String> get notices => _code?.notices ?? const [];

  Future<CodeReading> _reading() =>
      _asked ??= _codeAnalysis.read().then((reading) => _code = reading);

  // The check whose `gather` is running, and the checks that asked for the
  // reading: `runVerify` sets the first, so the reading is given only to a
  // check that gathered it.
  VerifyCheck? _gatheringFor;
  final _codeAskers = <VerifyCheck?>{};

  /// Runs [check]'s `gather`, noting what it asks for as asked by [check].
  Future<void> gatherFor(GatheringCheck check) async {
    _gatheringFor = check;
    try {
      await check.gather(this);
    } finally {
      _gatheringFor = null;
    }
  }

  /// The reading [code] took, for [check] when it runs.
  ///
  /// Throws a [StateError] that names [check] when it did not ask for the
  /// reading in its own `gather`.
  CodeReading codeFor(VerifyCheck check) {
    final reading = _code;
    if (reading == null || !_codeAskers.contains(check)) {
      throw StateError(
        'The check `${check.ids.first}` read the code analysis without '
        'gathering it. $_howToGather',
      );
    }
    return reading;
  }

  Future<SourceComments>? _commentsAsked;
  List<DeprecationIgnore>? _deprecationIgnores;
  final _ignoreAskers = <VerifyCheck?>{};

  // One reading of the analyzed files serves both the deprecated-use comments
  // and the suppression comments: each file is read and parsed once.
  Future<SourceComments> _sourceComments() {
    final root =
        projectRoot ??
        (throw StateError('This gathering was created without a project.'));
    return _commentsAsked ??= _reading()
        .then((reading) => readSourceComments(root, reading.analyzedFiles))
        .then((found) {
          _deprecationIgnores = found.deprecation;
          return found;
        });
  }

  /// The `// appstein:ignore` and `// appstein:ignore-file` comments of the
  /// Dart files the analysis server analyzed for this run's reading, in file
  /// and line order (spec §9.7), read together with [deprecationIgnores]:
  /// each file is read and parsed once.
  ///
  /// `runVerify` calls it after every check has gathered. When no check took
  /// the reading, none is taken for this, so no analysis server is started
  /// for the comments, and the list is empty: the comments are about the
  /// findings of a run that looked at the code.
  Future<List<SuppressionComment>> suppressionComments() async {
    if (projectRoot == null || _asked == null) return const [];
    return (await _sourceComments()).suppression;
  }

  /// The `// ignore_for_file:` comments that tell the analyzer not to report
  /// deprecated use in their whole file (one naming a deprecated-use code, or
  /// saying `type=hint`), as [suppressionComments] read them. A one-line
  /// `// appstein:ignore` never hides the `dart.deprecated` finding about
  /// such a comment; only `// appstein:ignore-file` or an `appstein.yaml`
  /// entry can (spec §9.7). Empty until [suppressionComments] has read the
  /// files.
  List<DeprecationIgnore> get fileWideIgnores => [
    for (final ignore in _deprecationIgnores ?? const <DeprecationIgnore>[])
      if (ignore.forFile) ignore,
  ];

  /// What tells the analyzer not to report deprecated use: the `// ignore:`
  /// and `// ignore_for_file:` comments that name a deprecated-use
  /// diagnostic or say `type=hint`, and the `analysis_options.yaml` entries
  /// that switch one off, in the files the analysis server analyzed for
  /// this run's reading (`readDeprecationIgnores`). The first call
  /// takes the reading, as [code] does, and reads those files; later calls
  /// get the same list. The analysis server can't be asked for the
  /// comments: one that works removes the diagnostic from its reading.
  ///
  /// Throws a `CodeAnalysisException` when the analysis can't answer, and a
  /// [StateError] when the gathering was created without a project.
  Future<List<DeprecationIgnore>> deprecationIgnores() {
    _ignoreAskers.add(_gatheringFor);
    return _sourceComments().then((found) => found.deprecation);
  }

  /// The comments [deprecationIgnores] found, for [check] when it runs.
  ///
  /// Throws a [StateError] that names [check] when it did not ask for them
  /// in its own `gather`.
  List<DeprecationIgnore> deprecationIgnoresFor(VerifyCheck check) {
    final found = _deprecationIgnores;
    if (found == null || !_ignoreAskers.contains(check)) {
      throw StateError(
        'The check `${check.ids.first}` read the project\'s ignore comments '
        'without gathering them. $_howToGatherIgnores',
      );
    }
    return found;
  }
}

/// How long one run may spend asking the analysis server whether `dart fix`
/// can migrate the deprecated uses on the unverified files
/// ([VerifyGathering.dartFixes]), so the questions can't push a fast run
/// past its 5 s target (spec §9.1, §15). The answers are kept while the
/// server runs, so a later run asks only about what changed.
const dartFixBudget = Duration(seconds: 1);

const _howToGatherFixes =
    'A check that reads `context.dartFixes` implements `GatheringCheck` and '
    'calls `gathering.dartFixes()` in `gather`.';

const _howToGatherFormatting =
    'A check that reads `context.formatting` implements `GatheringCheck` and '
    'calls `gathering.formatting()` in `gather`.';

const _howToGatherIgnores =
    'A check that reads `context.deprecationIgnores` implements '
    '`GatheringCheck` and calls `gathering.deprecationIgnores()` in `gather`.';

const _howToGather =
    'A check that reads `context.code` implements `GatheringCheck` and '
    'calls `gathering.code()` in `gather`.';

const _howToGatherTests =
    'A check that reads `context.tests` implements `GatheringCheck` and '
    'calls `gathering.tests()` in `gather`.';

/// One check of `appstein verify` (spec §9). The engine has the checks that
/// hold for every project; a pack contributes its own.
abstract interface class VerifyCheck {
  /// Every finding ID it can report, which are stable once released (spec
  /// §9.3). The first names the check where checks are listed.
  List<String> get ids;

  /// [VerifyMode.fast] runs in both modes, [VerifyMode.full] only in full
  /// mode.
  VerifyMode get mode;

  /// Whether it reads the project map (`.appstein/map/`, and the SDK facts
  /// the map is built on). Such a check isn't run while the knowledge is
  /// stale, and `verify` names it as not run.
  bool get needsMap;

  /// What it finds in the project. It never writes a project file (spec
  /// §9.1). Throwing means Appstein failed, not the project.
  Future<List<Finding>> run(VerifyContext context);
}

/// A check with something to gather before the knowledge lock is taken:
/// anything slow, and anything the analysis server answers.
abstract interface class GatheringCheck implements VerifyCheck {
  /// Asks [gathering] for what [run] will judge. `runVerify` calls it once
  /// per run, after the knowledge refresh and before the lock, for each
  /// check the mode selects and the stale knowledge doesn't rule out. It
  /// never writes a project file.
  ///
  /// A `CodeAnalysisException` it lets through fails the run as the
  /// analysis server's failure; anything else it throws is this check's.
  Future<void> gather(VerifyGathering gathering);
}

/// A check that also judges what the run keeps, after `verify.severity` and
/// the suppressions were applied: a finding that depends on whether the
/// findings of another check are still there.
abstract interface class FollowingCheck implements VerifyCheck {
  /// The findings this check adds once it sees [kept], the findings that
  /// stay in the result. It is called after [VerifyCheck.run], only in a run
  /// that ran the check, and may read what [run] could read.
  ///
  /// What it returns carries IDs the check declares. `verify.severity`
  /// applies to it; a suppression does not, so a finding with a file is not
  /// hidden either. Throwing means Appstein failed, as in [run].
  List<Finding> following(VerifyContext context, List<Finding> kept);
}

/// A check threw or broke its contract: Appstein itself failed (exit `3`,
/// spec §9.5). A code analysis that can't answer is not this: `runVerify`
/// passes its `CodeAnalysisException` on as it is, since no check is to
/// blame.
final class VerifyCheckError implements Exception {
  /// Creates the error.
  VerifyCheckError(this.checkId, this.error, this.stackTrace);

  /// The first ID of the check that failed.
  final String checkId;

  /// What it threw, or a sentence about the contract it broke.
  final Object error;

  /// Where it threw.
  final StackTrace stackTrace;

  @override
  String toString() => 'The check `$checkId` failed: $error';
}
