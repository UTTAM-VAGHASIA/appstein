/// The version of Appstein's data formats: the JSON it writes and the
/// models the CLI, MCP server and future UIs exchange.
///
/// It changes only when a format changes in a way older readers can't
/// handle, and `appstein upgrade` migrates stored data between versions.
const int protocolVersion = 1;
