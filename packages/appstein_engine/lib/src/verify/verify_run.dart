import 'package:appstein_protocol/appstein_protocol.dart';

import '../decisions/decision_store.dart';
import '../knowledge/knowledge_lock.dart';
import '../knowledge/knowledge_refresh.dart';
import '../knowledge/knowledge_store.dart';
import '../knowledge/knowledge_sync.dart';
import '../knowledge/knowledge_write_exception.dart';
import '../mcp/knowledge_snapshot.dart';
import '../packs/pack.dart';
import 'suppressions.dart';
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
/// 3. Holding the knowledge lock, it reads the knowledge once and runs each
///    of [checks] that [mode] selects. When the lock stays busy, it reports
///    `knowledge.stale` and runs the checks that don't need the map: files
///    are replaced whole, so reading without the lock is safe.
/// 4. It applies `verify.severity` from [config], then the suppressions.
///
/// [checks] is every check of the project, each with the pack that
/// contributed it (null for the engine's); `checksFor` builds the list.
/// [dartSdkPath] is passed to the sync, for tests.
///
/// Throws a [VerifyCheckError] when a check throws, or reports an ID it
/// doesn't declare.
Future<VerifyResult> runVerify({
  required String projectRoot,
  required AppsteinConfig config,
  required List<Pack> packs,
  required KnowledgeSync sync,
  required VerifyMode mode,
  required List<({VerifyCheck check, String? pack})> checks,
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
    final context = VerifyContext(
      projectRoot: projectRoot,
      config: config,
      packs: packs,
      knowledge: knowledge,
      decisions: readDecisions(projectRoot),
      staleProblem: stale,
      onSkipped: (part) {
        notRun[part] = CheckNotRun(id: part, reason: mapStale);
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
    );
    return VerifyResult(
      findings: sortFindings(suppressed.kept),
      suppressed: suppressed.suppressed,
      activeSuppressions: suppressed.active,
      notRun: notRun.values.toList()..sort((a, b) => a.id.compareTo(b.id)),
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
