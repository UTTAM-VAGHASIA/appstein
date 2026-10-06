/// The status of a decision record (spec §6.7).
enum DecisionStatus {
  /// Written down, not yet agreed by the user.
  proposed,

  /// In force.
  accepted,

  /// Replaced by a later decision.
  superseded;

  /// The word in the file's `status:` line.
  String get jsonName => name;

  /// The status [text] names, or null when it names none.
  static DecisionStatus? tryParse(String text) {
    for (final status in values) {
      if (status.jsonName == text) return status;
    }
    return null;
  }
}

/// The built-in decision checks a record may list in `checks` (spec §6.7).
const decisionChecks = ['stack.provider', 'paths.exist'];

/// A decision's [number] as file names and replies write it: at least four
/// digits, such as `0002`.
String decisionNumberText(int number) => '$number'.padLeft(4, '0');

/// One decision record, as its file in `.appstein/decisions/` holds it
/// (spec §6.7).
final class DecisionRecord {
  /// Creates the record.
  const DecisionRecord({
    required this.file,
    this.number,
    required this.title,
    required this.status,
    this.date,
    this.supersedes,
    this.paths = const [],
    this.checks = const [],
    required this.why,
  });

  /// Its file name, such as `0002-state.md`.
  final String file;

  /// The number its file name starts with; null when it starts with none.
  final int? number;

  /// Its title, on one line.
  final String title;

  /// The status its file states. Readers may count it as superseded all the
  /// same, when a later decision replaces it (spec §6.7).
  final DecisionStatus status;

  /// The day it was recorded, as the file writes it; null without one.
  final String? date;

  /// The number of the decision it replaces; null when it replaces none.
  final int? supersedes;

  /// The path patterns it applies to; empty when it applies everywhere.
  final List<String> paths;

  /// The verifier checks that confirm it.
  final List<String> checks;

  /// The reason, without the leading `Why:`.
  final String why;

  /// [number] with at least four digits; null without a number.
  String? get numberText => switch (number) {
    final number? => decisionNumberText(number),
    null => null,
  };
}
