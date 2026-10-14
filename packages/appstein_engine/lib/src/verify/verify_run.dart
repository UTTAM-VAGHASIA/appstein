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
}) async {
  final refresh =
      refreshed ??
      await refreshKnowledge(
        sync,
        projectRoot,
        dartSdkPath: dartSdkPath,
        runAgain: _runAgain,
      );
  // Everything slow, and everything the analysis server answers, is
  // gathered here: after the refresh, which may fetch the packages the
  // analysis reads, and before the knowledge lock, which other Appstein
  // processes wait for.
  final gathering = VerifyGathering(
    codeAnalysis,
    projectRoot: projectRoot,
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

  Future<VerifyResult> body(KnowledgeRefresh refresh) async {
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
    return VerifyResult(
      findings: sortFindings([...suppressed.kept, ...following]),
      suppressed: suppressed.suppressed,
      activeSuppressions: suppressed.active,
      notRun: notRun.values.toList()..sort((a, b) => a.id.compareTo(b.id)),
      notices: gathering.notices,
    );
  }

  // The refresh already waited the whole timeout for the lock: waiting for
  // it again would double the time before the same answer.
  if (refresh.problem == lockBusyProblem) return body(refresh);
  try {
    return await KnowledgeStore(
      projectRoot,
    ).locked(() => body(refresh), timeout: sync.lockTimeout);
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
