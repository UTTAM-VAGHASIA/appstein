import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  const info = SdkInfo(
    flutterVersion: '3.47.5',
    dartVersion: '3.13.4',
    channel: 'stable',
    languageVersion: '3.9',
    fvmVersion: '3.47.5',
  );

  test('round-trips through JSON with the sdk.json key names', () {
    final json = info.toJson();
    expect(json, {
      'flutter': '3.47.5',
      'dart': '3.13.4',
      'channel': 'stable',
      'languageVersion': '3.9',
      'fvm': '3.47.5',
    });
    expect(SdkInfo.fromJson(json), info);
  });

  test('optional fields may be null', () {
    final json = {'flutter': '3.47.5', 'dart': '3.13.4', 'channel': 'stable'};
    final parsed = SdkInfo.fromJson(json);
    expect(parsed.languageVersion, isNull);
    expect(parsed.fvmVersion, isNull);
  });

  test('a missing required field is a FormatException', () {
    expect(
      () => SdkInfo.fromJson({'dart': '3.13.4', 'channel': 'stable'}),
      throwsA(isA<FormatException>()),
    );
  });
}
