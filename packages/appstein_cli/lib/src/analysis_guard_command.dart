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
    // `exit`, as `runAnalysisGuard` asks, and not the exit code every other
    // command returns: a guard that has said it ended must not stay, and a
    // write to a server that had just died was seen to keep the process
    // running. The guard has flushed what it wrote.
    exit(await runAnalysisGuard(rest.single));
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
///   longer. The script is given the package configuration this process
///   runs with (`--packages`): one installed with `dart pub global
///   activate` lives in the pub cache, which has none beside it.
List<String> analysisGuardCommand() =>
    appsteinModeCommand(analysisGuardCommandName);

/// The command that starts this `appstein` again in its hidden mode [mode],
/// as [analysisGuardCommand] says for the guard's.
List<String> appsteinModeCommand(String mode) {
  // A compiled binary has no package configuration to ask.
  Uri? library;
  Uri? packageConfig;
  try {
    library = Isolate.resolvePackageUriSync(
      Uri.parse('package:appstein_cli/appstein_cli.dart'),
    );
    packageConfig = Isolate.packageConfigSync;
  } on UnsupportedError {
    library = null;
  }
  return modeCommandFrom(
    mode,
    executable: Platform.resolvedExecutable,
    library: library,
    packageConfig: packageConfig,
  );
}

/// [appsteinModeCommand] for the hidden mode [mode] (the guard's,
/// [analysisGuardCommandName], or the analysis host's,
/// `analysisHostCommandName`) from what the running Dart says: its
/// [executable], where `package:appstein_cli/appstein_cli.dart` is
/// ([library], null in a compiled binary) and the package configuration it
/// runs with ([packageConfig], null when there is none).
List<String> modeCommandFrom(
  String mode, {
  required String executable,
  Uri? library,
  Uri? packageConfig,
}) {
  if (library == null) return [executable, mode];
  return [
    executable,
    if (packageConfig != null && packageConfig.isScheme('file'))
      '--packages=${packageConfig.toFilePath()}',
    p.join(p.dirname(p.dirname(library.toFilePath())), 'bin', 'appstein.dart'),
    mode,
  ];
}
