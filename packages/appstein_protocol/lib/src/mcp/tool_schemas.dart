import 'json_schema.dart';

/// The input schemas of Appstein's MCP tools and the schemas of their
/// results (spec §8). A tool's full output schema is its result schema
/// with `summary` and `freshness` added (`toolOutputSchema`).
abstract final class ToolSchemas {
  /// The input of a tool that takes no arguments.
  static final Map<String, Object?> noInput = jsonObject({});
}
