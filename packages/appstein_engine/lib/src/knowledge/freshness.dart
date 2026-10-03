import 'package:appstein_protocol/appstein_protocol.dart';

/// Whether `.appstein/` holds what a sync would write now (spec §5.4,
/// §6.2), and which input files changed since the last sync.
///
/// `KnowledgeSync.freshness` computes it; `sync --detect`, `verify`'s
/// `knowledge.stale` check (1d) and the MCP server (1c) share it.
final class Freshness {
  /// Creates the result.
  const Freshness({required this.reasons, required this.changed, this.state});

  /// Whether nothing the knowledge reads changed since the last sync.
  bool get current => reasons.isEmpty;

  /// Why the knowledge must be rebuilt, in words that follow "because",
  /// such as `map/symbols.json is out of date`; empty when [current].
  final List<String> reasons;

  /// The input files that changed since the last sync, by input name,
  /// sorted ([changedSources]).
  final List<String> changed;

  /// The `state.json` it compared with; null when there was none, or it
  /// couldn't be read.
  final KnowledgeState? state;
}

/// The input names whose hash in [now] differs from [before] (a
/// `state.json`'s `sources`), files added and removed included, sorted.
/// With no [before], every name in [now].
List<String> changedSources(
  Map<String, String>? before,
  Map<String, String?> now,
) {
  final current = stateSources(now);
  if (before == null) return current.keys.toList()..sort();
  return {
    for (final MapEntry(:key, :value) in current.entries)
      if (before[key] != value) key,
    for (final key in before.keys)
      if (!current.containsKey(key)) key,
  }.toList()..sort();
}

/// [sources] as `state.json` keeps them: a file that can't be read is
/// `missing`.
Map<String, String> stateSources(Map<String, String?> sources) => {
  for (final MapEntry(:key, :value) in sources.entries) key: value ?? 'missing',
};
