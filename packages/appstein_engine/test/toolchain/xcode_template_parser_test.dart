import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../support/flutter_fixtures.dart';

void main() {
  String ios(String text) => parseDeploymentTarget(
    text,
    setting: 'IPHONEOS_DEPLOYMENT_TARGET',
    file: ToolchainFiles.iosTemplate,
  );
  String macos(String text) => parseDeploymentTarget(
    text,
    setting: 'MACOSX_DEPLOYMENT_TARGET',
    file: ToolchainFiles.macosTemplate,
  );

  test('reads the iOS and macOS targets of 3.47.5 and 3.44.9', () {
    expect(ios(fixtureText('3.47.5', ToolchainFiles.iosTemplate)), '15.0');
    expect(macos(fixtureText('3.47.5', ToolchainFiles.macosTemplate)), '12.0');
    expect(ios(fixtureText('3.44.9', ToolchainFiles.iosTemplate)), '13.0');
    expect(macos(fixtureText('3.44.9', ToolchainFiles.macosTemplate)), '10.15');
  });

  test('reads CRLF line endings and quoted values', () {
    expect(ios('a\r\n\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;\r\n'), '15.0');
    expect(ios('IPHONEOS_DEPLOYMENT_TARGET = "16.0";'), '16.0');
  });

  test('build configurations that disagree are reported', () {
    expect(
      () => ios(
        'IPHONEOS_DEPLOYMENT_TARGET = 15.0;\n'
        'IPHONEOS_DEPLOYMENT_TARGET = 13.0;\n',
      ),
      throwsA(
        isA<ToolchainParseException>().having(
          (e) => e.message,
          'message',
          contains('13.0, 15.0'),
        ),
      ),
    );
  });

  test('a template without the setting is reported', () {
    expect(() => ios('nothing here'), throwsA(isA<ToolchainParseException>()));
  });
}
