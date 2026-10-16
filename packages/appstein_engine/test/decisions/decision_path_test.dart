import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

List<(String, bool)> readings(String raw) => [
  for (final reading in decisionPathReadings(raw))
    (reading.pattern, reading.valid),
];

void main() {
  group('decisionPathReadings', () {
    test('a path without a backslash has one reading', () {
      expect(readings('lib/ui/**'), [('lib/ui/**', true)]);
    });

    test('a backslash not before [ ] { } is a separator in both readings, '
        'so there is one', () {
      expect(readings(r'lib\ui\*.dart'), [('lib/ui/*.dart', true)]);
    });

    test('a backslash before [ ] { } gives an escape reading, then a '
        'separator reading', () {
      expect(readings(r'lib/a\[1\].dart'), [
        (r'lib/a\[1\].dart', true),
        ('lib/a/[1/].dart', false),
      ]);
      expect(readings(r'lib\{ui,data}\x.dart'), [
        (r'lib\{ui,data}/x.dart', false),
        ('lib/{ui,data}/x.dart', true),
      ]);
    });

    test('a leading ./ and trailing / are dropped; slashes alone stay', () {
      expect(readings('./lib/'), [('lib', true)]);
      expect(readings(r'.\lib\\'), [('lib', true)]);
      expect(readings('//'), [('//', true)]);
    });

    test('a pattern invalid in every reading says why', () {
      final reading = decisionPathReadings('lib/{a').single;
      expect(reading.valid, isFalse);
      expect(reading.problem, isNotEmpty);
    });
  });
}
