/// Shared data models for Appstein.
///
/// Every model the CLI, the engine and the lint rules exchange lives here, so
/// there is exactly one data format (spec §4, principle 4).
library;

export 'src/layer_rules.dart';
export 'src/protocol_version.dart';
export 'src/sdk_info.dart';
export 'src/severity.dart';
