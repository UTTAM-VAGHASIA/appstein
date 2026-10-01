import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../support/flutter_fixtures.dart';

void main() {
  String checks(String version) =>
      fixtureText(version, ToolchainFiles.gradlePluginChecks);

  test('reads Flutter 3.47.5', () {
    expect(parseGradlePluginChecks(checks('3.47.5')).toJson(), {
      'gradle': {'warnBelow': '9.1.0', 'errorBelow': '8.14.0'},
      'agp': {'warnBelow': '9.0.1', 'errorBelow': '8.11.1'},
      'kgp': {'warnBelow': '2.3.20', 'errorBelow': '2.2.20'},
      'java': {'warnBelow': '17', 'errorBelow': '17'},
      'minSdk': {'warnBelow': '24', 'errorBelow': '23'},
    });
  });

  test('reads Flutter 3.44.9', () {
    expect(parseGradlePluginChecks(checks('3.44.9')).toJson(), {
      'gradle': {'warnBelow': '8.14.0', 'errorBelow': '8.7.0'},
      'agp': {'warnBelow': '8.11.1', 'errorBelow': '8.6.0'},
      'kgp': {'warnBelow': '2.2.20', 'errorBelow': '2.0.0'},
      'java': {'warnBelow': '17', 'errorBelow': '17'},
      'minSdk': {'warnBelow': '24', 'errorBelow': '23'},
    });
  });

  test('reads CRLF line endings (Review Focus 1)', () {
    final lf = checks('3.47.5').replaceAll('\r\n', '\n');
    expect(
      parseGradlePluginChecks(lf.replaceAll('\n', '\r\n')).toJson(),
      parseGradlePluginChecks(lf).toJson(),
    );
  });

  test('a Java version like 1.8 keeps its dot', () {
    final text = checks('3.47.5').replaceFirst(
      'warnJavaVersion: JavaVersion = JavaVersion.VERSION_17',
      'warnJavaVersion: JavaVersion = JavaVersion.VERSION_1_8',
    );
    expect(parseGradlePluginChecks(text).java.warnBelow, '1.8');
  });

  test('a missing threshold names it', () {
    final text = checks(
      '3.47.5',
    ).replaceFirst(RegExp('val errorKGPVersion[^\n]*'), '');
    expect(
      () => parseGradlePluginChecks(text),
      throwsA(
        isA<ToolchainParseException>().having(
          (e) => e.message,
          'message',
          contains('errorKGPVersion'),
        ),
      ),
    );
  });

  test('a value of another shape is reported', () {
    final text = checks('3.47.5').replaceFirst(
      'Version = Version(9, 1, 0)',
      'Version = Version.parse("9.1.0")',
    );
    expect(
      () => parseGradlePluginChecks(text),
      throwsA(
        isA<ToolchainParseException>().having(
          (e) => e.message,
          'message',
          contains('warnGradleVersion has an unexpected value'),
        ),
      ),
    );
  });

  test('a threshold declared twice is reported', () {
    final text =
        '${checks('3.47.5')}\nval warnKGPVersion: Version = Version(1, 0, 0)\n';
    expect(
      () => parseGradlePluginChecks(text),
      throwsA(isA<ToolchainParseException>()),
    );
  });
}
