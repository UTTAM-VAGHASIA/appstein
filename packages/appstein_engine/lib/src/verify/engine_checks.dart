import '../packs/pack.dart';
import 'checks/decisions_check.dart';
import 'checks/docs_stale_check.dart';
import 'checks/lessons_long_check.dart';
import 'checks/paths_exist_check.dart';
import 'checks/test_required_check.dart';
import 'decision_check.dart';
import 'verify_check.dart';

/// The decision checks the engine provides for every project (spec §6.7).
const engineDecisionChecks = <DecisionCheck>[PathsExistCheck()];

/// Every check of a project with [packs]: the engine's, then each pack's,
/// each with the pack that contributed it (null for the engine's). This is
/// the list `runVerify` takes.
///
/// Throws a [StateError] when two checks declare the same finding ID, or two
/// decision checks have the same name: a bug in a pack, since an ID must
/// mean one thing (spec §9.3).
List<({VerifyCheck check, String? pack})> checksFor(List<Pack> packs) {
  String from(String? pack) => pack == null ? 'the engine' : 'the pack `$pack`';

  final decisionChecks = <DecisionCheck>[];
  final decisionSources = <String, String?>{};
  for (final (pack, provided) in [
    (null, engineDecisionChecks),
    for (final pack in packs) (pack.id, pack.decisionChecks),
  ]) {
    for (final check in provided) {
      if (decisionSources.containsKey(check.id)) {
        throw StateError(
          'The decision check `${check.id}` is provided twice: by '
          '${from(decisionSources[check.id])} and by ${from(pack)}.',
        );
      }
      decisionSources[check.id] = pack;
      decisionChecks.add(check);
    }
  }

  final checks = <({VerifyCheck check, String? pack})>[
    (check: const DocsStaleCheck(), pack: null),
    (check: DecisionsCheck(decisionChecks), pack: null),
    (check: const LessonsLongCheck(), pack: null),
    (check: const TestRequiredCheck(), pack: null),
    for (final pack in packs)
      for (final check in pack.checks) (check: check, pack: pack.id),
  ];
  final sources = <String, String?>{};
  for (final (:check, :pack) in checks) {
    for (final id in check.ids) {
      if (sources.containsKey(id)) {
        throw StateError(
          'The finding ID `$id` is declared twice: by ${from(sources[id])} '
          'and by ${from(pack)}.',
        );
      }
      sources[id] = pack;
    }
  }
  return checks;
}
