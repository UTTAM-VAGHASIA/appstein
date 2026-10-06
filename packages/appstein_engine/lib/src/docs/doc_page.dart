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

final _notInFileNames = RegExp(r'[\\/:*?"<>|\x00-\x1f]');
final _deviceName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$',
  caseSensitive: false,
);

/// [name] as one segment of a page's path that is a file name on every
/// system. A page named after something in the project, such as a feature
/// folder, uses it, so the page has the same path on every machine (spec
/// §6.9): a folder called `shop:eu` can exist on Linux, and Windows could
/// never check out a page with that name.
///
/// What Windows refuses in a name (`\ / : * ? " < > |`, control characters,
/// a dot or a space at the end) becomes `_`, and a device name such as
/// `con` gets a `_` at its end. Two names may become the same one; the
/// renderer refuses that (`DocPagesCollide`).
String docFileName(String name) {
  var safe = name.replaceAll(_notInFileNames, '_');
  if (safe.endsWith('.') || safe.endsWith(' ')) {
    safe = '${safe.substring(0, safe.length - 1)}_';
  }
  return safe.isEmpty || _deviceName.hasMatch(safe) ? '${safe}_' : safe;
}

/// A source of human doc pages in a pack (spec §6.9, §10).
abstract interface class DocPage {
  /// A short name for error messages, such as `features`.
  String get id;

  /// The sections it contributes: none, one, or one per feature. It reads
  /// only [knowledge], and gives the same sections for the same knowledge.
  List<DocSection> sections(DocsKnowledge knowledge);
}
