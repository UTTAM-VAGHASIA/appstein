import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../knowledge/knowledge_store.dart';
import '../knowledge/knowledge_write_exception.dart';
import '../knowledge/plain_text.dart';
import 'doc_marker.dart';
import 'docs_knowledge.dart';
import 'docs_renderer.dart';

/// What is in a project's docs folder now (spec §6.9).
final class DocsFolderScan {
  /// Creates the scan.
  const DocsFolderScan({
    this.generated = const {},
    this.teamNotes = const [],
    this.problems = const [],
  });

  /// The text of each Markdown file that has Appstein's marker, by its path
  /// inside the folder, with `/`.
  final Map<String, String> generated;

  /// The Markdown files without the marker, sorted by path: the team's own
  /// notes, which Appstein never touches.
  final List<TeamNote> teamNotes;

  /// What kept the folder from being read, as sentences that follow
  /// "because". When there are any, nothing may be written.
  final List<String> problems;
}

final _heading = RegExp(r'^# +(.*\S)\s*$', multiLine: true);

// The replacement character, which decoding puts where bytes aren't UTF-8.
final _notUtf8 = String.fromCharCode(0xFFFD);

/// Reads the docs folder at [folder]. A folder that doesn't exist yet is an
/// empty scan. With [projectRoot], a link among the folders between the
/// project and the docs folder is a problem too: pages are never written
/// through a link.
///
/// Only `.md` files (in any letter case) are read. A file is Appstein's
/// when its first line is a marker ([DocMarker.of]); any other is a team
/// note, titled by its first `# ` heading, or by its path. Links are not
/// followed. It never throws for the project's own files: what can't be
/// read is in [DocsFolderScan.problems].
DocsFolderScan scanDocsFolder(String folder, {String? projectRoot}) {
  if (projectRoot != null && p.isWithin(projectRoot, folder)) {
    // The folders between the project and the docs folder, outermost first.
    final segments = p.split(p.relative(folder, from: projectRoot));
    for (var i = 1; i < segments.length; i++) {
      final ancestor = segments.sublist(0, i);
      if (FileSystemEntity.typeSync(
            p.joinAll([projectRoot, ...ancestor]),
            followLinks: false,
          ) ==
          FileSystemEntityType.link) {
        return DocsFolderScan(
          problems: [
            'the docs folder is inside `${ancestor.join('/')}`, which is a '
                'link, and Appstein does not write through links. Make it a '
                'folder, or change `docs.path`.',
          ],
        );
      }
    }
  }
  switch (FileSystemEntity.typeSync(folder, followLinks: false)) {
    case FileSystemEntityType.directory:
      break;
    case FileSystemEntityType.notFound:
      // The folder will be created; an ancestor that is a file would stop
      // that.
      var parent = p.dirname(folder);
      while (parent != p.dirname(parent) &&
          FileSystemEntity.typeSync(parent, followLinks: false) ==
              FileSystemEntityType.notFound) {
        parent = p.dirname(parent);
      }
      return FileSystemEntity.isDirectorySync(parent)
          ? const DocsFolderScan()
          : DocsFolderScan(
              problems: [
                'the docs folder cannot be created: `$parent` is not a '
                    'folder. Move or rename it, or change `docs.path`.',
              ],
            );
    case FileSystemEntityType.link:
      return const DocsFolderScan(
        problems: [
          'the docs folder is a link, and Appstein does not write through '
              'links. Make it a folder, or change `docs.path`.',
        ],
      );
    default:
      return const DocsFolderScan(
        problems: [
          'the docs folder is a file, not a folder. Move or rename it.',
        ],
      );
  }

  final generated = <String, String>{};
  final notes = <TeamNote>[];
  final problems = <String>[];
  final List<FileSystemEntity> entities;
  try {
    entities = Directory(folder).listSync(recursive: true, followLinks: false);
  } on FileSystemException catch (error) {
    return DocsFolderScan(
      problems: [
        'the docs folder cannot be listed (${fileErrorReason(error)}).',
      ],
    );
  }
  for (final entity in entities) {
    if (entity is! File || !entity.path.toLowerCase().endsWith('.md')) continue;
    final path = p.split(p.relative(entity.path, from: folder)).join('/');
    final String text;
    try {
      // A file that isn't valid UTF-8 is still read: its marker, if it has
      // one, is in plain ASCII.
      text = utf8.decode(entity.readAsBytesSync(), allowMalformed: true);
    } on FileSystemException catch (error) {
      problems.add('`$path` cannot be read (${fileErrorReason(error)}).');
      continue;
    }
    if (DocMarker.of(text) != null || isConflictedPage(text)) {
      generated[path] = text;
    } else {
      final title = _heading.firstMatch(withoutBom(text))?.group(1);
      notes.add(
        TeamNote(
          path: path,
          // The replacement character marks text that wasn't UTF-8.
          title: title == null || title.contains(_notUtf8) ? path : title,
        ),
      );
    }
  }
  notes.sort((a, b) => a.path.compareTo(b.path));
  problems.sort();
  return DocsFolderScan(
    generated: generated,
    teamNotes: notes,
    problems: problems,
  );
}

/// What happens to one page.
enum DocChangeKind {
  /// The file is what a render gives.
  unchanged,

  /// The file is written.
  write,

  /// The file is deleted.
  remove,

  /// The file is left as it is, though it isn't what a render gives: a
  /// person has to decide about it.
  keep,
}

/// Why a page is not what a render gives.
enum DocStaleReason {
  /// There is no file.
  missing,

  /// The file is an older render: the app or the templates changed since.
  behind,

  /// The file was edited by hand: its body no longer matches the hash in
  /// its marker.
  handEdited,

  /// Git left the file in a merge conflict ([isConflictedPage]). Writing
  /// the page again resolves it.
  conflicted,

  /// The file has the marker, but no page is rendered there any more.
  notRendered,

  /// As [notRendered], and its body was edited by hand. It is kept
  /// ([DocChangeKind.keep]): Appstein never deletes a person's text.
  editedLeftover,
}

/// What `appstein docs` does, or would do, to one page.
final class DocChange {
  /// Creates the change.
  const DocChange(
    this.path,
    this.kind, {
    this.reason,
    this.hadHandEdits = false,
  });

  /// The page's path inside the docs folder, with `/`.
  final String path;

  /// What happens to it.
  final DocChangeKind kind;

  /// Why; null when it is [DocChangeKind.unchanged].
  final DocStaleReason? reason;

  /// Whether the page had been edited by hand. A page that is written
  /// loses those edits; a page that is no longer rendered is kept because
  /// of them.
  final bool hadHandEdits;
}

/// Whether a page's body no longer matches the hash in its marker. A page
/// in a merge conflict has no readable marker; git changed it, not a hand.
bool _handEdited(String text) => switch (DocMarker.of(text)) {
  final marker? => marker.body != bodyHash(bodyOf(text)),
  null => false,
};

/// The changes that make the docs folder at [folder] hold exactly [pages],
/// sorted by path, and the files that stand in the way.
///
/// - A file that differs from its page only in line endings or a byte order
///   mark is unchanged (spec §6.9).
/// - A file with the marker that no page is rendered to is removed, unless
///   its body was edited by hand: then it is kept and reported.
/// - A file without the marker is never changed. When one is where a page
///   would be written, or a folder or a link is, that is in `blocked`, as a
///   sentence naming it. Nothing may be written while anything is blocked.
///
/// [scan] is [scanDocsFolder] of the same folder.
({List<DocChange> changes, List<String> blocked}) planDocs(
  String folder,
  DocsFolderScan scan,
  List<RenderedPage> pages,
) {
  final changes = <DocChange>[];
  final blocked = <String>[];
  final matched = <String>{};
  final teamNotes = {for (final note in scan.teamNotes) note.path};

  // A page is written through `<page>.tmp` (`replaceFile`). Anything there
  // that isn't what an interrupted write of a page left behind is a
  // person's, and writing the page would replace it.
  bool tempInTheWay(String path) {
    final temp = p.joinAll([folder, ...'$path.tmp'.split('/')]);
    final type = FileSystemEntity.typeSync(temp, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type == FileSystemEntityType.file) {
      try {
        if (isLeftoverPageWrite(
          utf8.decode(File(temp).readAsBytesSync(), allowMalformed: true),
        )) {
          return false;
        }
      } on FileSystemException {
        // Unreadable: not provably Appstein's, so it is left alone.
      }
    }
    blocked.add(
      '`$path.tmp` is in the way: Appstein writes `$path` through a file of '
      'that name. Move or delete it.',
    );
    return true;
  }

  for (final page in pages) {
    final segments = page.path.split('/');
    // An ancestor that isn't a folder.
    String? inTheWay;
    for (var i = 1; i < segments.length && inTheWay == null; i++) {
      final ancestor = segments.sublist(0, i);
      final type = FileSystemEntity.typeSync(
        p.joinAll([folder, ...ancestor]),
        followLinks: false,
      );
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        inTheWay = ancestor.join('/');
        blocked.add(
          '`$inTheWay` is a '
          '${type == FileSystemEntityType.link ? 'link' : 'file'}, and '
          '`${page.path}` would be written inside it. Move or rename it.',
        );
      }
    }
    if (inTheWay != null) continue;

    final type = FileSystemEntity.typeSync(
      p.joinAll([folder, ...segments]),
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      if (tempInTheWay(page.path)) continue;
      changes.add(
        DocChange(
          page.path,
          DocChangeKind.write,
          reason: DocStaleReason.missing,
        ),
      );
      continue;
    }
    if (type != FileSystemEntityType.file) {
      blocked.add(
        '`${page.path}` is a '
        '${type == FileSystemEntityType.link ? 'link' : 'folder'}, and a '
        'page would be written there. Move or rename it.',
      );
      continue;
    }
    // A file is there. The scan listed it under the name it has on disk:
    // that exact name, or, where the file system ignores letter case,
    // another case of it. A person's file under either name blocks the
    // page; only a file the scan found the marker in is the page.
    bool sameButForCase(String path) =>
        path != page.path && path.toLowerCase() == page.path.toLowerCase();
    final String? key;
    if (scan.generated.containsKey(page.path)) {
      key = page.path;
    } else if (teamNotes.contains(page.path)) {
      key = null;
      blocked.add(
        '`${page.path}` is not an Appstein page (it has no marker), and a '
        'page would be written there. Move or rename it.',
      );
    } else if (teamNotes.where(sameButForCase).firstOrNull case final note?) {
      key = null;
      blocked.add(
        '`$note` is not an Appstein page (it has no marker), and the page '
        '`${page.path}` would be written over it. Move or rename it.',
      );
    } else {
      key = (scan.generated.keys.where(sameButForCase).toList()..sort())
          .where((path) => !pages.any((other) => other.path == path))
          .firstOrNull;
      if (key == null) {
        blocked.add(
          '`${page.path}` is a file that is not an Appstein page, and a page '
          'would be written there. Move or rename it.',
        );
      }
    }
    if (key == null) continue;
    matched.add(key);
    final text = scan.generated[key]!;
    if (withoutEndingBreaks(text) == withoutEndingBreaks(page.text)) {
      changes.add(DocChange(page.path, DocChangeKind.unchanged));
    } else if (tempInTheWay(page.path)) {
      continue;
    } else if (isConflictedPage(text)) {
      changes.add(
        DocChange(
          page.path,
          DocChangeKind.write,
          reason: DocStaleReason.conflicted,
        ),
      );
    } else {
      final edited = _handEdited(text);
      changes.add(
        DocChange(
          page.path,
          DocChangeKind.write,
          reason: edited ? DocStaleReason.handEdited : DocStaleReason.behind,
          hadHandEdits: edited,
        ),
      );
    }
  }
  for (final MapEntry(key: path, value: text) in scan.generated.entries) {
    if (matched.contains(path)) continue;
    // Only a page that is provably Appstein's own unchanged output is
    // removed. One a person edited may be a copy they turned into notes,
    // or hold text they still want: it is kept, and named until they
    // delete it or make it a team note.
    changes.add(
      _handEdited(text)
          ? DocChange(
              path,
              DocChangeKind.keep,
              reason: DocStaleReason.editedLeftover,
              hadHandEdits: true,
            )
          : DocChange(
              path,
              DocChangeKind.remove,
              reason: DocStaleReason.notRendered,
            ),
    );
  }
  changes.sort((a, b) => a.path.compareTo(b.path));
  blocked.sort();
  return (changes: changes, blocked: blocked);
}

/// Does what [changes] says in the docs folder at [folder], with the text
/// of [pages]: it writes each page in one step, `README.md` last, so the
/// index never names a page that isn't there yet; then removes the pages
/// that are no longer rendered, and the folders that leaves empty (never
/// the docs folder itself).
///
/// Throws a [KnowledgeWriteException] when a file can't be written or
/// removed. Pages written before that stay written; running it again
/// finishes the work.
Future<void> applyDocs(
  String folder,
  List<RenderedPage> pages,
  List<DocChange> changes,
) async {
  String pathOf(String path) => p.joinAll([folder, ...path.split('/')]);
  final texts = {for (final page in pages) page.path: page.text};
  final writes = [
    for (final change in changes)
      if (change.kind == DocChangeKind.write && change.path != readmePath)
        change.path,
    for (final change in changes)
      if (change.kind == DocChangeKind.write && change.path == readmePath)
        change.path,
  ];
  for (final path in writes) {
    try {
      await replaceFile(pathOf(path), texts[path]!);
    } on KnowledgeWriteException catch (error) {
      throw KnowledgeWriteException(
        error.path,
        error.reason.replaceAll('`appstein sync`', '`appstein docs`'),
      );
    }
  }
  for (final change in changes) {
    if (change.kind != DocChangeKind.remove) continue;
    final file = File(pathOf(change.path));
    try {
      file.deleteSync();
      var parent = file.parent;
      while (!p.equals(parent.path, folder) &&
          p.isWithin(folder, parent.path) &&
          parent.listSync(followLinks: false).isEmpty) {
        parent.deleteSync();
        parent = parent.parent;
      }
    } on FileSystemException catch (error) {
      throw KnowledgeWriteException(
        file.path,
        '${fileErrorReason(error)} (it is no longer rendered and was to be '
        'removed).',
      );
    }
  }
}
