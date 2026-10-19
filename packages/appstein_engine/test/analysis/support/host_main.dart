// An analysis host, as the engine's tests start it: with the `dart` that runs
// the tests, since the engine has no `appstein` binary. Its arguments are the
// folder of its address file, the `dart` executable that runs the analysis
// server, its idle time in milliseconds, its Appstein version, a file it
// adds its process ID and start to as it starts (so a test can end every
// host it started, also one that lost a race, and only those) and, last (the
// client adds it), the project's folder. Its guard is `guard_main.dart`
// beside it.
//
// `--dart-from=<file>`, anywhere among them, names a file that holds the
// path of the `dart` to use instead, read each time the server is started
// or a reading looks for a change: a test changes it as `fvm use` changes
// the project's SDK.

import 'dart:io';

import 'package:appstein_engine/src/analysis/analysis_host.dart';
import 'package:appstein_engine/src/analysis/analysis_server.dart';
import 'package:appstein_engine/src/analysis/process_identity.dart';
import 'package:path/path.dart' as p;

const _dartFrom = '--dart-from=';

Future<void> main(List<String> arguments) async {
  final dartFrom = [
    for (final argument in arguments)
      if (argument.startsWith(_dartFrom)) argument.substring(_dartFrom.length),
  ].firstOrNull;
  final [folder, dart, idle, version, started, projectRoot] = [
    for (final argument in arguments)
      if (!argument.startsWith(_dartFrom)) argument,
  ];
  final start = switch (lookUpProcess(pid)) {
    ProcessRunning(:final identity) => identity.start,
    _ => '',
  };
  File(started).writeAsStringSync('$pid\t$start\n', mode: FileMode.append);
  final guard = p.join(
    p.dirname(Platform.script.toFilePath()),
    'guard_main.dart',
  );
  await runAnalysisHost(
    projectRoot: projectRoot,
    analysis: (writes) => AnalysisServer(
      projectRoot: projectRoot,
      guardCommand: [Platform.resolvedExecutable, guard],
      dartExecutable: () =>
          dartFrom == null ? dart : File(dartFrom).readAsStringSync().trim(),
      replaceText: writes.replaceText,
    ),
    addressFolder: folder,
    appsteinVersion: version,
    idleStop: Duration(milliseconds: int.parse(idle)),
  );
  exit(0);
}
