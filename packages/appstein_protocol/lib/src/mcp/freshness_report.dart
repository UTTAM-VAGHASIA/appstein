import 'json_schema.dart';

/// Whether the knowledge an MCP reply was built from is current (spec §8).
enum FreshnessState {
  /// Nothing the knowledge reads had changed.
  current,

  /// Something had changed, and the server rebuilt the knowledge first.
  rebuilt,

  /// The server couldn't sync, so the reply comes from the files on disk.
  stale,
}

/// The `freshness` field of every MCP reply (spec §8).
final class FreshnessReport {
  /// Nothing had changed.
  const FreshnessReport.current()
    : state = FreshnessState.current,
      because = const [],
      changed = const [],
      mapSkipped = null,
      problem = null,
      fixHint = null;

  /// The knowledge was rebuilt first, [because] of these reasons, after the
  /// [changed] input files changed. [mapSkipped] is why the project map
  /// was skipped, if it was.
  const FreshnessReport.rebuilt({
    required this.because,
    required this.changed,
    this.mapSkipped,
  }) : state = FreshnessState.rebuilt,
       problem = null,
       fixHint = null;

  /// The sync failed with [problem]; [fixHint] says what to do.
  const FreshnessReport.stale({required String this.problem, this.fixHint})
    : state = FreshnessState.stale,
      because = const [],
      changed = const [],
      mapSkipped = null;

  /// The most changed files a reply names; the rest are counted.
  static const changedLimit = 20;

  /// What happened.
  final FreshnessState state;

  /// Why it rebuilt (`SyncReport.rebuiltBecause`).
  final List<String> because;

  /// The input files that changed (`SyncReport.changed`).
  final List<String> changed;

  /// Why the project map was skipped when it rebuilt; null otherwise.
  final String? mapSkipped;

  /// Why it couldn't sync; null unless [state] is stale.
  final String? problem;

  /// What to do about [problem].
  final String? fixHint;

  /// The JSON form, with no null values and at most [changedLimit] changed
  /// files (`moreChanged` counts the rest).
  Map<String, Object?> toJson() => {
    'state': state.name,
    if (because.isNotEmpty) 'because': because,
    if (changed.isNotEmpty) 'changed': changed.take(changedLimit).toList(),
    if (changed.length > changedLimit)
      'moreChanged': changed.length - changedLimit,
    'mapSkipped': ?mapSkipped,
    'problem': ?problem,
    'fixHint': ?fixHint,
  };

  /// One or two sentences for a reply's text.
  String get sentence => switch (state) {
    FreshnessState.current => 'The knowledge was current.',
    FreshnessState.rebuilt =>
      'The knowledge was rebuilt first'
          '${because.isEmpty ? '' : ' (${because.first})'}.'
          '${mapSkipped == null ? '' : ' The project map was skipped: '
                    '${_withFullStop(mapSkipped!)}'}',
    FreshnessState.stale =>
      'The knowledge may be stale: ${_withFullStop(problem!)}'
          '${fixHint == null ? '' : ' ${_withFullStop(fixHint!)}'}',
  };

  /// The schema of [toJson].
  static final Map<String, Object?> schema = jsonObject(
    {
      'state': jsonString(
        values: [for (final state in FreshnessState.values) state.name],
      ),
      'because': jsonList(jsonString()),
      'changed': jsonList(jsonString()),
      'moreChanged': jsonInteger(),
      'mapSkipped': jsonString(),
      'problem': jsonString(),
      'fixHint': jsonString(),
    },
    required: ['state'],
    description:
        'Whether the knowledge was current, rebuilt first, or may be stale.',
  );
}

String _withFullStop(String text) {
  final trimmed = text.trim();
  return trimmed.endsWith('.') || trimmed.endsWith('!') || trimmed.endsWith('?')
      ? trimmed
      : '$trimmed.';
}
