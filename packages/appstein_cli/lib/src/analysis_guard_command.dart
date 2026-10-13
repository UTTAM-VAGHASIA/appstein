import 'dart:io';
import 'dart:isolate';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

/// The name of the guard mode: `appstein analysis-server-guard <dart>`.
const analysisGuardCommandName = 'analysis-server-guard';

/// `appstein analysis-server-guard <dart>`: the guard of a Dart analysis
/// server (decision record 0001). Appstein starts it; nobody types it, so
/// the help doesn't list it.
///
/// It starts the server with the `dart` executable it is given, passes its
/// own stdin and stdout through to it, and kills it when its stdin closes,
/// which happens when the Appstein process that started it ends in any way.
/// See `runAnalysisGuard`. Being a mode of the `appstein` binary, it needs
/// no second program installed.
final class AnalysisGuardCommand extends Command<int> {
  @override
  String get name => analysisGuardCommandName;

  @override
  String get description =>
      'Guard a Dart analysis server (started by Appstein itself).';

  @override
  bool get hidden => true;

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1) {
      usageException('Pass the dart executable that runs the server.');
    }
    return runAnalysisGuard(rest.single);
  }
}

/// The command that starts the guard from this process: what
/// `AnalysisServer` takes as its `guardCommand`.
///
/// - **A compiled `appstein`** starts itself again, with the name of the
///   guard mode as its one argument.
/// - **Appstein run from source** (its own tests, `dart run`) has no binary
///   to start. There the running `dart` starts `bin/appstein.dart` of this
///   package, with the same argument. It is the same command either way;
///   only how it is started differs, and from source it takes seconds
///   longer.
List<String> analysisGuardCommand() {
  final executable = Platform.resolvedExecutable;
  // A compiled binary has no package configuration to ask.
  Uri? library;
  try {
    library = Isolate.resolvePackageUriSync(
      Uri.parse('package:appstein_cli/appstein_cli.dart'),
    );
  } on UnsupportedError {
    library = null;
  }
  if (library == null) return [executable, analysisGuardCommandName];
  return [
    executable,
    p.join(p.dirname(p.dirname(library.toFilePath())), 'bin', 'appstein.dart'),
    analysisGuardCommandName,
  ];
}
