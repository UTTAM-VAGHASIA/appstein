import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/doctor_support.dart';
import '../../support/temp.dart';

void main() {
  test('ok when dart on PATH belongs to the same SDK', () async {
    final sdk = tempDir();
    final bin = Directory(p.join(sdk.path, 'bin'))..createSync();
    fakeExecutable(bin, 'dart');
    final result = await const DartCheck().run(
      testContext(
        sdk: foundSdk(root: sdk.path),
        environment: fakeEnvironment({
          'PATH': bin.path,
          'PATHEXT': defaultPathExt,
        }),
      ),
    );
    expect(result.status, CheckStatus.ok);
    expect(result.summary, contains('Dart 3.13.4'));
  });

  test('info when dart on PATH is a different SDK', () async {
    final other = tempDir();
    fakeExecutable(other, 'dart');
    final result = await const DartCheck().run(
      testContext(
        sdk: foundSdk(root: tempDir().path, source: SdkSource.fvm),
        environment: fakeEnvironment({
          'PATH': other.path,
          'PATHEXT': defaultPathExt,
        }),
      ),
    );
    expect(result.status, CheckStatus.info);
    expect(result.details.single, contains('fvm dart'));
  });

  test('skipped without a Flutter SDK', () async {
    final result = await const DartCheck().run(
      testContext(sdk: const SdkDetection.failed('x', 'y')),
    );
    expect(result.status, CheckStatus.skipped);
  });
}
