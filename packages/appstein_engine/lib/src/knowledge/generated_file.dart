/// A generated `.appstein/` file, built but not yet written: JSON with a
/// [body], or Markdown with a [markdown] text (spec §6.2).
final class GeneratedFile {
  /// A JSON file. The store adds its `meta` key.
  const GeneratedFile({
    required this.path,
    required Map<String, Object?> this.body,
    required this.inputHash,
  }) : markdown = null;

  /// A Markdown file. The store adds the front matter that holds its
  /// metadata.
  const GeneratedFile.markdown({
    required this.path,
    required String this.markdown,
    required this.inputHash,
  }) : body = null;

  /// Its path inside `.appstein/`, with `/`, such as `map/routes.json`.
  final String path;

  /// A JSON file's content, without `meta` (the store adds that); null for a
  /// Markdown file.
  final Map<String, Object?>? body;

  /// A Markdown file's text, without its front matter (the store adds that);
  /// null for a JSON file.
  final String? markdown;

  /// The hash of everything it was built from (spec §6.2).
  final String inputHash;
}
