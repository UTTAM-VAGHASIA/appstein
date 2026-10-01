import '../json_fields.dart';

/// A named declaration and the file that declares it, such as a screen or
/// a repository.
final class CodeRef {
  /// Creates a reference.
  const CodeRef({required this.name, required this.file});

  /// Reads a reference from [fields].
  factory CodeRef.read(JsonFields fields) =>
      CodeRef(name: fields.string('name'), file: fields.string('file'));

  /// The declaration's name, such as `HomeScreen`.
  final String name;

  /// Its file, relative to the project, with `/`.
  final String file;

  /// The JSON form.
  Map<String, Object?> toJson() => {'name': name, 'file': file};
}
