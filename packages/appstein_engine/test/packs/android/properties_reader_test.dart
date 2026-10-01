import 'package:appstein_engine/src/packs/android/properties_reader.dart';
import 'package:test/test.dart';

void main() {
  test("the template's gradle.properties", () {
    final entries = readProperties(
      'org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G\n'
      'android.useAndroidX=true\n'
      '# This newDsl flag was added by the Flutter template\n'
      'android.newDsl=false\n'
      '# This builtInKotlin flag was added by the Flutter template\n'
      'android.builtInKotlin=false\n',
    );
    expect(entries.keys, [
      'org.gradle.jvmargs',
      'android.useAndroidX',
      'android.newDsl',
      'android.builtInKotlin',
    ]);
    expect(entries['android.newDsl']!.value, 'false');
    expect(entries['android.newDsl']!.line, 4);
    expect(entries['android.builtInKotlin']!.line, 6);
  });

  test("the wrapper's escaped URL", () {
    final entries = readProperties(
      'distributionBase=GRADLE_USER_HOME\r\n'
      r'distributionUrl=https\://services.gradle.org/distributions/gradle-9.3.1-all.zip'
      '\r\n',
    );
    expect(
      entries['distributionUrl']!.value,
      'https://services.gradle.org/distributions/gradle-9.3.1-all.zip',
    );
    expect(entries['distributionUrl']!.line, 2);
  });

  test("Java's separators, comments, continuations and escapes", () {
    final entries = readProperties(
      '! a comment\n'
      '  spaced = value with spaces  \n'
      'colon:value\n'
      'blank value\n'
      'empty=\n'
      'long=first \\\n'
      '     second\n'
      r'unicode=café'
      '\n'
      r'key\ with\ space=1'
      '\n',
    );
    expect(entries['spaced']!.value, 'value with spaces  ');
    expect(entries['spaced']!.line, 2);
    expect(entries['colon']!.value, 'value');
    expect(entries['blank']!.value, 'value');
    expect(entries['empty']!.value, '');
    expect(entries['long']!.value, 'first second');
    expect(entries['long']!.line, 6);
    expect(entries['unicode']!.value, 'café');
    expect(entries['key with space']!.value, '1');
  });

  test('a key set twice keeps its last value, as in Java', () {
    final entries = readProperties('a=1\nb=2\na=3\n');
    expect(entries['a']!.value, '3');
    expect(entries['a']!.line, 3);
  });
}
