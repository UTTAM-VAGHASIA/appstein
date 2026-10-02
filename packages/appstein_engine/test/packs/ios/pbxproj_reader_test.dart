import 'dart:io';

import 'package:appstein_engine/src/packs/ios/pbxproj_reader.dart';
import 'package:appstein_engine/src/packs/ios/plist_value.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/native_support.dart';

void main() {
  for (final crlf in [false, true]) {
    test('the old-style format: comments, quoted and bare strings, arrays, '
        'lines${crlf ? ' (CRLF)' : ''}', () {
      const sample = r'''
// !$*UTF8*$!
{
	archiveVersion = 1;
	objects = {

/* Begin XCBuildConfiguration section */
		97C147061CF9000F007C117D /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				PRODUCT_BUNDLE_IDENTIFIER = dev.sample.probeApp;
				INFOPLIST_FILE = Runner/Info.plist;
				OTHER = "a \"quoted\" value";
				LIST = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
			};
			name = Debug;
		};
/* End XCBuildConfiguration section */
	};
	rootObject = 97C146E61CF9000F007C117D /* Project object */;
}
''';
      final root = readPbxproj(crlf ? sample.replaceAll('\n', '\r\n') : sample);
      final objects = root.entries['objects']! as PlistDict;
      final debug = objects.entries['97C147061CF9000F007C117D']! as PlistDict;
      expect(debug.line, 7);
      final settings = debug.entries['buildSettings']! as PlistDict;
      final id = settings.entries['PRODUCT_BUNDLE_IDENTIFIER']! as PlistString;
      expect(id.value, 'dev.sample.probeApp');
      expect(id.line, 10);
      expect(
        (settings.entries['INFOPLIST_FILE']! as PlistString).value,
        'Runner/Info.plist',
      );
      expect(
        (settings.entries['OTHER']! as PlistString).value,
        'a "quoted" value',
      );
      expect(
        [
          for (final item in (settings.entries['LIST']! as PlistArray).items)
            (item as PlistString).value,
        ],
        [r'$(inherited)', '@executable_path/Frameworks'],
      );
      expect(
        (root.entries['rootObject']! as PlistString).value,
        '97C146E61CF9000F007C117D',
      );
    });
  }

  test(r'\U escapes read four hex digits and nothing else', () {
    final root = readPbxproj(r'{ a = "x\U00e9y"; }');
    expect((root.entries['a']! as PlistString).value, 'xéy');
    for (final text in [
      r'{ a = "\U-001"; }',
      r'{ a = "\U+04x"; }',
      r'{ a = "\U12"; }',
      r'{ a = "\Uzzzz"; }',
    ]) {
      expect(
        () => readPbxproj(text),
        throwsA(isA<PlistFormatException>().having((e) => e.line, 'line', 1)),
        reason: text,
      );
    }
  });

  test("the template's project.pbxproj reads whole", () {
    final root = readPbxproj(
      File(
        p.join(
          nativeTemplateDir,
          'ios',
          'Runner.xcodeproj',
          'project.pbxproj.fixture',
        ),
      ).readAsStringSync(),
    );
    final objects = root.entries['objects']! as PlistDict;
    expect(objects.entries.length, greaterThan(20));
    final project =
        objects.entries[(root.entries['rootObject']! as PlistString).value]!
            as PlistDict;
    expect((project.entries['isa']! as PlistString).value, 'PBXProject');
  });

  test(
    'JSON, a missing ";" or an unclosed comment is a PlistFormatException',
    () {
      for (final (text, line) in [
        ('{"objects": {}}', 1),
        ('{\n  a = b\n}\n', 3),
        ('{\n  /* never closed\n', 2),
        ('{\n  a = "never closed;\n}\n', 2),
        ('[1, 2]', 1),
      ]) {
        expect(
          () => readPbxproj(text),
          throwsA(
            isA<PlistFormatException>().having((e) => e.line, 'line', line),
          ),
          reason: text,
        );
      }
    },
  );
}
