// The guard of an analysis server, as the engine's tests start it: with the
// `dart` that runs the tests, since the engine has no `appstein` binary. Its
// one argument is the `dart` executable that runs the server.

import 'dart:io';

// Only the guard, not the whole engine: `dart` compiles what a script
// imports each time it starts it.
import 'package:appstein_engine/src/analysis/analysis_guard.dart';

Future<void> main(List<String> arguments) async {
  // `exit`, as `runAnalysisGuard` asks: a guard that has said it ended must
  // not stay.
  exit(await runAnalysisGuard(arguments.single));
}
