import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../../support/doctor_support.dart';

void main() {
  Future<CheckResult> check(SdkDetection sdk) =>
      const FlutterCheck().run(testContext(sdk: sdk));

  test('a supported stable SDK is ok', () async {
    final result = await check(foundSdk());
    expect(result.status, CheckStatus.ok);
    expect(result.summary, 'Flutter 3.47.5 (stable)');
  });

  test('an SDK older than the minimum is an error', () async {
    final result = await check(foundSdk(flutter: '3.41.2'));
    expect(result.status, CheckStatus.error);
    expect(result.summary, contains('older than 3.44.0'));
  });

  test('an SDK newer than Appstein knows is info', () async {
    final result = await check(foundSdk(flutter: '3.48.1'));
    expect(result.status, CheckStatus.info);
    expect(result.details.join(' '), contains('may be incomplete'));
  });

  test('a non-stable channel is a warning', () async {
    final result = await check(foundSdk(channel: 'beta'));
    expect(result.status, CheckStatus.warning);
  });

  test('a failed detection passes its problem and fix through', () async {
    final result = await check(const SdkDetection.failed('No SDK', 'Install'));
    expect(result.status, CheckStatus.error);
    expect(result.summary, 'No SDK');
    expect(result.fixHint, 'Install');
  });
}
