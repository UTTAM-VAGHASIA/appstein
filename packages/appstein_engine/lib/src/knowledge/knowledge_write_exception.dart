/// Thrown when a `.appstein/` file or folder can't be written.
final class KnowledgeWriteException implements Exception {
  /// Creates the exception for [path].
  const KnowledgeWriteException(this.path, this.reason);

  /// The file or folder Appstein tried to write.
  final String path;

  /// Why it failed.
  final String reason;

  @override
  String toString() => 'Could not write $path: $reason';
}
