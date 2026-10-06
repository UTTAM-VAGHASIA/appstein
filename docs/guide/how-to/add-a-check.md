<!-- covers: none -->

# How to: add a verify check

This adds a check to `appstein verify`, or a check a decision record can name. Read [verify](../verify.md) first for how a run works.

## A verify check

1. **Decide who owns it.** A check that holds for every Flutter project goes in the engine (`packages/appstein_engine/lib/src/verify/checks/`). A check that knows one stack or one platform goes in that pack (`packages/appstein_engine/lib/src/packs/<pack>/`). The engine core never imports a pack.

2. **Choose its IDs.** An ID is `<pack or area>.<check>`, such as `docs.stale`, and is stable once released: projects name it in `suppressions:` and `verify.severity`. Check that the spec lists it (§9.2); the owner approves spec text.

3. **Write the tests first, with a passing and a failing fixture.** Every check has both (spec §16): a project where it reports nothing, and one where it reports the finding. Assert the whole finding: ID, severity, file, line, message and fix hint.
   - A check that reads the map: use `contextFor` from [`verify_support.dart`](../../../packages/appstein_engine/test/verify/support/verify_support.dart) on a copy of the fixture app, with all three packs.
   - A check that doesn't: build a `VerifyContext` over a temp folder.
   - Watch the test fail on behaviour, not only on a compile error: write the class with an empty `run` first.

4. **Implement `VerifyCheck`** ([source](../../../packages/appstein_engine/lib/src/verify/verify_check.dart)):
   - `ids`: every ID it can report. Reporting another one makes the run fail.
   - `mode`: `fast` only when it stays quick on a large project; fast verify has 5 seconds in total (spec §9.1).
   - `needsMap`: true when it reads `.appstein/map/` or the SDK facts. It is then skipped, and named as not run, while the knowledge is stale.
   - `run`: read only the `VerifyContext`. Never write a project file. Return findings in a fixed order. Throw only for a bug: a problem with the project is a finding.
   - Write each message as one true sentence about the project, and each fix hint as something the reader can do. Then run the real command and read both.

5. **Register it.** An engine check goes in `checksFor` in [`engine_checks.dart`](../../../packages/appstein_engine/lib/src/verify/engine_checks.dart). A pack's check goes in the pack's `checks`. Update the list `verify_fixture_test.dart` expects.

6. **Update the guide**: the table in [verify](../verify.md).

## A decision check

A decision check confirms that an accepted decision still holds, such as `paths.exist`.

1. Add its name to `decisionChecks` in [`decision_record.dart`](../../../packages/appstein_protocol/lib/src/decisions/decision_record.dart), so `record_decision` accepts it. Spec §6.7 lists the names; the owner approves spec text.
2. Write its tests, then implement [`DecisionCheck`](../../../packages/appstein_engine/lib/src/verify/decision_check.dart): `problems` returns one sentence per thing that no longer holds, and an empty list when the decision holds.
3. Put it in `engineDecisionChecks`, or in the pack's `decisionChecks`.

`pack_checks_test.dart` fails when a name in `decisionChecks` has no check behind it: such a name would be reported as drift on every run.
