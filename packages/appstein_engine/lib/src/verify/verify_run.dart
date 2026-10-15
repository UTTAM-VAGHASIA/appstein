import 'package:appstein_protocol/appstein_protocol.dart';

import '../analysis/code_analysis.dart';
import '../decisions/decision_store.dart';
import '../knowledge/knowledge_lock.dart';
import '../knowledge/knowledge_refresh.dart';
import '../knowledge/knowledge_store.dart';
import '../knowledge/knowledge_sync.dart';
import '../knowledge/knowledge_write_exception.dart';
import '../mcp/knowledge_snapshot.dart';
import '../packs/pack.dart';
import 'checks/dart_deprecated_check.dart';
import 'suppressions.dart';
import 'test_run.dart';
import 'unverified_files.dart';
import 'verify_check.dart';

/// The findings no suppression hides and no `verify.severity` override
/// changes (spec §9.7), so no line in `appstein.yaml` can make them quiet.
const unsuppressibleIds = {
  'knowledge.stale',
  'suppression.no_reason',
  'suppression.unknown_check',
  'suppression.unused',
};

const _runAgain = 'Then run `appstein verify` again.';

/// Writes the unverified files this run leaves in `state.json`, under the
/// knowledge lock the caller holds (slice 1d.2, spec §9.1):
/// - the run's [added] files (`--files`) join them;
/// - a file of the run's [unverified] set on which the run [reported] no
///   error leaves them: an error hidden by a suppression, or lowered by
///   `verify.severity`, counts as none. That is judged only when the run
///   took a [reading] of the code analysis: a run whose Dart checks didn't
///   run verified no file;
/// - a file the reading could not read joins them and never leaves;
/// - **a partial run lets no file leave** ([partial], the owner's decision
///   of 2026-10-14): one that reports `dart.plugin_failed` or
///   `knowledge.stale`, or in which a `dart.*` check was named as not run.
///   Tests not run don't make a run partial.
///
/// A `state.json` that can't be read or written is left as it is: the files
/// stay unverified, which only makes a later run report more. Returns false
/// when that left [added] files out.
Future<bool> _settleUnverified(
  KnowledgeStore store, {
  required List<Finding> reported,
  required CodeReading? reading,
  required UnverifiedFiles unverified,
  required List<String> added,
  required Map<String, String>? hashesAtStart,
  required bool partial,
}) async {
  final now = store.readState().state;
  if (now == null) return added.isEmpty;
  final withErrors = UnverifiedFiles([
    for (final finding in reported)
      if (finding.severity == Severity.error) ?finding.file,
  ]);
  final next = unverifiedAfterVerify(
    now,
    added: added,
    unreadable: reading?.unreadableFiles.keys ?? const [],
    verified: reading == null || partial
        ? const []
        : [
            for (final file in unverified.files)
              if (!withErrors.contains(file)) file,
          ],
    hashesAtStart: hashesAtStart,
  );
  if (next == null) return true;
  try {
    await store.writeState(now.copyWith(unverified: next));
    return true;
  } on KnowledgeWriteException {
    // Left as they were; see above.
    return added.isEmpty;
  }
}

/// The check IDs of the analyzer's code checks (slice 1d.2): a run in which
/// one of them was named as not run checked the code only in part, so no
/// file leaves the unverified files. Tests not run (`test.failed`, while the
/// code has an analyzer error) don't count: the owner's decision of
/// 2026-10-14, after the second review.
bool _isCodeCheck(String id) => id.startsWith('dart.');

/// What the run tells when the files it was given could not be kept for
/// later runs (`state.json` was not written).
const _filesNotKept =
    'The files given to this run (`--files`, or the tool\'s `files`) were '
    'checked in it, but not kept among the unverified files for later runs: '
    'another Appstein process held the knowledge lock, or `state.json` could '
    'not be written. Give them again with the next fast run.';

String _sentence(String text) => text.endsWith('.') ? text : '$text.';

/// Runs `appstein verify` on the project at [projectRoot] (spec §9).
///
/// 1. It brings the knowledge up to date with [sync], as `appstein sync
///    --detect` does, unless the caller did and passes the result as
///    [refreshed] (the MCP server does, spec §8).
/// 2. When that failed, or a file of the project map can't be read, it
///    reports `knowledge.stale` as an error. Checks that need the map are
///    not run and are named in [VerifyResult.notRun].
/// 3. Before it takes the knowledge lock, it lets each selected
///    [GatheringCheck] gather what it will judge ([VerifyGathering]). The
///    code analysis is asked here, at most once, and never under the lock.
///    The project's tests run here too, once, when a check asks for them,
///    with [sync]'s process runner on the Flutter SDK [sync] finds, for at
///    most `verify.test_timeout_seconds`.
/// 4. Holding the knowledge lock, it reads the knowledge once and runs each
///    of [checks] that [mode] selects. When the lock stays busy, it reports
///    `knowledge.stale` and runs the checks that don't need the map: files
///    are replaced whole, so reading without the lock is safe.
/// 5. It applies `verify.severity` from [config], then the suppressions: the
///    `suppressions:` entries of [config] and the `// appstein:ignore`
///    comments of the Dart files the code analysis covered, which are read
///    before the lock, with the deprecated-use comments, when a check took
///    the analysis's reading (`VerifyGathering.suppressionComments`).
/// 6. It asks each [FollowingCheck] that ran for what it adds now that it is
///    known which findings stay, and applies `verify.severity` to those.
/// 7. Still holding the lock, it writes the unverified files the run leaves
///    to `state.json` (slice 1d.2): [files] join them, a file of the run's
///    set with no error in the result leaves them, and a file that could not
///    be read stays (`unverifiedAfterVerify`).
///
/// The unverified files are read once, after the refresh and before
/// anything is gathered, with [files] added: paths from the project root
/// with `/`, as `resolveVerifyFiles` gives them (`--files`, or the tool's
/// `files`). That one set is what is gathered for and what the checks judge
/// (`VerifyContext.unverified`).
///
/// [checks] is every check of the project, each with the pack that
/// contributed it (null for the engine's); `checksFor` builds the list.
/// [codeAnalysis] answers the code checks. The caller owns it: a terminal
/// run gives a server of its own and stops it afterwards
/// (`ownAnalysisServer`). It is not asked, so no server is started, when no
/// selected check gathers its reading. [dartSdkPath] is passed to the sync,
/// for tests.
///
/// Throws a [VerifyCheckError] when a check throws, or reports an ID it
/// doesn't declare, a [CodeAnalysisException] when the code analysis can't
/// answer, and a [TestRunException] when the project's tests can't be run.
/// None is a finding: Appstein failed (spec §9.5).
Future<VerifyResult> runVerify({
  required String projectRoot,
  required AppsteinConfig config,
  required List<Pack> packs,
  required KnowledgeSync sync,
  required VerifyMode mode,
  required List<({VerifyCheck check, String? pack})> checks,
  required CodeAnalysis codeAnalysis,
  KnowledgeRefresh? refreshed,
  String? dartSdkPath,
  List<String> files = const [],
}) async {
  final refresh =
      refreshed ??
      await refreshKnowledge(
        sync,
        projectRoot,
        dartSdkPath: dartSdkPath,
        runAgain: _runAgain,
      );
  // The unverified files, read once, after the refresh that adds to them
  // and before the lock: the same set for what is gathered and what is
  // judged. Files are replaced whole, so reading without the lock is safe.
  final store = KnowledgeStore(projectRoot);
  final atStart = store.readState().state;
  final unverified = UnverifiedFiles([...?atStart?.unverified, ...files]);
  // Everything slow, and everything the analysis server answers, is
  // gathered here: after the refresh, which may fetch the packages the
  // analysis reads, and before the knowledge lock, which other Appstein
  // processes wait for.
  final gathering = VerifyGathering(
    codeAnalysis,
    projectRoot: projectRoot,
    unverified: unverified,
    mode: mode,
    // With the sync's machine and process runner, so the tests run on the
    // Flutter SDK the knowledge was built for.
    runTests: () => runProjectTests(
      projectRoot: projectRoot,
      environment: sync.environment,
      runner: sync.runner,
      timeout: Duration(seconds: config.verify.testTimeoutSeconds),
    ),
  );
  for (final (:check, pack: _) in checks) {
    if (check is! GatheringCheck) continue;
    if (mode == VerifyMode.fast && check.mode != VerifyMode.fast) continue;
    // It will not run: `knowledge.stale` is reported and it is named.
    if (check.needsMap && !refresh.ok) continue;
    try {
      await gathering.gatherFor(check);
    } on CodeAnalysisException {
      // The analysis server failed, not the check that asked it.
      rethrow;
    } on TestRunException {
      // The tests could not be run at all: no check's failure either.
      rethrow;
    } on Object catch (error, stackTrace) {
      throw VerifyCheckError(check.ids.first, error, stackTrace);
    }
  }

  // The `// appstein:ignore` comments of the files the analysis covered, read
  // with the deprecated-use comments, before the lock too.
  final comments = await gathering.suppressionComments();
  // The findings `dart.deprecated` reports about the `// ignore_for_file:`
  // comments, which a one-line comment does not hide: by file, line and
  // message, so a diagnostic on the same line is not among them.
  final fileWide = {
    for (final ignore in gathering.fileWideIgnores)
      (ignore.file, ignore.line, deprecatedIgnoreMessage(ignore)),
  };

  Future<VerifyResult> body(
    KnowledgeRefresh refresh, {
    bool locked = false,
  }) async {
    final knowledge = KnowledgeSnapshot(projectRoot);
    var stale = refresh.problem;
    var staleFix = refresh.fixHint;
    if (stale == null) {
      if (knowledge.mapProblem case final problem?) {
        stale = problem;
        staleFix = 'Run `appstein sync` in the project to see why.';
      }
    }

    final findings = <Finding>[
      if (stale != null)
        Finding(
          id: 'knowledge.stale',
          severity: Severity.error,
          message:
              'The knowledge could not be brought up to date: '
              '${_sentence(stale)}',
          fixHint: staleFix,
          knowledgeRef: '.appstein/state.json',
        ),
    ];
    const mapStale = 'the project map is not up to date';
    // By ID, so a part two decisions name is listed once.
    final notRun = <String, CheckNotRun>{};
    // The IDs whose findings may be missing, because their check, or a part
    // of it, did not run: a suppression of one is not "unused".
    final incomplete = <String>{};
    var running = const <String>[];
    late VerifyCheck runningCheck;
    final context = VerifyContext(
      projectRoot: projectRoot,
      config: config,
      packs: packs,
      knowledge: knowledge,
      decisions: readDecisions(projectRoot),
      // Only for the check that gathered it, and by name when it didn't.
      codeReader: () => gathering.codeFor(runningCheck),
      deprecationIgnoresReader: () =>
          gathering.deprecationIgnoresFor(runningCheck),
      staleProblem: stale,
      onSkipped: (part) {
        notRun[part] = CheckNotRun(id: part, reason: mapStale);
        incomplete.addAll(running);
      },
      testsReader: () => gathering.testsFor(runningCheck),
      onNotRun: (id, reason) {
        notRun[id] = CheckNotRun(id: id, reason: reason);
        incomplete.addAll(running);
      },
      dartFixesReader: () => gathering.dartFixesFor(runningCheck),
      formattingReader: () => gathering.formattingFor(runningCheck),
      pendingFixesReader: () => gathering.pendingFixesFor(runningCheck),
      unverified: unverified,
      mode: mode,
    );
    for (final (:check, :pack) in checks) {
      if (mode == VerifyMode.fast && check.mode != VerifyMode.fast) continue;
      final id = check.ids.first;
      if (check.needsMap && stale != null) {
        notRun[id] = CheckNotRun(id: id, reason: mapStale);
        incomplete.addAll(check.ids);
        continue;
      }
      running = check.ids;
      runningCheck = check;
      final List<Finding> found;
      try {
        found = await check.run(context);
      } on Object catch (error, stackTrace) {
        throw VerifyCheckError(id, error, stackTrace);
      }
      for (final finding in found) {
        if (!check.ids.contains(finding.id)) {
          throw VerifyCheckError(
            id,
            'it reported `${finding.id}`, which it does not declare.',
            StackTrace.current,
          );
        }
        findings.add(
          finding.pack == null && pack != null
              ? finding.withPack(pack)
              : finding,
        );
      }
    }

    final overridden = [
      for (final finding in findings)
        switch (config.verify.severity[finding.id]) {
          final severity? when !unsuppressibleIds.contains(finding.id) =>
            finding.withSeverity(severity),
          _ => finding,
        },
    ];
    final suppressed = applySuppressions(
      overridden,
      config.suppressions,
      knownIds: {
        for (final (:check, pack: _) in checks) ...check.ids,
        ...unsuppressibleIds,
      },
      mode: mode,
      notRunIds: incomplete,
      comments: comments,
      fileWideIgnores: fileWide,
    );
    // What a check adds once it sees the findings that stay: judged after
    // the suppressions, since they decide what stays. `verify.severity`
    // applies to it; a suppression does not.
    final following = <Finding>[];
    for (final (:check, :pack) in checks) {
      if (check is! FollowingCheck) continue;
      if (mode == VerifyMode.fast && check.mode != VerifyMode.fast) continue;
      if (check.needsMap && stale != null) continue;
      running = check.ids;
      runningCheck = check;
      final List<Finding> found;
      try {
        found = check.following(context, suppressed.kept);
      } on Object catch (error, stackTrace) {
        throw VerifyCheckError(check.ids.first, error, stackTrace);
      }
      for (final finding in found) {
        if (!check.ids.contains(finding.id)) {
          throw VerifyCheckError(
            check.ids.first,
            'it reported `${finding.id}`, which it does not declare.',
            StackTrace.current,
          );
        }
        final withPack = finding.pack == null && pack != null
            ? finding.withPack(pack)
            : finding;
        following.add(switch (config.verify.severity[finding.id]) {
          final severity? when !unsuppressibleIds.contains(finding.id) =>
            withPack.withSeverity(severity),
          _ => withPack,
        });
      }
    }
    final reported = [...suppressed.kept, ...following];
    // Reported before the suppressions, which can't hide either of them.
    final partial =
        overridden.any(
          (finding) =>
              finding.id == 'knowledge.stale' ||
              finding.id == 'dart.plugin_failed',
        ) ||
        notRun.keys.any(_isCodeCheck);
    final kept = locked
        ? await _settleUnverified(
            store,
            reported: reported,
            reading: gathering.reading,
            unverified: unverified,
            added: files,
            hashesAtStart: atStart?.dartFiles,
            partial: partial,
          )
        : files.isEmpty;
    return VerifyResult(
      findings: sortFindings(reported),
      suppressed: suppressed.suppressed,
      activeSuppressions: suppressed.active,
      notRun: notRun.values.toList()..sort((a, b) => a.id.compareTo(b.id)),
      notices: [...gathering.notices, if (!kept) _filesNotKept],
    );
  }

  // The refresh already waited the whole timeout for the lock: waiting for
  // it again would double the time before the same answer.
  if (refresh.problem == lockBusyProblem) return body(refresh);
  try {
    return await store.locked(
      () => body(refresh, locked: true),
      timeout: sync.lockTimeout,
    );
  } on KnowledgeWriteException catch (error) {
    // `.appstein` can't be created or opened (it is a file, or the folder
    // is read-only). That is the project's to fix, so it is a finding, and
    // the checks that need no map still run.
    return body(
      refresh.ok
          ? KnowledgeRefresh.failed(
              '$error',
              fixHint: 'Fix that, then run `appstein verify` again.',
            )
          : refresh,
    );
  } on KnowledgeLockTimeout {
    return body(
      refresh.ok
          ? const KnowledgeRefresh.failed(
              lockBusyProblem,
              fixHint: 'Run `appstein verify` again when it has finished.',
            )
          : refresh,
    );
  }
}
