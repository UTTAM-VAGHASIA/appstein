import 'package:appstein_engine/android.dart';
import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_engine/ios.dart';
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/native_support.dart';

void main() {
  test("the template app's native.json matches the golden", () {
    final build =
        const NativeSync(
          appsteinVersion: '0.1.0-dev',
          packs: [AndroidPack(), IosPack()],
        ).build(
          nativeContext(copyNativeTemplate(), android: flutterAndroidValues()),
        );
    expect(build.report.errors, isEmpty);
    expect(build.report.sections, {'android': 'read', 'ios': 'read'});
    expectGolden('native.json', build.file!.body!);
  });
}
