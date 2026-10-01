import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  final json = <String, Object?>{
    'id': 'dot-shorthands',
    'since': '3.38',
    'languageVersion': '3.10',
    'priority': 2,
    'area': 'dart',
    'summary': 'Dot shorthands omit the type name.',
    'use': '`.center`',
    'avoid': 'Below language version 3.10.',
    'source': 'https://dart.dev/language/dot-shorthands',
  };

  test('round-trips through JSON', () {
    final note = CuratedNote.fromJson(json);
    expect(note.area, NoteArea.dart);
    expect(note.languageVersion, '3.10');
    expect(note.toJson(), json);
  });

  test('languageVersion is optional', () {
    final note = CuratedNote.fromJson({...json}..remove('languageVersion'));
    expect(note.languageVersion, isNull);
    expect(note.toJson()['languageVersion'], isNull);
  });

  test('priority must be 1, 2 or 3', () {
    expect(
      () => CuratedNote.fromJson({...json, 'priority': 4}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'note: "priority" must be 1, 2 or 3.',
        ),
      ),
    );
  });

  test('an unknown area is a FormatException', () {
    expect(
      () => CuratedNote.fromJson({...json, 'area': 'web'}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'note: "area" must be one of framework, dart, android, ios, '
              'tooling.',
        ),
      ),
    );
  });
}
