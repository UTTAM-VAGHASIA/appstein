import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('every status has its name in the file, and reads back', () {
    expect(DecisionStatus.values.map((status) => status.jsonName), [
      'proposed',
      'accepted',
      'superseded',
    ]);
    for (final status in DecisionStatus.values) {
      expect(DecisionStatus.tryParse(status.jsonName), status);
    }
    expect(DecisionStatus.tryParse('nope'), isNull);
    expect(DecisionStatus.tryParse('Accepted'), isNull);
  });

  test('the built-in checks are the spec\'s two', () {
    expect(decisionChecks, ['stack.provider', 'paths.exist']);
  });

  test('a number is written with at least four digits', () {
    expect(decisionNumberText(2), '0002');
    expect(decisionNumberText(1234), '1234');
    expect(decisionNumberText(12345), '12345');
    const record = DecisionRecord(
      file: '0002-state.md',
      number: 2,
      title: 'State management',
      status: DecisionStatus.accepted,
      why: 'One stack pack keeps checks exact.',
    );
    expect(record.numberText, '0002');
    expect(record.paths, isEmpty);
    expect(record.checks, isEmpty);
    const unnumbered = DecisionRecord(
      file: 'notes.md',
      title: 'Notes',
      status: DecisionStatus.proposed,
      why: 'x',
    );
    expect(unnumbered.numberText, isNull);
  });
}
