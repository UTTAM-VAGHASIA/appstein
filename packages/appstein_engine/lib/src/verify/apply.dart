import 'package:appstein_protocol/appstein_protocol.dart';

import '../analysis/code_analysis.dart';
import '../docs/docs_folder.dart';
import '../docs/docs_run.dart';
import '../knowledge/knowledge_sync.dart';
import '../packs/pack.dart';
import 'formatting.dart';

/// How long a full run may spend finding the fixes `dart fix` would apply
/// (`VerifyGathering.pendingFixes`). The passes took 17 to 19 s on the
/// 200-file app in the slice's measurement; the limit only keeps a server
/// that has stopped answering from holding the run for good. Passes not
/// finished by then make `dart.fix_pending` name itself as not run.
const fixBudgetFull = Duration(seconds: 120);

/// How long `appstein verify --apply` may spend fixing and formatting the
/// project ([applyToProject]): the time of the passes and of the formatting
/// of every file together. What is not done by then stays pending, and the
/// checks that follow report it.
const applyBudget = Duration(seconds: 180);

/// Applies the fixes `dart fix --apply` would apply to the whole project at
/// [projectRoot], then formats it as `dart format` would, generated files
/// left out (a file that starts with a `GENERATED CODE - DO NOT MODIFY`
/// header, [lookAtDartFile], and those `analysis_options.yaml` excludes,
/// which the analysis does not cover). This is what `--apply` does (slice
/// 1d.2, spec §9.2), before the knowledge is brought up to date and before
/// any check runs, so the run's reading is of the rewritten files.
///
/// It takes a reading of [analysis] first, which starts its server when none
/// runs, then asks it to rewrite the files
/// (`CodeAnalysis.applyFixesAndFormat`). Returns what it did: each file it
/// wrote, and each it left as it was with why
/// ([AppliedChanges.notices] are the lines to tell about the latter).
///
/// Throws a [CodeAnalysisException] when the analysis can't answer.
Future<AppliedChanges> applyToProject(
  CodeAnalysis analysis, {
  required String projectRoot,
}) async {
  await analysis.read();
  return analysis.applyFixesAndFormat(
    leaveUnformatted: (file) async {
      final looked = await lookAtDartFile(projectRoot, file);
      return !looked.exists || looked.generated;
    },
    within: applyBudget,
  );
}

/// Renders the human docs of the project at [projectRoot] into its docs
/// folder, as `appstein verify --apply` does after it has fixed and formatted
/// the project (slice 1d.7, spec §5.3, §9.2), and returns the pages it wrote
/// and what the run must tell.
///
/// It is `runDocs`, the code of `appstein docs`, so the pages are the ones
/// `appstein docs` would write: it brings the knowledge up to date with
/// [sync] first (so the pages are of the rewritten files), then writes the
/// pages that differ and removes the ones no longer rendered.
///
/// `written` names each page it wrote, from the project root with `/`
/// (`docs/app/routes.md`), sorted. A page that did not change, and a page it
/// removed, are not named: the list is of files to read again before they are
/// edited. It is empty when `docs.enabled` is false.
///
/// `notices` has one line for each page it wrote over a person's edit, as
/// `appstein docs` says it did (spec §6.9): no finding, but the person must
/// know their edit is gone, and a hook has nobody to tell it otherwise.
///
/// A docs run that can't be done writes nothing and returns empty lists:
/// the knowledge could not be brought up to date (the run's own
/// `knowledge.stale` says so), the lock stayed busy, or a file of a person's
/// is where a page goes. That is the project's to fix, never Appstein
/// failing; the run's `docs.stale` check names what is behind.
///
/// Throws what `runDocs` throws when Appstein itself fails: a
/// `DocPageError` when a page source has a bug, and a `KnowledgeWriteException`
/// when a page can't be written or removed. Pages written before that stay
/// written.
Future<({List<String> written, List<String> notices})> renderDocsForApply({
  required String projectRoot,
  required AppsteinConfig config,
  required List<Pack> packs,
  required KnowledgeSync sync,
  String? dartSdkPath,
}) async {
  final outcome = await runDocs(
    projectRoot: projectRoot,
    config: config,
    packs: packs,
    sync: sync,
    check: false,
    dartSdkPath: dartSdkPath,
  );
  if (outcome case DocsDone(:final docsPath, :final changes)) {
    // `changes` are sorted by path.
    final writes = [
      for (final change in changes)
        if (change.kind == DocChangeKind.write) change,
    ];
    return (
      written: [for (final change in writes) '$docsPath/${change.path}'],
      notices: [
        for (final change in writes)
          if (change.hadHandEdits)
            'Rendering the human docs overwrote hand edits in '
                '`$docsPath/${change.path}`. Keep your own text in a file '
                'without the marker line.',
      ],
    );
  }
  return (written: const <String>[], notices: const <String>[]);
}
