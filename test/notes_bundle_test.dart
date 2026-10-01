import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/notes_bundle.dart';

void main() {
  test('renders raw strings, sorted by file name', () {
    final text = renderNotesBundle({'b.yaml': 'b: 1\n', 'a.yaml': "a: 'x'\n"});
    expect(text, contains("const bundledNotes = <String, String>{"));
    expect(text.indexOf("'a.yaml'"), lessThan(text.indexOf("'b.yaml'")));
    expect(text, contains("  'a.yaml': r'''\na: 'x'\n''',\n"));
  });

  test("uses double quotes when the YAML holds three single quotes", () {
    expect(
      renderNotesBundle({'a.yaml': "x: ''''\n"}),
      contains("  'a.yaml': r\"\"\"\nx: ''''\n\"\"\",\n"),
    );
  });

  test('the generated file is up to date with notes/', () {
    expect(
      File(notesBundleFile).readAsStringSync(),
      renderNotesBundle(readNotesSources(Directory.current.path)),
      reason: 'Run `fvm dart run tool/gen_notes.dart`.',
    );
  });

  test('reads notes/ with LF endings and a final newline', () {
    final sources = readNotesSources(Directory.current.path);
    expect(
      sources.keys,
      containsAll(['3.44.yaml', '3.47.yaml', 'stores.yaml']),
    );
    for (final text in sources.values) {
      expect(text, isNot(contains('\r')));
      expect(text, endsWith('\n'));
    }
  });

  test('no unquoted note value holds " #", which YAML reads as a comment', () {
    // An unquoted value is cut at " #": "issue #192167" would end the text.
    final unquoted = RegExp(r'''^\s*(?:- )?[\w-]+: +([^"'|>\s].*)$''');
    for (final MapEntry(key: file, value: text) in readNotesSources(
      Directory.current.path,
    ).entries) {
      final lines = text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final value = unquoted.firstMatch(lines[i])?.group(1);
        expect(
          value == null || !value.contains(' #'),
          isTrue,
          reason: '$file:${i + 1}: quote the value',
        );
      }
    }
  });
}
