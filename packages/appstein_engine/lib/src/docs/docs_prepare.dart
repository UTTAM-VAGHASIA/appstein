import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../decisions/decision_store.dart';
import '../index/index_sources.dart';
import '../mcp/knowledge_snapshot.dart';
import '../packs/pack.dart';
import 'docs_folder.dart';
import 'docs_knowledge.dart';
import 'docs_renderer.dart';
import 'engine_pages.dart';

/// The pages a render gives now, compared with the docs folder: a
/// [DocsPlan], or why there is none ([DocsNotPrepared]).
sealed class DocsPrepared {
  const DocsPrepared();
}

/// The pages can't be rendered from all of the knowledge, or can't be
/// compared with the docs folder.
final class DocsNotPrepared extends DocsPrepared {
  /// Creates the outcome.
  const DocsNotPrepared(this.problem, {this.fixHint, this.details = const []});

  /// Why, in words that follow "because".
  final String problem;

  /// What to do about it, as a sentence; null when [problem] or [details]
  /// already say.
  final String? fixHint;

  /// More about [problem], one sentence each.
  final List<String> details;
}

/// Every rendered page, and what differs from the docs folder.
final class DocsPlan extends DocsPrepared {
  /// Creates the plan.
  const DocsPlan({
    required this.folder,
    required this.pages,
    required this.scan,
    required this.changes,
    required this.blocked,
  });

  /// The docs folder, as an absolute path.
  final String folder;

  /// Every page, as a render gives it now.
  final List<RenderedPage> pages;

  /// What is in the folder.
  final DocsFolderScan scan;

  /// Every page, sorted by path, with what bringing the folder up to date
  /// would do to it.
  final List<DocChange> changes;

  /// The files that stand where a page would be written, as sentences.
  /// While there are any, nothing may be written.
  final List<String> blocked;
}

/// Renders every page of the human docs of the project at [projectRoot]
/// from [snapshot] and [decisions], and plans the docs folder
/// `config.docs.path` (spec §6.9). It writes nothing.
///
/// `appstein docs`, `appstein docs --check` and the `docs.stale` check all
/// start here, so they can't disagree about a page (spec §9.2). The caller
/// holds the knowledge lock, or accepts a reading from between two writes.
///
/// Throws a `DocPageError` when a page source fails (a bug in Appstein or a
/// pack).
DocsPrepared prepareDocs({
  required String projectRoot,
  required AppsteinConfig config,
  required List<Pack> packs,
  required KnowledgeSnapshot snapshot,
  required DecisionSet decisions,
}) {
  final docsPath = config.docs.path;
  if (snapshot.mapProblem case final problem?) {
    return DocsNotPrepared(
      problem,
      fixHint: 'Run `appstein sync` in the project to see why.',
    );
  }

  final folder = p.joinAll([projectRoot, ...docsPath.split('/')]);
  final scan = scanDocsFolder(folder, projectRoot: projectRoot);
  if (scan.problems.isNotEmpty) {
    return scan.problems.length == 1
        ? DocsNotPrepared(scan.problems.single)
        : DocsNotPrepared(
            'the docs folder could not be read',
            details: scan.problems,
          );
  }

  final List<RenderedPage> pages;
  try {
    pages = renderPages(
      knowledge: DocsKnowledge(
        docsPath: docsPath,
        projectName: readIndexSources(projectRoot).projectName,
        platforms: platformFolders(projectRoot),
        stack: config.packs.stack,
        sdk: snapshot.sdk.value!,
        features: snapshot.features.value!,
        symbols: snapshot.symbols.value!,
        routes: snapshot.routes.value!,
        layers: snapshot.layers.value!,
        deps: snapshot.deps.value!,
        native: snapshot.native.value!,
        decisions: decisions,
        teamNotes: scan.teamNotes,
      ),
      sources: [
        engineDocSource,
        for (final pack in packs)
          (id: pack.id, version: pack.version, pages: pack.docPages),
      ],
      readme: readmeSection,
    );
  } on DocPagesCollide catch (collision) {
    return DocsNotPrepared(
      collision.problem,
      fixHint:
          'Rename one of the folders they are rendered from, so each page '
          'has its own file on every system.',
    );
  }

  final plan = planDocs(folder, scan, pages);
  return DocsPlan(
    folder: folder,
    pages: pages,
    scan: scan,
    changes: plan.changes,
    blocked: plan.blocked,
  );
}
