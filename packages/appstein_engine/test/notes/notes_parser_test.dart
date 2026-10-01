import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

const _head = 'flutter: "3.47"\nreleased: 2026-08-12\ndart: "3.13"\n';

const _toolchain = '''
toolchain:
  android:
    template: {gradle: "9.3.1", agp: "9.1.0", kgp: "2.4.0", ndk: "28.2.13676358", compileSdk: 36, targetSdk: 36, minSdk: 24}
    flutterMinimums: {compileSdk: 36, buildTools: "28.0.3", java: {warnBelow: "17.0.0", errorBelow: "17.0.0"}}
    buildChecks:
      gradle: {warnBelow: "9.1.0", errorBelow: "8.14.0"}
      agp: {warnBelow: "9.0.1", errorBelow: "8.11.1"}
      kgp: {warnBelow: "2.3.20", errorBelow: "2.2.20"}
      java: {warnBelow: "17", errorBelow: "17"}
      minSdk: {warnBelow: "24", errorBelow: "23"}
    maxKnown: {gradle: "9.3.1", kgp: "2.4.0", agp: "9.2", agpWithFullKotlinSupport: "9.1.0"}
    javaGradle:
      - {javaMin: "25", javaMax: "26", gradleMin: "9.1.0"}
    javaAgp:
      - {javaMin: "17", javaDefault: "17", agpMin: "8.0", agpMax: "9.2"}
  ios: {deploymentTarget: "15.0"}
  macos: {deploymentTarget: "12.0"}
''';

const _note = '''
  - id: ios-minimum-15
    since: "3.47"
    priority: 1
    area: ios
    summary: iOS 15 is the minimum.
    use: "`IPHONEOS_DEPLOYMENT_TARGET = 15.0`"
    avoid: "13.0"
    source: https://docs.flutter.dev/reference/supported-platforms
''';

String _file({
  String head = _head,
  String toolchain = _toolchain,
  String notes = _note,
}) => '$head${toolchain}notes:\n$notes';

/// The 1-based line of the first [needle] in [text].
int _lineOf(String text, String needle) =>
    text.substring(0, text.indexOf(needle)).split('\n').length;

Matcher _formatError(String message, {int? line}) => isA<NotesFormatException>()
    .having((e) => e.message, 'message', contains(message))
    .having((e) => e.line, 'line', line ?? anything);

void main() {
  group('parseNotesFile', () {
    test('reads a valid file', () {
      final file = parseNotesFile('3.47.yaml', _file());
      expect(file.flutter, '3.47');
      expect(file.released, '2026-08-12');
      expect(file.dart, '3.13');
      expect(file.android.template.agp, '9.1.0');
      expect(file.android.javaGradle.single.gradleMax, isNull);
      expect(file.ios.deploymentTarget, '15.0');
      expect(file.notes.single.area, NoteArea.ios);
      expect(file.notes.single.languageVersion, isNull);
    });

    test('ignores a byte order mark', () {
      expect(parseNotesFile('3.47.yaml', '\uFEFF${_file()}').flutter, '3.47');
    });

    test('an unquoted version is reported on its line', () {
      final text = _file(notes: _note.replaceFirst('"3.47"', '3.40'));
      expect(
        () => parseNotesFile('3.47.yaml', text),
        throwsA(
          _formatError(
            'must be a quoted string such as "3.38"',
            line: _lineOf(text, 'since: 3.40'),
          ),
        ),
      );
    });

    final cases = <String, (String, String)>{
      'an unknown key': (
        _note.replaceFirst('    priority:', '    tags: [x]\n    priority:'),
        'unknown key "tags"',
      ),
      'a missing key': (
        _note.replaceFirst(RegExp('    avoid: .*\n'), ''),
        'is missing "avoid"',
      ),
      'a priority out of range': (
        _note.replaceFirst('priority: 1', 'priority: 4'),
        '"priority" must be 1, 2 or 3',
      ),
      'an unknown area': (
        _note.replaceFirst('area: ios', 'area: web'),
        '"area" must be one of framework, dart, android, ios, tooling',
      ),
      'a source that is not a URL': (
        _note.replaceFirst(RegExp('source: .*'), 'source: sdk:packages/x'),
        'must be an https:// URL',
      ),
      'a note newer than its file': (
        _note.replaceFirst('"3.47"', '"3.50"'),
        "after this file's Flutter 3.47",
      ),
      'a duplicate id': ('$_note$_note', 'appears twice'),
      'an id that is not kebab-case': (
        _note.replaceFirst('ios-minimum-15', 'iOS_minimum'),
        'must look like dot-shorthands',
      ),
    };
    cases.forEach((name, testCase) {
      test('reports $name', () {
        expect(
          () => parseNotesFile('3.47.yaml', _file(notes: testCase.$1)),
          throwsA(_formatError(testCase.$2)),
        );
      });
    });

    test('the flutter version must match the file name', () {
      expect(
        () => parseNotesFile('3.44.yaml', _file()),
        throwsA(_formatError('but the file is named 3.44.yaml', line: 1)),
      );
    });

    test('a bad toolchain value names the part and key', () {
      final text = _file(
        toolchain: _toolchain.replaceFirst('agp: "9.1.0"', 'agp: 9.1'),
      );
      expect(
        () => parseNotesFile('3.47.yaml', text),
        throwsA(_formatError('"toolchain.android": "agp" must be a string')),
      );
    });

    test('invalid YAML is a NotesFormatException with a line', () {
      expect(
        () => parseNotesFile('3.47.yaml', 'notes: [\n'),
        throwsA(
          isA<NotesFormatException>().having((e) => e.line, 'line', isNotNull),
        ),
      );
    });
  });

  group('parseStoreRequirements', () {
    const valid = '''
play:
  targetSdk:
    - value: 36
      since: 2026-08-31
      summary: Target API level 36.
      source: https://developer.android.com/google/play/requirements/target-sdk
    - value: 35
      since: 2026-08-31
      formFactor: wear
      summary: Wear OS targets 35.
      source: https://developer.android.com/google/play/requirements/target-sdk
appStore:
  xcode:
    - value: "14.1"
      since: 2023-04-25
      summary: Xcode 14.1.
      source: https://developer.apple.com/news/upcoming-requirements/
    - value: 27
      since: 2027-04
      summary: The iOS 27 SDK.
      source: https://developer.apple.com/news/?id=k1mtkt1k
''';

    test('reads values as strings, months and form factors', () {
      final stores = parseStoreRequirements('stores.yaml', valid);
      expect(stores.play['targetSdk']!.first.value, '36');
      expect(stores.play['targetSdk']!.last.formFactor, 'wear');
      expect(stores.appStore['xcode']!.first.value, '14.1');
      expect(stores.appStore['xcode']!.last.since, '2027-04');
    });

    test('rejects an unquoted decimal value', () {
      expect(
        () => parseStoreRequirements(
          'stores.yaml',
          valid.replaceFirst('"14.1"', '14.1'),
        ),
        throwsA(_formatError('quoted string such as "14.1"')),
      );
    });

    test('rejects entries out of date order', () {
      expect(
        () => parseStoreRequirements(
          'stores.yaml',
          valid.replaceFirst('2023-04-25', '2028-01-01'),
        ),
        throwsA(_formatError('oldest first')),
      );
    });

    test('rejects a missing summary', () {
      expect(
        () => parseStoreRequirements(
          'stores.yaml',
          valid.replaceFirst('      summary: Xcode 14.1.\n', ''),
        ),
        throwsA(_formatError('is missing "summary"')),
      );
    });
  });
}
