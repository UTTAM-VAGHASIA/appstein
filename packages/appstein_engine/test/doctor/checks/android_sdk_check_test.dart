import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/temp.dart';

void main() {
  late String sdk;

  setUp(() {
    sdk = p.join(tempDir().path, 'android sdk');
    Directory(p.join(sdk, 'platform-tools')).createSync(recursive: true);
  });

  void buildTools(String version, {bool zipalign = true}) {
    final dir = Directory(p.join(sdk, 'build-tools', version))
      ..createSync(recursive: true);
    if (zipalign) {
      File(
        p.join(dir.path, Platform.isWindows ? 'zipalign.exe' : 'zipalign'),
      ).writeAsStringSync('');
    }
  }

  Future<CheckResult> run() => const AndroidSdkCheck().run(
    testContext(environment: fakeEnvironment({'ANDROID_HOME': sdk})),
  );

  test('ok with the newest stable build-tools and zipalign', () async {
    buildTools('35.0.0');
    buildTools('36.1.0');
    buildTools('37.0.0-rc2');
    final result = await run();
    expect(result.status, CheckStatus.ok);
    expect(result.summary, contains('36.1.0'));
  });

  test('warning when the newest build-tools has no zipalign', () async {
    buildTools('36.1.0', zipalign: false);
    final result = await run();
    expect(result.status, CheckStatus.warning);
    expect(result.details.join('\n'), contains('zipalign'));
  });

  test('error without build-tools', () async {
    expect((await run()).status, CheckStatus.error);
  });

  test('error without any Android SDK', () async {
    final result = await const AndroidSdkCheck().run(
      testContext(environment: fakeEnvironment({})),
    );
    expect(result.status, CheckStatus.error);
    expect(result.fixHint, contains('ANDROID_HOME'));
  });
}
