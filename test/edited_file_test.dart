import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/src/edited_file.dart';
import 'support/temp_repo.dart';

void main() {
  const original = '/// A.\nclass A {}\n';
  late Directory project;
  late File file;

  setUp(() {
    project = tempFolder();
    file = File(p.join(project.path, 'lib', 'a.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync(original);
  });

  test('projectFile reads a path from the root with / in any folder', () {
    expect(projectFile(project.path, 'lib/a.dart').path, file.path);
    expect(
      projectFile(project.path, 'a.dart').path,
      p.join(project.path, 'a.dart'),
    );
  });

  test('adds the error of each edit on a line of its own, and says which '
      'line', () {
    final edited = EditedFile(project.path, 'lib/a.dart');
    final lines = <int>[];
    for (var n = 0; n < 3; n++) {
      lines.add(edited.addError(n));
      final text = file.readAsLinesSync();
      expect(text[lines.last - 1], startsWith('int wrong$n'));
    }
    expect(lines.toSet(), hasLength(3));
  });

  test('puts the file back as it was', () {
    final edited = EditedFile(project.path, 'lib/a.dart')..addError(4);
    expect(file.readAsStringSync(), isNot(original));
    edited.restore();
    expect(file.readAsStringSync(), original);
  });
}
