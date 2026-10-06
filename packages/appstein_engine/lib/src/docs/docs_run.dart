import 'package:appstein_protocol/appstein_protocol.dart';

import '../decisions/decision_store.dart';
import '../knowledge/knowledge_lock.dart';
import '../knowledge/knowledge_refresh.dart';
import '../knowledge/knowledge_store.dart';
import '../knowledge/knowledge_sync.dart';
import '../knowledge/knowledge_write_exception.dart';
import '../mcp/knowledge_snapshot.dart';
import '../packs/pack.dart';
import 'docs_folder.dart';
import 'docs_knowledge.dart';
import 'docs_prepare.dart';

/// What `appstein docs` did, or why it did nothing (spec §6.9).
sealed class DocsOutcome {
  const DocsOutcome();
}

/// `docs.enabled` is false in `appstein.yaml`: nothing ran.
final class DocsDisabled extends DocsOutcome {
  /// Creates the outcome.
  const DocsDisabled();
}

/// Nothing in the docs folder was written, removed or judged, because the
/// pages could not be rendered from all of the knowledge, or a file stands
/// where a page would be written.
final class DocsRefused extends DocsOutcome {
  /// Creates the outcome.
  const DocsRefused({
    required this.docsPath,
    required this.problem,
    this.fixHint,
    this.details = const [],
  });

  /// The docs folder from the project root, with `/`.
  final String docsPath;

  /// Why, in words that follow "because".
  final String problem;

  /// What to do about it, as a sentence; null when [problem] or [details]
  /// already say.
  final String? fixHint;

  /// More about [problem], one sentence each, such as each file in the way.
  final List<String> details;
}

/// The pages were rendered and compared with the docs folder, and, unless
/// [check], written.
final class DocsDone extends DocsOutcome {
  /// Creates the outcome.
  const DocsDone({
    required this.docsPath,
    required this.check,
    required this.changes,
    required this.teamNotes,
  });

  /// The docs folder from the project root, with `/`.
  final String docsPath;

  /// Whether this was `--check`: nothing was written.
  final bool check;

  /// Every page, sorted by path, with what was done to it, or with
  /// [check], what would be.
  final List<DocChange> changes;

  /// The team's own notes in the folder, which were left alone.
  final List<TeamNote> teamNotes;

  /// Whether any page was not what a render gives.
  bool get stale =>
      changes.any((change) => change.kind != DocChangeKind.unchanged);
}

const _runAgain = 'Then run `appstein docs` again.';

DocsRefused _lockBusy(
  DocsRefused Function(String problem, {String? fixHint}) refused,
) => refused(
  lockBusyProblem,
  fixHint: 'Run `appstein docs` again when it has finished.',
);

/// Renders the human docs of the project at [projectRoot] into the folder
/// `config.docs.path` (spec §6.9), from the pages of the engine and of
/// [packs], in order.
///
/// 1. It brings the knowledge up to date with [sync], as `appstein sync
///    --detect` does.
/// 2. If that fails, or the project map is missing, or a knowledge file
///    can't be read, it changes nothing and says why ([DocsRefused]). Pages
///    are never rendered from part of the knowledge.
/// 3. Holding the knowledge lock, it reads the knowledge, renders every
///    page, and compares them with the folder. A file without the marker
///    where a page would go also changes nothing ([DocsRefused]).
/// 4. With [check], it reports what differs. Otherwise it writes the pages
///    that differ and removes the marked pages that are no longer rendered.
///
/// [dartSdkPath] is passed to the sync, for tests.
///
/// Throws a `DocPageError` when a page source fails (a bug), and a
/// [KnowledgeWriteException] when a page can't be written or removed.
Future<DocsOutcome> runDocs({
  required String projectRoot,
  required AppsteinConfig config,
  required List<Pack> packs,
  required KnowledgeSync sync,
  required bool check,
  String? dartSdkPath,
}) async {
  if (!config.docs.enabled) return const DocsDisabled();
  final docsPath = config.docs.path;
  DocsRefused refused(
    String problem, {
    String? fixHint,
    List<String> details = const [],
  }) => DocsRefused(
    docsPath: docsPath,
    problem: problem,
    fixHint: fixHint,
    details: details,
  );

  final refresh = await refreshKnowledge(
    sync,
    projectRoot,
    dartSdkPath: dartSdkPath,
    runAgain: _runAgain,
  );
  if (refresh.problem case final problem?) {
    return problem == lockBusyProblem
        ? _lockBusy(refused)
        : refused(problem, fixHint: refresh.fixHint);
  }

  final store = KnowledgeStore(projectRoot);
  try {
    return await store.locked(() async {
      final DocsPlan plan;
      switch (prepareDocs(
        projectRoot: projectRoot,
        config: config,
        packs: packs,
        snapshot: KnowledgeSnapshot(projectRoot),
        decisions: readDecisions(projectRoot),
      )) {
        case DocsNotPrepared(:final problem, :final fixHint, :final details):
          return refused(problem, fixHint: fixHint, details: details);
        case final DocsPlan prepared:
          plan = prepared;
      }
      if (plan.blocked.isNotEmpty) {
        return refused('a file is in the way', details: plan.blocked);
      }
      if (!check) await applyDocs(plan.folder, plan.pages, plan.changes);
      return DocsDone(
        docsPath: docsPath,
        check: check,
        changes: plan.changes,
        teamNotes: plan.scan.teamNotes,
      );
    }, timeout: sync.lockTimeout);
  } on KnowledgeLockTimeout {
    return _lockBusy(refused);
  }
}
