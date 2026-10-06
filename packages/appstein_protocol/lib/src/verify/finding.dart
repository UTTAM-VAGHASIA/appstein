import '../json_fields.dart';
import '../severity.dart';

/// One thing `verify` found (spec §9.3).
final class Finding {
  /// Creates a finding.
  const Finding({
    required this.id,
    required this.severity,
    this.file,
    this.line,
    required this.message,
    this.fixHint,
    this.knowledgeRef,
    this.pack,
    this.docs,
  });

  /// Reads a finding from its JSON form.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory Finding.fromJson(Map<String, Object?> json) {
    final fields = JsonFields('finding', json);
    final severity = fields.string('severity');
    return Finding(
      id: fields.string('id'),
      severity: Severity.values.firstWhere(
        (value) => value.name == severity,
        orElse: () => throw const FormatException(
          'finding: "severity" must be error, warning or info.',
        ),
      ),
      file: fields.optionalString('file'),
      line: fields.optionalInteger('line'),
      message: fields.string('message'),
      fixHint: fields.optionalString('fixHint'),
      knowledgeRef: fields.optionalString('knowledgeRef'),
      pack: fields.optionalString('pack'),
      docs: fields.optionalString('docs'),
    );
  }

  /// The check's ID, such as `docs.stale`. IDs are stable once released.
  final String id;

  /// How serious it is. Only an error blocks "done".
  final Severity severity;

  /// The file it is about, from the project root, with `/`; null when it
  /// is about the project as a whole.
  final String? file;

  /// The 1-based line in [file]; null when it has none.
  final int? line;

  /// What is wrong, as a sentence.
  final String message;

  /// What to do about it; null when [message] says enough.
  final String? fixHint;

  /// The knowledge file the finding rests on, such as
  /// `.appstein/platform/toolchain.json#kotlin`.
  final String? knowledgeRef;

  /// The pack whose check reported it; null for the engine's own checks.
  final String? pack;

  /// A page that explains the rule.
  final String? docs;

  /// This finding with another [severity].
  Finding withSeverity(Severity severity) => _copy(severity: severity);

  /// This finding as reported by [pack].
  Finding withPack(String pack) => _copy(pack: pack);

  Finding _copy({Severity? severity, String? pack}) => Finding(
    id: id,
    severity: severity ?? this.severity,
    file: file,
    line: line,
    message: message,
    fixHint: fixHint,
    knowledgeRef: knowledgeRef,
    pack: pack ?? this.pack,
    docs: docs,
  );

  /// The JSON form (spec §9.3). Fields that aren't set are left out.
  Map<String, Object?> toJson() => {
    'id': id,
    'severity': severity.name,
    'file': ?file,
    'line': ?line,
    'message': message,
    'fixHint': ?fixHint,
    'knowledgeRef': ?knowledgeRef,
    'pack': ?pack,
    'docs': ?docs,
  };
}
