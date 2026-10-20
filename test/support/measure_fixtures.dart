import 'dart:io';

import 'package:path/path.dart' as p;

import '../../tool/src/mcp_session.dart';
import '../../tool/src/process_memory.dart';

/// Starts `appstein mcp`'s stand-in, `fake_mcp_server.dart`, as the tests of
/// the measuring tools talk to it: its `verify` reads the Dart file at [file]
/// from disk and reports it as [name], with the [flags] the fake knows (see
/// its header). Tests run from the repo root.
Future<McpSession> startFakeMcp({
  required File file,
  String name = 'lib/a.dart',
  List<String> flags = const [],
  Duration callTimeout = const Duration(seconds: 60),
  String clientName = 'measure_test',
}) => McpSession.start(
  Platform.resolvedExecutable,
  [
    p.join('test', 'support', 'fake_mcp_server.dart'),
    '--file',
    file.path,
    '--name',
    name,
    ...flags,
  ],
  clientName: clientName,
  callTimeout: callTimeout,
);

/// The rows of one analysis host with its guard and the server under it, as a
/// process list shows them: the host is a child of [parent], the guard of the
/// host, the server of the guard, each started a little after the one before
/// ([at] is the host's start). The names are [hostName], [guardName] and
/// [serverName], so a test can give them the names of Windows
/// (`appstein.exe`, `dart.exe`) or Linux (`/work/appstein`, `dart:script`);
/// the memory is 100 times [bytes] for the host, 10 times for the guard and
/// 1,000 times for the server.
List<ProcessRow> hostTreeRows({
  required int parent,
  int host = 100,
  int at = 20000,
  int bytes = 1000,
  String hostName = 'appstein.exe',
  String guardName = 'appstein.exe',
  String serverName = 'dart.exe',
}) => [
  ProcessRow(host, parent, 100 * bytes, at, hostName),
  ProcessRow(host + 1, host, 10 * bytes, at + 100, guardName),
  ProcessRow(host + 2, host + 1, 1000 * bytes, at + 200, serverName),
];
