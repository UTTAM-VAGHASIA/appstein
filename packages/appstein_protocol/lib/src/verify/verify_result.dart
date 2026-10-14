import '../json_fields.dart';
import '../severity.dart';
import 'finding.dart';

/// A check that did not run, and why (spec §9).
final class CheckNotRun {
  /// Creates the entry.
  const CheckNotRun({required this.id, required this.reason});

  /// The check's ID.
  final String id;

  /// Why it did not run, in words that follow the ID and a colon.
  final String reason;

  /// The JSON form.
  Map<String, Object?> toJson() => {'id': id, 'reason': reason};
}

/// What one `verify` run found (spec §9.3).
final class VerifyResult {
  /// Creates the result. [findings] are in [sortFindings]' order and
  /// [notRun] is sorted by ID.
  const VerifyResult({
    required this.findings,
    this.suppressed = 0,
    this.activeSuppressions = 0,
    this.notRun = const [],
    this.notices = const [],
  });

  /// Reads a result from its JSON form.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory VerifyResult.fromJson(Map<String, Object?> json) {
    final fields = JsonFields('verify result', json);
    return VerifyResult(
      findings: [
        for (final finding in fields.objects('findings'))
          Finding.fromJson(finding.json),
      ],
      suppressed: fields.integer('suppressed'),
      activeSuppressions: fields.integer('activeSuppressions'),
      notRun: [
        for (final entry in fields.objects('notRun'))
          CheckNotRun(id: entry.string('id'), reason: entry.string('reason')),
      ],
      // Absent in a result with nothing to tell, and in every result
      // written before the field existed.
      notices: json.containsKey('notices') ? fields.strings('notices') : [],
    );
  }

  /// This result with [more] added to its [notices].
  VerifyResult withNotices(List<String> more) => more.isEmpty
      ? this
      : VerifyResult(
          findings: findings,
          suppressed: suppressed,
          activeSuppressions: activeSuppressions,
          notRun: notRun,
          notices: [...notices, ...more],
        );

  /// The findings that were not suppressed.
  final List<Finding> findings;

  /// How many findings a suppression hid (spec §9.7): an entry of
  /// `appstein.yaml` or an `// appstein:ignore` comment in a Dart file.
  final int suppressed;

  /// How many suppressions, entries of `appstein.yaml` and comments in Dart
  /// files together, hid at least one of them. One broad suppression can hide
  /// many findings, so both numbers are given.
  final int activeSuppressions;

  /// The checks of the chosen mode that did not run.
  final List<CheckNotRun> notRun;

  /// What the reader must be told that is no finding about the project,
  /// one plain line each: today, a process that may be an analysis server
  /// Appstein started and did not end, because it could not confirm the
  /// process is its own, with the command to end it by hand. They never
  /// change the counts or the exit code. The JSON form has `notices` only
  /// when there are any, so a reader that doesn't know the field is not
  /// affected.
  final List<String> notices;

  /// The number of error findings. Any error blocks "done".
  int get errors => _count(Severity.error);

  /// The number of warning findings.
  int get warnings => _count(Severity.warning);

  /// The number of info findings.
  int get info => _count(Severity.info);

  int _count(Severity severity) =>
      findings.where((finding) => finding.severity == severity).length;

  /// The JSON form: what `appstein verify --format json` prints and the
  /// `verify` tool returns (spec §9.3).
  Map<String, Object?> toJson() => {
    'findings': [for (final finding in findings) finding.toJson()],
    'summary': {'errors': errors, 'warnings': warnings, 'info': info},
    'suppressed': suppressed,
    'activeSuppressions': activeSuppressions,
    'notRun': [for (final entry in notRun) entry.toJson()],
    if (notices.isNotEmpty) 'notices': notices,
  };
}

/// [findings] in the order every output uses: those without a file first,
/// then by file; inside a file by severity (error, warning, info), then by
/// line (those without one first), then by ID, then by message.
List<Finding> sortFindings(Iterable<Finding> findings) =>
    findings.toList()..sort((a, b) {
      if (a.file != b.file) {
        if (a.file == null) return -1;
        if (b.file == null) return 1;
        return a.file!.compareTo(b.file!);
      }
      if (a.severity != b.severity) {
        return a.severity.index.compareTo(b.severity.index);
      }
      if (a.line != b.line) return (a.line ?? 0).compareTo(b.line ?? 0);
      if (a.id != b.id) return a.id.compareTo(b.id);
      return a.message.compareTo(b.message);
    });
