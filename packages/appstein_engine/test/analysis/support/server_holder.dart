// Run by analysis_server_test.dart as a separate process, to be killed: it
// starts an analysis server for the project in its first argument, with the
// `dart` in its second and the guard script in its third, waits for the
// first analysis, prints `holding <this process> <the guard> <the server>`
// and waits.

import 'dart:io';

import 'package:appstein_engine/src/analysis/analysis_server.dart';

Future<void> main(List<String> arguments) async {
  final [projectRoot, dart, guard] = arguments;
  final server = AnalysisServer(
    projectRoot: projectRoot,
    guardCommand: [Platform.resolvedExecutable, guard],
    dartExecutable: () => dart,
  );
  try {
    await server.read();
    final (guard: guardId, server: serverId) = server.processes!;
    stdout.writeln('holding $pid $guardId $serverId');
    await Future<void>.delayed(const Duration(minutes: 5));
  } finally {
    await server.stop();
  }
}
