/// The tools `appstein mcp` serves, in the order it lists them (spec §8).
/// `decisions`, `record_decision`, `memory_read` and `memory_write` come
/// with slice 1c.2; `verify` and `package_check` with slice 1d.
///
/// `INDEX.md` names a tool only when it is in this list (spec §6.3).
const mcpToolNames = [
  'overview',
  'where_is',
  'feature',
  'route',
  'check_api',
  'what_changed',
  'toolchain',
];
