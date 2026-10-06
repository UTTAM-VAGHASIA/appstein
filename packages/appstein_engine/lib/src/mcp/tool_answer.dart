/// What an MCP tool's query gives the server (spec §8): a [ToolReply] or a
/// [ToolRefusal].
sealed class ToolAnswer {
  /// Lets subclasses be constant.
  const ToolAnswer();
}

/// An answer: the structured [result], which matches the tool's result
/// schema, and a one- or two-sentence [summary].
final class ToolReply extends ToolAnswer {
  /// Creates the reply.
  const ToolReply(this.result, this.summary);

  /// The structured result, without `summary` and `freshness` (the server
  /// adds them). A result with a `summary` of its own keeps it, and then
  /// the sentence is in the reply's text only.
  final Map<String, Object?> result;

  /// What the answer says, for the agent.
  final String summary;
}

/// A question the tool can't answer, such as an unknown feature or missing
/// knowledge, and why. The server sends it as an error result, so the agent
/// sees the [message] and can correct itself.
final class ToolRefusal extends ToolAnswer {
  /// Creates the refusal.
  const ToolRefusal(this.message);

  /// Why, and what to do instead.
  final String message;
}
