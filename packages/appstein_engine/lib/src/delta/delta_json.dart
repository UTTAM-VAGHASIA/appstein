import 'package:appstein_protocol/appstein_protocol.dart';

import 'delta_document.dart';

/// Where the version delta's structured form lives inside `.appstein/`
/// (spec §6.2).
const deltaJsonPath = 'platform/delta.json';

/// The body of `delta.json` (spec §6.2, §8): the notes and facts
/// [renderDelta] writes into `delta.md`, as data, for the MCP tools
/// `check_api` and `what_changed`. The store adds its `meta`.
///
/// The notes are split as `delta.md` splits them ([needsNewerLanguage]).
/// Without facts, the API lists are null and `missing` says why: the
/// internal error's type when collecting them failed, otherwise the map's
/// skip reason.
Map<String, Object?> deltaJsonBody(DeltaInputs inputs) {
  final facts = inputs.facts;
  final languageVersion = inputs.languageVersion;
  return DeltaKnowledge(
    flutterVersion: inputs.flutterVersion,
    languageVersion: languageVersion,
    baseline: inputs.baseline,
    coverage: inputs.coverage.name,
    newestNotes: inputs.newestNotes,
    notes: [
      for (final note in inputs.notes)
        if (!needsNewerLanguage(note, languageVersion)) note,
    ],
    laterNotes: [
      for (final note in inputs.notes)
        if (needsNewerLanguage(note, languageVersion)) note,
    ],
    apis: facts == null
        ? null
        : DeltaApis(
            deprecated: [
              for (final api in facts.deprecated)
                DeltaDeprecatedApi(
                  library: api.group,
                  name: api.name,
                  kind: api.kind.name,
                  rule: api.kind.rule,
                  message: api.message,
                  migrations: api.migrations,
                ),
            ],
            migrated: [
              for (final api in facts.migrated)
                DeltaMigratedApi(
                  library: api.group,
                  name: api.name,
                  status: api.status.name,
                  title: api.title,
                ),
            ],
            moved: [
              for (final moved in facts.moved)
                DeltaMovedLibrary(
                  from: moved.from,
                  to: moved.to,
                  title: moved.title,
                ),
            ],
            unread: [
              for (final unread in facts.unread)
                DeltaUnreadFile(file: unread.file, reason: unread.reason),
            ],
          ),
    missing: facts != null
        ? null
        : switch (inputs.internalError) {
            final error? =>
              'Appstein could not collect them because of an internal error '
                  '($error)',
            null => inputs.skipped ?? 'no reason was given',
          },
  ).toJson();
}
