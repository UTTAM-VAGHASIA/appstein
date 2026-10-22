import 'package:appstein_engine/appstein_engine.dart';
import 'package:path/path.dart' as p;

import 'analysis_guard_command.dart';
import 'analysis_host_command.dart';
import 'version.dart';

/// The code analysis of a run that asks the project's analysis host
/// (`analysisHostCodeAnalysis`, decision record 0002) for the project at
/// [projectRoot], with the host's address file in the folder [environment]
/// names (`chooseAnalysisHostFolder`; when it is refused, the error says why
/// the user's own folders were not used). Two kinds of run use it, told apart by
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
/// **The folder is chosen when the host is first asked**, not when this is
/// called: a run that never asks the host pays for no look at the disk
/// (`chooseAnalysisHostFolder`). When no host can be used there (the folder
/// is another user's, or the host could not start in it), the run is
/// answered by a server of its own, with a notice that says why, and why the
/// user's own folders were not used; the other places the host may be are
/// looked at first (`otherAnalysisHostPlaces`).
///
/// A host is told to follow its folder (`--follow-folder`) only on Linux,
/// where the folder is chosen from facts of the machine that can change, and
/// only when the machine chose it: [followFolder] false (tests, whose
/// environment describes a machine that is not the real one) never.
///
/// [newOwnServer] replaces the analysis server a run that uses none gets, for
/// tests.
///
/// With [keepOwnServer] (`appstein mcp`, a session of many calls) the server
/// of its own that a call that can use no host gets is kept for the session,
/// and stopped after 10 minutes unused, instead of one being started for each
/// call; the session stops it when it ends ([SessionOwnServer.close]).
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
  bool followFolder = true,
  SessionOwnServer? keepOwnServer,
  void Function(List<String> notices)? onLeft,
  StoppableCodeAnalysis Function()? newOwnServer,
}) {
  final own = <AnalysisServer>[];
  StoppableCodeAnalysis newServer() =>
      newOwnServer?.call() ??
      AnalysisServer(
        projectRoot: projectRoot,
        guardCommand: analysisGuardCommand(),
        dartExecutable: () => projectDartExecutable(
          environment,
          projectRoot,
          dartSdkPath: dartSdkPath,
        ),
        environment: analysisServerEnvironment(environment),
      );
  final scope = analysisHostCodeAnalysis(
    projectRoot: projectRoot,
    location: () {
      final chosen = chooseAnalysisHostFolder(environment);
      return (
        folder: chosen.folder,
        command: analysisHostCommand(
          addressFolder: chosen.folder,
          dartSdkPath: dartSdkPath,
          // A folder chosen from the machine's facts is looked after by the
          // host; one the variable gave (tests, the measurement tool) stays
          // where it is.
          followFolder: hostFollowsFolder(
            environment,
            followFolder: followFolder,
          ),
        ),
        note: chosen.cacheNote,
        others: () =>
            otherAnalysisHostPlaces(environment, chosen: chosen.folder),
      );
    },
    appsteinVersion: appsteinVersion,
    startHost: startHost,
    // The server of a run that does not use the host: the one a terminal run
    // without a host starts, or the session's own.
    ownServer: () {
      if (keepOwnServer != null) {
        return _BorrowedServer(keepOwnServer._keep(newServer));
      }
      final server = newServer();
      if (server is AnalysisServer) own.add(server);
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

/// The analysis server of its own that the calls of one `appstein mcp`
/// session share when they can use no host ([hostCodeAnalysis]'s
/// `keepOwnServer`): made by the first such call, kept between calls, stopped
/// after 10 minutes unused, and stopped by [close] when the session ends, so
/// the command never outlives its session because of it.
final class SessionOwnServer {
  KeptAnalysisServer<StoppableCodeAnalysis>? _kept;
  StoppableCodeAnalysis? _server;
  bool _closed = false;

  KeptAnalysisServer<StoppableCodeAnalysis> _keep(
    StoppableCodeAnalysis Function() newServer,
  ) {
    if (_closed) {
      throw const CodeAnalysisException('the session has ended');
    }
    return _kept ??= KeptAnalysisServer(_server = newServer());
  }

  /// Stops the kept server, if a call made one, and waits for it; returns a
  /// line for each process its stop could not end because it could not be
  /// shown to be the server's own (`AnalysisServer.leftProcesses`). No call
  /// can use it afterwards.
  Future<List<String>> close() async {
    _closed = true;
    final kept = _kept;
    if (kept == null) return const [];
    await kept.close();
    final server = _server;
    return server is AnalysisServer ? server.leftProcesses() : const [];
  }
}

/// The session's kept server ([hostCodeAnalysis]'s `keepOwnServer`) as one
/// call's own server: each question takes the kept server for its turn, and
/// the end of the call stops nothing: the server is kept, and stopped by its
/// idle time.
final class _BorrowedServer implements StoppableCodeAnalysis {
  _BorrowedServer(this._kept);

  final KeptAnalysisServer<StoppableCodeAnalysis> _kept;

  @override
  Future<CodeReading> read() => _kept.use((analysis) => analysis.read());

  @override
  Future<bool> canDartFix(
    CodeDiagnostic diagnostic, {
    required Duration within,
  }) =>
      _kept.use((analysis) => analysis.canDartFix(diagnostic, within: within));

  @override
  Future<FormatAnswers> formatChanges(
    List<String> files, {
    required Duration within,
  }) => _kept.use((analysis) => analysis.formatChanges(files, within: within));

  @override
  Future<PendingFixes> pendingFixes({required Duration within}) =>
      _kept.use((analysis) => analysis.pendingFixes(within: within));

  @override
  Future<AppliedChanges> applyFixesAndFormat({
    required Future<bool> Function(String file) leaveUnformatted,
    required Duration within,
  }) => _kept.use(
    (analysis) => analysis.applyFixesAndFormat(
      leaveUnformatted: leaveUnformatted,
      within: within,
    ),
  );

  @override
  Future<void> stop() async {}

  @override
  Future<void> close() async {}
}

/// Whether the host a client starts for [environment] is told to follow its
/// folder (`--follow-folder`): only on Linux, where the folder is chosen from
/// facts of the machine that can change, and only when the machine chose it
/// (`APPSTEIN_ANALYSIS_HOST_FOLDER` not set), and not when [followFolder] is
/// false (tests, whose environment describes a machine that is not the real
/// one). Windows and macOS hosts never look after their folder, so nothing is
/// read or started for it there.
bool hostFollowsFolder(
  HostEnvironment environment, {
  bool followFolder = true,
}) =>
    followFolder &&
    environment.os == HostOs.linux &&
    environment.variable(analysisHostFolderVariable) == null;
