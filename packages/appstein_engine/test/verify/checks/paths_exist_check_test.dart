import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../docs/support/docs_support.dart';
import '../../support/temp.dart';

const _check = PathsExistCheck();

void main() {
  late String root;

  setUp(() {
    // The project is a folder inside the temp folder, so a file can be put
    // next to it, outside the project.
    root = p.join(tempDir().path, 'app');
    Directory(root).createSync();
  });

  void file(String path, {String? under}) =>
      File(p.joinAll([under ?? root, ...path.split('/')]))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');

  List<String> problems(List<String> paths) => _check.problems(
    decisionEntry(1, 'A decision', paths: paths),
    VerifyContext(
      projectRoot: root,
      config: const AppsteinConfig(),
      packs: const [],
      knowledge: KnowledgeSnapshot(root),
      decisions: const DecisionSet(),
    ),
  );

  test('it is `paths.exist` and reads no map', () {
    expect(_check.id, 'paths.exist');
    expect(_check.needsMap, isFalse);
  });

  test('a decision with no paths holds', () {
    expect(problems(const []), isEmpty);
  });

  test('a pattern that matches a file holds', () {
    file('lib/ui/booking/view_models/booking_viewmodel.dart');
    expect(problems(['lib/ui/**/view_models/**']), isEmpty);
    expect(problems(['lib/ui/*/view_models/*.dart']), isEmpty);
    expect(problems(['lib/{ui,data}/**.dart']), isEmpty);
  });

  test('a plain path holds when it is a file or a folder', () {
    file('lib/main.dart');
    expect(problems(['lib/main.dart']), isEmpty);
    expect(problems(['lib']), isEmpty);
    expect(problems(['lib/']), isEmpty);
    expect(problems(['./lib/main.dart']), isEmpty);
    expect(problems([r'lib\main.dart']), isEmpty);
  });

  test('each pattern that matches nothing is named', () {
    file('lib/main.dart');
    expect(problems(['lib/gone.dart', 'lib/main.dart', 'lib/ui/**']), [
      'The path `lib/gone.dart` matches no file.',
      'The path `lib/ui/**` matches no file.',
    ]);
  });

  test('a pattern in a folder that does not exist matches nothing', () {
    expect(problems(['nowhere/**/*.dart']), [
      'The path `nowhere/**/*.dart` matches no file.',
    ]);
  });

  test('a pattern that could leave the project is reported, and nothing '
      'outside the project is listed', () {
    // Each of these would match if it were followed.
    file('x', under: p.dirname(root));
    file('x');
    file('lib/x');
    for (final pattern in [
      '{..,lib}/x',
      '../x',
      'lib/../../x',
      'lib/..',
      r'..\x',
      '/etc/passwd',
      r'C:\x',
      'C:/x',
      r'\\server\share\x',
      '{lib,..}/x',
    ]) {
      expect(problems([pattern]), [
        'The path `$pattern` could leave the project, so it was not checked.',
      ], reason: pattern);
    }
  });

  test('two dots inside a name are not a way out', () {
    file('lib/a..b.dart');
    file('lib/..hidden');
    expect(problems(['lib/a..b.dart', 'lib/..hidden', 'lib/a..*']), isEmpty);
  });

  test('a pattern that is not a valid glob is named', () {
    expect(problems(['lib/[x']), ['The path `lib/[x` is not a valid pattern.']);
  });
}
