import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../support/flutter_fixtures.dart';

void main() {
  String gradleUtils(String version) =>
      fixtureText(version, ToolchainFiles.gradleUtils);

  test('reads Flutter 3.47.5', () {
    final facts = parseGradleUtils(gradleUtils('3.47.5'));
    expect(facts.template.toJson(), {
      'gradle': '9.3.1',
      'agp': '9.1.0',
      'kgp': '2.4.0',
      'ndk': '28.2.13676358',
      'compileSdk': 36,
      'targetSdk': 36,
      'minSdk': 24,
    });
    expect(facts.flutterMinimums.toJson(), {
      'compileSdk': 36,
      'buildTools': '28.0.3',
      'java': {'warnBelow': '17.0.0', 'errorBelow': '17.0.0'},
    });
    expect(facts.maxKnown.toJson(), {
      'gradle': '9.3.1',
      'kgp': '2.4.0',
      'agp': '9.2',
      'agpWithFullKotlinSupport': '9.1.0',
    });
    expect(facts.javaGradle, hasLength(18));
    expect(facts.javaGradle.first.toJson(), {
      'javaMin': '25',
      'javaMax': '26',
      'gradleMin': '9.1.0',
      'gradleMax': null,
    });
    // `gradleMax: maxGradleVersionForJavaPre17` resolves to its value.
    expect(facts.javaGradle[9].toJson(), {
      'javaMin': '16',
      'javaMax': '17',
      'gradleMin': '7.0',
      'gradleMax': '8.14.100',
    });
    expect(facts.javaGradle.last.toJson(), {
      'javaMin': '1.8',
      'javaMax': '1.9',
      'gradleMin': '2.0',
      'gradleMax': '8.14.100',
    });
    expect(
      [for (final row in facts.javaAgp) row.toJson()],
      [
        {
          'javaMin': '17',
          'javaDefault': '17',
          'agpMin': '8.0',
          'agpMax': '9.2',
        },
        {
          'javaMin': '11',
          'javaDefault': '11',
          'agpMin': '7.0',
          'agpMax': '7.4',
        },
        {
          'javaMin': '1.8',
          'javaDefault': '1.8',
          'agpMin': '4.2',
          'agpMax': '4.2',
        },
      ],
    );
  });

  test('reads Flutter 3.44.9', () {
    final facts = parseGradleUtils(gradleUtils('3.44.9'));
    expect(facts.template.toJson(), {
      'gradle': '9.1.0',
      'agp': '9.0.1',
      'kgp': '2.3.20',
      'ndk': '28.2.13676358',
      'compileSdk': 36,
      'targetSdk': 36,
      'minSdk': 24,
    });
    expect(facts.maxKnown.toJson(), {
      'gradle': '9.3.1',
      'kgp': '2.3.20',
      'agp': '9.1',
      'agpWithFullKotlinSupport': '9.0.1',
    });
    expect(facts.javaGradle, hasLength(18));
    expect(facts.javaAgp.first.agpMax, '9.1');
  });

  test('reads CRLF line endings as it reads LF (Review Focus 1)', () {
    final text = gradleUtils('3.47.5');
    final crlf = text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
    final lf = parseGradleUtils(text.replaceAll('\r\n', '\n'));
    final fromCrlf = parseGradleUtils(crlf);
    expect(fromCrlf.template.toJson(), lf.template.toJson());
    expect(
      [for (final row in fromCrlf.javaGradle) row.toJson()],
      [for (final row in lf.javaGradle) row.toJson()],
    );
  });

  test('a missing declaration names it', () {
    final text = gradleUtils(
      '3.47.5',
    ).replaceFirst(RegExp(r"const ndkVersion = '[^']*';"), '');
    expect(
      () => parseGradleUtils(text),
      throwsA(
        isA<ToolchainParseException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('gradle_utils.dart'), contains('ndkVersion')),
        ),
      ),
    );
  });

  test('a value of another shape is reported, not guessed', () {
    final text = gradleUtils('3.47.5').replaceFirst(
      "const templateDefaultGradleVersion = '9.3.1';",
      "const templateDefaultGradleVersion = gradleFor('9');",
    );
    expect(
      () => parseGradleUtils(text),
      throwsA(
        isA<ToolchainParseException>().having(
          (e) => e.message,
          'message',
          contains('templateDefaultGradleVersion has an unexpected value'),
        ),
      ),
    );
  });

  test('a list entry of another shape is reported', () {
    final text = gradleUtils(
      '3.47.5',
    ).replaceFirst('JavaAgpCompat(javaMin:', 'const JavaAgpCompat(javaMin:');
    expect(
      () => parseGradleUtils(text),
      throwsA(isA<ToolchainParseException>()),
    );
  });
}
