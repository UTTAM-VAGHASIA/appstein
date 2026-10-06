import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/temp.dart';

void main() {
  late String root;

  setUp(() => root = tempDir().path);

  void lessons(int lines, {String eol = '\n', bool endingBreak = true}) {
    final text = [for (var i = 1; i <= lines; i++) '- lesson $i'].join(eol);
    File(p.join(root, '.appstein', 'memory', 'lessons.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(endingBreak ? '$text$eol' : text);
  }

  Future<List<Finding>> run([
    LessonsLongCheck check = const LessonsLongCheck(),
  ]) => check.run(
    VerifyContext(
      projectRoot: root,
      config: const AppsteinConfig(),
      packs: const [],
      knowledge: KnowledgeSnapshot(root),
      decisions: const DecisionSet(),
    ),
  );

  test('it is `memory.lessons_long`, in full mode, without the map', () {
    const check = LessonsLongCheck();
    expect(check.ids, ['memory.lessons_long']);
    expect(check.mode, VerifyMode.full);
    expect(check.needsMap, isFalse);
    expect(check.limit, 200);
  });

  test('no file: no finding', () async {
    expect(await run(), isEmpty);
  });

  test('a folder in the file\'s place: no finding', () async {
    Directory(
      p.join(root, '.appstein', 'memory', 'lessons.md'),
    ).createSync(recursive: true);
    expect(await run(), isEmpty);
  });

  test('200 lines are fine, however the file ends', () async {
    lessons(200);
    expect(await run(), isEmpty);
    lessons(200, endingBreak: false);
    expect(await run(), isEmpty);
    lessons(200, eol: '\r\n');
    expect(await run(), isEmpty);
  });

  test('201 lines: one info finding that says how many', () async {
    lessons(201, eol: '\r\n');
    final finding = (await run()).single;
    expect(finding.id, 'memory.lessons_long');
    expect(finding.severity, Severity.info);
    expect(finding.file, '.appstein/memory/lessons.md');
    expect(finding.line, isNull);
    expect(
      finding.message,
      'lessons.md has 201 lines; over 200, it is slow to read in full.',
    );
    expect(
      finding.fixHint,
      'Merge related lessons into fewer lines. Nothing is deleted '
      'automatically.',
    );
  });

  test('the limit can be set', () async {
    lessons(4);
    expect(await run(const LessonsLongCheck(limit: 4)), isEmpty);
    expect(
      (await run(const LessonsLongCheck(limit: 3))).single.message,
      'lessons.md has 4 lines; over 3, it is slow to read in full.',
    );
  });
}
