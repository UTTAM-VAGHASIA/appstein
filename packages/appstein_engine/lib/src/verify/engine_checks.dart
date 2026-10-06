import 'checks/paths_exist_check.dart';
import 'decision_check.dart';

/// The decision checks the engine provides for every project (spec §6.7).
const engineDecisionChecks = <DecisionCheck>[PathsExistCheck()];
