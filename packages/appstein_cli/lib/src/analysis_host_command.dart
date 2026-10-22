import 'dart:io';

import 'package:appstein_engine/appstein_engine.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'analysis_guard_command.dart';
import 'version.dart';

/// The name of the analysis host's mode:
/// `appstein analysis-host --address-folder <folder> <project>`.
const analysisHostCommandName = 'analysis-host';

/// `appstein analysis-host <project>`: the analysis host of one project
/// (decision record 0002, `runAnalysisHost`). A client of the host starts it,
/// detached, when none answers (`analysisHostCodeAnalysis`); nobody types it,
/// so the help doesn't list it.
///
/// It owns the project's analysis server, of the SDK the project uses and
/// behind the guard ([analysisGuardCommand]), answers code questions on
/// `127.0.0.1` behind a secret, and ends itself after ten minutes with no
/// client. It writes nothing on stdout or stderr: a detached process has
/// nobody reading them.
///
/// Its options are for whoever starts it: `--address-folder`, where its
/// address file goes (the starter's `analysisHostFolder`, so both look in
/// the same place); `--follow-folder`, given when the client chose that folder
/// from the machine's facts, so the host looks after it as `runAnalysisHost`
/// says (`folderNow`); `--dart-sdk`, a Dart SDK that runs the server instead
/// of the project's Flutter SDK's (Appstein's own tests); and
/// `--idle-stop-seconds`, a shorter idle time (tests).
final class AnalysisHostCommand extends Command<int> {
  /// Creates the command.
  AnalysisHostCommand() {
    argParser
      ..addOption('address-folder', valueHelp: 'folder')
      ..addFlag('follow-folder', negatable: false)
      ..addOption('dart-sdk', valueHelp: 'path')
      ..addOption('idle-stop-seconds', valueHelp: 'seconds');
  }

  @override
  String get name => analysisHostCommandName;

  @override
  String get description =>
      "Answer a project's code questions (started by Appstein itself).";

  @override
  bool get hidden => true;

  @override
  Future<int> run() async {
    final results = argResults!;
    final rest = results.rest;
    if (rest.length != 1) usageException('Pass the project folder.');
    final projectRoot = p.normalize(p.absolute(rest.single));
    final machine = HostEnvironment.current();
    final dartSdk = results.option('dart-sdk');
    final idle = int.tryParse(results.option('idle-stop-seconds') ?? '');
    try {
      await runAnalysisHost(
        projectRoot: projectRoot,
        analysis: (writes) => AnalysisServer(
          projectRoot: projectRoot,
          guardCommand: analysisGuardCommand(),
          dartExecutable: () =>
              projectDartExecutable(machine, projectRoot, dartSdkPath: dartSdk),
          environment: analysisServerEnvironment(machine),
          // A rewrite whose client has gone away writes nothing.
          replaceText: writes.replaceText,
        ),
        addressFolder:
            results.option('address-folder') ?? analysisHostFolder(machine),
        appsteinVersion: appsteinVersion,
        idleStop: idle == null ? analysisHostIdleStop : Duration(seconds: idle),
        os: machine.os,
        folderNow: results.flag('follow-folder')
            ? analysisHostFolderNow(machine)
            : null,
      );
    } on Object {
      // It could not start, and has left why for its client
      // (`analysisHostFailureFile`); nobody reads this process's output.
      exit(1);
    }
    // `exit`, as the guard does: nothing may keep an ended host running.
    exit(0);
  }
}

/// The command that starts the analysis host from this process, without
/// the project folder, which the client adds: this `appstein` in its host
/// mode ([appsteinModeCommand]), with [addressFolder] and, for tests,
/// [dartSdkPath] and [idleStop]. With [followFolder] the host looks after its
/// folder: it moves its address when the folder chosen from the machine's
/// facts changes (`--follow-folder`).
List<String> analysisHostCommand({
  required String addressFolder,
  String? dartSdkPath,
  Duration? idleStop,
  bool followFolder = false,
}) => [
  ...appsteinModeCommand(analysisHostCommandName),
  '--address-folder=$addressFolder',
  if (followFolder) '--follow-folder',
  if (dartSdkPath != null) '--dart-sdk=$dartSdkPath',
  if (idleStop != null) '--idle-stop-seconds=${idleStop.inSeconds}',
];
