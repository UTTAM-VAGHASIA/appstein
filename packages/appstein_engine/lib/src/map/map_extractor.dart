import 'project_analysis.dart';

/// Builds files of `.appstein/map/` from the resolved project (spec §6.5,
/// §10).
abstract interface class MapExtractor {
  /// The bodies of the files it builds, by their path inside `.appstein/`,
  /// such as `map/routes.json`. Each body is written with its `meta`.
  Map<String, Map<String, Object?>> extract(ProjectAnalysis analysis);
}
