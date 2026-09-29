import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../support/fake_android.dart';
import '../support/temp.dart';

void main() {
  test('flutter config --jdk-dir wins', () {
    final location = locateFlutterJava(fakeEnvironment({'JAVA_HOME': 'jh'}), {
      'jdk-dir': 'configured',
    });
    expect(location!.source, JavaSource.flutterConfig);
    expect(location.home, 'configured');
  });

  test("Android Studio's JDK comes before JAVA_HOME", () {
    final studio = fakeStudio(tempDir());
    final location = locateFlutterJava(fakeEnvironment({'JAVA_HOME': 'jh'}), {
      'android-studio-dir': studio,
    });
    expect(location!.source, JavaSource.androidStudio);
  });

  test('then JAVA_HOME, then java on PATH', () {
    expect(
      locateFlutterJava(fakeEnvironment({'JAVA_HOME': 'jh'}), {})!.source,
      JavaSource.javaHome,
    );
    final bin = tempDir();
    fakeExecutable(bin, 'java');
    final onPath = locateFlutterJava(
      fakeEnvironment({'PATH': bin.path, 'PATHEXT': defaultPathExt}),
      {},
    );
    expect(onPath!.source, JavaSource.path);
  }, skip: studioInstalledReason());

  test('returns null when there is no JDK at all', () {
    expect(locateFlutterJava(fakeEnvironment({}), {}), isNull);
  }, skip: studioInstalledReason());

  test('parses the major version from java -version output', () {
    expect(parseJavaMajor('openjdk version "21.0.2" 2024-01-16'), 21);
    expect(parseJavaMajor('java version "1.8.0_202"'), 8);
    expect(parseJavaMajor('openjdk version "17" 2021-09-14'), 17);
    expect(parseJavaMajor('openjdk 21.0.1 2023-10-17'), 21);
    expect(parseJavaMajor('garbage'), isNull);
  });
}
