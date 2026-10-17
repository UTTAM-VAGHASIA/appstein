// An analysis host, as the engine's tests start it: with the `dart` that runs
// the tests, since the engine has no `appstein` binary. Its arguments are the
// folder of its address file, the `dart` executable that runs the analysis
// server, its idle time in milliseconds and, last (the client adds it), the
// project's folder. Its guard is `guard_main.dart` beside it.

import 'dart:io';

import 'package:appstein_engine/src/analysis/analysis_host.dart';
import 'package:appstein_engine/src/analysis/analysis_server.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final [folder, dart, idle, projectRoot] = arguments;
  final guard = p.join(
    p.dirname(Platform.script.toFilePath()),
    'guard_main.dart',
  );
  await runAnalysisHost(
    projectRoot: projectRoot,
    analysis: (writes) => AnalysisServer(
      projectRoot: projectRoot,
      guardCommand: [Platform.resolvedExecutable, guard],
      dartExecutable: () => dart,
      replaceText: writes.replaceText,
    ),
    addressFolder: folder,
    appsteinVersion: 'test',
    idleStop: Duration(milliseconds: int.parse(idle)),
  );
  exit(0);
}
