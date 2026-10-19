import '../json_fields.dart';
import '../severity.dart';
import 'finding.dart';

/// A check that did not run, and why (spec §9).
final class CheckNotRun {
  /// Creates the entry.
  const CheckNotRun({
    required this.id,
    required this.reason,
    this.cutByCap = false,
  });

  /// The check's ID.
  final String id;

  /// Why it did not run, in words that follow the ID and a colon.
  final String reason;

  /// Whether the time limit of a fast run (`verify.fast_timeout_seconds`)
  /// cut the code analysis it needed, so the run did not finish checking. It
  /// is not in a check's JSON form: the result says it once, as
  /// [VerifyResult.incomplete], and a result read back from JSON does not
  /// carry it.
  final bool cutByCap;

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
    this.applied = const [],
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
      // Absent in every result written before the field existed.
      applied: json.containsKey('applied') ? fields.strings('applied') : [],
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
          applied: applied,
        );

  /// This result with [files] as its [applied] files.
  VerifyResult withApplied(List<String> files) => VerifyResult(
    findings: findings,
    suppressed: suppressed,
    activeSuppressions: activeSuppressions,
    notRun: notRun,
    notices: notices,
    applied: files,
  );

  /// Each file `--apply` (or the tool's `apply`) rewrote before the checks
  /// ran, from the project folder with `/`, sorted (spec §9.2, §9.3): an
  /// agent reads them again before it edits them. Empty without `--apply`,
  /// and when it rewrote nothing.
  final List<String> applied;

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

  /// The checks the time limit of a fast run cut ([CheckNotRun.cutByCap]).
  List<CheckNotRun> get cutChecks => [
    for (final check in notRun)
      if (check.cutByCap) check,
  ];

  /// Whether the time limit of a fast run cut any check, so the run did not
  /// finish checking: the terminal exits 3, and the JSON form says so.
  bool get incomplete => cutChecks.isNotEmpty;

  /// Why the first cut check did not run; null when [incomplete] is false.
  String? get incompleteReason => cutChecks.firstOrNull?.reason;

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
    // Only on a run the cap cut, as `notices` only when there are any.
    if (incomplete) ...{
      'incomplete': true,
      'incompleteReason': incompleteReason,
    },
    if (notices.isNotEmpty) 'notices': notices,
    'applied': applied,
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
