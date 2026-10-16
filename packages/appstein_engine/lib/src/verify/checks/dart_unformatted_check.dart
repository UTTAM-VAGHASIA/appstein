import 'package:appstein_protocol/appstein_protocol.dart';

import '../verify_check.dart';

/// `dart.unformatted`: a Dart file whose formatting `dart format` would
/// change is a warning on the file (slice 1d.2, spec §9.1). A fast run
/// reports it for the unverified files only, a full run for every file.
///
/// - **The project's own formatter decides.** The analysis server of the
///   project's SDK is asked what its formatter would change
///   (`CodeAnalysis.formatChanges`), the `formatter:` settings of the
///   project's `analysis_options.yaml` (the page width) included, so `verify`
///   never asks for a format the developer's tools would undo.
/// - **Generated files are left out:** those `analysis_options.yaml`
///   excludes (the analysis does not cover them), and those that start with a
///   `GENERATED CODE - DO NOT MODIFY` header. A file that can't be read is
///   `dart.unreadable`'s.
/// - **A file that can't be parsed** gives no finding here: its `dart.error`
///   says why.
/// - **A file the server did not answer for in time**, or every file when it
///   could not answer, is named among the checks not run; a file is never
///   taken for formatted because nobody asked.
/// - **Nothing is written.** `appstein verify --apply` is what formats.
///
/// The questions are asked while gathering, before the knowledge lock
/// (`VerifyGathering.formatting`); it needs no map, so it runs while the
/// knowledge is stale.
final class DartUnformattedCheck implements GatheringCheck {
  /// Creates the check.
  const DartUnformattedCheck();

  static const _id = 'dart.unformatted';

  @override
  List<String> get ids => const [_id];

  // In both modes; the fast mode asks about the unverified files only.
  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  bool get needsMap => false;

  @override
  Future<void> gather(VerifyGathering gathering) async {
    await gathering.code();
    await gathering.formatting();
  }

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    final formatting = context.formatting;
    if (formatting.unchecked.isNotEmpty) {
      context.notRun(
        _id,
        'the formatting of ${formatting.unchecked.length} of '
        '${formatting.checked} files was not checked: ${formatting.why}',
      );
    }
    return [
      for (final file in formatting.unformatted)
        Finding(
          id: _id,
          severity: Severity.warning,
          file: file,
          message:
              'The formatting of this file would change: `dart format` of '
              "the project's SDK, with the project's formatter settings, "
              'would rewrite it.',
          fixHint:
              '`appstein verify --apply` formats the project (and applies '
              '`dart fix`). Or run `dart format` on this file with the '
              "project's SDK.",
        ),
    ];
  }
}
