import '../decisions/decision_store.dart';
import 'verify_check.dart';

/// A check a decision record can name in `checks:` (spec §6.7). `verify`
/// runs it for every accepted decision that names it, and reports what no
/// longer holds as `decision.drift`.
///
/// The engine has the checks that hold for every project; a pack
/// contributes the ones that know its stack.
abstract interface class DecisionCheck {
  /// Its name in a decision file, such as `paths.exist`.
  String get id;

  /// Whether it reads the project map. Such a check isn't run while the map
  /// can't be read.
  bool get needsMap;

  /// What no longer holds for [decision], one sentence each; empty when it
  /// holds. It never writes a project file.
  List<String> problems(DecisionEntry decision, VerifyContext context);
}
