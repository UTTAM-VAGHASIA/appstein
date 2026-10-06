import 'doc_marker.dart';
import 'doc_page.dart';
import 'docs_knowledge.dart';

/// The page every project has, rendered by the engine from the other pages.
const readmePath = 'README.md';

/// The contributor id of the engine's own pages in a page's marker.
const engineDocsId = 'engine';

/// One contributor of pages: the engine or a pack, with its template
/// `version` and its page sources.
typedef DocSource = ({String id, String version, List<DocPage> pages});

/// One generated page, ready to write.
final class RenderedPage {
  /// Creates the page.
  const RenderedPage({
    required this.path,
    required this.title,
    required this.text,
    required this.marker,
  });

  /// Its path inside the docs folder, with `/`.
  final String path;

  /// Its `# ` heading.
  final String title;

  /// The whole file: the marker line, the notice, the heading and the
  /// sections, with `\n` line endings and one line break at the end.
  final String text;

  /// The marker in its first line.
  final DocMarker marker;
}

/// A page source that misbehaved: a bug in Appstein or in a pack, never
/// something the project's owner can fix. Nothing is rendered when it is
/// thrown, so a broken page source can't shrink a project's docs.
final class DocPageError extends Error {
  /// Creates the error.
  DocPageError({
    required this.source,
    required this.page,
    required this.message,
    this.cause,
  });

  /// The contributor's id: a pack's, or `engine`.
  final String source;

  /// The page source's id.
  final String page;

  /// What is wrong.
  final String message;

  /// What the page source threw, when it threw.
  final Object? cause;

  @override
  String toString() =>
      'The doc page source "$page" of $source failed: $message'
      '${cause == null ? '' : ' ($cause)'}';
}

/// Two pages would be one file. Page names come from the project, such as
/// its feature folders, so this is the project's to fix, unlike a
/// [DocPageError]. Nothing is rendered when it is thrown.
final class DocPagesCollide implements Exception {
  /// Creates the exception for the pages at [first] and [second]. A page
  /// source that finds two of its own names giving one path (`docFileName`)
  /// passes that path twice and says which names in [because].
  const DocPagesCollide(this.first, this.second, {this.because});

  /// The path of the page that was rendered first.
  final String first;

  /// The path of the page that would land on the same file.
  final String second;

  /// The page source's own words for [problem]; null for two paths that
  /// differ only in letter case.
  final String? because;

  /// What is wrong, in words that follow "because".
  String get problem =>
      because ??
      'two pages would be the same file where letter case is ignored '
          '(`$first` and `$second`)';

  @override
  String toString() => problem;
}

final _segment = RegExp(r'^[^/\\:]+$');

String? _pathProblem(String path) {
  if (path.toLowerCase() == readmePath.toLowerCase()) {
    return '$readmePath is rendered by the engine';
  }
  final segments = path.split('/');
  final file = segments.last;
  final ok =
      file.toLowerCase().endsWith('.md') &&
      file.length > 3 &&
      segments.every(
        (segment) =>
            _segment.hasMatch(segment) && segment != '.' && segment != '..',
      );
  return ok
      ? null
      : 'the path "$path" must be a path inside the docs folder, with "/", '
            'ending in .md';
}

/// Renders every page of the human docs (spec §6.9), sorted by path.
///
/// [sources] are the contributors in order: the engine's own pages first,
/// then each pack's. Sections with the same path are joined in that order
/// under the first one's title. `README.md` is rendered last by [readme],
/// which is given the other pages, and belongs to the engine.
///
/// Each page is its marker line, [docNotice], its `# ` heading and its
/// sections, a blank line between each. The same [knowledge] always gives
/// the same text.
///
/// Throws a [DocPageError], and renders nothing, when a page source throws
/// or returns a section that can't be used. Throws a [DocPagesCollide] when
/// two pages would be one file.
List<RenderedPage> renderPages({
  required DocsKnowledge knowledge,
  required List<DocSource> sources,
  required DocSection Function(
    DocsKnowledge knowledge,
    List<RenderedPage> pages,
  )
  readme,
}) {
  final drafts = <String, _Draft>{};
  final paths = <String, String>{};
  for (final source in sources) {
    for (final page in source.pages) {
      DocPageError error(String message, [Object? cause]) => DocPageError(
        source: source.id,
        page: page.id,
        message: message,
        cause: cause,
      );
      final List<DocSection> sections;
      try {
        sections = page.sections(knowledge);
      } on DocPagesCollide {
        // The project's to fix, not a failure of the page source.
        rethrow;
      } on Object catch (cause) {
        throw error('it threw', cause);
      }
      for (final section in sections) {
        if (_pathProblem(section.path) case final problem?) {
          throw error(problem);
        }
        _checkText(section, error);
        final known = paths.putIfAbsent(
          section.path.toLowerCase(),
          () => section.path,
        );
        // Sections with one path are joined on purpose (`native.md`); two
        // paths a file system can't tell apart are two pages on one file.
        if (known != section.path) throw DocPagesCollide(known, section.path);
        (drafts[section.path] ??= _Draft(section.title))
          ..templates[source.id] = source.version
          ..sections.add(section.markdown.trim());
      }
    }
  }
  final pages = [
    for (final MapEntry(key: path, value: draft) in drafts.entries)
      _page(path, draft),
  ]..sort((a, b) => a.path.compareTo(b.path));

  DocPageError readmeError(String message, [Object? cause]) => DocPageError(
    source: engineDocsId,
    page: 'readme',
    message: message,
    cause: cause,
  );
  final DocSection home;
  try {
    home = readme(knowledge, List.unmodifiable(pages));
  } on Object catch (cause) {
    throw readmeError('it threw', cause);
  }
  if (home.path != readmePath) {
    throw readmeError('its path must be $readmePath, not "${home.path}"');
  }
  _checkText(home, readmeError);
  return [
    _page(
      readmePath,
      _Draft(home.title)
        ..templates[engineDocsId] = docsEngineVersion
        ..sections.add(home.markdown.trim()),
    ),
    ...pages,
  ]..sort((a, b) => a.path.compareTo(b.path));
}

void _checkText(
  DocSection section,
  DocPageError Function(String message) error,
) {
  final title = section.title;
  if (title.trim().isEmpty || title.contains(RegExp(r'[\r\n]'))) {
    throw error('the title of "${section.path}" must be one line of text');
  }
  if (section.markdown.trim().isEmpty) {
    throw error('the section for "${section.path}" is empty');
  }
}

RenderedPage _page(String path, _Draft draft) {
  final title = draft.title.trim();
  final body =
      '$docNotice\n\n# $title\n\n'
      '${plainLines(draft.sections.join('\n\n'))}\n';
  final marker = DocMarker(
    templates: Map.unmodifiable(draft.templates),
    body: bodyHash(body),
  );
  return RenderedPage(
    path: path,
    title: title,
    text: markedPage(marker, body),
    marker: marker,
  );
}

final class _Draft {
  _Draft(this.title);

  final String title;
  final templates = <String, String>{};
  final sections = <String>[];
}
