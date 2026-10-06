import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp.dart';
import 'support/docs_support.dart';

DocSection _section(String path, String text) =>
    DocSection(path: path, title: 'T', markdown: text);

/// Pages rendered from [sections], plus the README.
List<RenderedPage> _pages(Map<String, String> sections) => renderPages(
  knowledge: sampleKnowledge(),
  sources: [
    (
      id: 'official_mvvm',
      version: '2',
      pages: [
        FakeDocPage([
          for (final MapEntry(:key, :value) in sections.entries)
            _section(key, value),
        ]),
      ],
    ),
  ],
  readme: (_, pages) => DocSection(
    path: 'README.md',
    title: 'Home',
    markdown: pages.map((page) => '- ${page.path}').join('\n'),
  ),
);

void main() {
  late String folder;

  setUp(() => folder = p.join(tempDir().path, 'docs', 'the app'));

  File file(String path) => File(p.joinAll([folder, ...path.split('/')]));

  void write(String path, String text) => file(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  Map<String, String> onDisk() => {
    for (final entity in Directory(folder).listSync(recursive: true))
      if (entity is File)
        p.split(p.relative(entity.path, from: folder)).join('/'): entity
            .readAsStringSync(),
  };

  ({List<DocChange> changes, List<String> blocked}) plan(
    List<RenderedPage> pages,
  ) => planDocs(folder, scanDocsFolder(folder), pages);

  Future<void> render(List<RenderedPage> pages) async {
    final planned = plan(pages);
    expect(planned.blocked, isEmpty);
    await applyDocs(folder, pages, planned.changes);
  }

  Map<String, String> summary(List<DocChange> changes) => {
    for (final change in changes)
      change.path:
          '${change.kind.name}'
          '${change.reason == null ? '' : '/${change.reason!.name}'}'
          '${change.hadHandEdits ? '/handEdits' : ''}',
  };

  final pages = _pages({
    'routes.md': 'One route.',
    'features/auth/login.md': 'Login.',
    'features/home.md': 'Home.',
  });

  test('a missing folder is an empty scan, and every page is missing', () {
    final scan = scanDocsFolder(folder);
    expect(scan.generated, isEmpty);
    expect(scan.teamNotes, isEmpty);
    expect(scan.problems, isEmpty);
    final planned = plan(pages);
    expect(planned.blocked, isEmpty);
    expect(summary(planned.changes), {
      'README.md': 'write/missing',
      'features/auth/login.md': 'write/missing',
      'features/home.md': 'write/missing',
      'routes.md': 'write/missing',
    });
    expect(Directory(folder).existsSync(), isFalse, reason: 'planning');
  });

  test('writes the pages, and the next plan changes nothing', () async {
    await render(pages);
    expect(onDisk(), {for (final page in pages) page.path: page.text});
    expect(
      file('routes.md').readAsBytesSync().take(3),
      isNot([0xEF, 0xBB, 0xBF]),
    );
    expect(summary(plan(pages).changes).values.toSet(), {'unchanged'});
  });

  test('pages with other line endings or a BOM are unchanged, and are not '
      'rewritten', () async {
    for (final page in pages) {
      write(page.path, page.text.replaceAll('\n', '\r\n'));
    }
    write(
      'routes.md',
      '${String.fromCharCode(0xFEFF)}${file('routes.md').readAsStringSync()}',
    );
    final before = {
      for (final page in pages)
        page.path: (
          file(page.path).readAsBytesSync(),
          file(page.path).lastModifiedSync(),
        ),
    };
    final planned = plan(pages);
    expect(summary(planned.changes).values.toSet(), {'unchanged'});
    await applyDocs(folder, pages, planned.changes);
    for (final page in pages) {
      expect(file(page.path).readAsBytesSync(), before[page.path]!.$1);
      expect(file(page.path).lastModifiedSync(), before[page.path]!.$2);
    }
  });

  test('a page edited by hand is overwritten, and the plan says so', () async {
    await render(pages);
    final routes = pages.singleWhere((page) => page.path == 'routes.md');
    write('routes.md', '${routes.text}My own note.\n');
    final planned = plan(pages);
    expect(summary(planned.changes)['routes.md'], 'write/handEdited/handEdits');
    await applyDocs(folder, pages, planned.changes);
    expect(file('routes.md').readAsStringSync(), routes.text);
  });

  test('a page from an older render is behind, not hand-edited', () async {
    await render(_pages({'routes.md': 'An older route.'}));
    final planned = plan(_pages({'routes.md': 'One route.'}));
    expect(summary(planned.changes), {
      'README.md': 'unchanged',
      'routes.md': 'write/behind',
    });
  });

  test('a page that is no longer rendered is removed, with the folders it '
      'leaves empty', () async {
    await render(pages);
    final fewer = _pages({
      'routes.md': 'One route.',
      'features/home.md': 'Home.',
    });
    var planned = plan(fewer);
    expect(summary(planned.changes), {
      'README.md': 'write/behind',
      'features/auth/login.md': 'remove/notRendered',
      'features/home.md': 'unchanged',
      'routes.md': 'unchanged',
    });
    await applyDocs(folder, fewer, planned.changes);
    expect(onDisk().keys.toSet(), {
      'README.md',
      'features/home.md',
      'routes.md',
    });
    expect(Directory(p.join(folder, 'features', 'auth')).existsSync(), isFalse);
    expect(Directory(p.join(folder, 'features')).existsSync(), isTrue);

    final none = _pages({'routes.md': 'One route.'});
    planned = plan(none);
    await applyDocs(folder, none, planned.changes);
    expect(Directory(p.join(folder, 'features')).existsSync(), isFalse);
    expect(Directory(folder).existsSync(), isTrue);
  });

  test('a removed page that had hand edits is reported as such', () async {
    await render(pages);
    write(
      'features/home.md',
      '${file('features/home.md').readAsStringSync()}Mine.\n',
    );
    final planned = plan(_pages({'routes.md': 'One route.'}));
    expect(
      summary(planned.changes)['features/home.md'],
      'remove/notRendered/handEdits',
    );
  });

  test('a folder that still holds a team note is kept', () async {
    await render(pages);
    write('features/auth/notes.md', '# Auth notes\n');
    final fewer = _pages({'routes.md': 'One route.'});
    await applyDocs(folder, fewer, plan(fewer).changes);
    expect(file('features/auth/notes.md').existsSync(), isTrue);
    expect(file('features/auth/login.md').existsSync(), isFalse);
  });

  test('team notes are listed by title and never touched', () async {
    write('onboarding.md', '\n# Start here\n\nText.\n');
    write('runbooks/deploy it.md', 'No heading here.\n## Second level\n');
    write('z.MD', '#Not a heading\n# Zed  \n');
    write('notes.txt', '# Not Markdown\n');
    file('logo.png').writeAsBytesSync([0x89, 0x50, 0xFF]);
    file('odd.md').writeAsBytesSync([0x23, 0x20, 0xC3, 0x28, 0x0A]);
    final before = {
      for (final entity in Directory(folder).listSync(recursive: true))
        if (entity is File) entity.path: entity.readAsBytesSync(),
    };
    final scan = scanDocsFolder(folder);
    expect(scan.problems, isEmpty);
    expect(
      {for (final note in scan.teamNotes) note.path: note.title},
      {
        'odd.md': 'odd.md',
        'onboarding.md': 'Start here',
        'runbooks/deploy it.md': 'runbooks/deploy it.md',
        'z.MD': 'Zed',
      },
    );
    expect(
      [for (final note in scan.teamNotes) note.path],
      ['odd.md', 'onboarding.md', 'runbooks/deploy it.md', 'z.MD'],
    );
    await render(pages);
    for (final MapEntry(:key, :value) in before.entries) {
      expect(File(key).readAsBytesSync(), value, reason: key);
    }
    expect(summary(plan(pages).changes).keys, isNot(contains('onboarding.md')));
  });

  group('a file in the way blocks the run:', () {
    test('a file a person wrote where a page goes', () {
      write('routes.md', '# Our routes\n');
      final planned = plan(pages);
      expect(planned.blocked, [
        '`routes.md` is not an Appstein page (it has no marker), and a page '
            'would be written there. Move or rename it.',
      ]);
    });

    test('a folder where a page goes', () {
      Directory(p.join(folder, 'routes.md')).createSync(recursive: true);
      expect(plan(pages).blocked, [
        '`routes.md` is a folder, and a page would be written there. Move '
            'or rename it.',
      ]);
    });

    test('a file where a folder of pages goes', () {
      write('features', 'not a folder');
      expect(plan(pages).blocked, [
        '`features` is a file, and `features/auth/login.md` would be '
            'written inside it. Move or rename it.',
        '`features` is a file, and `features/home.md` would be written '
            'inside it. Move or rename it.',
      ]);
    });

    test('the docs folder being a file', () {
      File(folder)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');
      final scan = scanDocsFolder(folder);
      expect(scan.problems, [
        'the docs folder is a file, not a folder. Move or rename it.',
      ]);
    });
  });

  test('a page under another letter case is that page where the file system '
      'ignores case', () async {
    await render(pages);
    final routes = pages.singleWhere((page) => page.path == 'routes.md');
    file('routes.md').renameSync(p.join(folder, 'Routes.md'));
    final caseBlind = file('routes.md').existsSync();
    final planned = plan(pages);
    expect(planned.blocked, isEmpty);
    if (caseBlind) {
      expect(summary(planned.changes), isNot(contains('Routes.md')));
      expect(summary(planned.changes)['routes.md'], 'unchanged');
    } else {
      expect(summary(planned.changes)['Routes.md'], 'remove/notRendered');
      expect(summary(planned.changes)['routes.md'], 'write/missing');
    }
    await applyDocs(folder, pages, planned.changes);
    expect(file('routes.md').readAsStringSync(), routes.text);
  });

  test('a write that fails leaves the old page whole', () async {
    await render(_pages({'routes.md': 'An older route.'}));
    final old = file('routes.md').readAsStringSync();
    // A folder where the temporary file goes makes the write fail on every
    // system.
    Directory('${file('routes.md').path}.tmp').createSync();
    final newer = _pages({'routes.md': 'One route.'});
    await expectLater(
      applyDocs(folder, newer, plan(newer).changes),
      throwsA(
        isA<KnowledgeWriteException>()
            .having((e) => e.path, 'path', file('routes.md').path)
            .having((e) => '$e', 'text', isNot(contains('appstein sync'))),
      ),
    );
    expect(file('routes.md').readAsStringSync(), old);
  });

  test('a link in the folder is not followed and not removed', () async {
    await render(pages);
    final outside = p.join(p.dirname(p.dirname(folder)), 'outside');
    final marked = pages.first.text;
    File(p.join(outside, 'stale.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync(marked);
    try {
      Link(p.join(folder, 'linked')).createSync(outside);
    } on FileSystemException {
      markTestSkipped('this system does not let the test make a link');
      return;
    }
    final planned = plan(pages);
    expect(summary(planned.changes).keys, isNot(contains('linked/stale.md')));
    await applyDocs(folder, pages, planned.changes);
    expect(File(p.join(outside, 'stale.md')).readAsStringSync(), marked);
  });
}
