import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;

import 'analysis_guard_command.dart';
import 'analysis_host_command.dart';
import 'version.dart';

/// The code analysis of a run that asks the project's analysis host
/// (`analysisHostCodeAnalysis`, decision record 0002) for the project at
/// [projectRoot], with the host's address file in the folder [environment]
/// names (`analysisHostFolder`). Two kinds of run use it, told apart by
/// [startHost]:
///
/// - **The `verify` tool of `appstein mcp` and the hooks** ([startHost] true;
///   a hook run begins the look, and the launch, at its start with `warmUp`):
///   the host is started when none answers ([analysisHostCommand]), and given the
///   analysis cache folder [environment] names
///   (`analysisServerEnvironment`) as a full path, since the host runs in
///   another folder. When the host runs a newer Appstein, the call is
///   answered by an analysis server of its own instead, and says the session
///   should be restarted.
/// - **A terminal `appstein verify`** ([startHost] false): the scope only
///   uses a host that already answers with this Appstein's version, and
///   never starts, stops or deletes one. With no host that can be used (none,
///   a dead one, one of another version, one that won't answer), the call is
///   answered by an analysis server of its own, stopped at the end, as in
///   slice 1d.2; a host that fails after it answered is Appstein failing
///   (see `analysisHostCodeAnalysis`).
///
/// [dartSdkPath] replaces the Flutter SDK's own Dart SDK, for tests.
///
/// [onLeft] is told, after a call that used a server of its own was
/// answered and the server stopped, a line for each process the stop could
/// not end because it could not be shown to be the server's own
/// (`AnalysisServer.leftProcesses`); `appstein mcp` writes them to stderr,
/// and a terminal run prints them.
CodeAnalysisScope hostCodeAnalysis({
  required String projectRoot,
  required HostEnvironment environment,
  String? dartSdkPath,
  bool startHost = true,
  void Function(List<String> notices)? onLeft,
}) {
  final folder = analysisHostFolder(environment);
  final own = <AnalysisServer>[];
  final scope = analysisHostCodeAnalysis(
    projectRoot: projectRoot,
    hostCommand: analysisHostCommand(
      addressFolder: folder,
      dartSdkPath: dartSdkPath,
    ),
    addressFolder: folder,
    appsteinVersion: appsteinVersion,
    startHost: startHost,
    // The server of a run that does not use the host: the one a terminal run
    // without a host starts.
    ownServer: () {
      final server = AnalysisServer(
        projectRoot: projectRoot,
        guardCommand: analysisGuardCommand(),
        dartExecutable: () => projectDartExecutable(
          environment,
          projectRoot,
          dartSdkPath: dartSdkPath,
        ),
        environment: analysisServerEnvironment(environment),
      );
      own.add(server);
      return server;
    },
    os: environment.os,
    environment: {
      for (final MapEntry(:key, :value) in analysisServerEnvironment(
        environment,
      ).entries)
        key: value.isEmpty || p.isAbsolute(value)
            ? value
            : p.join(environment.workingDirectory, value),
    },
  );
  return <T>(body) async {
    try {
      return await scope(body);
    } finally {
      // The scope has closed its own server, if it used one.
      final servers = [...own];
      own.clear();
      for (final server in servers) {
        final left = server.leftProcesses();
        if (left.isNotEmpty) onLeft?.call(left);
      }
    }
  };
}
