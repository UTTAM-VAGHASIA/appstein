import '../analysis/code_analysis.dart';
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
