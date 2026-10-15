import 'package:appstein_protocol/appstein_protocol.dart';

import '../verify_check.dart';

/// `dart.fix_pending`: the fixes `dart fix` would apply, one warning per
/// file and code with the count (`deprecated_member_use: 6 fixes`), on the
/// file with no line (slice 1d.2, spec §9.1, §9.2). A full run only: the
/// passes take seconds (17 to 19 s on the 200-file app), so a fast run never
/// runs it and does not name it as not run.
///
/// - **The counts are `dart fix --dry-run`'s.** The analysis server of the
///   project's SDK is asked as `dart fix` asks it, in passes, each applied to
///   an overlay in the server's memory and never to disk
///   (`CodeAnalysis.pendingFixes`), and the counts of the passes are summed.
/// - **Judged against the code on disk.** The run's reading is taken before
///   the first pass, so no other finding is judged against the fixed code,
///   and the overlays are removed when the passes end.
/// - **Passes that did not finish** (the time limit, or a pass the server
///   refused) make the check name itself as not run, with why; what the
///   finished passes found is still reported.
/// - **Nothing is written.** `appstein verify --apply` is what applies them.
///
/// The passes run while gathering, before the knowledge lock
/// (`VerifyGathering.pendingFixes`); it needs no map, so it runs while the
/// knowledge is stale.
final class DartFixPendingCheck implements GatheringCheck {
  /// Creates the check.
  const DartFixPendingCheck();

  static const _id = 'dart.fix_pending';

  @override
  List<String> get ids => const [_id];

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  bool get needsMap => false;

  @override
  Future<void> gather(VerifyGathering gathering) async {
    await gathering.code();
    await gathering.pendingFixes();
  }

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    final pending = context.pendingFixes;
    if (pending.unfinished case final why?) {
      context.notRun(
        _id,
        'the pending fixes were not all found: $why. The counts reported '
        'are those of the passes that ended',
      );
    }
    return [
      for (final MapEntry(key: file, value: byCode) in pending.counts.entries)
        for (final MapEntry(key: code, value: count) in byCode.entries)
          if (count > 0)
            Finding(
              id: _id,
              severity: Severity.warning,
              file: file,
              message:
                  '`dart fix` would apply fixes to this file: '
                  '`$code: $count ${count == 1 ? 'fix' : 'fixes'}`.',
              fixHint:
                  '`appstein verify --apply` applies them (and formats the '
                  "project). Or run `dart fix --apply` with the project's "
                  'SDK; `dart fix --dry-run` lists them.',
            ),
    ];
  }
}
