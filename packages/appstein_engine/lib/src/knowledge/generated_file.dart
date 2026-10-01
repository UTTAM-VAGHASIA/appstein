/// A generated `.appstein/` file, built but not yet written.
final class GeneratedFile {
  /// Creates the file.
  const GeneratedFile({
    required this.path,
    required this.body,
    required this.inputHash,
  });

  /// Its path inside `.appstein/`, with `/`, such as `map/routes.json`.
  final String path;

  /// Its content, without `meta` (the store adds that).
  final Map<String, Object?> body;

  /// The hash of everything it was built from (spec §6.2).
  final String inputHash;
}
