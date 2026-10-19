// A client of the analysis host that begins its look for the host, as a hook
// does, and ends its run 300 ms later. Its arguments are the folder of the
// address file and the project's folder. It prints `ended` when its run is
// over: the process must end at once after that, with nothing of the look
// still pending (a connection to a closed port, a lock wait, a poll).

import 'package:appstein_engine/appstein_engine.dart';

Future<void> main(List<String> arguments) async {
  final [folder, project] = arguments;
  final scope = analysisHostCodeAnalysis(
    projectRoot: project,
    // Never run: the connection the look is making is cancelled when the run
    // ends, before the look could launch anything.
    hostCommand: ['no such program'],
    addressFolder: folder,
    appsteinVersion: 'test',
    ownServer: () => throw StateError('no server of its own'),
  );
  await scope((analysis) async {
    (analysis as WarmableCodeAnalysis).warmUp();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  // ignore: avoid_print
  print('ended');
}
