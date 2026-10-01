import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  final matcher = LayerMatcher(
    LayerRules.fromJson({
      'layers': {
        'test': ['packages/*/test/**'],
        'pack.android': ['packages/appstein_engine/lib/src/packs/android/**'],
        'engine': ['packages/appstein_engine/**'],
      },
    }),
  );

  test('the first matching tag wins', () {
    expect(
      matcher.tagFor('packages/appstein_engine/lib/src/packs/android/a.dart'),
      'pack.android',
    );
    expect(
      matcher.tagFor('packages/appstein_engine/lib/src/host/b.dart'),
      'engine',
    );
    expect(matcher.tagFor('packages/appstein_engine/test/c_test.dart'), 'test');
  });

  test('files no glob matches get no tag', () {
    expect(matcher.tagFor('tool/x.dart'), isNull);
  });
}
