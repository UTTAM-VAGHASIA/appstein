import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  test('reads the lower bound of the SDK constraint', () {
    expect(languageVersionFromPubspec('environment:\n  sdk: ^3.9.0\n'), '3.9');
    expect(
      languageVersionFromPubspec("environment:\n  sdk: '>=3.7.2 <4.0.0'\n"),
      '3.7',
    );
  });

  test('returns null when there is no lower bound or no constraint', () {
    expect(languageVersionFromPubspec('environment:\n  sdk: any\n'), isNull);
    expect(languageVersionFromPubspec('name: app\n'), isNull);
    expect(languageVersionFromPubspec('{broken'), isNull);
  });
}
