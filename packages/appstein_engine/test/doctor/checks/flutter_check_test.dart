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

  test('an SDK that meets an unmet FVM pin says why it is used', () async {
    final result = await check(foundSdk(unmetFvmPin: '3.47.5'));
    expect(result.status, CheckStatus.ok);
    expect(
      result.details,
      contains(
        'The project pins Flutter 3.47.5 with FVM; FVM does not have it, so '
        'this matching Flutter is used.',
      ),
    );
  });

  test('a version@channel pin reads as a version on a channel', () async {
    final result = await check(foundSdk(unmetFvmPin: '3.47.5@beta'));
    expect(
      result.details,
      contains(
        'The project pins Flutter 3.47.5 on the beta channel with FVM; FVM '
        'does not have it, so this matching Flutter is used.',
      ),
    );
  });

  test('an SDK on the channel an unmet FVM pin names says why it is '
      'used', () async {
    final result = await check(foundSdk(unmetFvmPin: 'stable'));
    expect(result.status, CheckStatus.ok);
    expect(
      result.details,
      contains(
        'The project pins the Flutter stable channel with FVM; FVM does not '
        'have it, so this Flutter on that channel is used.',
      ),
    );
  });

  test("shows the SDK lookup's notes", () async {
    const note =
        'FLUTTER_ROOT is set to /nowhere, which is not a Flutter SDK, so it '
        'was ignored.';
    final result = await check(foundSdk(notes: const [note]));
    expect(result.details, contains(note));
  });

  test('a failed detection passes its problem and fix through', () async {
    final result = await check(const SdkDetection.failed('No SDK', 'Install'));
    expect(result.status, CheckStatus.error);
    expect(result.summary, 'No SDK');
    expect(result.fixHint, 'Install');
  });
}
