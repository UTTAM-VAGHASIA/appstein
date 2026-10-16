import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:appstein_engine/appstein_engine.dart';
// The engine's own seams, which the package does not export.
import 'package:appstein_engine/src/verify/deprecation_ignores.dart'
    show SourceComments, readSourceComments;
import 'package:appstein_engine/src/verify/suppression_comments.dart'
    show suppressionCommentsIn;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

/// Writes [files] (project-relative path to text) into a new project folder
/// and reads their comments as the analysis server's list of analyzed files
/// would send them: those of [files], and the paths in [also], which are not
/// on disk.
///
/// With [counted], every source read and every parse is noted there.
Future<SourceComments> _readSourceCommentsOf(
  Map<String, String> files, {
  List<String> also = const [],
  _Counted? counted,
}) {
  final project = p.join(tempDir().path, 'my app');
  files.forEach((relative, content) {
    File(p.joinAll([project, ...relative.split('/')]))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  });
  final all = [...files.keys, ...also];
  if (counted == null) return readSourceComments(project, all);
  return readSourceComments(
    project,
    all,
    readSource: (path) async {
      counted.reads.add(path);
      try {
        return utf8.decode(
          await File(path).readAsBytes(),
          allowMalformed: true,
        );
      } on FileSystemException {
        return null;
      }
    },
    parseSource: (content) {
      counted.parses.add(content);
      return parseString(content: content, throwIfDiagnostics: false).unit;
    },
  );
}

// What `suppressionCommentsIn` reads from Dart source: which comments are
// `// appstein:ignore` comments, what each names and says, and which lines
// each one covers (slice 1d.2, ticket 09, spec §9.7).
void main() {
  List<SuppressionComment> read(String source) =>
      suppressionCommentsIn(source, file: 'lib/a.dart');

  SuppressionComment only(String source) {
    final found = read(source);
    expect(found, hasLength(1));
    return found.single;
  }

  group('which comments count', () {
    test('a file with no such comment gives nothing', () {
      expect(read('int a = 1; // plain\n'), isEmpty);
      expect(read(''), isEmpty);
    });

    test('the comment is read with its file, line, check and reason', () {
      final comment = only(
        'int a = 1; // appstein:ignore dart.error — accepted\n',
      );
      expect(comment.file, 'lib/a.dart');
      expect(comment.line, 1);
      expect(comment.forFile, isFalse);
      expect(comment.id, 'dart.error');
      expect(comment.reason, 'accepted');
    });

    test('the space after the slashes is optional, and spaces around the '
        'text do not count', () {
      final comment = only(
        'int a = 1; //appstein:ignore   dart.error —   accepted   \n',
      );
      expect(comment.id, 'dart.error');
      expect(comment.reason, 'accepted');
    });

    test('a doc comment, a block comment and a longer name are not '
        'suppressions', () {
      expect(
        read('''
/// appstein:ignore dart.error — doc
/* appstein:ignore dart.error — block */
// appstein:ignored dart.error — another word
// appstein:ignore-files dart.error — another word
// not appstein:ignore dart.error — not at the start
int a = 1;
'''),
        isEmpty,
      );
    });

    test('text that looks like one inside a string is not a comment', () {
      expect(
        read(r"""
const a = '// appstein:ignore dart.error — in a string';
const b = '''
// appstein:ignore dart.error — in a multi-line string
''';
const c = 'x ${'// appstein:ignore dart.error — interpolated'}';
"""),
        isEmpty,
      );
    });

    test('a comment is still found after a string that holds the text', () {
      final comment = only(r"""
const a = '// appstein:ignore dart.error — in a string'; // appstein:ignore dart.lint — real
""");
      expect(comment.id, 'dart.lint');
      expect(comment.line, 1);
    });

    test('source that is not valid Dart is read all the same', () {
      final comment = only('class { // appstein:ignore dart.error — r\n');
      expect(comment.id, 'dart.error');
    });
  });

  group('the separator and the check ID', () {
    for (final (separator, label) in [
      ('—', 'an em dash'),
      ('--', 'two hyphens'),
      (' -', 'a hyphen between spaces'),
    ]) {
      test('$label separates the ID from the reason', () {
        final comment = only(
          'int a = 1; // appstein:ignore dart.error $separator the reason\n',
        );
        expect(comment.id, 'dart.error');
        expect(comment.reason, 'the reason');
      });
    }

    test('the separator may touch the ID', () {
      expect(
        only('// appstein:ignore dart.error— the reason\nint a;').id,
        'dart.error',
      );
      expect(
        only('// appstein:ignore dart.error--the reason\nint a;').reason,
        'the reason',
      );
    });

    test('a check ID with a hyphen is read whole', () {
      for (final text in [
        '// appstein:ignore my-pack.some-check — why\nint a;',
        '// appstein:ignore my-pack.some-check -- why\nint a;',
        '// appstein:ignore my-pack.some-check - why\nint a;',
        '// appstein:ignore my-pack.some-check--why\nint a;',
      ]) {
        final comment = only(text);
        expect(comment.id, 'my-pack.some-check', reason: text);
        expect(comment.reason, 'why', reason: text);
      }
    });

    test('the first separator ends the ID; later ones belong to the '
        'reason', () {
      final comment = only(
        '// appstein:ignore dart.error — a - b -- c — d\nint a;',
      );
      expect(comment.id, 'dart.error');
      expect(comment.reason, 'a - b -- c — d');
    });

    test('several IDs are one text that names no check', () {
      expect(
        only('// appstein:ignore dart.error, dart.lint — why\nint a;').id,
        'dart.error, dart.lint',
      );
      expect(
        only('// appstein:ignore dart.error dart.lint — why\nint a;').id,
        'dart.error dart.lint',
      );
    });

    test('a comment with no reason has none', () {
      for (final text in [
        '// appstein:ignore dart.error\nint a;',
        '// appstein:ignore dart.error —\nint a;',
        '// appstein:ignore dart.error —   \nint a;',
        '// appstein:ignore dart.error because I said so\nint a;',
        '// appstein:ignore dart.error-\nint a;',
        '// appstein:ignore\nint a;',
      ]) {
        expect(only(text).reason, isNull, reason: text);
      }
    });

    test('a comment with a reason and no ID names an empty one', () {
      final comment = only('// appstein:ignore — why\nint a;');
      expect(comment.id, '');
      expect(comment.reason, 'why');
    });
  });

  group('appstein:ignore covers a line', () {
    test('at the end of a line of code, it covers that line', () {
      final comment = only('''
int a = 1;
int b = 2; // appstein:ignore dart.error — r
int c = 3;
''');
      expect((comment.firstLine, comment.lastLine), (2, 2));
      expect(comment.forFile, isFalse);
    });

    test('alone on a line, it covers the next line of code', () {
      final comment = only('''
int a = 1;
// appstein:ignore dart.error — r
int b = 2;
int c = 3;
''');
      expect((comment.firstLine, comment.lastLine), (3, 3));
    });

    test('alone on a line, it reaches over blank lines and comments to the '
        'next line of code, which includes them', () {
      final comment = only('''
// appstein:ignore dart.deprecated — r

// ignore: deprecated_member_use
/// A doc comment.
/* a block comment */
int b = 2;
''');
      expect((comment.firstLine, comment.lastLine), (2, 6));
    });

    test('an annotation is a line of code', () {
      final comment = only('''
// appstein:ignore dart.error — r
@override
int b() => 2;
''');
      expect((comment.firstLine, comment.lastLine), (2, 2));
    });

    test('a line inside a multi-line string is a line of code', () {
      final comment = only("""
// appstein:ignore dart.error — r
const a = '''
text
''';
""");
      expect((comment.firstLine, comment.lastLine), (2, 2));
    });

    test('a comment after the last line of code covers nothing', () {
      final comment = only('''
int a = 1;
// appstein:ignore dart.error — r
''');
      expect(comment.firstLine, isNull);
      expect(comment.lastLine, isNull);
    });

    test('after a block comment on its own line it is still alone', () {
      final comment = only('''
/* note */ // appstein:ignore dart.error — r
int b = 2;
''');
      expect((comment.firstLine, comment.lastLine), (2, 2));
    });

    test('after a block comment that follows code it ends a line of '
        'code', () {
      final comment = only('''
int b = 2; /* note */ // appstein:ignore dart.error — r
int c = 3;
''');
      expect((comment.firstLine, comment.lastLine), (1, 1));
    });

    test('two comments in a row cover the same next line of code', () {
      final found = read('''
// appstein:ignore dart.error — r
// appstein:ignore dart.lint — r
int b = 2;
''');
      expect(
        [for (final c in found) (c.id, c.firstLine, c.lastLine)],
        [('dart.error', 2, 3), ('dart.lint', 3, 3)],
      );
    });

    test('the line numbers are right with CRLF line endings', () {
      final comment = only(
        'int a = 1;\r\n// appstein:ignore dart.error — r\r\nint b = 2;\r\n',
      );
      expect((comment.line, comment.firstLine, comment.lastLine), (2, 3, 3));
    });

    test('the end of a line of code after a multi-line string is that '
        'line', () {
      final comment = only("""
const a = '''
text
'''; // appstein:ignore dart.error — r
""");
      expect((comment.firstLine, comment.lastLine), (3, 3));
    });
  });

  group('appstein:ignore-file', () {
    test('before the first declaration, it is in force, with the imports '
        'after it', () {
      final comment = only('''
// appstein:ignore-file dart.error — r
import 'dart:io';

class A {}
''');
      expect(comment.forFile, isTrue);
      expect(comment.afterDeclaration, isFalse);
      expect(comment.id, 'dart.error');
      expect(comment.reason, 'r');
      expect(comment.firstLine, isNull);
    });

    test('between the imports and the first declaration, it is in '
        'force', () {
      final comment = only('''
import 'dart:io';

// appstein:ignore-file dart.error — r

class A {}
''');
      expect(comment.afterDeclaration, isFalse);
    });

    test('after the first declaration, it is not in force', () {
      final comment = only('''
class A {}

// appstein:ignore-file dart.error — r
class B {}
''');
      expect(comment.forFile, isTrue);
      expect(comment.afterDeclaration, isTrue);
    });

    test('at the end of the first declaration\'s line it is after it', () {
      final comment = only('class A {} // appstein:ignore-file x.y — r\n');
      expect(comment.afterDeclaration, isTrue);
    });

    test('inside a declaration it is after the first declaration', () {
      final comment = only('''
class A {
  // appstein:ignore-file dart.error — r
  int a = 1;
}
''');
      expect(comment.afterDeclaration, isTrue);
    });

    test('above the first declaration\'s doc comment and annotation it is '
        'in force', () {
      final comment = only('''
// appstein:ignore-file dart.error — r
/// A class.
@deprecated
class A {}
''');
      expect(comment.afterDeclaration, isFalse);
    });

    test('between the first declaration\'s doc comment or annotation and the '
        'declaration, it is after the start of the declaration', () {
      expect(
        only('''
/// A class.
// appstein:ignore-file dart.error — r
class A {}
''').afterDeclaration,
        isTrue,
      );
      expect(
        only('''
@deprecated
// appstein:ignore-file dart.error — r
class A {}
''').afterDeclaration,
        isTrue,
      );
    });

    test('a file with no declaration takes it anywhere', () {
      final comment = only('''
import 'dart:io';
// appstein:ignore-file dart.error — r
export 'dart:async';
''');
      expect(comment.afterDeclaration, isFalse);
    });

    test('trailing a line of code before the first declaration is in '
        'force', () {
      final comment = only('''
import 'dart:io'; // appstein:ignore-file dart.error — r
class A {}
''');
      expect(comment.afterDeclaration, isFalse);
    });

    test('a comment without a reason keeps the form it was written in', () {
      final comment = only('// appstein:ignore-file dart.error\nclass A {}\n');
      expect(comment.forFile, isTrue);
      expect(comment.reason, isNull);
    });
  });

  group('readSourceComments', () {
    test('reads the suppression comments and the deprecated-use comments in '
        'one pass', () async {
      final found = await _readSourceCommentsOf({
        'lib/a.dart': '''
// ignore_for_file: deprecated_member_use
int a = 1; // appstein:ignore dart.error — r
''',
        'lib/b.dart': 'int b = 1;\n',
        'lib/c.dart': '// appstein:ignore-file dart.lint — r\nint c = 1;\n',
      });
      expect(
        [for (final c in found.suppression) (c.file, c.id)],
        [('lib/a.dart', 'dart.error'), ('lib/c.dart', 'dart.lint')],
      );
      expect([for (final i in found.deprecation) i.file], ['lib/a.dart']);
    });

    test('reads each file once and parses it at most once: a file with '
        'both kinds of comment once, one with neither not at all', () async {
      final counted = _Counted();
      final found = await _readSourceCommentsOf({
        // Both kinds: one parse for the two readings.
        'lib/both.dart': '''
// ignore_for_file: deprecated_member_use
int a = 1; // appstein:ignore dart.error — r
''',
        'lib/deprecated_only.dart':
            '// ignore: deprecated_member_use\nint b;\n',
        'lib/suppression_only.dart':
            'int c = 1; // appstein:ignore dart.error — r\n',
        'lib/neither.dart': 'int d = 1;\n',
      }, counted: counted);
      expect(counted.reads.toSet(), hasLength(4));
      expect(counted.reads, hasLength(4));
      expect(counted.parses, hasLength(3));
      expect(
        counted.parses.toSet(),
        hasLength(3),
        reason: 'the same text was parsed twice',
      );
      expect(counted.parses.any((text) => text.contains('int d')), isFalse);
      expect(found.suppression, hasLength(2));
      expect(found.deprecation, hasLength(2));
    });

    test('a file that is gone or not readable is left out', () async {
      final found = await _readSourceCommentsOf(
        {'lib/a.dart': 'int a = 1; // appstein:ignore dart.error — r\n'},
        also: ['lib/missing.dart'],
      );
      expect([for (final c in found.suppression) c.file], ['lib/a.dart']);
    });

    test('a yaml or xml file is not read for comments, whatever it holds, '
        'and nor is an options file', () async {
      const text = '// appstein:ignore dart.error — r\nint a = 1;\n';
      final counted = _Counted();
      final found = await _readSourceCommentsOf({
        // Text that is found when parsed as Dart.
        'pubspec.yaml': text,
        'android/app/src/main/AndroidManifest.xml': text,
        'analysis_options.yaml': text,
        'lib/a.dart': 'int a = 1;\n',
      }, counted: counted);
      expect(found.suppression, isEmpty);
      expect(counted.parses, isEmpty);
      expect(counted.reads.map(p.basename).where((name) => name != 'a.dart'), [
        'analysis_options.yaml',
      ], reason: 'only the options file and the Dart file are read');
    });

    test(
      'a file that starts with a byte order mark is read, on disk too',
      () async {
        final bom = String.fromCharCode(0xFEFF);
        expect(
          only('$bom// appstein:ignore-file dart.error — r\nclass A {}\n').line,
          1,
        );
        final onDisk = p.join(tempDir().path, 'my app');
        File(p.join(onDisk, 'lib', 'a.dart'))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync([
            0xEF,
            0xBB,
            0xBF,
            ...utf8.encode(
              '// appstein:ignore-file dart.error — r\nclass A {}\n',
            ),
          ]);
        final found = await readSourceComments(onDisk, ['lib/a.dart']);
        final comment = found.suppression.single;
        expect(comment.line, 1);
        expect(comment.forFile, isTrue);
        expect(comment.afterDeclaration, isFalse);
        expect(comment.id, 'dart.error');
      },
    );

    test('a comment after a byte order mark on the first line of code '
        'covers that line', () {
      final bom = String.fromCharCode(0xFEFF);
      final comment = only('${bom}int a = 1; // appstein:ignore a.b — r\n');
      expect((comment.firstLine, comment.lastLine), (1, 1));
    });
  });
}

/// What `readSourceComments` read and parsed, for a test to count.
final class _Counted {
  final reads = <String>[];
  final parses = <String>[];
}
