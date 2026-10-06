import 'package:appstein_protocol/appstein_protocol.dart';

import '../decisions/decision_store.dart';
import '../mcp/knowledge_snapshot.dart';
import '../packs/pack.dart';

/// When a check runs (spec §9.1, §9.2).
enum VerifyMode {
  /// After every change. A fast check also runs in full mode.
  fast,

  /// When the agent says "done": every check.
  full,
}

/// What a check may read: the project, its configuration and one reading of
/// its knowledge, taken while `verify` holds the knowledge lock, so every
/// check judges the same state (spec §9).
final class VerifyContext {
  /// Creates the context.
  const VerifyContext({
    required this.projectRoot,
    required this.config,
    required this.packs,
    required this.knowledge,
    required this.decisions,
  });

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

/// A check threw or broke its contract: Appstein itself failed (exit `3`,
/// spec §9.5).
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
