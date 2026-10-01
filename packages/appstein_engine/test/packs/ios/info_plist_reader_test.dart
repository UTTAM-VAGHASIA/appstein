import 'dart:io';

import 'package:appstein_engine/src/packs/ios/info_plist_reader.dart';
import 'package:appstein_engine/src/packs/ios/plist_value.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/native_support.dart';

void main() {
  test(
    "the template's Info.plist: strings, nested dicts and arrays, lines",
    () {
      final text = File(
        p.join(nativeTemplateDir, 'ios', 'Runner', 'Info.plist.fixture'),
      ).readAsStringSync();
      final dict = readXmlPlist(text);
      final lines = text.split('\n');
      int lineOf(String needle) =>
          lines.indexWhere((line) => line.contains(needle)) + 1;

      final display = dict.entries['CFBundleDisplayName']! as PlistString;
      expect(display.value, 'Probe App');
      expect(display.line, lineOf('<string>Probe App</string>'));
      expect(
        dict.keyLines['CFBundleDisplayName'],
        lineOf('CFBundleDisplayName'),
      );
      expect(
        (dict.entries['CFBundleIdentifier']! as PlistString).value,
        r'$(PRODUCT_BUNDLE_IDENTIFIER)',
      );
      expect((dict.entries['LSRequiresIPhoneOS']! as PlistBool).value, isTrue);
      final scene = dict.entries['UIApplicationSceneManifest']! as PlistDict;
      final configurations =
          scene.entries['UISceneConfigurations']! as PlistDict;
      final roles =
          configurations.entries['UIWindowSceneSessionRoleApplication']!
              as PlistArray;
      final first = roles.items.single as PlistDict;
      final delegate =
          first.entries['UISceneDelegateClassName']! as PlistString;
      expect(delegate.value, r'$(PRODUCT_MODULE_NAME).SceneDelegate');
      expect(delegate.line, lineOf('SceneDelegate</string>'));
      expect(
        (dict.entries['UISupportedInterfaceOrientations']! as PlistArray)
            .items
            .length,
        3,
      );
    },
  );

  for (final crlf in [false, true]) {
    test('integers, dates and escaped text${crlf ? ' (CRLF)' : ''}', () {
      const sample = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Count</key>
  <integer>3</integer>
  <key>NSCameraUsageDescription</key>
  <string>Scans &amp; uploads</string>
  <key>Empty</key>
  <string/>
</dict>
</plist>
''';
      final dict = readXmlPlist(
        crlf ? sample.replaceAll('\n', '\r\n') : sample,
      );
      expect((dict.entries['Count']! as PlistOther).text, '3');
      expect((dict.entries['Count']! as PlistOther).kind, 'integer');
      expect(
        (dict.entries['NSCameraUsageDescription']! as PlistString).value,
        'Scans & uploads',
      );
      expect(dict.entries['NSCameraUsageDescription']!.line, 8);
      expect((dict.entries['Empty']! as PlistString).value, '');
    });
  }

  test('what is not a readable property list is a PlistFormatException', () {
    for (final (text, message) in [
      ('bplist00\u0000\u0001', 'binary'),
      ('<plist><dict><key>a</key></dict></plist>', 'has no value'),
      ('<plist><dict><string>a</string></dict></plist>', 'without a <key>'),
      ('<plist><array/></plist>', 'no <dict>'),
      ('<plist><dict><key>a</key><string>b</dict></plist>', 'not valid XML'),
      ('<plist><dict><key>a</key><widget/></dict></plist>', 'unexpected'),
    ]) {
      expect(
        () => readXmlPlist(text),
        throwsA(
          isA<PlistFormatException>().having(
            (e) => e.message,
            'message',
            contains(message),
          ),
        ),
        reason: text,
      );
    }
  });
}
