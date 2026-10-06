import 'doc_marker.dart';
import 'docs_renderer.dart';
import 'pages/decisions_page.dart';
import 'pages/dependencies_page.dart';

export 'pages/decisions_page.dart';
export 'pages/dependencies_page.dart';
export 'pages/readme_page.dart';

/// The pages the engine renders itself (spec §6.9), besides `README.md`:
/// `dependencies.md` and `decisions.md`, as the first [DocSource] of a
/// render.
const DocSource engineDocSource = (
  id: engineDocsId,
  version: docsEngineVersion,
  pages: [DependenciesPage(), DecisionsPage()],
);
