import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  test('reads the major and minor at the start of a version', () {
    expect(flutterMinorOf('3.47.5'), (major: 3, minor: 47));
    expect(flutterMinorOf('3.48.0-0.1.pre'), (major: 3, minor: 48));
    expect(flutterMinorOf('3.44'), (major: 3, minor: 44));
    expect(flutterMinorOf('main'), isNull);
  });

  test('compares numerically, not as text', () {
    expect(
      compareFlutterMinors((major: 3, minor: 9), (major: 3, minor: 10)),
      lessThan(0),
    );
    expect(
      compareFlutterMinors((major: 4, minor: 0), (major: 3, minor: 47)),
      greaterThan(0),
    );
    expect(
      compareFlutterMinors((major: 3, minor: 47), (major: 3, minor: 47)),
      0,
    );
  });
}
