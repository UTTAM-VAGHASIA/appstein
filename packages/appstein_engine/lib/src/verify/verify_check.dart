import 'package:appstein_protocol/appstein_protocol.dart';

import '../analysis/code_analysis.dart';
import '../decisions/decision_store.dart';
import '../mcp/knowledge_snapshot.dart';
import '../packs/pack.dart';
import 'deprecation_ignores.dart';
import 'test_run.dart';

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
  });

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
/// for it, so every check judges the same one. Today there are three: the
/// code analysis's reading, the comments and settings that hide deprecated
/// use, and the project's test run. A later check with slow work of its own
/// (a file's formatting, the pending fixes) adds it here in the same way: a
/// method the check calls from [GatheringCheck.gather], and a getter on
/// [VerifyContext] for what it found.
final class VerifyGathering {
  /// Creates the gathering of one run, which asks [codeAnalysis], reads the
  /// source files of the project at [projectRoot], and runs the project's
  /// tests with `runTests` when a check asks for them.
  VerifyGathering(CodeAnalysis codeAnalysis, {this.projectRoot, this._runTests})
    : _codeAnalysis = codeAnalysis;

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

  Future<List<DeprecationIgnore>>? _ignoresAsked;
  List<DeprecationIgnore>? _deprecationIgnores;
  final _ignoreAskers = <VerifyCheck?>{};

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
    final root =
        projectRoot ??
        (throw StateError('This gathering was created without a project.'));
    return _ignoresAsked ??= _reading()
        .then((reading) => readDeprecationIgnores(root, reading.analyzedFiles))
        .then((found) => _deprecationIgnores = found);
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
