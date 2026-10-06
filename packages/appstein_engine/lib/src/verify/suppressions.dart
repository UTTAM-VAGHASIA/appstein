import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import '../config/config_loader.dart';
import '../text/edit_distance.dart';
import 'verify_check.dart';
import 'verify_run.dart';

/// Applies the `suppressions:` list of `appstein.yaml` to [findings] (spec
/// §9.7).
///
/// An entry hides the findings of its check on the files its path matches:
/// that file, the files below that folder, or the files the glob matches.
/// A finding about the whole project is never hidden.
///
/// An entry that can't work is reported instead, on its line of
/// `appstein.yaml`, and hides nothing:
/// - without a reason: the error `suppression.no_reason`;
/// - with an ID outside [knownIds] (every ID a check of the project can
///   report), or one of [unsuppressibleIds]: the error
///   `suppression.unknown_check`;
/// - hiding no finding: the warning `suppression.unused`, in
///   [VerifyMode.full] only, since in fast mode most checks did not run.
///
/// `kept` is the findings that stay, followed by those reports in the
/// order of [entries]; `suppressed` is how many findings were hidden.
({List<Finding> kept, int suppressed}) applySuppressions(
  List<Finding> findings,
  List<SuppressionEntry> entries, {
  required Set<String> knownIds,
  required VerifyMode mode,
}) {
  Finding report(
    String id,
    Severity severity,
    SuppressionEntry entry,
    String message, {
    String? fixHint,
  }) => Finding(
    id: id,
    severity: severity,
    file: configFileName,
    line: entry.line,
    message: message,
    fixHint: fixHint,
  );

  final hidden = <Finding>{};
  final reports = <Finding>[];
  for (final entry in entries) {
    final what = 'The suppression of `${entry.id}` on `${entry.path}`';
    if (entry.reason == null) {
      reports.add(
        report(
          'suppression.no_reason',
          Severity.error,
          entry,
          '$what has no reason, so it hides nothing.',
          fixHint: 'Add `reason:` saying why this finding is accepted.',
        ),
      );
      continue;
    }
    if (unsuppressibleIds.contains(entry.id)) {
      reports.add(
        report(
          'suppression.unknown_check',
          Severity.error,
          entry,
          "`${entry.id}` can't be suppressed.",
          fixHint: 'Remove this entry and fix what the finding reports.',
        ),
      );
      continue;
    }
    if (!knownIds.contains(entry.id)) {
      final closest = closestMatch(
        entry.id,
        knownIds.difference(unsuppressibleIds).toList()..sort(),
      );
      reports.add(
        report(
          'suppression.unknown_check',
          Severity.error,
          entry,
          'No check of this project reports `${entry.id}`.',
          fixHint: closest == null ? null : 'Did you mean `$closest`?',
        ),
      );
      continue;
    }

    final glob = Glob(entry.path, context: p.posix);
    final matched = [
      for (final finding in findings)
        if (finding.id == entry.id)
          if (finding.file case final file?)
            if (file == entry.path ||
                file.startsWith('${entry.path}/') ||
                glob.matches(file))
              finding,
    ];
    hidden.addAll(matched);
    if (matched.isEmpty && mode == VerifyMode.full) {
      reports.add(
        report(
          'suppression.unused',
          Severity.warning,
          entry,
          '$what hides no finding.',
          fixHint:
              "Remove it, so it can't hide the same finding if it comes "
              'back.',
        ),
      );
    }
  }
  return (
    kept: [
      for (final finding in findings)
        if (!hidden.contains(finding)) finding,
      ...reports,
    ],
    suppressed: hidden.length,
  );
}
