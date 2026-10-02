import 'package:appstein_engine/src/packs/android/manifest_reader.dart';
import 'package:test/test.dart';

void main() {
  test("the template's main manifest: the label and icon lines are the "
      "attributes' own", () {
    final facts = readManifest('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="probe_app"
        android:name="\${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <activity android:name=".MainActivity" android:exported="true"/>
    </application>
</manifest>
''');
    expect(facts.label!.value, 'probe_app');
    expect(facts.label!.line, 3);
    expect(facts.icon!.value, '@mipmap/ic_launcher');
    expect(facts.icon!.line, 5);
    expect(facts.permissions, isEmpty);
  });

  test('permissions, with their extras, under any prefix', () {
    final facts = readManifest('''
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:a="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <uses-permission a:name="android.permission.INTERNET"/>
    <uses-permission a:name="android.permission.WRITE_EXTERNAL_STORAGE"
        a:maxSdkVersion="28" />
    <uses-permission-sdk-23 a:name="android.permission.CAMERA"/>
    <uses-permission a:name="android.permission.RECORD_AUDIO" tools:node="remove"/>
    <application>
        <uses-permission a:name="not.a.real.place"/>
    </application>
</manifest>
''');
    expect(
      [for (final permission in facts.permissions) permission.name],
      [
        'android.permission.INTERNET',
        'android.permission.WRITE_EXTERNAL_STORAGE',
        'android.permission.CAMERA',
        'android.permission.RECORD_AUDIO',
      ],
    );
    expect(facts.permissions[0].line, 4);
    expect(facts.permissions[1].maxSdkVersion, '28');
    expect(facts.permissions[2].sdk23, isTrue);
    expect(facts.permissions[3].removed, isTrue);
    expect(facts.label, isNull);
    expect(facts.hasApplication, isTrue);
    expect(readManifest('<manifest/>').hasApplication, isFalse);
  });

  test('broken XML is a ManifestFormatException with the line', () {
    expect(
      () => readManifest('<manifest>\n  <application>\n</manifest>\n'),
      throwsA(isA<ManifestFormatException>().having((e) => e.line, 'line', 3)),
    );
    expect(
      () => readManifest('<manifest>\n  <a>\n  </b>\n</manifest>\n'),
      throwsA(isA<ManifestFormatException>().having((e) => e.line, 'line', 3)),
    );
    expect(
      () => readManifest('<manifest>\n  <application a="1>\n</manifest>\n'),
      throwsA(isA<ManifestFormatException>().having((e) => e.line, 'line', 2)),
    );
    expect(
      () => readManifest('\n<resources/>\n'),
      throwsA(isA<ManifestFormatException>().having((e) => e.line, 'line', 2)),
    );
  });
}
