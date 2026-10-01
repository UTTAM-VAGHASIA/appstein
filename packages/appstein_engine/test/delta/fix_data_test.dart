import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  final flutter = Uri.parse('package:flutter/');

  List<FixDataTransform> parse(String text, {Uri? base}) =>
      parseFixData(text, file: 'fix.yaml', base: base ?? flutter);

  // Two of Flutter 3.47.5's real migrations, from fix_widgets.yaml.
  const stack = '''
version: 1
transforms:
  # Changes made in https://github.com/flutter/flutter/pull/66305
  - title: "Migrate to 'clipBehavior'"
    date: 2020-09-22
    element:
      uris: [ 'widgets.dart', 'material.dart', 'cupertino.dart' ]
      field: 'overflow'
      inClass: 'Stack'
    changes:
      - kind: 'rename'
        newName: 'clipBehavior'

  - title: "Migrate to 'clipBehavior'"
    date: 2020-09-22
    element:
      uris: [ 'widgets.dart', 'material.dart', 'cupertino.dart' ]
      constructor: ''
      inClass: 'Stack'
    oneOf:
      - if: "overflow == 'Overflow.clip'"
        changes:
          - kind: 'addParameter'
            index: 0
            name: 'clipBehavior'
            style: optional_named
          - kind: 'removeParameter'
            name: 'overflow'
''';

  test('reads element migrations, resolving relative URIs against the '
      'package', () {
    final transforms = parse(stack);
    expect(transforms, hasLength(2));
    final field = transforms[0];
    expect(field.title, "Migrate to 'clipBehavior'");
    expect(field.uris.map((u) => '$u'), [
      'package:flutter/widgets.dart',
      'package:flutter/material.dart',
      'package:flutter/cupertino.dart',
    ]);
    expect(field.kind, 'field');
    expect(field.name, 'overflow');
    expect(field.container, 'Stack');
    expect(field.oldParameters, isEmpty);
    expect(field.library, isNull);
  });

  test('an unnamed constructor has the name "", and old parameters come '
      'from oneOf too', () {
    final constructor = parse(stack)[1];
    expect(constructor.kind, 'constructor');
    expect(constructor.name, '');
    expect(constructor.oldParameters, {'overflow'});
  });

  test('renamed parameters count by their old name', () {
    final transforms = parse('''
transforms:
  - title: "Migrate 'child' to 'content'"
    element:
      uris: [ 'cupertino.dart' ]
      constructor: ''
      inClass: 'CupertinoPopupSurface'
    changes:
      - kind: 'renameParameter'
        oldName: 'child'
        newName: 'content'
''');
    expect(transforms.single.oldParameters, {'child'});
  });

  test('a parameter the migration also adds back is not an old one, as in '
      "Flutter 3.47.5's Tooltip migration", () {
    final transforms = parse('''
transforms:
  - title: "Migrate to 'constraints'"
    element:
      uris: [ 'material.dart' ]
      constructor: ""
      inClass: "Tooltip"
    oneOf:
      - if: "height == 'null'"
        changes:
          - kind: "removeParameter"
            name: "height"
      - if: "constraints == 'null' && height != ''"
        changes:
          - kind: "removeParameter"
            name: "constraints"
          - kind: "addParameter"
            index: 0
            name: "constraints"
            style: optional_named
          - kind: "removeParameter"
            name: "height"
''');
    expect(transforms.single.oldParameters, {'height'});
  });

  test('the same library named relatively and absolutely counts once, '
      "as in go_router's file", () {
    final transforms = parse('''
transforms:
  - title: "Replaces 'location' in 'GoRouterState' with `uri.toString()`"
    date: 2023-07-06
    bulkApply: true
    element:
      # TODO(ahmednfwela): Workaround for https://github.com/dart-lang/sdk/issues/52233
      uris: [ 'go_router.dart', 'package:go_router/go_router.dart' ]
      field: 'location'
      inClass: 'GoRouterState'
    changes:
      - kind: 'rename'
        newName: 'uri.toString()'
''', base: Uri.parse('package:go_router/'));
    expect(transforms.single.uris.map((u) => '$u'), [
      'package:go_router/go_router.dart',
    ]);
  });

  test('top-level kinds and the other containers', () {
    final transforms = parse('''
transforms:
  - title: 'A'
    element: {uris: ['a.dart'], function: 'f'}
  - title: 'B'
    element: {uris: ['a.dart'], constant: 'b', inEnum: 'E'}
  - title: 'C'
    element: {uris: ['a.dart'], method: 'm', inExtension: 'X'}
  - title: 'D'
    element: {uris: ['a.dart'], getter: 'g', inMixin: 'M'}
''');
    expect(
      [for (final t in transforms) '${t.kind} ${t.name} ${t.container}'],
      ['function f null', 'constant b E', 'method m X', 'getter g M'],
    );
  });

  test("reads a library migration, as Flutter 3.47's material_ui move", () {
    final transform = parse('''
transforms:
  - title: 'Migrate from flutter/material.dart to material_ui/material_ui.dart.'
    date: 2026-07-08
    library: 'package:flutter/material.dart'
    changes:
      - kind: 'replacedBy'
        newLibrary: 'package:material_ui/material_ui.dart'
''').single;
    expect(transform.library, Uri.parse('package:flutter/material.dart'));
    expect(
      transform.newLibrary,
      Uri.parse('package:material_ui/material_ui.dart'),
    );
    expect(transform.uris, isEmpty);
    expect(transform.kind, isNull);
  });

  test('a library migration without replacedBy has no new library', () {
    final transform = parse('''
transforms:
  - title: 'Stop using it.'
    library: 'package:flutter/material.dart'
''').single;
    expect(transform.newLibrary, isNull);
  });

  for (final empty in [
    '',
    '# Only a comment, like Flutter\'s fix_template.yaml.\n',
    'version: 1\n',
    'version: 1\ntransforms:\n',
  ]) {
    test('has no transforms: ${empty.split('\n').first}', () {
      expect(parse(empty), isEmpty);
    });
  }

  test('CRLF text reads the same', () {
    expect(parse(stack.replaceAll('\n', '\r\n')).map((t) => t.name), [
      'overflow',
      '',
    ]);
  });

  for (final (text, line, problem) in [
    ('- a\n', 1, 'must be a map with a "transforms" list.'),
    ('transforms: 3\n', 1, '"transforms" must be a list.'),
    ('transforms:\n  - 3\n', 2, 'Each transform must be a map.'),
    (
      'transforms:\n  - date: 2020-01-01\n',
      2,
      'A transform needs a "title" string.',
    ),
    (
      "transforms:\n  - title: 'x'\n",
      2,
      'A transform needs an "element" map or a "library".',
    ),
    (
      "transforms:\n  - title: 'x'\n    element:\n      class: 'A'\n",
      4,
      '"uris" must be a list of URI strings.',
    ),
    (
      "transforms:\n  - title: 'x'\n    element:\n      uris: ['a.dart']\n      class: 'A'\n      method: 'm'\n",
      4,
      'The element must name exactly one of: class, constant, constructor, '
          'enum, extension, field, function, getter, method, mixin, setter, '
          'typedef, variable.',
    ),
    (
      "transforms:\n  - title: 'x'\n    element:\n      uris: ['a.dart']\n      extensionType: 'A'\n",
      4,
      'The element must name exactly one of: class, constant, constructor, '
          'enum, extension, field, function, getter, method, mixin, setter, '
          'typedef, variable.',
    ),
    (
      "transforms:\n  - title: 'x'\n    element:\n      uris: ['a.dart']\n      method: 'm'\n      inClass: 'A'\n      inMixin: 'B'\n",
      4,
      'The element may have only one of inClass, inEnum, inExtension, '
          'inMixin.',
    ),
  ]) {
    test('reports line $line: $problem', () {
      expect(
        () => parse(text),
        throwsA(
          isA<FixDataFormatException>()
              .having((e) => e.file, 'file', 'fix.yaml')
              .having((e) => e.line, 'line', line)
              .having((e) => e.problem, 'problem', problem)
              .having((e) => e.reason, 'reason', 'line $line: $problem'),
        ),
      );
    });
  }

  test('invalid YAML is a FixDataFormatException with its line', () {
    expect(
      () => parse('transforms:\n  - title: [\n'),
      throwsA(
        isA<FixDataFormatException>()
            .having((e) => e.line, 'line', isNotNull)
            .having(
              (e) => e.problem,
              'problem',
              startsWith('is not valid YAML'),
            ),
      ),
    );
  });

  // Odd shapes are reported, never a TypeError, so sync lists the file
  // under "Not read" and carries on.
  for (final odd in [
    'hello\n',
    'transforms:\n  - title: 3\n',
    "transforms:\n  - title: 'x'\n    library: 3\n",
    "transforms:\n  - title: 'x'\n    element:\n      uris: [3]\n      class: 'A'\n",
    "transforms:\n  - title: 'x'\n    element:\n      uris: ['a.dart']\n      class: ['A']\n",
    "transforms:\n  - title: 'x'\n    element:\n      uris: ['a.dart']\n      method: 'm'\n      inClass: 3\n",
    "transforms:\n  - title: 'x'\n    element:\n      uris: ['http://[x']\n      class: 'A'\n",
  ]) {
    test('reports an odd shape: ${odd.replaceAll('\n', ' ').trim()}', () {
      expect(() => parse(odd), throwsA(isA<FixDataFormatException>()));
    });
  }
}
