import 'dart:convert';
import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_app.dart';
import '../support/temp.dart';

void main() {
  const mainDart = '''
import 'package:delta_kit/delta_kit.dart';

/// The app's own deprecated API, which the delta leaves out.
@Deprecated('Use newHelper instead.')
void oldHelper() {}

Object box() => NewBox(size: 1);
''';

  Future<DeltaFacts> collect(String main) async =>
      collectDelta(await analyzeDeltaApp(main), dartSdkPath: testDartSdk);

  List<String> kit(Iterable<Object> facts) => [
    for (final fact in facts)
      if ('$fact'.startsWith('package:delta_kit ')) '$fact',
  ];

  test("lists every kind of deprecation the imports expose, with the "
      "library's own message on one line", () async {
    final facts = await collect(mainDart);
    expect(kit(facts.deprecated), [
      'package:delta_kit Mode.b [use] Use a.',
      'package:delta_kit NewBox.colour= [use] (no message)',
      'package:delta_kit NewBox.draw [use] Use paint instead.',
      'package:delta_kit NewBox.new(label) [optional] Pass a label; it '
          'becomes required in 2.0.',
      "package:delta_kit NewBox.new(width) [use] Use size instead. "
          "| Migrate 'width' to 'size'",
      'package:delta_kit NewBox.surface [use] Use area instead.',
      "package:delta_kit OldBox [use] Use NewBox instead. This feature was "
          "deprecated after v1.2.0-3.0.pre. | Migrate to 'NewBox'",
      'package:delta_kit Panel.show [use] Use open instead.',
      'package:delta_kit Sealing [extend] (no message)',
      'package:delta_kit Shape [implement] Extend Shape instead.',
      'package:delta_kit drawAll [use] Use `paint()` instead of drawing '
          '*by hand*.',
      'package:delta_kit legacyLevel [use] Use Mode.a instead.',
      'package:delta_kit legacyMode= [use] Use Mode instead.',
      'package:delta_kit legacyName [use] Use Mode.b instead.',
    ]);
  });

  test("leaves out the app's own code and what no import exposes", () async {
    final text = (await collect(mainDart)).toString();
    expect(text, isNot(contains('oldHelper')));
    expect(text, isNot(contains('Hidden')));
    expect(text, isNot(contains('Extra')));
    expect(text, isNot(contains('_PanelBase')));
  });

  test('classifies the migrations in scope: removed, changed, or attached '
      'to a deprecation', () async {
    final facts = await collect(mainDart);
    expect(kit(facts.migrated), [
      "package:delta_kit GoneBox removed Rename to 'NewBox'",
      "package:delta_kit NewBox.new changed Migrate from 'height'",
      "package:delta_kit NewBox.render removed Rename to 'paint'",
    ]);
  });

  test('a library migration is a moved library when the app imports '
      'it', () async {
    final facts = await collect(mainDart);
    expect(facts.moved.map((m) => '$m'), [
      'package:delta_kit/delta_kit.dart -> '
          'package:delta_kit_v2/delta_kit_v2.dart: '
          'Migrate from delta_kit to delta_kit_v2.',
    ]);
  });

  test('a broken migration file is reported, an empty one is not, and '
      'the rest still counts', () async {
    final facts = await collect(mainDart);
    expect(facts.unread.map((u) => '$u'), [
      'package:delta_kit/fix_data/fix_broken.yaml: line 2: A transform '
          'needs an "element" map or a "library".',
    ]);
    expect(kit(facts.migrated), isNotEmpty);
  });

  test('an app that imports nothing from delta_kit gets nothing from '
      'it', () async {
    final facts = await collect("String hi() => 'hi';\n");
    expect(kit(facts.deprecated), isEmpty);
    expect(kit(facts.migrated), isEmpty);
    expect(facts.moved, isEmpty);
    expect(facts.unread, isEmpty);
  });

  test("importing dart:io brings the Dart SDK's own migrations", () async {
    final facts = await collect(
      "import 'dart:io';\n\nString home() => Platform.pathSeparator;\n",
    );
    expect(facts.migrated.where((m) => m.group == 'dart:io'), isNotEmpty);
  });

  test('a deprecation in a private dart: library is grouped under the public '
      'library it was reached through', () async {
    final facts = await collect(
      "import 'dart:io';\n\nString home() => Platform.pathSeparator;\n",
    );
    for (final group in [
      ...facts.deprecated.map((d) => d.group),
      ...facts.migrated.map((m) => m.group),
    ]) {
      expect(group, isNot(startsWith('dart:_')));
    }
    // Where this SDK has them, HttpStatus's old names are dart:io's.
    final statuses = facts.deprecated.where(
      (d) => d.name.startsWith('HttpStatus.'),
    );
    expect(
      statuses.map((d) => d.group).toSet().difference({'dart:io'}),
      isEmpty,
    );
  });

  test('a fix_data file that is not valid UTF-8 is unread, with a name '
      'free of any machine path', () async {
    final analysis = await analyzeDeltaApp(mainDart);
    final folder = p.join(
      analysis.projectRoot,
      '..',
      'stubs',
      'delta_kit',
      'lib',
      'fix_data',
    );
    File(
      p.join(folder, 'fix_bytes.yaml'),
    ).writeAsBytesSync([0x74, 0x3a, 0xff, 0xfe, 0x80]);
    final facts = collectDelta(analysis, dartSdkPath: testDartSdk);
    final bad = facts.unread.where(
      (u) => u.file == 'package:delta_kit/fix_data/fix_bytes.yaml',
    );
    expect(bad, hasLength(1));
    expect('${bad.single}', isNot(contains(p.normalize(analysis.projectRoot))));
    expect(kit(facts.migrated), isNotEmpty);
  });

  test('a package whose files sit under the project folder is not the '
      "project's own", () async {
    final work = tempDir().path;
    final app = p.join(work, 'delta app');
    File(p.join(app, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('name: delta_app\nenvironment:\n  sdk: ^3.12.0\n');
    File(p.join(app, 'lib', 'main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync(mainDart);
    copyFixtureTree(
      p.join(fixtureAppsDir, 'stubs', 'delta_kit'),
      p.join(app, 'vendor', 'delta_kit'),
    );
    File(p.join(app, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'delta_app',
              'rootUri': '../',
              'packageUri': 'lib/',
              'languageVersion': '3.12',
            },
            {
              'name': 'delta_kit',
              'rootUri': '../vendor/delta_kit',
              'packageUri': 'lib/',
              'languageVersion': '3.12',
            },
          ],
        }),
      );
    final analysis = await ProjectAnalysis.analyze(
      app,
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    final facts = collectDelta(analysis, dartSdkPath: testDartSdk);
    expect(kit(facts.deprecated), isNotEmpty);
    expect(kit(facts.migrated), isNotEmpty);
  });

  test("go_router's single fix_data.yaml counts: location was "
      'removed', () async {
    final app = copyFixtureApp();
    final analysis = await ProjectAnalysis.analyze(
      app,
      dartSdkPath: testDartSdk,
    );
    addTearDown(analysis.dispose);
    final facts = collectDelta(analysis, dartSdkPath: testDartSdk);
    expect(
      facts.migrated.map((m) => '$m'),
      contains(
        "package:go_router GoRouterState.location removed Replaces "
        "'location' in 'GoRouterState' with `uri.toString()`",
      ),
    );
  });

  test('two collections of the same project are equal', () async {
    final analysis = await analyzeDeltaApp(mainDart);
    final first = collectDelta(analysis, dartSdkPath: testDartSdk);
    final second = collectDelta(analysis, dartSdkPath: testDartSdk);
    expect(second, first);
    expect('$second', '$first');
  });
}
