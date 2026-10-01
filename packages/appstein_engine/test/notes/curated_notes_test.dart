import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

void main() {
  final notes = CuratedNotes.bundled();

  test(
    'the bundled notes parse: one file per stable minor, and the stores',
    () {
      expect([for (final file in notes.files) file.flutter], ['3.44', '3.47']);
      expect(notes.newestMinor, '3.47');
      expect(notes.stores.play['targetSdk'], isNotEmpty);
      expect(notes.stores.appStore['xcode'], isNotEmpty);
      expect(
        notes.inputs.keys,
        containsAll([
          'notes:3.44.yaml',
          'notes:3.47.yaml',
          'notes:stores.yaml',
        ]),
      );
    },
  );

  test('coverage is partial only above the newest notes (Review Focus 3)', () {
    expect(notes.coverageFor('3.47.5'), NotesCoverage.complete);
    expect(notes.coverageFor('3.44.0'), NotesCoverage.complete);
    expect(notes.coverageFor('3.38.6'), NotesCoverage.complete);
    expect(notes.coverageFor('3.48.0-0.1.pre'), NotesCoverage.partial);
    expect(notes.coverageFor('3.50.1'), NotesCoverage.partial);
    expect(notes.coverageFor('main'), NotesCoverage.partial);
  });

  test('an unversioned SDK gets partial coverage and no notes', () {
    expect(notes.coverageFor('0.0.0-unknown'), NotesCoverage.partial);
    expect(notes.fileFor('0.0.0-unknown'), isNull);
    expect(notes.notesFor('0.0.0-unknown'), isEmpty);
  });

  test('the fallback file is the newest at or below the version', () {
    expect(notes.fileFor('3.47.5')?.flutter, '3.47');
    expect(notes.fileFor('3.46.0-0.3.pre')?.flutter, '3.44');
    expect(notes.fileFor('3.44.9')?.flutter, '3.44');
    expect(notes.fileFor('4.0.0')?.flutter, '3.47');
    expect(notes.fileFor('3.38.6'), isNull);
    expect(notes.fileFor('main'), isNull);
  });

  test('notesFor keeps notes since at or below the version, sorted', () {
    final on344 = [for (final note in notes.notesFor('3.44.9')) note.id];
    expect(on344, contains('dot-shorthands'));
    expect(on344, isNot(contains('ios-minimum-15')));
    final on347 = notes.notesFor('3.47.5');
    expect([for (final note in on347) note.id], contains('ios-minimum-15'));
    for (var i = 1; i < on347.length; i++) {
      final a = on347[i - 1];
      final b = on347[i];
      expect(
        a.priority <= b.priority,
        isTrue,
        reason: '${a.id} before ${b.id}',
      );
    }
    final android = notes.notesFor('3.47.5', areas: {NoteArea.android});
    expect(android, isNotEmpty);
    expect(android.every((note) => note.area == NoteArea.android), isTrue);
    expect(notes.notesFor('main'), isEmpty);
  });

  test('an id in two files is reported', () {
    final sources = Map.of(bundledNotes);
    final duplicate = sources['3.47.yaml']!.replaceFirst(
      'id: ios-minimum-15',
      'id: dot-shorthands',
    );
    expect(
      () => CuratedNotes.parse({...sources, '3.47.yaml': duplicate}),
      throwsA(
        isA<NotesFormatException>().having(
          (e) => e.message,
          'message',
          contains('also in 3.44.yaml'),
        ),
      ),
    );
  });

  test('stores.yaml is required', () {
    expect(
      () => CuratedNotes.parse({...bundledNotes}..remove('stores.yaml')),
      throwsA(isA<NotesFormatException>()),
    );
  });
}
