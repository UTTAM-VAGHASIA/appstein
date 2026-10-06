/// Shared data models for Appstein.
///
/// Every model the CLI, the engine and the lint rules exchange lives here, so
/// there is exactly one data format (spec §4, principle 4).
library;

export 'src/config/appstein_config.dart';
export 'src/decisions/decision_record.dart';
export 'src/knowledge/curated_note.dart';
export 'src/knowledge/delta_knowledge.dart';
export 'src/knowledge/knowledge_meta.dart';
export 'src/knowledge/knowledge_state.dart';
export 'src/knowledge/notes_coverage.dart';
export 'src/knowledge/toolchain.dart';
export 'src/layer_matcher.dart';
export 'src/layer_rules.dart';
export 'src/map/code_ref.dart';
export 'src/map/deps_map.dart';
export 'src/map/features_map.dart';
export 'src/map/layers_map.dart';
export 'src/map/map_files.dart';
export 'src/map/native_config.dart';
export 'src/map/routes_map.dart';
export 'src/map/symbols_map.dart';
export 'src/mcp/freshness_report.dart';
export 'src/mcp/json_schema.dart';
export 'src/mcp/tool_output.dart';
export 'src/mcp/tool_schemas.dart';
export 'src/protocol_version.dart';
export 'src/sdk_info.dart';
export 'src/severity.dart';
