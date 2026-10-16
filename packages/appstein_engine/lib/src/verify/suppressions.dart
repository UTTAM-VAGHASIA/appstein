import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import '../config/config_loader.dart';
import '../text/edit_distance.dart';
import 'suppression_comments.dart';
import 'verify_check.dart';
import 'verify_run.dart';

final _commentStart = RegExp(r'//\s*appstein:ignore(-file)?(\s|$)');

/// Whether [text], the ID or the reason of a comment, holds a second
/// `// appstein:ignore` comment: a `//` that starts after whitespace (or at
/// the start of the text) and is not inside a span in backticks. A `//` glued
/// to other text, as in a URL, is not one, and nor is a comment a reason
/// quotes in backticks.
bool _hasSecondComment(String text) {
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == '`') {
      quoted = !quoted;
    } else if (!quoted &&
        char == '/' &&
        text.startsWith('//', i) &&
        (i == 0 || text[i - 1].trim().isEmpty) &&
        text.substring(i).startsWith(_commentStart)) {
      return true;
    }
  }
  return false;
}

/// Text after an ID that looks like a separator typed wrong: an en dash, a
/// hyphen that ends the text, a hyphen glued to the word before it and
/// followed by a space (`dart.lint- why`), or one that follows a space and
/// touches the word after it (`dart.lint -why`).
final _wrongSeparator = RegExp(r'–|-$|\S-\s|\s-[^-\s]');

const _separatorHint =
    'The separator between the ID and the reason must be `—`, `--` or '
    '` - ` (a hyphen with a space on each side); an en dash `–` or a hyphen '
    'at the end is not one.';

/// Whether [text], a comment's ID text with no separator, lists several
/// check IDs: it is at least two words, split at commas and spaces, and every
/// one is shaped like an ID (`area.check`). A text with ordinary words in it
/// is not a list, so `dart.lint because it is old` is a comment with no
/// reason.
bool _severalIds(String text) {
  final words = text.split(RegExp(r'[,\s]+')).where((word) => word.isNotEmpty);
  final shape = RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+$');
  return words.length >= 2 && words.every(shape.hasMatch);
}

/// Applies the `suppressions:` list of `appstein.yaml` and the
/// `// appstein:ignore` comments of Dart files, [comments], to [findings]
/// (spec §9.7).
///
/// An entry hides the findings of its check on the files its path matches:
/// that file, the files below that folder, or the files the glob matches.
/// A comment hides the findings of the check it names on the lines it covers,
/// or in its file for `appstein:ignore-file` ([SuppressionComment.covers]).
/// A finding about the whole project is never hidden.
///
/// A finding hidden by an entry and a comment is hidden once, and both count
/// as active. An entry or comment that can't work is reported instead, on
/// its line of `appstein.yaml` or of the Dart file, and hides nothing:
/// - without a reason: the error `suppression.no_reason`;
/// - with an ID outside [knownIds] (every ID a check of the project can
///   report), or one of [unsuppressibleIds]: the error
///   `suppression.unknown_check`;
/// - hiding no finding: the warning `suppression.unused`, in
///   [VerifyMode.full] only, since in fast mode most checks did not run,
///   and never for an ID in [notRunIds], whose check (or a part of it) did
///   not run this time: its finding may only be missing.
///
/// - a comment that is after its file's first declaration (`ignore-file`)
///   hides nothing, so it is `suppression.unused` too;
/// - a comment that names several checks, or none, is
///   `suppression.unknown_check`. So is a line with two comments in it.
///
/// A one-line comment never hides the `dart.deprecated` finding about an
/// `// ignore_for_file:` comment: [fileWideIgnores] has the file, line and
/// message of each such finding. A diagnostic the analyzer reports on the
/// same line has another message and is hidden as usual. `ignore-file`
/// comments and `appstein.yaml` entries hide the finding about the comment.
///
/// `kept` is the findings that stay, followed by those reports in the
/// order of [entries], then of [comments]; `suppressed` is how many findings
/// were hidden, and `active` how many entries and comments hid at least one.
({List<Finding> kept, int suppressed, int active}) applySuppressions(
  List<Finding> findings,
  List<SuppressionEntry> entries, {
  required Set<String> knownIds,
  required VerifyMode mode,
  Set<String> notRunIds = const {},
  List<SuppressionComment> comments = const [],
  Set<(String, int, String)> fileWideIgnores = const {},
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
  var active = 0;
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
    if (matched.isNotEmpty) active++;
    if (matched.isEmpty &&
        mode == VerifyMode.full &&
        !notRunIds.contains(entry.id)) {
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

  // The comments in Dart files follow the same rules as the entries, and
  // their reports are on the comment's own line. A finding both an entry
  // and a comment hide is hidden, and counted, once; both are active.
  for (final comment in comments) {
    final keyword = comment.forFile
        ? 'appstein:ignore-file'
        : 'appstein:ignore';
    final what =
        'The `// $keyword` comment'
        '${comment.id.isEmpty ? '' : ' for `${comment.id}`'}';
    Finding reportAt(
      String id,
      Severity severity,
      String message, {
      String? fixHint,
    }) => Finding(
      id: id,
      severity: severity,
      file: comment.file,
      line: comment.line,
      message: message,
      fixHint: fixHint,
    );
    // Two comments at the end of one line read as one: the second is inside
    // the first one's text. That is a comment naming more than one check.
    if (_hasSecondComment(comment.id) ||
        _hasSecondComment(comment.reason ?? '')) {
      reports.add(
        reportAt(
          'suppression.unknown_check',
          Severity.error,
          'This line names more than one check: a comment names one, and '
              'a second `// appstein:ignore` inside the first is part of its '
              'text. It hides nothing.',
          fixHint:
              'Put each comment on a line of its own, above the code it is '
              'about.',
        ),
      );
      continue;
    }
    // Several IDs and no reason: the IDs are the first thing wrong.
    if (comment.reason == null && _severalIds(comment.id)) {
      reports.add(
        reportAt(
          'suppression.unknown_check',
          Severity.error,
          '$what names more than one check, and has no reason. It hides '
              'nothing.',
          fixHint:
              'A comment names one check: write one comment for each, as '
              '`// $keyword <check-id> — <reason>`.',
        ),
      );
      continue;
    }
    if (comment.reason == null) {
      reports.add(
        reportAt(
          'suppression.no_reason',
          Severity.error,
          '$what has no reason, so it hides nothing.',
          fixHint:
              'Write it as `// $keyword <check-id> — <reason>`, with the '
              'reason after the ID.'
              '${_wrongSeparator.hasMatch(comment.id) ? ' $_separatorHint' : ''}',
        ),
      );
      continue;
    }
    if (comment.id.isEmpty) {
      reports.add(
        reportAt(
          'suppression.unknown_check',
          Severity.error,
          '$what names no check.',
          fixHint: 'Write it as `// $keyword <check-id> — <reason>`.',
        ),
      );
      continue;
    }
    if (unsuppressibleIds.contains(comment.id)) {
      reports.add(
        reportAt(
          'suppression.unknown_check',
          Severity.error,
          "`${comment.id}` can't be suppressed.",
          fixHint: 'Remove this comment and fix what the finding reports.',
        ),
      );
      continue;
    }
    if (!knownIds.contains(comment.id)) {
      final several = comment.id.contains(RegExp(r'[,\s]'));
      final closest = several
          ? null
          : closestMatch(
              comment.id,
              knownIds.difference(unsuppressibleIds).toList()..sort(),
            );
      reports.add(
        reportAt(
          'suppression.unknown_check',
          Severity.error,
          'No check of this project reports `${comment.id}`.',
          // A mistyped separator is the cause when the text has one, and the
          // text only looks like a list because the reason ended up in it.
          fixHint: switch ((_wrongSeparator.hasMatch(comment.id), several)) {
            (true, _) => _separatorHint,
            (false, true) =>
              'A comment names one check: write one comment for each.',
            _ => closest == null ? null : 'Did you mean `$closest`?',
          },
        ),
      );
      continue;
    }

    // A one-line comment never hides the finding on an `// ignore_for_file:`
    // comment that silences deprecated use in the whole file.
    bool keeps(Finding finding) =>
        !comment.forFile &&
        finding.id == 'dart.deprecated' &&
        finding.file != null &&
        finding.line != null &&
        fileWideIgnores.contains((
          finding.file!,
          finding.line!,
          finding.message,
        ));
    final matched = [
      for (final finding in findings)
        if (finding.id == comment.id &&
            comment.covers(finding) &&
            !keeps(finding))
          finding,
    ];
    final kept = [
      for (final finding in findings)
        if (finding.id == comment.id &&
            comment.covers(finding) &&
            keeps(finding))
          finding,
    ];
    hidden.addAll(matched);
    if (matched.isNotEmpty) active++;
    if (matched.isEmpty &&
        mode == VerifyMode.full &&
        !notRunIds.contains(comment.id)) {
      reports.add(
        comment.afterDeclaration
            ? reportAt(
                'suppression.unused',
                Severity.warning,
                '$what comes after the start of the first declaration of the '
                    'file, which begins at its doc comment or annotation, so '
                    'it hides nothing.',
                fixHint:
                    "Move it above the first declaration's doc comment and "
                    'annotations, or remove it.',
              )
            : kept.isNotEmpty
            ? reportAt(
                'suppression.unused',
                Severity.warning,
                '$what hides no finding: the finding it covers is on an '
                    '`// ignore_for_file:` comment, which silences deprecated '
                    'use in the whole file, and a one-line comment never '
                    'hides that.',
                fixHint:
                    'Use `// appstein:ignore-file ${comment.id} — <reason>` '
                    'before the first declaration, or a `suppressions:` entry '
                    'in `appstein.yaml`.',
              )
            : reportAt(
                'suppression.unused',
                Severity.warning,
                '$what hides no finding.',
                fixHint:
                    "Remove it, so it can't hide the same finding if it "
                    'comes back.',
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
    active: active,
  );
}
