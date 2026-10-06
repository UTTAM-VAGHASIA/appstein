import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:appstein_engine/official_mvvm.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  const packs = <Pack>[OfficialMvvmPack(), AndroidPack(), IosPack()];

  test('official_mvvm provides the decision check `stack.provider`', () {
    expect(const OfficialMvvmPack().decisionChecks.map((check) => check.id), [
      'stack.provider',
    ]);
    expect(const AndroidPack().decisionChecks, isEmpty);
    expect(const IosPack().decisionChecks, isEmpty);
  });

  test('no built-in pack adds a verify check yet', () {
    for (final pack in packs) {
      expect(pack.checks, isEmpty, reason: pack.id);
    }
  });

  test('every check `record_decision` accepts is one `verify` can run', () {
    // `decisionChecks` is what a decision file may name (spec §6.7). A name
    // with nothing behind it would be reported as drift on every run.
    final provided = {
      for (final check in engineDecisionChecks) check.id,
      for (final pack in packs)
        for (final check in pack.decisionChecks) check.id,
    };
    expect(provided, unorderedEquals(decisionChecks));
  });
}
