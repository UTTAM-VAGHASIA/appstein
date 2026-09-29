import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  test('edit distance counts single-character edits', () {
    expect(editDistance('kitten', 'sitting'), 3);
    expect(editDistance('', 'abc'), 3);
    expect(editDistance('same', 'same'), 0);
  });

  test('closest match suggests a likely typo and nothing for noise', () {
    const keys = ['packs', 'packages', 'delta'];
    expect(closestMatch('pakages', keys), 'packages');
    expect(closestMatch('zzzzzz', keys), isNull);
  });
}
