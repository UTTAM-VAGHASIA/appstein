import 'dart:io';

import 'package:analyzer/error/error.dart' show diagnosticCodeValues;
import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';

// What counts as an ignore comment that names a deprecated-use diagnostic.
// The forms were compared with `dart analyze` of the pinned SDK (3.13.4) on
// 2026-10-14: every text "not reported" here is one the analyzer does not
// take for an ignore comment naming such a code. A comment reported here is
// one the analyzer reads as naming the code; whether it then drops a
// diagnostic depends on the use below it, which these tests don't claim.
void main() {
  /// The line, kind and codes (joined with a comma) of each comment found
  /// in [content]; `type=hint` stands for a comment that says so.
  List<(int, bool, String)> found(String content) => [
    for (final comment in deprecationIgnoresIn(content, file: 'lib/a.dart'))
      (
        comment.line,
        comment.forFile,
        comment.allHints ? 'type=hint' : comment.codes.join(','),
      ),
  ];

  const use = 'deprecated_member_use';

  group('the deprecated-use codes', () {
    const ofTheLint = {
      'deprecated_member_use_from_same_package',
      'deprecated_member_use_from_same_package_with_message',
      'deprecated_member_use_from_same_package_without_message',
    };

    // An analyzer upgrade that adds, renames or removes a form fails here.
    test('are the names the pinned analyzer package has, and the three of '
        'the SDK\'s lint', () {
      final ofTheAnalyzer = <String>{};
      for (final code in diagnosticCodeValues) {
        // As the analyzer reads a name in an ignore comment: the code's
        // name, or its longer name without what stands before a full stop.
        final unique = code.lowerCaseUniqueName;
        for (final name in [
          code.lowerCaseName,
          unique.substring(unique.indexOf('.') + 1),
        ]) {
          if (name.startsWith('deprecated_member_use')) ofTheAnalyzer.add(name);
        }
      }
      expect(ofTheAnalyzer, {
        'deprecated_member_use',
        'deprecated_member_use_with_message',
        'deprecated_member_use_implicit',
        'deprecated_member_use_implicit_with_message',
      });
      expect(deprecatedUseCodes, {...ofTheAnalyzer, ...ofTheLint});
    });

    test('each is one, in any letter case', () {
      for (final code in deprecatedUseCodes) {
        expect(isDeprecatedUseCode(code), isTrue, reason: code);
        expect(isDeprecatedUseCode(code.toUpperCase()), isTrue, reason: code);
      }
    });

    test('no other code is, also one that only starts like one', () {
      for (final code in [
        'deprecated_member_use_foo',
        'deprecated_member_use_',
        'deprecated_member_use_from_same_package_foo',
        'deprecated_member',
        'deprecated_export_use',
        'unused_import',
        'not_deprecated_member_use',
        '',
      ]) {
        expect(isDeprecatedUseCode(code), isFalse, reason: code);
      }
    });
  });

  group('an // ignore: comment that names a deprecated-use code', () {
    test('alone on the line above, and at the end of the line', () {
      expect(
        found('''
void f() {
  // ignore: deprecated_member_use
  oldWay();
  oldWay(); // ignore: deprecated_member_use
}
'''),
        [(2, false, use), (4, false, use)],
      );
    });

    test('carries the file it was given', () {
      final comment = deprecationIgnoresIn(
        '// ignore: deprecated_member_use\nint a = 1;\n',
        file: 'lib/my folder/a.dart',
      ).single;
      expect(comment.file, 'lib/my folder/a.dart');
    });

    test('each variant, in the analyzer\'s own spellings', () {
      expect(
        found('''
void f() {
  // ignore: deprecated_member_use_from_same_package
  mine();
  // ignore: deprecated_member_use_with_message
  oldWay();
  // ignore: DEPRECATED_MEMBER_USE
  oldWay();
  //ignore:deprecated_member_use
  oldWay();
  /// ignore: deprecated_member_use
  oldWay();
}
'''),
        [
          (2, false, 'deprecated_member_use_from_same_package'),
          (4, false, 'deprecated_member_use_with_message'),
          (6, false, use),
          (8, false, use),
          (10, false, use),
        ],
      );
    });

    test('among other codes, with text after them, and named twice', () {
      expect(
        found('''
void f() {
  // ignore: unused_import, deprecated_member_use, because it is old
  oldWay();
  // ignore: deprecated_member_use, deprecated_member_use
  oldWay();
  // ignore: deprecated_member_use, deprecated_member_use_from_same_package
  oldWay();
}
'''),
        [
          (2, false, use),
          (4, false, use),
          (
            6,
            false,
            'deprecated_member_use,deprecated_member_use_from_same_package',
          ),
        ],
      );
    });

    test('with a plugin\'s name before the code', () {
      expect(
        found('// ignore: some_plugin/deprecated_member_use\nint a = 1;\n'),
        [(1, false, use)],
      );
    });
  });

  group('an // ignore_for_file: comment', () {
    test('at the top, and at the end of the file', () {
      expect(
        found('''
// ignore_for_file: deprecated_member_use

void f() {
  oldWay();
}

// ignore_for_file: unused_import, DEPRECATED_MEMBER_USE_FROM_SAME_PACKAGE
'''),
        [(1, true, use), (7, true, 'deprecated_member_use_from_same_package')],
      );
    });
  });

  // `// ignore: type=hint` and `// ignore_for_file: TYPE = HINT` made the
  // pinned SDK's analyzer drop `deprecated_member_use`; `type=warning` and
  // `type=lint` did not (`type=lint` drops the same-package lint only).
  group('a comment that says type=hint', () {
    test('for a line and for the file, in the spellings the analyzer '
        'reads', () {
      expect(
        found('''
// ignore_for_file: type=hint
void f() {
  // ignore: type=hint
  oldWay();
  oldWay(); // ignore: TYPE = HINT
  // ignore: unused_import, type=hint, for reasons
  oldWay();
  //ignore:type=hint
  oldWay();
}
// ignore_for_file: Type =hint
'''),
        [
          (1, true, 'type=hint'),
          (3, false, 'type=hint'),
          (5, false, 'type=hint'),
          (6, false, 'type=hint'),
          (8, false, 'type=hint'),
          (11, true, 'type=hint'),
        ],
      );
    });

    test('with a deprecated-use code beside it: once for each', () {
      expect(
        found('// ignore: type=hint, deprecated_member_use\nint a = 1;\n'),
        [(1, false, use), (1, false, 'type=hint')],
      );
    });

    test('carries no code', () {
      final comment = deprecationIgnoresIn(
        '// ignore_for_file: type=hint\n',
        file: 'lib/a.dart',
      ).single;
      expect(comment.allHints, isTrue);
      expect(comment.codes, isEmpty);
      expect(comment.optionsValue, isNull);
    });

    test('not another type, not in a string or a doc comment\'s sample, '
        'and not a word that only starts like it', () {
      expect(
        found(r"""
// ignore_for_file: type=lint
// ignore_for_file: type=warning

/// ```dart
/// // ignore: type=hint
/// ```
const advice = '// ignore: type=hint';

void f() {
  // ignore: type=lint, type=warning
  oldWay();
  // ignore: type=hints
  oldWay();
  // ignore: type=hint.
  oldWay();
  // ignore: type hint
  oldWay();
  /* ignore: type=hint */
  oldWay();
  // the type=hint form is not used here
  oldWay();
}
"""),
        isEmpty,
      );
    });
  });

  group('an analysis_options.yaml entry', () {
    /// The line, name and value of each entry found in [content].
    List<(int, String, String?)> switches(String content) => [
      for (final entry in deprecationSwitchesIn(
        content,
        file: 'analysis_options.yaml',
      ))
        (entry.line, entry.codes.single, entry.optionsValue),
    ];

    String errors(String entry) => 'analyzer:\n  errors:\n    $entry\n';

    // With each of these the pinned SDK's analyzer stopped reporting the
    // diagnostic.
    test('that sets a deprecated-use code to ignore or false, in any '
        'letter case, is one', () {
      for (final (entry, name, value) in [
        ('deprecated_member_use: ignore', use, 'ignore'),
        ('deprecated_member_use: IGNORE', use, 'IGNORE'),
        ('deprecated_member_use: "ignore"', use, 'ignore'),
        ('deprecated_member_use: false', use, 'false'),
        ('DEPRECATED_MEMBER_USE: ignore', use, 'ignore'),
        (
          'deprecated_member_use_from_same_package: ignore',
          'deprecated_member_use_from_same_package',
          'ignore',
        ),
      ]) {
        expect(switches(errors(entry)), [(3, name, value)], reason: entry);
      }
    });

    // With each of these the analyzer still reported it.
    test('that gives another value is not', () {
      for (final entry in [
        'deprecated_member_use: info',
        'deprecated_member_use: warning',
        'deprecated_member_use: error',
        'deprecated_member_use: true',
        'deprecated_member_use: off',
        'deprecated_member_use: none',
        'deprecated_member_use:',
        'deprecated_member_use: [ignore]',
        'deprecated_member_use: {ignore: true}',
      ]) {
        expect(switches(errors(entry)), isEmpty, reason: entry);
      }
    });

    test('that names another code, or one that only starts like one, is '
        'not', () {
      for (final entry in [
        'unused_import: ignore',
        'deprecated_export_use: ignore',
        'deprecated_member_use_foo: ignore',
        'todo: ignore',
      ]) {
        expect(switches(errors(entry)), isEmpty, reason: entry);
      }
    });

    // The analyzer warns `unrecognized_error_code` for each of these and
    // still reports the diagnostic (pinned SDK 3.13.4, 2026-10-14), so the
    // entry hides nothing and is not reported as one that does. They are
    // names for an `// ignore:` comment only.
    test('that gives a longer name of a form is not: the analyzer rejects '
        'it', () {
      for (final name in deprecatedUseCodes) {
        if (name == 'deprecated_member_use' ||
            name == 'deprecated_member_use_from_same_package') {
          continue;
        }
        for (final value in ['ignore', 'false']) {
          expect(
            switches(errors('$name: $value')),
            isEmpty,
            reason: '$name: $value',
          );
          expect(
            switches(errors('${name.toUpperCase()}: $value')),
            isEmpty,
            reason: '${name.toUpperCase()}: $value',
          );
        }
      }
    });

    test('each entry is on its own line, among others, with comments and '
        'Windows line ends', () {
      expect(
        switches(
          '# deprecated_member_use: ignore\r\n'
          'include: package:flutter_lints/flutter.yaml\r\n'
          '\r\n'
          'analyzer:\r\n'
          '  exclude:\r\n'
          '    - lib/generated/**\r\n'
          '  errors:\r\n'
          '    unused_import: ignore\r\n'
          '    deprecated_member_use: ignore # for now\r\n'
          '    todo: info\r\n'
          '    deprecated_member_use_from_same_package: false\r\n'
          'linter:\r\n'
          '  rules:\r\n'
          '    - deprecated_member_use_from_same_package\r\n',
        ),
        [
          (9, use, 'ignore'),
          (11, 'deprecated_member_use_from_same_package', 'false'),
        ],
      );
    });

    test('in flow style, and after a byte order mark', () {
      expect(
        switches(
          '${String.fromCharCode(0xFEFF)}'
          'analyzer: {errors: {deprecated_member_use: ignore}}\n',
        ),
        [(1, use, 'ignore')],
      );
    });

    test('the name anywhere else in the file is not one: excluding a '
        'folder, switching the lint off, another section', () {
      for (final content in [
        'analyzer:\n  exclude:\n    - lib/deprecated_member_use/**\n',
        'linter:\n  rules:\n    deprecated_member_use_from_same_package: false\n',
        'linter:\n  rules:\n    - deprecated_member_use_from_same_package\n',
        'errors:\n  deprecated_member_use: ignore\n',
        'analyzer:\n  deprecated_member_use: ignore\n',
        'analyzer:\n  errors: deprecated_member_use\n',
        'analyzer:\n  errors:\n    - deprecated_member_use: ignore\n',
        'other:\n  analyzer:\n    errors:\n      deprecated_member_use: ignore\n',
        'deprecated_member_use: ignore\n',
        '- deprecated_member_use\n',
      ]) {
        expect(switches(content), isEmpty, reason: content);
      }
    });

    test('a file that isn\'t YAML gives nothing, and no error', () {
      for (final content in [
        'analyzer: [\n  errors\n deprecated_member_use: ignore',
        'analyzer:\n  errors:\n    deprecated_member_use: ignore\n'
            '    deprecated_member_use: ignore\n',
        '\t{deprecated_member_use: ignore',
        '',
      ]) {
        expect(switches(content), isEmpty, reason: content);
      }
    });

    test('it is no comment: it carries its value and is for no file', () {
      final entry = deprecationSwitchesIn(
        errors('deprecated_member_use: ignore'),
        file: 'packages/inner/analysis_options.yaml',
      ).single;
      expect(entry.file, 'packages/inner/analysis_options.yaml');
      expect(entry.optionsValue, 'ignore');
      expect((entry.forFile, entry.allHints), (false, false));
    });
  });

  group('is not reported', () {
    test('an ignore comment that names only other codes', () {
      expect(
        found('''
// ignore_for_file: unused_import, avoid_print
void f() {
  // ignore: unused_local_variable
  final a = 1;
  // ignore: type=lint
  print('x'); // ignore: avoid_print, some_plugin/some_code
  // ignore: deprecated_export_use
}
'''),
        isEmpty,
      );
    });

    test('a name that only starts like a deprecated-use code', () {
      expect(
        found('''
// ignore_for_file: deprecated_member_use_foo
void f() {
  // ignore: deprecated_member_use_, deprecated_member_uses
  oldWay();
}
'''),
        isEmpty,
      );
    });

    test('a code that is comment text, after a code without a comma', () {
      expect(
        found('// ignore: unused_import deprecated_member_use\nint a = 1;\n'),
        isEmpty,
      );
    });

    test('text that looks like one inside a string', () {
      expect(
        found(r"""
const one = '// ignore: deprecated_member_use';
const two = "// ignore_for_file: deprecated_member_use";
const raw = r'// ignore: deprecated_member_use';
const many = '''
// ignore_for_file: deprecated_member_use
  // ignore: deprecated_member_use
''';
String both(String name) => '$name // ignore: deprecated_member_use ${name}';
"""),
        isEmpty,
      );
    });

    test('a doc comment\'s code sample, and a doc comment that names the '
        'file form', () {
      expect(
        found('''
/// ignore_for_file: deprecated_member_use
library;

/// Reads the old way.
///
/// ```dart
/// // ignore_for_file: deprecated_member_use
/// // ignore: deprecated_member_use
/// oldWay();
/// ```
///
///     // ignore: deprecated_member_use
///     oldWay();
void f() {}

/**
 * // ignore: deprecated_member_use
 */
void g() {}
'''),
        isEmpty,
      );
    });

    test('a block comment, a space before the colon, and text before the '
        'word', () {
      expect(
        found('''
void f() {
  /* ignore: deprecated_member_use */
  oldWay();
  /** ignore: deprecated_member_use */
  oldWay();
  // ignore : deprecated_member_use
  oldWay();
  // see ignore: deprecated_member_use
  oldWay();
  // ignored: deprecated_member_use
  oldWay();
}
'''),
        isEmpty,
      );
    });
  });

  group('the line is the comment\'s', () {
    test('with Windows line ends', () {
      expect(
        found(
          'void f() {\r\n'
          '  oldWay();\r\n'
          '  // ignore: deprecated_member_use\r\n'
          '  oldWay();\r\n'
          '}\r\n',
        ),
        [(3, false, use)],
      );
    });

    test('after a byte order mark', () {
      expect(
        found(
          '${String.fromCharCode(0xFEFF)}'
          '// ignore_for_file: deprecated_member_use\n'
          'int a = 1;\n',
        ),
        [(1, true, use)],
      );
    });

    test('in a file that isn\'t valid Dart', () {
      expect(
        found('''
void f( {
  // ignore: deprecated_member_use
  oldWay(
}
class {
'''),
        [(2, false, use)],
      );
    });

    test('in a file without a line end, and in an empty one', () {
      expect(found('// ignore: deprecated_member_use'), [(1, false, use)]);
      expect(found(''), isEmpty);
    });
  });

  group('readDeprecationIgnores', () {
    late String project;

    void write(String relative, String content) =>
        File(p.joinAll([project, ...relative.split('/')]))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content);

    const hiding = '// ignore_for_file: deprecated_member_use\n';

    /// The file and line of each comment found in [files], which stand for
    /// the files the analysis server analyzed.
    Future<List<(String, int)>> read(List<String> files) async => [
      for (final comment in await readDeprecationIgnores(project, files))
        (comment.file, comment.line),
    ];

    setUp(() => project = p.join(tempDir().path, 'my app'));

    test('the files it is given and no other, in file and line order, '
        'whatever the order given', () async {
      write('lib/z.dart', hiding);
      write(
        'lib/my folder/a.dart',
        'void f() {\n'
            '  g(); // ignore: deprecated_member_use\n'
            '  // ignore: deprecated_member_use\n'
            '  g();\n'
            '}\n',
      );
      write('test/a_test.dart', hiding);
      write('bin/tool.dart', '// ignore: DEPRECATED_MEMBER_USE\nint a = 1;\n');
      write('lib/clean.dart', '// ignore: unused_import\nint a = 1;\n');
      // Not analyzed, so not given: excluded, or in a folder never read.
      write('lib/generated/api.dart', hiding);
      write('.dart_tool/build/generated.dart', hiding);
      expect(
        await read([
          'test/a_test.dart',
          'lib/z.dart',
          'lib/clean.dart',
          'lib/my folder/a.dart',
          'bin/tool.dart',
          // Named twice: read once.
          'lib/z.dart',
        ]),
        [
          ('bin/tool.dart', 1),
          ('lib/my folder/a.dart', 2),
          ('lib/my folder/a.dart', 3),
          ('lib/z.dart', 1),
          ('test/a_test.dart', 1),
        ],
      );
    });

    test('a part file whose name doesn\'t end in .dart is read like any '
        'other', () async {
      write('lib/whole.dart', "part 'odd.part';\n");
      write('lib/odd.part', "${hiding}part of 'whole.dart';\n");
      write('lib/NO_EXTENSION', hiding);
      expect(
        await read(['lib/whole.dart', 'lib/odd.part', 'lib/NO_EXTENSION']),
        [('lib/NO_EXTENSION', 1), ('lib/odd.part', 1)],
      );
    });

    test('the files the analyzer reads as something other than Dart are '
        'skipped', () async {
      const looksLikeOne =
          'name: x # // ignore_for_file: deprecated_member_use\n'
          '// ignore_for_file: deprecated_member_use\n';
      for (final file in [
        'pubspec.yaml',
        'analysis_options.yaml',
        'lib/fix_data/fixes.YAML',
        'data.yml',
        'android/app/src/main/AndroidManifest.xml',
      ]) {
        write(file, looksLikeOne);
      }
      expect(
        await read([
          'pubspec.yaml',
          'analysis_options.yaml',
          'lib/fix_data/fixes.YAML',
          'data.yml',
          'android/app/src/main/AndroidManifest.xml',
        ]),
        isEmpty,
      );
    });

    test('every analysis_options.yaml it is given is read for its '
        'entries, and no other YAML file', () async {
      const off = 'analyzer:\n  errors:\n    deprecated_member_use: ignore\n';
      write('analysis_options.yaml', off);
      write('packages/inner/analysis_options.yaml', '# One line down.\n$off');
      write('lib/other_options.yaml', off);
      // Not analyzed, so not given.
      write('tool/analysis_options.yaml', off);
      write('lib/a.dart', hiding);
      final found = await readDeprecationIgnores(project, [
        'packages/inner/analysis_options.yaml',
        'lib/other_options.yaml',
        'lib/a.dart',
        'analysis_options.yaml',
      ]);
      expect(
        [
          for (final entry in found)
            (entry.file, entry.line, entry.optionsValue),
        ],
        [
          ('analysis_options.yaml', 3, 'ignore'),
          ('lib/a.dart', 1, null),
          ('packages/inner/analysis_options.yaml', 4, 'ignore'),
        ],
      );
    });

    group('an analysis_options.yaml above the project', () {
      const off = 'analyzer:\n  errors:\n    deprecated_member_use: ignore\n';

      // Two folders inside the temporary one, so no test writes above it.
      setUp(() => project = p.join(tempDir().path, 'parent', 'my app'));

      void writeAt(String folder, String content) =>
          File(p.join(folder, 'analysis_options.yaml'))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(content);

      /// The file, line and value of each entry found in [files].
      Future<List<(String, int, String?)>> entries(List<String> files) async =>
          [
            for (final entry in await readDeprecationIgnores(project, files))
              (entry.file, entry.line, entry.optionsValue),
          ];

      // The analyzer applies the nearest options file of an enclosing folder
      // to a project without its own, and with `ignore` it reports nothing
      // (pinned SDK 3.13.4, 2026-10-14). The file is outside the project, so
      // its path from the root starts with `../`.
      test('is read when the project has none, as a path from the project '
          'root', () async {
        writeAt(p.dirname(project), '# One line down.\n$off');
        write('lib/a.dart', 'int a = 1;\n');
        expect(await entries(['lib/a.dart']), [
          ('../analysis_options.yaml', 4, 'ignore'),
        ]);
      });

      test('is the nearest one, a folder or more up', () async {
        writeAt(p.dirname(p.dirname(project)), off);
        // Nothing in between: the one two folders up.
        expect(await entries([]), [
          ('../../analysis_options.yaml', 3, 'ignore'),
        ]);
        // A nearer file wins, whether or not it switches anything off.
        writeAt(p.dirname(project), 'analyzer:\n  errors:\n    todo: info\n');
        expect(await entries([]), isEmpty);
      });

      test('is not read when the project has an options file of its own, '
          'listed or not', () async {
        writeAt(p.dirname(project), off);
        writeAt(project, 'analyzer:\n  errors:\n    todo: info\n');
        expect(await entries([]), isEmpty);
        expect(await entries(['analysis_options.yaml']), isEmpty);
      });

      test('is read along with the options files below the project', () async {
        writeAt(p.dirname(project), off);
        writeAt(p.join(project, 'packages', 'inner'), off);
        expect(await entries(['packages/inner/analysis_options.yaml']), [
          ('../analysis_options.yaml', 3, 'ignore'),
          ('packages/inner/analysis_options.yaml', 3, 'ignore'),
        ]);
      });

      test('that is not YAML, or has no such entry, gives nothing', () async {
        writeAt(p.dirname(project), 'analyzer: [\n');
        expect(await entries([]), isEmpty);
        writeAt(p.dirname(project), 'linter:\n  rules:\n    - unused_import\n');
        expect(await entries([]), isEmpty);
      });
    });

    // The analyzer follows `include:` and merges the included file's
    // settings under the including file's own (pinned SDK 3.13.4, measured
    // with `dart analyze` on Windows, 2026-10-14): the path is a URI resolved
    // against the including file's folder; a setting of the including file
    // wins over an included one; in a list a later entry wins over an earlier
    // one; a cycle is cut with a warning and the rest still applies; a
    // `package:` URI is followed too (which is not done here).
    group('an include: in an options file', () {
      const off = 'analyzer:\n  errors:\n    deprecated_member_use: ignore\n';

      // Two folders inside the temporary one, so no test writes above it.
      setUp(() => project = p.join(tempDir().path, 'parent', 'my app'));

      void writeAbove(String relative, String content) =>
          File(p.joinAll([p.dirname(project), ...relative.split('/')]))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(content);

      /// The options file of the project that includes the file above, with
      /// [value] given to the code after the `include:`.
      String over(String value) =>
          'include: ../hide.yaml\n'
          'analyzer:\n  errors:\n    deprecated_member_use: $value\n';

      /// The file, line, value and including files (joined) of each entry
      /// found in [files].
      Future<List<(String, int, String?, String)>> entries(
        List<String> files,
      ) async => [
        for (final entry in await readDeprecationIgnores(project, files))
          (
            entry.file,
            entry.line,
            entry.optionsValue,
            entry.includedBy.join(' + '),
          ),
      ];

      const root = ['analysis_options.yaml'];

      test('of a file above the project: its entry is reported on its own '
          'line, with its path from the project root and the file that '
          'includes it', () async {
        writeAbove('hide.yaml', '# Shared.\n$off');
        write('analysis_options.yaml', 'include: ../hide.yaml\n');
        expect(await entries(root), [
          ('../hide.yaml', 4, 'ignore', 'analysis_options.yaml'),
        ]);
      });

      test('of a file inside the project, in every spelling the analyzer '
          'resolves, with a path with /', () async {
        write('shared/base.yaml', off);
        write('with space/other.yaml', off);
        final base = Uri.file(p.join(project, 'shared', 'base.yaml'));
        for (final (include, file) in [
          ('shared/base.yaml', 'shared/base.yaml'),
          ('./shared/../shared/base.yaml', 'shared/base.yaml'),
          (r'shared\base.yaml', 'shared/base.yaml'),
          ('"shared/base.yaml"', 'shared/base.yaml'),
          ('with space/other.yaml', 'with space/other.yaml'),
          ('with%20space/other.yaml', 'with space/other.yaml'),
          ('$base', 'shared/base.yaml'),
        ]) {
          write('analysis_options.yaml', 'include: $include\n');
          expect(await entries(root), [
            (file, 3, 'ignore', 'analysis_options.yaml'),
          ], reason: include);
        }
      });

      test(
        'is resolved against the folder of the file that includes it',
        () async {
          write('packages/inner/base.yaml', off);
          write('base.yaml', '# Not this one.\n$off');
          write('packages/inner/analysis_options.yaml', 'include: base.yaml\n');
          expect(await entries(['packages/inner/analysis_options.yaml']), [
            (
              'packages/inner/base.yaml',
              3,
              'ignore',
              'packages/inner/analysis_options.yaml',
            ),
          ]);
        },
      );

      // The analyzer follows a `package:` include; this does not, the
      // owner's decision of 2026-10-14. The other four it cannot find
      // either (it warns), and a file it cannot parse it reports and goes on.
      test('that is not a file this can follow gives nothing and no '
          'error', () async {
        write('shared/base.yaml', off);
        write('bad.yaml', 'analyzer: [\n  errors: {\n');
        for (final include in [
          'package:some_package/analysis_options.yaml',
          'C:/other/base.yaml',
          'http://example.com/base.yaml',
          'missing.yaml',
          'shared',
          'bad.yaml',
          '',
          '[a, b]',
          '{a: b}',
          'a b: c',
        ]) {
          write('analysis_options.yaml', 'include: $include\n');
          expect(await entries(root), isEmpty, reason: include);
        }
      });

      test('with a setting of the including file that keeps the diagnostic '
          'reports nothing', () async {
        writeAbove('hide.yaml', off);
        for (final value in ['info', 'warning', 'error', 'INFO', '"Warning"']) {
          write('analysis_options.yaml', over(value));
          expect(await entries(root), isEmpty, reason: value);
        }
        write(
          'analysis_options.yaml',
          'include: ../hide.yaml\n'
              'analyzer:\n  errors:\n    DEPRECATED_MEMBER_USE: info\n',
        );
        expect(await entries(root), isEmpty, reason: 'upper case name');
      });

      test('with a setting of the including file that changes nothing, or '
          'for another code, still reports the included entry', () async {
        writeAbove('hide.yaml', off);
        for (final value in ['true', 'bogus', '']) {
          write('analysis_options.yaml', over(value));
          expect(await entries(root), [
            ('../hide.yaml', 3, 'ignore', 'analysis_options.yaml'),
          ], reason: value);
        }
        write(
          'analysis_options.yaml',
          'include: ../hide.yaml\n'
              'analyzer:\n  errors:\n'
              '    deprecated_member_use_from_same_package: info\n'
              '    unused_import: error\n',
        );
        expect(await entries(root), [
          ('../hide.yaml', 3, 'ignore', 'analysis_options.yaml'),
        ]);
      });

      test('with its own ignore: only the nearest entry is reported, the '
          'one that is its own', () async {
        writeAbove('hide.yaml', off);
        write('analysis_options.yaml', over('false'));
        expect(await entries(root), [
          ('analysis_options.yaml', 4, 'false', ''),
        ]);
      });

      test('the same file sets the code back later on: the entry above it '
          'hides nothing', () async {
        writeAbove(
          'hide.yaml',
          'analyzer:\n  errors:\n'
              '    deprecated_member_use: ignore\n'
              '    DEPRECATED_MEMBER_USE: info\n',
        );
        write('analysis_options.yaml', 'include: ../hide.yaml\n');
        expect(await entries(root), isEmpty);
        writeAbove(
          'hide.yaml',
          'analyzer:\n  errors:\n'
              '    deprecated_member_use: info\n'
              '    DEPRECATED_MEMBER_USE: false\n',
        );
        expect(await entries(root), [
          ('../hide.yaml', 4, 'false', 'analysis_options.yaml'),
        ]);
      });

      test('through a chain: every file is followed, and the nearest '
          'setting wins', () async {
        write('analysis_options.yaml', 'include: ../a.yaml\n');
        writeAbove('a.yaml', 'include: b.yaml\n');
        writeAbove('b.yaml', 'include: sub/c.yaml\n');
        writeAbove('sub/c.yaml', '# Deep.\n$off');
        expect(await entries(root), [
          ('../sub/c.yaml', 4, 'ignore', 'analysis_options.yaml'),
        ]);
        // A file nearer to the project sets it back: the deep one is moot.
        writeAbove(
          'b.yaml',
          'include: sub/c.yaml\n'
              'analyzer:\n  errors:\n    deprecated_member_use: info\n',
        );
        expect(await entries(root), isEmpty);
        // And a file nearer still hides it again: that one is reported.
        writeAbove(
          'a.yaml',
          'include: b.yaml\n'
              'analyzer:\n  errors:\n    deprecated_member_use: false\n',
        );
        expect(await entries(root), [
          ('../a.yaml', 4, 'false', 'analysis_options.yaml'),
        ]);
      });

      test('in a list: every file is followed and a later one wins over an '
          'earlier one', () async {
        writeAbove('hide.yaml', off);
        writeAbove(
          'info.yaml',
          'analyzer:\n  errors:\n    deprecated_member_use: info\n',
        );
        final hidden = [('../hide.yaml', 3, 'ignore', 'analysis_options.yaml')];
        for (final (include, expected) in [
          ('  - ../info.yaml\n  - ../hide.yaml\n', hidden),
          ('  - ../hide.yaml\n  - ../info.yaml\n', <Never>[]),
          ('  - ../hide.yaml\n', hidden),
          ('  - 5\n  - [x]\n  - ../hide.yaml\n  - missing.yaml\n', hidden),
        ]) {
          write('analysis_options.yaml', 'include:\n$include');
          expect(await entries(root), expected, reason: include);
        }
      });

      test('that includes itself, round about or at once, ends and reports '
          'the entry once', () async {
        write('analysis_options.yaml', 'include: ../a.yaml\n');
        writeAbove('a.yaml', 'include: b.yaml\n');
        writeAbove('b.yaml', 'include: a.yaml\n$off');
        expect(await entries(root), [
          ('../b.yaml', 4, 'ignore', 'analysis_options.yaml'),
        ]);
        writeAbove('a.yaml', 'include: a.yaml\n$off');
        write('analysis_options.yaml', 'include: ../a.yaml\n');
        expect(await entries(root), [
          ('../a.yaml', 4, 'ignore', 'analysis_options.yaml'),
        ]);
      });

      test('an options file that includes itself, or is included by another '
          'one the server lists, is reported once, as its own', () async {
        write('analysis_options.yaml', 'include: analysis_options.yaml\n$off');
        expect(await entries(root), [
          ('analysis_options.yaml', 4, 'ignore', ''),
        ]);
        write('packages/inner/analysis_options.yaml', off);
        write(
          'analysis_options.yaml',
          'include: packages/inner/analysis_options.yaml\n',
        );
        expect(
          await entries([
            'analysis_options.yaml',
            'packages/inner/analysis_options.yaml',
          ]),
          [('packages/inner/analysis_options.yaml', 3, 'ignore', '')],
        );
      });

      test('one entry is reported once when several options files include '
          'its file, naming each, and not the one that sets it back', () async {
        write('shared.yaml', off);
        write('analysis_options.yaml', 'include: shared.yaml\n');
        write(
          'packages/b/analysis_options.yaml',
          'include: ../../shared.yaml\n',
        );
        write(
          'packages/a/analysis_options.yaml',
          'include: ../../shared.yaml\n',
        );
        write(
          'packages/c/analysis_options.yaml',
          'include: ../../shared.yaml\n'
              'analyzer:\n  errors:\n    deprecated_member_use: info\n',
        );
        expect(
          await entries([
            'packages/c/analysis_options.yaml',
            'packages/b/analysis_options.yaml',
            'analysis_options.yaml',
            'packages/a/analysis_options.yaml',
          ]),
          [
            (
              'shared.yaml',
              3,
              'ignore',
              'analysis_options.yaml + packages/a/analysis_options.yaml + '
                  'packages/b/analysis_options.yaml',
            ),
          ],
        );
      });

      test('in an options file below the project applies to that one only, '
          'whatever the root\'s says', () async {
        write('hide.yaml', off);
        write(
          'analysis_options.yaml',
          'analyzer:\n  errors:\n    todo: info\n',
        );
        write(
          'packages/inner/analysis_options.yaml',
          'include: ../../hide.yaml\n',
        );
        expect(
          await entries([
            'analysis_options.yaml',
            'packages/inner/analysis_options.yaml',
          ]),
          [('hide.yaml', 3, 'ignore', 'packages/inner/analysis_options.yaml')],
        );
      });

      test('in the options file above a project that has none is followed '
          'from the folder of that file', () async {
        writeAbove('analysis_options.yaml', 'include: base/hide.yaml\n');
        writeAbove('base/hide.yaml', '# Shared.\n$off');
        expect(await entries([]), [
          ('../base/hide.yaml', 4, 'ignore', '../analysis_options.yaml'),
        ]);
        // Not when the project has its own options file: the analyzer looks
        // no further up.
        write(
          'analysis_options.yaml',
          'analyzer:\n  errors:\n    todo: info\n',
        );
        expect(await entries(root), isEmpty);
      });

      test('an enclosing options file\'s own entry is the one reported, not '
          'the entry of the file it includes', () async {
        writeAbove('analysis_options.yaml', 'include: hide.yaml\n$off');
        writeAbove('hide.yaml', '# Shared.\n\n$off');
        expect(await entries([]), [
          ('../analysis_options.yaml', 4, 'ignore', ''),
        ]);
      });

      test('writes nothing', () async {
        write('analysis_options.yaml', 'include: shared/base.yaml\n');
        write('shared/base.yaml', off);
        List<String> files() => [
          for (final entity in Directory(project).listSync(recursive: true))
            p.relative(entity.path, from: project),
        ]..sort();
        final before = files();
        expect((await entries(root)).map((entry) => entry.$1), [
          'shared/base.yaml',
        ]);
        expect(files(), before);
      });
    });

    test('more files than are open at a time: each is read, in '
        'order', () async {
      final files = [
        for (var i = 0; i < 150; i++) 'lib/f${'$i'.padLeft(3, '0')}.dart',
      ];
      for (final (index, file) in files.indexed) {
        write(file, index.isEven ? hiding : 'int a = 1;\n');
      }
      expect(await read(files.reversed.toList()), [
        for (final (index, file) in files.indexed)
          if (index.isEven) (file, 1),
      ]);
    });

    test('a file that isn\'t text is read as far as it can be', () async {
      File(p.join(project, 'lib', 'odd.dart'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([...hiding.codeUnits, 0xFF, 0xFE, 0x0A]);
      expect(await read(['lib/odd.dart']), [('lib/odd.dart', 1)]);
    });

    test('a file that is gone, a folder, and a project that doesn\'t exist '
        'are left out without an error', () async {
      write('lib/a.dart', hiding);
      Directory(p.join(project, 'lib', 'folder.dart')).createSync();
      expect(await read(['lib/gone.dart', 'lib/folder.dart', 'lib/a.dart']), [
        ('lib/a.dart', 1),
      ]);
      expect(
        await readDeprecationIgnores(p.join(project, 'no such'), [
          'lib/a.dart',
        ]),
        isEmpty,
      );
      expect(await read([]), isEmpty);
    });

    // The reason it may be left out is proved with a real analysis server
    // in verify_dart_test.dart: the server reports nothing for it either.
    test('a file another handle holds locked is left out without an '
        'error', () async {
      write('lib/locked.dart', hiding);
      write('lib/free.dart', hiding);
      final held = File(
        p.join(project, 'lib', 'locked.dart'),
      ).openSync(mode: FileMode.append)..lockSync(FileLock.exclusive);
      addTearDown(() {
        held
          ..unlockSync()
          ..closeSync();
      });
      expect(await read(['lib/locked.dart', 'lib/free.dart']), [
        ('lib/free.dart', 1),
      ]);
    }, testOn: 'windows');

    test('it writes nothing', () async {
      write('lib/a.dart', hiding);
      List<String> files() => [
        for (final entity in Directory(project).listSync(recursive: true))
          p.relative(entity.path, from: project),
      ]..sort();
      final before = files();
      await read(['lib/a.dart']);
      expect(files(), before);
    });
  });
}
