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

  test('a page that is no longer rendered is kept when a person edited '
      'it', () async {
    await render(pages);
    final edited = '${file('features/home.md').readAsStringSync()}Mine.\n';
    write('features/home.md', edited);
    // A copy of a page that someone turned into their own notes still has
    // the marker in its first line.
    final notes = '${file('routes.md').readAsStringSync()}My notes.\n';
    write('my-route-notes.md', notes);
    final fewer = _pages({'routes.md': 'One route.'});
    final planned = plan(fewer);
    expect(planned.blocked, isEmpty);
    expect(summary(planned.changes), {
      'README.md': 'write/behind',
      'features/auth/login.md': 'remove/notRendered',
      'features/home.md': 'keep/editedLeftover/handEdits',
      'my-route-notes.md': 'keep/editedLeftover/handEdits',
      'routes.md': 'unchanged',
    });
    await applyDocs(folder, fewer, planned.changes);
    expect(file('features/home.md').readAsStringSync(), edited);
    expect(file('my-route-notes.md').readAsStringSync(), notes);
    expect(file('features/auth/login.md').existsSync(), isFalse);
    // It is reported until a person deals with it.
    expect(
      summary(plan(fewer).changes)['my-route-notes.md'],
      'keep/editedLeftover/handEdits',
    );
  });

  test('an unedited copy of a page is removed like any leftover', () async {
    await render(pages);
    write('copy.md', file('routes.md').readAsStringSync());
    expect(summary(plan(pages).changes)['copy.md'], 'remove/notRendered');
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

  test("a person's file is never taken for a page under another letter "
      'case', () async {
    // What a file system that tells letter case apart holds: a person's
    // `routes.md` and a marked `Routes.md`. The scan is given as that
    // system would list it, so this runs everywhere.
    final routes = pages.singleWhere((page) => page.path == 'routes.md');
    write('routes.md', '# Our own routes\n');
    final scan = DocsFolderScan(
      generated: {'Routes.md': routes.text},
      teamNotes: const [TeamNote(path: 'routes.md', title: 'Our own routes')],
    );
    final planned = planDocs(folder, scan, pages);
    expect(planned.blocked, [
      '`routes.md` is not an Appstein page (it has no marker), and a page '
          'would be written there. Move or rename it.',
    ]);
    expect(summary(planned.changes).keys, isNot(contains('routes.md')));
    expect(file('routes.md').readAsStringSync(), '# Our own routes\n');
  });

  test("a person's file under another letter case is named as it is on "
      'disk', () {
    write('Routes.md', '# Our own routes\n');
    final planned = plan(pages);
    if (file('routes.md').existsSync()) {
      expect(planned.blocked, [
        '`Routes.md` is not an Appstein page (it has no marker), and the '
            'page `routes.md` would be written over it. Move or rename it.',
      ]);
    } else {
      expect(planned.blocked, isEmpty);
      expect(summary(planned.changes)['routes.md'], 'write/missing');
    }
  });

  test('a page with a merge conflict is still a page, and is written '
      'again', () async {
    await render(pages);
    final routes = pages.singleWhere((page) => page.path == 'routes.md');
    final theirs = _pages({
      'routes.md': 'Another route.',
    }).singleWhere((page) => page.path == 'routes.md');
    final conflicted =
        '<<<<<<< HEAD\n${routes.marker.line}\n=======\n'
        '${theirs.marker.line}\n>>>>>>> feature\n'
        '${bodyOf(routes.text)}';
    for (final text in [conflicted, conflicted.replaceAll('\n', '\r\n')]) {
      write('routes.md', text);
      final scan = scanDocsFolder(folder);
      expect(scan.generated.keys, contains('routes.md'));
      expect(scan.teamNotes, isEmpty);
      final planned = plan(pages);
      expect(planned.blocked, isEmpty);
      expect(summary(planned.changes)['routes.md'], 'write/conflicted');
      await applyDocs(folder, pages, planned.changes);
      expect(file('routes.md').readAsStringSync(), routes.text);
    }
  });

  test('conflict lines in a file without a marker do not make it a page', () {
    write('notes.md', '<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> x\n');
    write(
      'later.md',
      '# Notes\n\n<<<<<<< HEAD\n${pages.first.marker.line}\n=======\n',
    );
    final scan = scanDocsFolder(folder);
    expect(scan.generated, isEmpty);
    expect(
      [for (final note in scan.teamNotes) note.path],
      ['later.md', 'notes.md'],
    );
  });

  test('a write that fails leaves the old page whole', () async {
    await render(_pages({'routes.md': 'An older route.'}));
    final old = file('routes.md').readAsStringSync();
    // A folder where the temporary file goes makes the write fail on every
    // system.
    final newer = _pages({'routes.md': 'One route.'});
    final changes = plan(newer).changes;
    Directory('${file('routes.md').path}.tmp').createSync();
    // A plan made now would name the folder as in the way; this one was
    // made before it appeared.
    expect(plan(newer).blocked, hasLength(1));
    await expectLater(
      applyDocs(folder, newer, changes),
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

  group('blank lines at the end of a page (an editor adds or strips '
      'them)', () {
    final routes = pages.singleWhere((page) => page.path == 'routes.md');

    test('a page without its final newline, or with more, is '
        'unchanged', () async {
      for (final text in [
        routes.text.substring(0, routes.text.length - 1),
        '${routes.text}\n\n',
        '${routes.text.replaceAll('\n', '\r\n')}\r\n',
      ]) {
        await render(pages);
        write('routes.md', text);
        final modified = file('routes.md').lastModifiedSync();
        final planned = plan(pages);
        expect(summary(planned.changes)['routes.md'], 'unchanged');
        await applyDocs(folder, pages, planned.changes);
        expect(file('routes.md').readAsStringSync(), text);
        expect(file('routes.md').lastModifiedSync(), modified);
      }
    });

    test('a page that fell behind and lost its final newline is behind, '
        'not hand-edited', () async {
      final old = _pages({
        'routes.md': 'An older route.',
      }).singleWhere((page) => page.path == 'routes.md');
      write('routes.md', old.text.substring(0, old.text.length - 1));
      expect(summary(plan(pages).changes)['routes.md'], 'write/behind');
    });

    test('a blank line removed inside the page is still a hand edit', () async {
      await render(pages);
      write('routes.md', routes.text.replaceFirst('\n\n# ', '\n# '));
      expect(
        summary(plan(pages).changes)['routes.md'],
        'write/handEdited/handEdits',
      );
    });

    test('a leftover page that only lost its final newline is still '
        'removed', () async {
      await render(pages);
      final home = pages.singleWhere((page) => page.path == 'features/home.md');
      write('features/home.md', home.text.trimRight());
      final fewer = _pages({'routes.md': 'One route.'});
      expect(
        summary(plan(fewer).changes)['features/home.md'],
        'remove/notRendered',
      );
    });
  });

  group("a person's file where a page's temporary file goes", () {
    test('blocks the page that would be written', () async {
      await render(pages);
      write('routes.md.tmp', 'my scratch notes');
      final newer = _pages({
        'routes.md': 'Two routes.',
        'features/auth/login.md': 'Login.',
        'features/home.md': 'Home.',
      });
      expect(plan(newer).blocked, [
        '`routes.md.tmp` is in the way: Appstein writes `routes.md` through '
            'a file of that name. Move or delete it.',
      ]);
      expect(file('routes.md.tmp').readAsStringSync(), 'my scratch notes');
    });

    test('blocks nothing next to a page that is unchanged', () async {
      await render(pages);
      write('routes.md.tmp', 'my scratch notes');
      expect(plan(pages).blocked, isEmpty);
    });

    test('blocks a page that is missing too', () {
      write('routes.md.tmp', 'x');
      expect(plan(pages).blocked, hasLength(1));
    });

    test('what an interrupted write of a page left behind is not in the '
        'way', () async {
      final routes = pages.singleWhere((page) => page.path == 'routes.md');
      for (final leftover in ['', routes.text.substring(0, 40)]) {
        write('routes.md.tmp', leftover);
        await render(pages);
        expect(file('routes.md').readAsStringSync(), routes.text);
        expect(file('routes.md.tmp').existsSync(), isFalse);
        file('routes.md').deleteSync();
      }
    });
  });

  test('a docs folder below a linked folder is refused', () {
    final root = p.dirname(p.dirname(folder));
    final real = Directory(p.join(root, 'real'))..createSync(recursive: true);
    try {
      Link(p.join(root, 'docs')).createSync(real.path);
    } on FileSystemException {
      markTestSkipped('this system does not let the test make a link');
      return;
    }
    for (final existing in [false, true]) {
      if (existing) Directory(p.join(real.path, 'the app')).createSync();
      expect(scanDocsFolder(folder, projectRoot: root).problems, [
        'the docs folder is inside `docs`, which is a link, and Appstein '
            'does not write through links. Make it a folder, or change '
            '`docs.path`.',
      ]);
    }
  });
}
