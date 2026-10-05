import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('current is just its state', () {
    expect(const FreshnessReport.current().toJson(), {'state': 'current'});
    expect(
      const FreshnessReport.current().sentence,
      'The knowledge was current.',
    );
  });

  test('rebuilt lists why and what changed, at most 20 names', () {
    final report = FreshnessReport.rebuilt(
      because: const ['lib/a.dart changed'],
      changed: [for (var i = 0; i < 25; i++) 'lib/f$i.dart'],
      mapSkipped: 'the packages could not be fetched',
    );
    final json = report.toJson();
    expect(json['state'], 'rebuilt');
    expect(json['because'], ['lib/a.dart changed']);
    expect((json['changed']! as List).length, 20);
    expect(json['moreChanged'], 5);
    expect(json['mapSkipped'], 'the packages could not be fetched');
    expect(
      report.sentence,
      'The knowledge was rebuilt first (lib/a.dart changed). The project map '
      'was skipped: the packages could not be fetched.',
    );
  });

  test('stale says the problem and the fix, each as a sentence', () {
    const report = FreshnessReport.stale(
      problem: 'No Flutter SDK was found.',
      fixHint: 'Run `appstein doctor`',
    );
    expect(report.toJson(), {
      'state': 'stale',
      'problem': 'No Flutter SDK was found.',
      'fixHint': 'Run `appstein doctor`',
    });
    expect(
      report.sentence,
      'The knowledge may be stale: No Flutter SDK was found. Run `appstein '
      'doctor`.',
    );
  });
}
