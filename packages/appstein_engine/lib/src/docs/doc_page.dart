import 'docs_knowledge.dart';

/// One piece of a generated page (spec §6.9): Markdown that goes into the
/// file at [path]. When several sources write to one path, as the platform
/// packs do for `native.md`, the engine joins their sections in order.
final class DocSection {
  /// Creates the section.
  const DocSection({
    required this.path,
    required this.title,
    required this.markdown,
  });

  /// The page's path inside the docs folder, with `/`, ending in `.md`.
  final String path;

  /// The page's `# ` heading. When several sections share a path, the first
  /// one's title is used.
  final String title;

  /// The section's Markdown, starting at the `## ` level or with plain text.
  /// Text that comes from the app must already be escaped (`mdText`,
  /// `mdCode`).
  final String markdown;
}

/// A source of human doc pages in a pack (spec §6.9, §10).
abstract interface class DocPage {
  /// A short name for error messages, such as `features`.
  String get id;

  /// The sections it contributes: none, one, or one per feature. It reads
  /// only [knowledge], and gives the same sections for the same knowledge.
  List<DocSection> sections(DocsKnowledge knowledge);
}
