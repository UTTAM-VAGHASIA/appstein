import 'package:dart_mcp/client.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

/// A client connected to the server on the other end of [channel], after
/// the MCP initialization handshake. It is shut down after the test.
Future<ServerConnection> connectTo(StreamChannel<String> channel) async {
  final client = MCPClient(Implementation(name: 'appstein-test', version: '1'));
  final server = client.connectServer(channel);
  addTearDown(server.shutdown);
  final result = await server.initialize(
    InitializeRequest(
      protocolVersion: ProtocolVersion.latestSupported,
      capabilities: client.capabilities,
      clientInfo: client.implementation,
    ),
  );
  expect(result.capabilities.tools, isNotNull);
  server.notifyInitialized();
  return server;
}

/// Calls [tool] with [arguments].
Future<CallToolResult> call(
  ServerConnection server,
  String tool, [
  Map<String, Object?> arguments = const {},
]) => server.callTool(CallToolRequest(name: tool, arguments: arguments));

/// The text of [result]'s first content block.
String textOf(CallToolResult result) =>
    (result.content.first as TextContent).text;
