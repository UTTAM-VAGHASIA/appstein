import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/host_environment.dart';
import '../knowledge/input_hash.dart';
import '../sdk/sdk_detector.dart';
import 'analysis_cache.dart';
import 'analysis_guard.dart';
import 'code_analysis.dart';
import 'disk_look.dart';
import 'process_identity.dart';

/// How long an analysis server may take until its analysis is done, before
/// the run fails (slice 1d.2). The slowest start measured was 71 s.
const analysisReadyTimeout = Duration(seconds: 180);

/// The ID the analysis server gives a data-driven fix (a migration a
/// package's `fix_data.yaml` describes), the kind `dart fix` applies to the
/// use of a deprecated API. Measured in ticket 02 of slice 1d.2.
const dataDrivenFixId = 'dart.fix.dataDriven';

/// The real `dart` executable of the Dart SDK at [dartSdkPath]: never the
/// `dart.bat` wrapper of a Flutter SDK or FVM's, which each cost a second
/// per start on Windows.
String dartExecutableIn(String dartSdkPath) =>
    p.join(dartSdkPath, 'bin', Platform.isWindows ? 'dart.exe' : 'dart');

/// The `dart` executable of the Flutter SDK the project at [projectRoot]
/// uses, found as every other part of Appstein finds the SDK, so `verify`
/// agrees with the developer's `dart analyze` and IDE. [dartSdkPath]
/// replaces the Flutter SDK's own Dart SDK, for tests.
///
/// Throws a [CodeAnalysisException] when the project has no usable SDK.
String projectDartExecutable(
  HostEnvironment environment,
  String projectRoot, {
  String? dartSdkPath,
}) {
  if (dartSdkPath != null) return dartExecutableIn(dartSdkPath);
  final detection = SdkDetector(environment).detect(projectRoot: projectRoot);
  final location = detection.location;
  if (detection.info == null || location == null) {
    final problem = detection.problem ?? 'no Flutter SDK was found';
    throw CodeAnalysisException(
      'the project has no usable Flutter SDK '
      '(${problem.replaceFirst(RegExp(r'\.$'), '')})',
    );
  }
  return dartExecutableIn(p.join(location.root, 'bin', 'cache', 'dart-sdk'));
}

/// A scope that gives each body an analysis server of its own for the
/// project at [projectRoot], and stops it when the body ends, normally or
/// with an error. This is what a terminal `appstein verify` does. The
/// server is started only when the body first asks something. A question
/// asked after the body has ended never starts a server nobody stops:
/// `read` throws a [StateError], and `formatChanges`, `canDartFix`,
/// `pendingFixes` and `applyFixesAndFormat` throw a
/// [CodeAnalysisException].
///
/// The arguments are [AnalysisServer.new]'s, and [onLeft]: called after the
/// server was stopped, with a line for each process the stop could not end
/// because it could not be shown to be the server's own
/// ([AnalysisServer.leftProcesses]). A terminal run has no later run to
/// tell it in, so it prints them.
CodeAnalysisScope ownAnalysisServer({
  required String projectRoot,
  required List<String> guardCommand,
  required String Function() dartExecutable,
  Map<String, String> environment = const {},
  Duration readyTimeout = analysisReadyTimeout,
  ProcessLookup processLookup = lookUpProcess,
  void Function(List<String> notices)? onLeft,
}) => <T>(body) async {
  final server = AnalysisServer(
    projectRoot: projectRoot,
    guardCommand: guardCommand,
    dartExecutable: dartExecutable,
    environment: environment,
    readyTimeout: readyTimeout,
    processLookup: processLookup,
  );
  try {
    return await body(server);
  } finally {
    await server.close();
    // What the stop could not end and could not show to be its own. The
    // body's result was made before the stop, so it can't hold this.
    final left = server.leftProcesses();
    if (left.isNotEmpty) onLeft?.call(left);
  }
};

/// The code analysis of one project, answered by a Dart analysis server
/// that runs as a child process behind a guard (decision record 0001).
///
/// - **The server** is `dart language-server --protocol=analyzer` of the
///   project's own SDK, spoken to over the legacy analyzer protocol: one
///   JSON object per line on its stdin and stdout.
/// - **It starts when it is first asked**, so an owner that never asks holds
///   no server. A question waits until the server says its analysis is done
///   (`server.status`), which over this protocol includes its plugins'.
/// - **Diagnostics** are kept from the `analysis.errors` notifications the
///   server sends for each file, since the request for one file's errors
///   leaves a plugin's diagnostics out. A file is dropped when the server
///   sends `analysis.flushResults` for it.
/// - **A plugin that could not be loaded** is told with `server.pluginError`,
///   after which the server reports its analysis done as usual. Those
///   messages are kept and returned with every reading.
/// - **Whoever creates it owns it** and must call [stop] or [close]. No
///   check does.
/// - **It may be kept between questions** (`KeptAnalysisServer`). Every
///   question then makes the server take in what changed on disk since the
///   last one, before it reads ([read]).
///
/// A server that can't be started, reports a fatal error, ends by itself,
/// loses its guard, or isn't done within [readyTimeout] makes the question
/// throw a [CodeAnalysisException]. Its processes are ended before the
/// exception is thrown, and the next question starts a new server. One
/// case is not an error: a server that answered an earlier question and is
/// found dead by this one is replaced, and this question is answered by the
/// new server.
final class AnalysisServer implements StoppableCodeAnalysis {
  /// Creates the analysis of the project at [projectRoot]. Nothing is
  /// started yet.
  ///
  /// [guardCommand] starts the guard: the `appstein` binary and the name of
  /// its guard mode, or where Appstein runs from source, `dart`, its entry
  /// script and that name. The server's `dart` is added as the last
  /// argument. [dartExecutable] gives that `dart` when the server is
  /// started; it may throw a [CodeAnalysisException] when the project has
  /// none (see [projectDartExecutable]). [environment] is added to
  /// Appstein's own environment for the guard, and so for the server.
  AnalysisServer({
    required String projectRoot,
    required this.guardCommand,
    required this.dartExecutable,
    this.environment = const {},
    this.readyTimeout = analysisReadyTimeout,
    this.processLookup = lookUpProcess,
    this.afterLook,
    this.replaceText = replaceFileText,
  }) : projectRoot = p.normalize(p.absolute(projectRoot));

  /// How [applyFixesAndFormat] writes a file's new text: [replaceFileText].
  /// Replaced by a test, so a write can fail or take long, and by the
  /// analysis host (`AnalysisHostWrites.replaceText`), so a rewrite whose
  /// client has gone away writes nothing. A write that throws a
  /// [FileSystemException] leaves its file as it was, named in `leftAlone`.
  final Future<void> Function(String path, String text) replaceText;

  /// **Test-only**, like [processLookup]: called in each reading after the
  /// look at the disk and the reading of the changed files, before the
  /// server is told of them, so a test can change a file at that moment.
  /// Production code leaves it null; `ownAnalysisServer` and the CLI never
  /// pass it.
  final Future<void> Function()? afterLook;

  /// Asks the system which process runs under an ID: how a process is
  /// shown to be one this object started before it is ended by its ID.
  /// Only tests replace it.
  final ProcessLookup processLookup;

  /// Processes that were to be ended by their ID and may still be there, by
  /// ID: `seen` is the process that had the ID then (null when it couldn't
  /// be told who it was), and `shown` says whether it was shown to be one
  /// this object started (it was then killed) or not (it was left alone).
  /// One ID is one entry, however often a stop met it.
  final _left = <int, ({ProcessIdentity? seen, bool shown})>{};

  /// Notes the process with the ID [id] as left; an ID noted already keeps
  /// its first note.
  void _leave(int id, ProcessIdentity? seen, {required bool shown}) =>
      _left.putIfAbsent(id, () => (seen: seen, shown: shown));

  /// Looks again at each process an earlier stop may have left, and
  /// returns one line for each that is still there and could not be ended:
  /// its ID, that Appstein could not confirm it is its own analysis server
  /// and so did not end it, and the command to end it by hand.
  ///
  /// - A process that is gone, or whose ID another process has now, is
  ///   forgotten.
  /// - One that was shown to be this object's own and is still there is
  ///   killed again.
  /// - One that can't be told about at all is reported, never dropped.
  ///
  /// Every reading does this first and carries the lines
  /// (`CodeReading.notices`); the owner of a server that is closed for
  /// good asks once more afterwards.
  List<String> leftProcesses() {
    final lines = <String>[];
    for (final id in [..._left.keys]) {
      final left = _left[id]!;
      switch (processLookup(id)) {
        case ProcessGone():
          _left.remove(id);
        case ProcessRunning(identity: final now)
            when left.seen != null && now != left.seen:
          // Another process has the ID: the one that was left has ended.
          _left.remove(id);
        case ProcessRunning(identity: final now) when left.shown:
          Process.killPid(now.id, ProcessSignal.sigkill);
        case ProcessRunning(identity: final now):
          lines.add(_leftLine(id, now.image, 'confirm that it is its own'));
        case ProcessUnknown():
          lines.add(
            _leftLine(id, left.seen?.image, 'tell what the process is'),
          );
      }
    }
    return lines;
  }

  static String _leftLine(int id, String? image, String couldNot) =>
      'Process $id${image == null ? '' : ' ($image)'} may be an analysis '
      'server that Appstein started and could not stop. Appstein could not '
      '$couldNot, so it did not end it. To end it by hand: '
      '`${endByHandCommand(id, image: image)}`';

  /// The project's folder, absolute.
  final String projectRoot;

  /// The command that starts the guard, without the server's `dart`.
  final List<String> guardCommand;

  /// Gives the `dart` executable that runs the server.
  final String Function() dartExecutable;

  /// The variables the guard is started with besides Appstein's own
  /// environment; the server inherits the guard's. Empty in production,
  /// where the developer's own environment says where the server's cache is
  /// ([analysisCacheVariable]); a test gives its servers a cache folder of
  /// their own here.
  final Map<String, String> environment;

  /// How long a question waits for the server's analysis to be done.
  final Duration readyTimeout;

  _Session? _session;
  var _closed = false;

  /// The process IDs of the running guard and server; null when no server
  /// is running, or the guard hasn't named them yet.
  ({int guard, int server})? get processes => _session?.processes;

  /// One reading from the running server, which is started first when none
  /// is running. Questions asked at the same time share one server, and are
  /// answered one after the other.
  ///
  /// **The reading is never older than the files on disk** as they were
  /// when it was asked for. A running server learns of a changed file from
  /// its own file watcher, some time later, so a question does not rely on
  /// that. Before each reading it
  /// 1. looks at the project's files itself and compares them with its last
  ///    look: every Dart file's time and size, and the text of the files
  ///    that set how the project is analyzed (`analysis_options.yaml`,
  ///    `pubspec.yaml` and `.dart_tool/package_config.json`). Folders whose
  ///    name starts with a dot are left out, as the server leaves them out;
  /// 2. tells the server each Dart file that changed, appeared or is gone
  ///    (`analysis.updateContent`, which makes it read the file again at
  ///    once), and asks it for one of those files' errors: the answer comes
  ///    only after the server has taken the changes in and started on them;
  /// 3. waits until the server says its analysis is done.
  ///
  /// With no change it still sends one request and waits for the answer, so
  /// **a reading is never taken from a server that has died**: a dead
  /// server answers nothing. A server that answered an earlier question and
  /// is found dead here is replaced by a new one, which answers this
  /// question.
  ///
  /// **When one of the files that set how the project is analyzed changed,
  /// the server is started again** and the new one answers. The server
  /// takes such a change in by itself, but later, and nothing it sends says
  /// when it has. A new server has read the files as they are, and it tells
  /// a plugin that still can't be loaded again, so `pluginFailures` holds a
  /// failure only while it holds.
  @override
  Future<CodeReading> read() async {
    if (_closed) {
      throw StateError(
        'The analysis server of $projectRoot was asked after its owner '
        'closed it.',
      );
    }
    var replacedDead = false;
    for (var starts = 0; ; starts++) {
      if (_closed) throw const CodeAnalysisException('it was stopped');
      final session = _session ??= _Session(this);
      // A server that answered before may have died since: that is found
      // here, and is no reason to fail this question.
      final kept = session.answered;
      var late = false;
      try {
        return await session.read().timeout(
          readyTimeout,
          onTimeout: () {
            late = true;
            throw CodeAnalysisException(
              'its analysis was not done within ${readyTimeout.inSeconds} s',
            );
          },
        );
      } on _SettingsChanged {
        await _replace(session);
        if (starts >= _mostStarts) {
          throw const CodeAnalysisException(
            'the files that set how the project is analyzed kept changing '
            'while it started',
          );
        }
      } on CodeAnalysisException {
        // Another question on the same server already replaced it.
        final replaced = session.replaced;
        // Nothing is left running, and the next question starts again.
        if (identical(_session, session)) _session = null;
        await session.stop();
        if (replaced && starts < _mostStarts) continue;
        if (!kept || late || replacedDead || session.stoppedByOwner) rethrow;
        replacedDead = true;
      }
    }
  }

  /// Asks the running server, which answered the last [read], whether it
  /// offers a data-driven fix for [diagnostic] (`edit.getFixes` at the
  /// diagnostic's offset): a migration the package that deprecated the API
  /// describes in its `fix_data.yaml`. Nothing is changed, on disk or in the
  /// server.
  ///
  /// The answer is kept by the file's path, the hash of the text the server
  /// analyzed (the text a reading gave it), the offset and the code, for as
  /// long as the server runs: a use in an unchanged file is asked about
  /// once. Where that text isn't known the answer is not kept.
  ///
  /// Throws a [CodeAnalysisException] when no reading was taken from the
  /// running server (another caller replaced it, or it died: the offset
  /// belongs to that reading), and when the server fails meanwhile. A
  /// caller falls back to saying nothing.
  @override
  Future<bool> canDartFix(
    CodeDiagnostic diagnostic, {
    required Duration within,
  }) async {
    final session = _session;
    if (session == null || !session.answered) {
      throw const CodeAnalysisException(
        'it was asked about a fix with no reading taken from it',
      );
    }
    // The time is the server's own: an earlier question of the same run
    // that it is still busy with counts, nothing of the caller's does.
    return session.canDartFix(diagnostic).timeout(within);
  }

  /// Asks the running server, which answered the last [read], which of
  /// [files] its formatter would change (`edit.format`, which the server
  /// answers with the edits `dart format` of its SDK would make, the project's
  /// `formatter:` settings in `analysis_options.yaml` included). Nothing is
  /// changed, on disk or in the server.
  ///
  /// - **The questions are sent together**, at most 32 at a time (the most
  ///   files the look keeps open): a question costs the server about 15 ms
  ///   when it is the only one in flight, and next to nothing when many are,
  ///   so 100 files cost 30 to 125 ms, not 1.5 s.
  /// - **At most [within] is spent**, counted from when the server is asked
  ///   (and, past that, [questionGrace] for a server stuck on an earlier
  ///   question). A question still unanswered then is given up and its file
  ///   is in neither map of the result; its answer, when it comes, is kept
  ///   for the next question.
  /// - **The answer is kept** by the file's path and the hash of the text
  ///   the server analyzed (the text a reading gave it), for as long as the
  ///   server runs, so a file that did not change is asked about once. A new
  ///   server (a change to a file that sets how the project is analyzed, such
  ///   as `analysis_options.yaml`, which can change the format) starts with
  ///   none. Where that text isn't known the answer is not kept.
  /// - **The server answers from its own copy of the file**, which its file
  ///   watcher may have updated after the reading. So when an answer arrives,
  ///   the file is read again; if it is no longer the text of the reading
  ///   (changed, deleted, locked), the answer is neither kept nor used: the
  ///   file is in `refused`, as one not checked. The re-read compares the
  ///   text, so it also finds an edit that keeps the file's size and puts its
  ///   time back, which the reading's look (sizes and times) never sees; such
  ///   a file is "not checked" for that question, and the next reading tells
  ///   the server about it again, so the question after it is answered. The
  ///   same re-read comes before a syntax-error answer is used or kept.
  /// - **A file with a syntax error** is answered false: the server refuses
  ///   to format it (`FORMAT_WITH_ERRORS`). Any other refusal is that file's
  ///   alone: it is in `refused` with the server's words, and the other
  ///   answers are kept.
  ///
  /// Throws a [CodeAnalysisException] when no reading was taken from the
  /// running server (another caller replaced it, or it died: the kept answers
  /// belong to that reading), and when the server fails meanwhile.
  @override
  Future<FormatAnswers> formatChanges(
    List<String> files, {
    required Duration within,
  }) async {
    final session = _session;
    if (session == null || !session.answered) {
      throw const CodeAnalysisException(
        'it was asked about formatting with no reading taken from it',
      );
    }
    return session
        .formatChanges(files, within)
        .timeout(
          within + questionGrace,
          onTimeout: () => const FormatAnswers(),
        );
  }

  /// Asks the running server, which answered the last [read], for the fixes
  /// `dart fix --dry-run` would list, in passes (`edit.bulkFixes`, as `dart
  /// fix` asks): each pass's edits are applied to an overlay of the file in
  /// the server's memory (`analysis.updateContent` with `add`), and the
  /// server is asked again, until a pass finds none or [mostFixPasses] passes
  /// have found fixes, which is where `dart fix` of the pinned SDK stops too
  /// (finished, not cut short). The counts of every pass are summed by file
  /// and code.
  ///
  /// - **Nothing is written to disk.** The overlays are removed when the
  ///   passes end, also when a pass fails, is refused or runs out of time,
  ///   and the next reading tells the server those files again (`_renew`),
  ///   so it is of the files on disk. A server that refuses to remove an
  ///   overlay, or does not answer an overlay's change within its limit, is
  ///   given up and stopped at once, so the overlay ends with it, and the
  ///   question fails.
  /// - **The passes are asked in turn with the readings**, after the reading
  ///   the run judges, so no finding is judged against the fixed code, and
  ///   no other question is answered while an overlay is in place.
  /// - **A file is only ever changed from the text the reading saw.** A file
  ///   whose text on disk is no longer the reading's, or whose text the
  ///   reading could not tell (it changed between the reading's two whole
  ///   reads), stops the passes: the server's edits were made for its own
  ///   copy, which may be another text. A file reached through a link to
  ///   outside the project is left out.
  /// - **At most [within] is spent**, counted from now (and [questionGrace]
  ///   past that for a server stuck on an earlier question): a pass still
  ///   unanswered then is given up, and the answer says the passes did not
  ///   finish (`PendingFixes.unfinished`). So does a refused pass or overlay.
  ///
  /// Throws a [CodeAnalysisException] when no reading was taken from the
  /// running server, and when the server fails meanwhile.
  @override
  Future<PendingFixes> pendingFixes({required Duration within}) async {
    final session = _session;
    if (session == null || !session.answered) {
      throw const CodeAnalysisException(
        'it was asked for the pending fixes with no reading taken from it',
      );
    }
    final since = Stopwatch()..start();
    final limit = fixQuestionLimit(within);
    return session
        .pendingFixes(since, within)
        .timeout(
          limit,
          onTimeout: () => PendingFixes(
            unfinished:
                'the analysis server did not answer within '
                '${secondsText(limit)}',
          ),
        );
  }

  /// The most passes in which the pending fixes are asked: `dart fix` of the
  /// pinned SDK (3.47.5) stops after four passes that found fixes, and a
  /// chain of eight migrations was shown to stop there (four listed, and
  /// `--apply` leaving the fifth name). Reaching it is finished, as it is for
  /// `dart fix`, so a fix that undoes another never makes a run partial.
  static const mostFixPasses = 4;

  /// Applies the fixes [pendingFixes] finds to the files on disk, and formats
  /// each Dart file of the last reading that [leaveUnformatted] does not
  /// rule out, with the server's formatter (`edit.format`, asked of the
  /// fixed text while its overlay is in place). The overlays are removed,
  /// and then each file is written once, with its final text, only when
  /// that differs from the text on disk, through a new file beside it that
  /// takes its place ([replaceText], [replaceFileText]).
  ///
  /// A file is written only when its text on disk is still the text the
  /// last reading saw and the text the fixes were applied to, it is valid
  /// UTF-8, and it is inside the project once links are followed; otherwise
  /// it is left as it is, with why (`AppliedChanges.leftAlone`), and what it
  /// needs stays pending. So is a file whose new text could not be written.
  /// The next reading tells the server every file that was written or
  /// overlaid.
  ///
  /// [within] is counted from now, and every request has a limit of its own
  /// ([fixRequestFloor] at least). **The server's part is limited as a
  /// whole too**, for a server stuck on an earlier question: when the
  /// passes, the formatting and the removal of the overlays have not ended
  /// within [fixQuestionLimit], the server is given up, the call fails, and
  /// nothing is written. The writes that follow need no server and have no
  /// limit: once they begin, the call returns what was written.
  ///
  /// Throws a [CodeAnalysisException] as [pendingFixes] does.
  @override
  Future<AppliedChanges> applyFixesAndFormat({
    required Future<bool> Function(String file) leaveUnformatted,
    required Duration within,
  }) async {
    final session = _session;
    if (session == null || !session.answered) {
      throw const CodeAnalysisException(
        'it was asked to apply fixes with no reading taken from it',
      );
    }
    final since = Stopwatch()..start();
    final limit = fixQuestionLimit(within);
    final rewrite = session.applyFixesAndFormat(
      leaveUnformatted,
      since,
      within,
    );
    try {
      await rewrite.serverDone.timeout(limit);
    } on TimeoutException {
      // The writes wait for the server's part; they see this and write
      // nothing, since the call's answer could no longer name them.
      session._rewriteAbandoned = true;
      rewrite.written.ignore();
      throw session.giveUp('the rewrite', limit);
    }
    return rewrite.written;
  }

  /// How often one question starts a server again before it gives up.
  static const _mostStarts = 5;

  /// Ends [session] because a new server must answer in its place.
  Future<void> _replace(_Session session) async {
    session.replaced = true;
    if (identical(_session, session)) _session = null;
    await session.stop();
  }

  /// Stops the server and its guard, and returns when both have ended. The
  /// server is killed, which leaves half-written files in its cache. The
  /// guard deletes them (only this server's, once it is shown to be gone:
  /// [runAnalysisGuard]) before it ends, so they are gone when this returns.
  /// It does nothing when no server is running, and never throws. A question
  /// asked afterwards starts a new server; a question that is waiting fails
  /// with a [CodeAnalysisException].
  @override
  Future<void> stop() async {
    final session = _session;
    _session = null;
    session?.stoppedByOwner = true;
    await session?.stop();
  }

  /// Stops the server as [stop] does, for good: a question asked afterwards
  /// never starts a server nobody would stop. [read] throws a [StateError],
  /// and [formatChanges], [canDartFix], [pendingFixes] and
  /// [applyFixesAndFormat] throw a [CodeAnalysisException].
  @override
  Future<void> close() {
    _closed = true;
    return stop();
  }
}

/// A file that set how the project is analyzed has changed: the session
/// that found it can't answer, and a new one must.
final class _SettingsChanged implements Exception {
  const _SettingsChanged();
}

/// What the passes of the pending fixes found.
final class _FixPasses {
  /// The counts by file (from the project root with `/`) and code.
  final counts = <String, Map<String, int>>{};

  /// How many passes found fixes.
  var passes = 0;

  /// Why the passes stopped early; null when one found no fix.
  String? unfinished;

  /// The text on disk of each file a pass changed, by absolute path, as the
  /// first pass that changed it read it.
  final bases = <String, String>{};

  /// The files among [bases] that are not valid UTF-8: never written.
  final notUtf8 = <String>{};

  /// The files with fixes that are outside the project once links are
  /// followed: never overlaid, counted or written.
  final outside = <String>{};

  /// The file whose text the passes could not rely on, which stopped them.
  final unknownText = <String>{};
}

/// What the server's part of a rewrite worked out, for the writes.
final class _RewritePlan {
  _RewritePlan({
    required this.finals,
    required this.bases,
    required this.notUtf8,
    required this.leftAlone,
  });

  /// The final text of each file, by absolute path.
  final Map<String, String> finals;

  /// The text each file had on disk when it was taken up, by absolute path.
  final Map<String, String> bases;

  /// The files that are not valid UTF-8.
  final Set<String> notUtf8;

  /// The files left as they were so far, from the project root, with why.
  final Map<String, String> leftAlone;
}

/// The overlays of one run of the fix passes.
final class _Overlays {
  /// The text the server has for each file, by absolute path.
  final texts = <String, String>{};

  /// Every file an overlay was sent for, taken by the server or not: each is
  /// removed afterwards.
  final sent = <String>{};
}

/// Writes all of [bytes] to [file] and flushes them: how [replaceFileText]
/// writes the new file beside the original, unless a test passes its own.
Future<void> _writeAll(RandomAccessFile file, List<int> bytes) async {
  await file.writeFrom(bytes);
  await file.flush();
}

/// Sets the permissions of the file at [path] to [mode] (octal, as `chmod`
/// takes it); false when that failed, also when there is no `chmod` or the
/// file isn't the user's. What [replaceFileText] runs, on Linux and macOS
/// only, when the new file's permissions differ from the original's, and
/// what the analysis host's address file is made user-only with.
Future<bool> setFileMode(String mode, String path) async {
  try {
    return (await Process.run('chmod', [mode, path])).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// The name of the new file [replaceFileText] writes beside the file
/// [name], for the process [processId]: a dot first, so the analysis and
/// Appstein's look leave it out.
String besideFileName(String name, int processId) =>
    '.$name.appstein-$processId.tmp';

/// A file [besideFileName] made: group 1 is the process that made it.
final besideFilePattern = RegExp(r'^\..+\.appstein-(\d+)\.tmp$');

/// The `chmod` mode to give the new file so it has the original's
/// permissions, or null when they are the same already: the permission
/// bits (`& 0o777`) of the new file's [besideMode] and of the original's
/// [originalMode], as `FileStat.mode` gives them.
String? permissionsToSet({required int besideMode, required int originalMode}) {
  final wanted = originalMode & 0x1FF;
  if ((besideMode & 0x1FF) == wanted) return null;
  return wanted.toRadixString(8);
}

/// Replaces the text of the file at [path] with [text], UTF-8 encoded
/// exactly as it is: a byte order mark at its start is kept, and line ends
/// are not touched. A file that is a link to a file keeps being a link: the
/// text goes to the file it points to.
///
/// **A crash or a full disk never leaves the file half written.** The text
/// goes to a new file beside it ([besideFileName], named with a dot, so the
/// analysis leaves it out), which then takes the file's place. On Linux and
/// macOS the new file is first given the original's permissions when they
/// differ ([permissionsToSet], one `chmod`); that costs no process when they
/// are the same.
///
/// - **The original is written in place only when that is safe:** when the
///   new file was written completely and could not take the original's
///   place (on Windows, another program holds the original open without
///   sharing its deletion), or could not be given the original's
///   permissions; and when the new file could not even be created (a folder
///   in which no file can be made), unless the reason is a full disk or a
///   quota ([isDiskFull]). Never after a partial write of the new file.
/// - **When the new file could not be created on a full disk, or not
///   written completely** (a full disk, a quota), it is deleted and the
///   original is left untouched: a [FileSystemException] says so.
/// - The new file is removed on every path. A process killed between the
///   two steps leaves it behind. A later `--apply` that rewrites a file in
///   the same folder removes it (`AnalysisServer.applyFixesAndFormat`); in
///   a folder no later `--apply` rewrites a file in, it stays until removed
///   by hand.
///
/// [openBeside], [writeBeside] and [chmod] are for tests: the first makes
/// the creation of the new file fail, the second makes its write fail part
/// way, the last stands for `chmod`.
///
/// Throws a [FileSystemException] when the file was left as it was.
Future<void> replaceFileText(
  String path,
  String text, {
  Future<RandomAccessFile> Function(File file) openBeside = _openBeside,
  Future<void> Function(RandomAccessFile file, List<int> bytes) writeBeside =
      _writeAll,
  Future<bool> Function(String mode, String path) chmod = setFileMode,
}) async {
  final bytes = utf8.encode(text);
  // A link stays a link: its target is what gets the text.
  var target = path;
  try {
    target = await File(path).resolveSymbolicLinks();
  } on FileSystemException {
    // Not there to resolve: the path is written as it is.
  }
  final beside = File(
    p.join(p.dirname(target), besideFileName(p.basename(target), pid)),
  );
  final RandomAccessFile open;
  try {
    open = await openBeside(beside);
  } on FileSystemException catch (error) {
    if (isDiskFull(error.osError)) {
      // A write in place could fail part way too: the original stays.
      try {
        if (await beside.exists()) await beside.delete();
      } on FileSystemException {
        // The next `--apply` tries.
      }
      throw FileSystemException(
        'no new file could be made beside it: the disk is full '
        '(${error.message})',
        target,
        error.osError,
      );
    }
    // No file can be made beside it: nothing partial exists anywhere.
    await File(target).writeAsBytes(bytes, flush: true);
    return;
  }
  try {
    try {
      await writeBeside(open, bytes);
    } on FileSystemException catch (error) {
      throw FileSystemException(
        'its new text could not be written to a new file beside it '
        '(${error.message})',
        target,
        error.osError,
      );
    } finally {
      try {
        await open.close();
      } on FileSystemException {
        // The bytes were flushed, or the write already failed.
      }
    }
    // Complete: from here a write in place is safe.
    if (await _samePermissions(beside, target, chmod)) {
      try {
        await beside.rename(target);
        return;
      } on FileSystemException {
        // Refused: written in place below.
      }
    }
    await File(target).writeAsBytes(bytes, flush: true);
  } finally {
    try {
      if (await beside.exists()) await beside.delete();
    } on FileSystemException {
      // Nothing more can be done about it here; the next `--apply` tries.
    }
  }
}

/// Whether [error] says the disk is full or a quota is reached:
/// `ERROR_DISK_FULL` (112), `ERROR_HANDLE_DISK_FULL` (39) and
/// `ERROR_DISK_QUOTA_EXCEEDED` (1295) on Windows, `ENOSPC` (28) and
/// `EDQUOT` (122 on Linux, 69 on macOS) elsewhere.
bool isDiskFull(OSError? error) {
  final code = error?.errorCode;
  if (code == null) return false;
  if (Platform.isWindows) return code == 112 || code == 39 || code == 1295;
  if (Platform.isMacOS) return code == 28 || code == 69;
  return code == 28 || code == 122;
}

Future<RandomAccessFile> _openBeside(File file) =>
    file.open(mode: FileMode.writeOnly);

/// Whether [beside] has, or was given, the permissions of [original]; false
/// when `chmod` failed. Always true on Windows, which has no such bits.
Future<bool> _samePermissions(
  File beside,
  String original,
  Future<bool> Function(String mode, String path) chmod,
) async {
  if (Platform.isWindows) return true;
  final mode = permissionsToSet(
    besideMode: (await beside.stat()).mode,
    originalMode: (await File(original).stat()).mode,
  );
  return mode == null || await chmod(mode, beside.path);
}

/// One run of the server: its guard process and what the server has said.
final class _Session {
  _Session(this._owner) {
    _opened = _open();
    // A failure is reported to whoever asks next.
    _opened.ignore();
  }

  final AnalysisServer _owner;
  late final Future<void> _opened;

  /// The files as the server knows them: the look taken before the server
  /// was started, then the look of each reading.
  late DiskLook _seen;

  /// The folders whose packages the look leaves out ([unchangingFolders]).
  late final List<String> _unchanging;

  /// The Dart files of the project the server read for the reading under
  /// way, which are read whole before and after it.
  var _told = const <String>[];

  /// The hash of the text the server analyzes for each Dart file of the
  /// project, by absolute path, where it is known: read the same whole
  /// before and after the reading in which the server read it. What
  /// [canDartFix]'s kept answers are keyed by.
  final _textHashes = <String, String>{};

  void _noteText(String file, String? text) {
    if (text == null) {
      _textHashes.remove(file);
    } else {
      _textHashes[file] = sha256Hex(utf8.encode(text));
    }
  }

  /// Whether no reading has been taken from this session yet.
  var _firstReading = true;

  /// What [canDartFix] answered, by file, the hash of its text, offset and
  /// code: an unchanged file is never asked about again while this session
  /// runs. A new session (a settings change, which can change the fixes)
  /// starts empty.
  final _fixAnswers = <String, bool>{};

  /// The reading before the one that is asked for now: readings are taken
  /// one after the other.
  Future<void> _turn = Future.value();

  /// Whether it has answered a reading.
  var answered = false;

  /// Whether a new server took its place ([AnalysisServer.read]).
  var replaced = false;

  /// Whether its owner stopped it ([AnalysisServer.stop]).
  var stoppedByOwner = false;

  Process? _process;
  final _listening = <StreamSubscription<String>>[];
  ({int guard, int server})? processes;

  /// The requests the server hasn't answered, by ID.
  final _pending = <String, Completer<Object?>>{};
  var _nextId = 0;

  /// The latest diagnostics the server sent for each file, as it sent them.
  final _errors = <String, List<Object?>>{};

  /// What the server said about each plugin it could not load or run.
  final _pluginFailures = <String>[];

  /// The last lines the guard and the server wrote to stderr.
  final _said = <String>[];

  /// Completes when the guard's stderr has closed.
  final _saidAll = Completer<void>();

  /// Whether the guard said it ended in order ([analysisGuardEnded]): its
  /// server has ended too.
  var _guardEndedInOrder = false;

  /// Whether the server said it is analyzing, and whether it has since said
  /// it is done.
  var _analyzing = false;
  var _analyzed = false;
  final _waiting = <Completer<void>>[];

  CodeAnalysisException? _failure;
  var _stopping = false;

  /// Set when the guard's process has exited: completes when its end has
  /// been judged and the session has failed.
  Future<void>? _exiting;

  String get _root => _owner.projectRoot;

  /// Starts the guard, and tells the server which notifications to send
  /// and where the project is.
  Future<void> _open() async {
    final dart = _owner.dartExecutable();
    if (!File(dart).existsSync()) {
      throw CodeAnalysisException('there is no Dart executable at $dart');
    }
    final command = [..._owner.guardCommand, dart];
    // Before the server reads anything: what changes from here on is told.
    _unchanging = unchangingFolders(dart, Platform.environment);
    _seen = await DiskLook.of(_root, unchanging: _unchanging);
    if (_stopping) throw _failure!;
    final Process process;
    try {
      process = await Process.start(
        command.first,
        command.sublist(1),
        environment: _owner.environment.isEmpty ? null : _owner.environment,
      );
    } on ProcessException catch (error) {
      throw CodeAnalysisException(
        'its guard could not be started with ${command.first} '
        '(${error.message})',
      );
    }
    _process = process;
    // A write to a process that has ended fails; its exit says why.
    process.stdin.done.ignore();
    _listening
      ..add(_lines(process.stdout).listen(_onLine, onError: (Object _) {}))
      ..add(
        _lines(
          process.stderr,
        ).listen(_onSaid, onError: (Object _) {}, onDone: _saidAll.complete),
      );
    unawaited(process.exitCode.then((code) => _exiting = _onExit(code)));
    await _request('server.setSubscriptions', {
      'subscriptions': ['STATUS'],
    });
    await _request('analysis.setAnalysisRoots', {
      'included': [_root],
      'excluded': <String>[],
    });
  }

  static Stream<String> _lines(Stream<List<int>> bytes) => bytes
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  /// What the server says about the project as its files are now: the
  /// diagnostics `dart analyze` would show for the files inside the
  /// project, and the plugins that failed. Readings asked for at the same
  /// time are taken one after the other.
  ///
  /// Throws a [_SettingsChanged] when this server can't answer for the
  /// files as they are and a new one must.
  Future<CodeReading> read() {
    final reading = _turn.then((_) => _read());
    _turn = reading.then<void>((_) {}, onError: (Object _) {});
    return reading;
  }

  /// Makes the server take in what changed on disk since the last look, and
  /// returns when it has answered a request sent after that look.
  Future<void> _takeIn() async {
    final now = await DiskLook.of(_root, unchanging: _unchanging);
    if (_failure case final failure?) throw failure;
    if (!now.sameSettingsAs(_seen)) throw const _SettingsChanged();
    // Besides what the look sees change: the files a formatting question
    // found different from the text of the last reading, which the look may
    // never see (a same-size edit whose time was put back). Without them such
    // a file would be named "not checked" by every run until the look saw it
    // change, and a partial run lets no file leave the unverified files.
    final changed = <String>{
      ...now.dartChangedSince(_seen),
      for (final path in _renew)
        if (now.dart.containsKey(path)) path,
    }.toList()..sort();
    _renew.clear();
    _seen = now;
    // The files of the project the server reads for this reading: those
    // told below, and at a session's first reading every file, which it
    // read when it started. Each is read whole here and again after the
    // reading (the look reads only a file's first byte, which a lock
    // further in doesn't stop): a lock taken in between that is still held
    // is found by the second read. The server is not given the text as an
    // overlay: an overlay keeps its own file watcher off that file for good,
    // and the watcher is what sees a change the look can't (a same-size
    // edit whose time is put back), shown by the engine's tests.
    _told = [
      for (final file in _firstReading ? now.dart.keys : changed)
        if (p.isWithin(_root, file)) file,
    ];
    _firstReading = false;
    await now.readWhole(_told);
    await _owner.afterLook?.call();
    if (changed.isEmpty) {
      await _request('server.getVersion');
      return;
    }
    // Taking an overlay away, also where there is none, makes the server
    // read the file from disk again, add it when it is new, and drop it
    // when it is gone. It works for a file outside the project folder that
    // the project imports, which the server never notices by itself.
    await _request('analysis.updateContent', {
      'files': {
        for (final file in changed) file: {'type': 'remove'},
      },
    });
    // The answer to this comes after the server has taken those changes in
    // and has said that it is analyzing; a request that needs no analysis
    // is answered in order too, but only as the server happens to work. It
    // is asked about a file of the project: one of the changed ones, or
    // any when the changes are all outside or all deletions.
    final probe = now.dartFileInProject(changed);
    if (probe == null) {
      await _request('server.getVersion');
      return;
    }
    try {
      await _request('analysis.getErrors', {'file': probe});
    } on CodeAnalysisException {
      // Refused: a file the project's analysis options leave out. The
      // refusal is an answer all the same.
      if (_failure case final failure?) throw failure;
    }
  }

  Future<CodeReading> _read() async {
    await _opened;
    // A guard that has exited is being looked at (did it end in order?):
    // what its server sent is not answered from in the meantime.
    if (_exiting case final exiting?) await exiting;
    if (_failure case final failure?) throw failure;
    await _takeIn();
    if (_failure case final failure?) throw failure;
    if (!_analyzed || _analyzing) {
      final done = Completer<void>();
      _waiting.add(done);
      await done.future;
    }
    // A file locked after the look, before the server read it, was read as
    // empty: still unreadable now, it is reported so. The text the server
    // analyzed is known when both reads gave the same text (the server read
    // the file between them); otherwise it is not, and no fix answer is
    // kept for that file.
    final before = {for (final file in _told) file: _seen.texts[file]};
    await _seen.readWhole(_told);
    for (final file in _told) {
      final text = _seen.texts[file];
      _noteText(file, text == before[file] ? text : null);
    }
    answered = true;
    final found = <CodeDiagnostic>[];
    // The server sends `analysis.errors` for every file it analyzes, with
    // an empty list for a file without a diagnostic.
    final analyzed = <String>[];
    for (final MapEntry(key: file, value: errors) in _errors.entries) {
      if (!p.isWithin(_root, file)) continue;
      final relative = p.split(p.relative(file, from: _root)).join('/');
      analyzed.add(relative);
      for (final error in errors) {
        if (error case {
          'severity': final String severity,
          'type': final String type,
          'location': {'startLine': final int line, 'offset': final int offset},
          'code': final String code,
          'message': final String message,
        }) {
          // A `TODO` comment the project didn't raise above info level:
          // the server sends it for IDEs, and `dart analyze` hides it.
          if (type == 'TODO' && severity == 'INFO') continue;
          found.add(
            CodeDiagnostic(
              file: relative,
              line: line,
              offset: offset,
              code: code,
              message: message,
              level: switch (severity) {
                'ERROR' => DiagnosticLevel.error,
                'WARNING' => DiagnosticLevel.warning,
                _ => DiagnosticLevel.info,
              },
              correction: switch (error) {
                {'correction': final String correction} => correction,
                _ => null,
              },
            ),
          );
        } else {
          throw CodeAnalysisException(
            'it sent a diagnostic for $relative in a form Appstein does not '
            'know',
          );
        }
      }
    }
    found.sort((a, b) {
      final byFile = a.file.compareTo(b.file);
      if (byFile != 0) return byFile;
      final byLine = a.line.compareTo(b.line);
      return byLine != 0 ? byLine : a.code.compareTo(b.code);
    });
    // The files this reading's look could not read, among those the server
    // analyzed: it lists such a file with no diagnostic. One the project's
    // options exclude is not the analysis's, and is left out.
    final covered = analyzed.toSet();
    final unreadable = <String, String>{
      for (final MapEntry(key: file, value: reason) in _seen.unreadable.entries)
        if (p.isWithin(_root, file) &&
            covered.contains(p.split(p.relative(file, from: _root)).join('/')))
          p.split(p.relative(file, from: _root)).join('/'): reason,
    };
    return CodeReading(
      diagnostics: found,
      pluginFailures: List.unmodifiable(_pluginFailures),
      notices: _owner.leftProcesses(),
      analyzedFiles: List.unmodifiable(analyzed..sort()),
      unreadableFiles: Map.unmodifiable(
        Map.fromEntries(
          unreadable.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
        ),
      ),
    );
  }

  /// Whether the server offers a data-driven fix for [diagnostic], which
  /// `dart fix` applies by itself. Asked after a reading, in turn with the
  /// readings, of the files as that reading saw them.
  Future<bool> canDartFix(CodeDiagnostic diagnostic) {
    final asked = _turn.then((_) => _canDartFix(diagnostic));
    _turn = asked.then<void>((_) {}, onError: (Object _) {});
    return asked;
  }

  Future<bool> _canDartFix(CodeDiagnostic diagnostic) async {
    final offset = diagnostic.offset;
    if (offset == null) return false;
    await _opened;
    if (_failure case final failure?) throw failure;
    final file = p.joinAll([_root, ...diagnostic.file.split('/')]);
    // The text the reading was taken from, not the file as it is now: an
    // edit since then must not file an answer under the wrong text.
    final text = _textHashes[file];
    final key = '${diagnostic.file}|$text|$offset|${diagnostic.code}';
    if (text != null) {
      if (_fixAnswers[key] case final known?) return known;
    }
    final found = await _askDartFix(file, offset, diagnostic.code);
    // Kept only when the text the server analyzed is known.
    if (text != null) _fixAnswers[key] = found;
    return found;
  }

  Future<bool> _askDartFix(String file, int offset, String asked) async {
    final Object? answer;
    try {
      answer = await _request('edit.getFixes', {
        'file': file,
        'offset': offset,
      });
    } on CodeAnalysisException {
      // A refusal (a file the options leave out) offers no fix; a server
      // that failed fails the question.
      if (_failure case final failure?) throw failure;
      return false;
    }
    if (answer case {'fixes': final List<Object?> entries}) {
      for (final entry in entries) {
        if (entry case {
          'error': {
            'code': final String code,
            'location': {'offset': final int at},
          },
          'fixes': final List<Object?> fixes,
        } when code == asked && at == offset) {
          for (final fix in fixes) {
            if (fix case {'id': dataDrivenFixId}) return true;
          }
        }
      }
    }
    return false;
  }

  /// What [formatChanges] answered, by file and the hash of its text: an
  /// unchanged file is never asked about again while this session runs.
  final _formatAnswers = <String, bool>{};

  /// How many formatting questions are in flight at once: each re-reads its
  /// file when it is answered, and the look keeps at most this many files
  /// open at once ([openFilesAtOnce]).
  static const _formatInFlight = openFilesAtOnce;

  /// Which of [files] the server's formatter would change, within [within].
  /// Asked after a reading, in turn with the readings, of the files as that
  /// reading saw them.
  Future<FormatAnswers> formatChanges(List<String> files, Duration within) {
    final asked = _turn.then((_) => _formatChanges(files, within));
    _turn = asked.then<void>((_) {}, onError: (Object _) {});
    return asked;
  }

  Future<FormatAnswers> _formatChanges(
    List<String> files,
    Duration within,
  ) async {
    await _opened;
    if (_failure case final failure?) throw failure;
    final spent = Stopwatch()..start();
    final answers = <String, bool>{};
    final refused = <String, String>{};
    final toAsk = <({String file, String path, String? text})>[];
    for (final file in files) {
      final path = p.joinAll([_root, ...file.split('/')]);
      // The text the reading was taken from, not the file as it is now: an
      // edit since then must not file an answer under the wrong text.
      final text = _textHashes[path];
      final known = text == null ? null : _formatAnswers['$file|$text'];
      if (known != null) {
        answers[file] = known;
      } else {
        toAsk.add((file: file, path: path, text: text));
      }
    }
    // A question still unanswered when the time is up is dropped from the
    // result, but its answer is still kept when it comes.
    var open = true;
    try {
      for (var from = 0; from < toAsk.length; from += _formatInFlight) {
        final left = within - spent.elapsed;
        if (left <= Duration.zero) break;
        final window = toAsk.skip(from).take(_formatInFlight);
        final asking = [
          for (final question in window)
            _askFormat(question.path, question.text).then((answer) {
              switch (answer) {
                case (changed: final changed?, why: _):
                  if (question.text case final text?) {
                    _formatAnswers['${question.file}|$text'] = changed;
                  }
                  if (open) answers[question.file] = changed;
                case (changed: _, why: final why?):
                  if (open) refused[question.file] = why;
                case _:
                  break;
              }
            }),
        ];
        try {
          await Future.wait(asking).timeout(left);
        } on TimeoutException {
          break;
        }
      }
    } finally {
      open = false;
    }
    return FormatAnswers(
      changed: Map.unmodifiable(answers),
      refused: Map.unmodifiable(refused),
    );
  }

  /// Whether the server's formatter would change the file at [path]
  /// (`changed`), or why that can't be said for this file (`why`): the
  /// server refused the question, or the file is not [text] (the hash of the
  /// text the reading saw) by the time it was answered. A server that failed
  /// fails the question.
  Future<({bool? changed, String? why})> _askFormat(
    String path,
    String? text,
  ) async {
    Object? answer;
    var syntaxError = false;
    try {
      answer = await _request('edit.format', {
        'file': path,
        'selectionOffset': 0,
        'selectionLength': 0,
      });
    } on CodeAnalysisException catch (error) {
      if (_failure case final failure?) throw failure;
      // Any other refusal is about this file; the others are still asked.
      if (error.refusalCode != 'FORMAT_WITH_ERRORS') {
        return (changed: null, why: error.reason);
      }
      // A file with a syntax error has no format to ask for: "would not
      // change", once the check below has shown it is the reading's text.
      syntaxError = true;
      answer = null;
    }
    // The server answered from its own copy of the file, which its watcher
    // may have updated since the reading: the answer is about the reading's
    // text only if the file still is that text. That holds for a refusal for
    // a syntax error too: it is no more true of the reading's text than any
    // other answer, and a later reading of that text must not be served it.
    if (text != null && await _textHashOnDisk(path) != text) {
      // Not what the look saw, and the look may never see it (a same-size
      // edit whose time was put back): the next reading tells the server
      // about the file again, and takes its text anew.
      _renew.add(path);
      return (
        changed: null,
        why:
            'the file changed, or could not be read again, while its '
            'formatting was being checked',
      );
    }
    if (syntaxError) return (changed: false, why: null);
    if (answer case {'edits': final List<Object?> edits}) {
      return (changed: edits.isNotEmpty, why: null);
    }
    return (
      changed: null,
      why: 'it answered a formatting question in a form Appstein does not know',
    );
  }

  /// The files [formatChanges] found different from the text of the reading,
  /// by absolute path: the next reading tells the server about them again
  /// (`_takeIn`), whether or not the look sees them change.
  final _renew = <String>{};

  /// The hash of the text of the file at [path] as the look reads it (UTF-8,
  /// malformed bytes replaced); null when it can't be read.
  static Future<String?> _textHashOnDisk(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      return sha256Hex(
        utf8.encode(const Utf8Decoder(allowMalformed: true).convert(bytes)),
      );
    } on FileSystemException {
      return null;
    }
  }

  /// The pending fixes, in passes on overlays; asked after a reading, in
  /// turn with the readings ([AnalysisServer.pendingFixes]).
  Future<PendingFixes> pendingFixes(Stopwatch since, Duration within) {
    final asked = _turn.then(
      (_) => _onOverlays(
        (overlays) async {
          final passes = await _fixPasses(overlays, since, within);
          return PendingFixes(
            counts: passes.counts,
            passes: passes.passes,
            unfinished: passes.unfinished,
            notCounted: [for (final file in passes.outside) _named(file)]
              ..sort(),
          );
        },
        since,
        within,
      ),
    );
    _turn = asked.then<void>((_) {}, onError: (Object _) {});
    return asked;
  }

  /// The fixes applied and the files formatted, on disk; asked after a
  /// reading, in turn with the readings
  /// ([AnalysisServer.applyFixesAndFormat]). `serverDone` completes when the
  /// server's part has ended (the overlays are removed), or fails with it;
  /// `written` is what the writes that follow wrote.
  ({Future<void> serverDone, Future<AppliedChanges> written})
  applyFixesAndFormat(
    Future<bool> Function(String file) leaveUnformatted,
    Stopwatch since,
    Duration within,
  ) {
    final serverDone = Completer<void>();
    final asked = _turn.then((_) async {
      final plan = await _onOverlays(
        (overlays) => _planRewrite(overlays, leaveUnformatted, since, within),
        since,
        within,
      );
      serverDone.complete();
      return _writeRewrite(plan);
    });
    asked.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        if (!serverDone.isCompleted) {
          serverDone.completeError(error, stackTrace);
        }
      },
    );
    _turn = asked.then<void>((_) {}, onError: (Object _) {});
    return (serverDone: serverDone.future, written: asked);
  }

  /// Gives this server up because it did not answer [what] within [limit],
  /// or would keep an overlay: the session fails, and its processes are
  /// stopped at once, so an overlay in its memory ends with it. The next
  /// question starts a new server. Returns the failure to throw.
  CodeAnalysisException giveUp(String what, Duration limit) {
    _fail(
      CodeAnalysisException(
        'it did not answer $what within ${secondsText(limit)}',
      ),
    );
    unawaited(stop());
    return _failure!;
  }

  /// Sends [files] to the server as `analysis.updateContent`, about [what],
  /// with [left] to answer and [fixRequestFloor] at least. A
  /// server that does not answer in time is given up ([giveUp]); a refusal
  /// is thrown as it is, with the session still alive.
  Future<void> _changeOverlays(
    String what,
    Map<String, Object?> files,
    Duration left,
  ) async {
    final limit = left < fixRequestFloor ? fixRequestFloor : left;
    try {
      await _request('analysis.updateContent', {'files': files}).timeout(limit);
    } on TimeoutException {
      throw giveUp(what, limit);
    }
  }

  /// Runs [body] with the overlays it gives the server ([_Overlays]), and
  /// removes them all when [body] ends, normally or with an error, unless
  /// [body] removed them itself ([_removeOverlays]). The next reading tells
  /// the server each of those files again (`_renew`): it reads them from
  /// disk, and its notifications about the overlays' text are replaced
  /// before that reading is taken.
  Future<T> _onOverlays<T>(
    Future<T> Function(_Overlays overlays) body,
    Stopwatch since,
    Duration within,
  ) async {
    await _opened;
    if (_failure case final failure?) throw failure;
    final overlays = _Overlays();
    try {
      return await body(overlays);
    } finally {
      await _removeOverlays(overlays, since, within);
    }
  }

  /// Takes every overlay in [overlays] away. A server that refuses, or does
  /// not answer in time, is given up and stopped, so the overlay ends with
  /// it, and that failure is thrown: a server that kept an overlay would
  /// answer for text that is not on disk.
  Future<void> _removeOverlays(
    _Overlays overlays,
    Stopwatch since,
    Duration within,
  ) async {
    if (overlays.sent.isEmpty) return;
    final files = [...overlays.sent];
    overlays.sent.clear();
    _renew.addAll(files);
    // A server that has failed is stopped, with its overlays.
    if (_failure != null) return;
    try {
      await _changeOverlays('the removal of the overlays', {
        for (final file in files) file: {'type': 'remove'},
      }, within - since.elapsed);
    } on CodeAnalysisException catch (error) {
      if (_failure case final failure?) throw failure;
      _fail(
        CodeAnalysisException(
          'it kept the overlays of the pending fixes (${error.reason})',
        ),
      );
      unawaited(stop());
      throw _failure!;
    }
  }

  /// Whether [path] is a file of the project once links are followed: a
  /// file reached through a link to outside the project is never overlaid or
  /// written, so `--apply` can't write through it.
  Future<bool> _inProject(String path) async {
    if (!p.isWithin(_root, path)) return false;
    try {
      final real = await File(path).resolveSymbolicLinks();
      final root = await Directory(_root).resolveSymbolicLinks();
      return p.isWithin(root, real);
    } on FileSystemException {
      return false;
    }
  }

  /// Why a file reached through a link was left out.
  static const _outsideWhy =
      'it is outside the project once links are followed';

  /// Why a file whose text could not be relied on was left out.
  static const _changedWhy =
      'its text on disk is not the one the reading saw, or the reading could '
      'not tell which text it saw';

  /// The text each file had on disk when a pass first needed it, by
  /// absolute path, and whether it is valid UTF-8; null when it could not be
  /// read, is no longer the text the last reading saw, or the reading could
  /// not tell which text it saw (the file changed between the reading's two
  /// whole reads, so no hash was kept): the server's copy may then be
  /// another text, and its edits must not be applied to this one.
  Future<({String text, bool utf8})?> _baseText(String path) async {
    final List<int> bytes;
    try {
      bytes = await File(path).readAsBytes();
    } on FileSystemException {
      return null;
    }
    final text = const Utf8Decoder(allowMalformed: true).convert(bytes);
    final known = _textHashes[path];
    if (known == null || sha256Hex(utf8.encode(text)) != known) {
      // The next reading tells the server the file again.
      _renew.add(path);
      return null;
    }
    var valid = true;
    try {
      utf8.decode(bytes);
    } on FormatException {
      valid = false;
    }
    return (text: text, utf8: valid);
  }

  /// The passes of [pendingFixes]: [overlays] gets the fixed text of each
  /// file a pass changed, and the server analyzes it in place of the file.
  Future<_FixPasses> _fixPasses(
    _Overlays overlays,
    Stopwatch since,
    Duration within,
  ) async {
    final found = _FixPasses();
    while (true) {
      // As `dart fix` does: the passes so far are all there is.
      if (found.passes >= AnalysisServer.mostFixPasses) return found;
      final left = within - since.elapsed;
      if (left <= Duration.zero) {
        return found
          ..unfinished =
              'the analysis server did not finish them within '
              '${secondsText(within)}';
      }
      final Object? answer;
      try {
        answer = await _request('edit.bulkFixes', {
          'included': [_root],
          'inTestMode': false,
          'updatePubspec': false,
        }).timeout(left);
      } on TimeoutException {
        continue;
      } on CodeAnalysisException catch (error) {
        if (_failure case final failure?) throw failure;
        return found
          ..unfinished = 'the analysis server refused a pass (${error.reason})';
      }
      if (answer case {
        'edits': final List<Object?> edits,
        'details': final List<Object?> details,
      }) {
        if (edits.isEmpty) return found;
        final changed = <String, String>{};
        final outside = <String>{};
        for (final fileEdit in edits) {
          if (fileEdit case {
            'file': final String file,
            'edits': final List<Object?> sourceEdits,
          }) {
            if (!await _inProject(file)) {
              outside.add(file);
              found.outside.add(file);
              continue;
            }
            var text = changed[file] ?? overlays.texts[file];
            if (text == null) {
              final base = await _baseText(file);
              if (base == null) {
                found.unknownText.add(file);
                return found
                  ..unfinished =
                      'the text of ${_named(file)} on disk is not the one the '
                      'reading saw, or the reading could not tell which text '
                      'it saw';
              }
              found.bases[file] = base.text;
              if (!base.utf8) found.notUtf8.add(file);
              text = base.text;
            }
            final applied = _applyEdits(text, sourceEdits);
            if (applied == null) return found..unfinished = _unknownForm;
            changed[file] = applied;
          } else {
            return found..unfinished = _unknownForm;
          }
        }
        for (final detail in details) {
          if (detail case {
            'path': final String path,
            'fixes': final List<Object?> fixes,
          } when p.isWithin(_root, path) && !outside.contains(path)) {
            final byCode = found.counts.putIfAbsent(_named(path), () => {});
            for (final fix in fixes) {
              if (fix case {
                'code': final String code,
                'occurrences': final int count,
              }) {
                byCode[code] = (byCode[code] ?? 0) + count;
              }
            }
          }
        }
        // Only files outside the project had fixes: nothing more to find.
        if (changed.isEmpty) return found;
        // Removed afterwards whether or not the server took them.
        overlays.sent.addAll(changed.keys);
        try {
          await _changeOverlays('an overlay of the fixes', {
            for (final MapEntry(key: file, value: text) in changed.entries)
              file: {'type': 'add', 'content': text},
          }, within - since.elapsed);
        } on CodeAnalysisException catch (error) {
          if (_failure case final failure?) throw failure;
          return found
            ..unfinished =
                'the analysis server refused an overlay (${error.reason})';
        }
        overlays.texts.addAll(changed);
        found.passes++;
      } else {
        return found..unfinished = _unknownForm;
      }
    }
  }

  static const _unknownForm =
      'the analysis server answered in a form Appstein does not know';

  /// [path] from the project root with `/`, or as it is when it is outside.
  String _named(String path) => p.isWithin(_root, path)
      ? p.split(p.relative(path, from: _root)).join('/')
      : path;

  /// [text] with the server's [edits] applied in the order they are listed
  /// (a file's edits come last offset first); null when an edit is not in a
  /// form Appstein knows or falls outside the text.
  static String? _applyEdits(String text, List<Object?> edits) {
    for (final edit in edits) {
      if (edit case {
        'offset': final int offset,
        'length': final int length,
        'replacement': final String replacement,
      } when offset >= 0 && length >= 0 && offset + length <= text.length) {
        text = text.replaceRange(offset, offset + length, replacement);
      } else {
        return null;
      }
    }
    return text;
  }

  /// Set when the caller gave up on the server's part of a rewrite: the
  /// writes that would follow it write nothing.
  var _rewriteAbandoned = false;

  /// [applyFixesAndFormat]'s part that needs the server: the passes, then
  /// the formatter, then the removal of the overlays.
  Future<_RewritePlan> _planRewrite(
    _Overlays overlays,
    Future<bool> Function(String file) leaveUnformatted,
    Stopwatch since,
    Duration within,
  ) async {
    // The Dart files of the reading, before a pass sends notifications about
    // overlays.
    final dartFiles = [
      for (final file in _errors.keys)
        if (p.isWithin(_root, file) &&
            file.endsWith('.dart') &&
            !_seen.unreadable.containsKey(file))
          file,
    ]..sort();
    final leftAlone = <String, String>{};
    final passes = await _fixPasses(overlays, since, within);
    for (final file in passes.outside) {
      leftAlone[_named(file)] = _outsideWhy;
    }
    for (final file in passes.unknownText) {
      leftAlone[_named(file)] = _changedWhy;
    }
    final finals = {...overlays.texts};
    final bases = {...passes.bases};
    final notUtf8 = {...passes.notUtf8};
    // Formatted 32 at a time, each from its fixed text when it has one.
    final toFormat = <String>[];
    for (final file in dartFiles) {
      if (await leaveUnformatted(_named(file))) continue;
      if (!await _inProject(file)) {
        leftAlone[_named(file)] = _outsideWhy;
        continue;
      }
      toFormat.add(file);
    }
    for (var from = 0; from < toFormat.length; from += _formatInFlight) {
      if (within - since.elapsed <= Duration.zero) break;
      await Future.wait([
        for (final file in toFormat.skip(from).take(_formatInFlight))
          () async {
            var text = finals[file];
            if (text == null) {
              final base = await _baseText(file);
              if (base == null) {
                leftAlone[_named(file)] = _changedWhy;
                return;
              }
              bases[file] = base.text;
              if (!base.utf8) notUtf8.add(file);
              text = base.text;
            }
            final left = within - since.elapsed;
            if (left <= Duration.zero) return;
            final Object? answer;
            try {
              answer = await _request('edit.format', {
                'file': file,
                'selectionOffset': 0,
                'selectionLength': 0,
              }).timeout(left);
            } on TimeoutException {
              return;
            } on CodeAnalysisException {
              if (_failure case final failure?) throw failure;
              // A file that does not parse, or that the formatter refused:
              // left as the fixes made it.
              return;
            }
            if (answer case {'edits': final List<Object?> edits}) {
              // The formatter's edits are listed for the text it has; applied
              // last offset first, whatever order they come in.
              final sorted = [...edits]
                ..sort(
                  (a, b) => switch ((a, b)) {
                    ({'offset': final int x}, {'offset': final int y}) =>
                      y.compareTo(x),
                    _ => 0,
                  },
                );
              if (_applyEdits(text, sorted) case final formatted?) {
                finals[file] = formatted;
              }
            }
          }(),
      ]);
    }
    // The overlays go before anything is written: a server that would keep
    // one fails the rewrite here, while nothing has been written yet.
    await _removeOverlays(overlays, since, within);
    return _RewritePlan(
      finals: finals,
      bases: bases,
      notUtf8: notUtf8,
      leftAlone: leftAlone,
    );
  }

  /// [applyFixesAndFormat]'s writes, which need no server and have no time
  /// limit: once they begin, what they wrote is returned. Nothing is written
  /// when the caller gave up on the server's part.
  Future<AppliedChanges> _writeRewrite(_RewritePlan plan) async {
    if (_rewriteAbandoned) return const AppliedChanges();
    final _RewritePlan(:finals, :bases, :notUtf8, :leftAlone) = plan;
    await _removeStaleBesideFiles(finals.keys);
    final written = <String>[];
    // A link in the project to a file in the project: both names are in
    // [finals], one file on disk. It is written once, under the first name;
    // the other name is listed as written too, never as "changed meanwhile"
    // because the first write changed it.
    final writtenFiles = <String>{};
    for (final MapEntry(key: file, value: text) in finals.entries) {
      final base = bases[file];
      if (base == null || text == base) continue;
      final real = await _resolved(file);
      if (writtenFiles.contains(real)) {
        // Told to the server again under this name too.
        _renew.add(file);
        written.add(_named(file));
        continue;
      }
      if (notUtf8.contains(file)) {
        leftAlone[_named(file)] =
            'it is not valid UTF-8, so it could not be written back unchanged';
        continue;
      }
      // Written only when the disk still has the text the fixes and the
      // formatter worked on: an edit made meanwhile is never overwritten.
      final now = await _baseText(file);
      if (now == null || now.text != base) {
        leftAlone[_named(file)] = _changedWhy;
        continue;
      }
      try {
        await _owner.replaceText(file, text);
      } on FileSystemException catch (error) {
        leftAlone[_named(file)] = 'it could not be written (${error.message})';
        continue;
      }
      _renew.add(file);
      writtenFiles.add(real);
      written.add(_named(file));
    }
    return AppliedChanges(
      written: written..sort(),
      leftAlone: Map.fromEntries(
        leftAlone.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
      ),
    );
  }

  /// [file] with its links followed; [file] itself when it can't be
  /// resolved.
  Future<String> _resolved(String file) async {
    try {
      return p.normalize(await File(file).resolveSymbolicLinks());
    } on FileSystemException {
      return p.normalize(file);
    }
  }

  /// Removes the new files an earlier rewrite left beside the originals in
  /// the folders of [files] ([besideFilePattern]): a process killed between
  /// writing one and putting it in place leaves it, a full copy of a source
  /// file that `git add -A` would commit. One is removed only when the
  /// process that made it is not running ([AnalysisServer.processLookup]),
  /// or is this one (whose writes are one at a time, and none is under way):
  /// another `appstein` may be writing its own.
  Future<void> _removeStaleBesideFiles(Iterable<String> files) async {
    final folders = <String>{};
    for (final file in files) {
      try {
        folders.add(p.dirname(await File(file).resolveSymbolicLinks()));
      } on FileSystemException {
        folders.add(p.dirname(file));
      }
    }
    for (final folder in folders) {
      final List<FileSystemEntity> entries;
      try {
        entries = await Directory(folder).list(followLinks: false).toList();
      } on FileSystemException {
        continue;
      }
      for (final entry in entries) {
        if (entry is! File) continue;
        final made = besideFilePattern.firstMatch(p.basename(entry.path));
        final maker = made == null ? null : int.tryParse(made[1]!);
        if (maker == null) continue;
        if (maker != pid && _owner.processLookup(maker) is! ProcessGone) {
          continue;
        }
        try {
          await entry.delete();
        } on FileSystemException {
          // Left for the next rewrite.
        }
      }
    }
  }

  /// Sends a request, and completes with the server's `result` when it
  /// answers.
  Future<Object?> _request(String method, [Map<String, Object?>? params]) {
    if (_failure case final failure?) throw failure;
    final id = '${++_nextId}';
    final answered = _pending[id] = Completer<Object?>();
    _send({'id': id, 'method': method, 'params': ?params});
    return answered.future;
  }

  void _send(Map<String, Object?> message) {
    try {
      // Bytes, so a path keeps its non-ASCII characters on every system.
      _process?.stdin.add(utf8.encode('${jsonEncode(message)}\n'));
    } on Object {
      // The process has ended; `_onExit` reports it.
    }
  }

  void _onLine(String line) {
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (message is! Map<String, Object?>) return;
    final params = message['params'];
    switch (message['event']) {
      case null:
        final answered = _pending.remove('${message['id']}');
        if (answered == null) return;
        if (message['error'] case final Map<String, Object?> error) {
          answered.completeError(
            CodeAnalysisException(
              'it refused a request (${_plain('${error['message']}')})',
              refusalCode: switch (error['code']) {
                final String code => code,
                _ => null,
              },
            ),
          );
        } else {
          answered.complete(message['result']);
        }
      case 'server.status' when params is Map<String, Object?>:
        final analysis = params['analysis'];
        if (analysis is! Map<String, Object?>) return;
        if (analysis['isAnalyzing'] == true) {
          _analyzing = true;
        } else if (_analyzing) {
          _analyzing = false;
          _analyzed = true;
          for (final waiter in _waiting) {
            waiter.complete();
          }
          _waiting.clear();
        }
      case 'analysis.errors' when params is Map<String, Object?>:
        if ((params['file'], params['errors']) case (
          final String file,
          final List<Object?> errors,
        )) {
          _errors[file] = errors;
        }
      case 'analysis.flushResults' when params is Map<String, Object?>:
        if (params['files'] case final List<Object?> files) {
          files.forEach(_errors.remove);
        }
      case 'server.pluginError' when params is Map<String, Object?>:
        // The message ends with the server's own stack trace.
        final said = _plain('${params['message']}'.split('\n#0').first);
        if (!_pluginFailures.contains(said)) _pluginFailures.add(said);
      case 'server.error' when params is Map<String, Object?>:
        final said = _plain('${params['message']}');
        if (params['isFatal'] == true) {
          _fail(CodeAnalysisException('it reported a fatal error ($said)'));
        } else {
          _onSaid(said);
        }
    }
  }

  void _onSaid(String line) {
    if (processes == null && line.startsWith(analysisGuardSign)) {
      final ids = line
          .substring(analysisGuardSign.length)
          .split(' ')
          .map(int.tryParse)
          .toList();
      if (ids case [final guard?, final server?]) {
        processes = (guard: guard, server: server);
        // At once, while both run: what a later kill by ID is checked
        // against.
        _guardIdentity = _identityOf(guard);
        _serverIdentity = _identityOf(server);
        return;
      }
    }
    // The guard starts this line on a line of its own, but a stream may
    // still deliver it after text that had no line end: what stands before
    // it is the server's last words.
    if (line.trimRight().endsWith(analysisGuardEnded)) {
      _guardEndedInOrder = true;
      line = line.trimRight();
      line = line.substring(0, line.length - analysisGuardEnded.length);
    }
    if (line.trim().isEmpty) return;
    _said.add(line.trim());
    if (_said.length > 5) _said.removeAt(0);
  }

  Future<void> _onExit(int code) async {
    await _endOrphan();
    if (_stopping) return;
    final said = _said.isEmpty ? '' : ': ${_plain(_said.join(' '))}';
    _fail(
      CodeAnalysisException(
        _guardEndedInOrder
            ? 'it ended by itself with exit code $code$said'
            : 'its guard ended without it, with exit code $code$said',
      ),
    );
  }

  /// The guard and the server as they were when the guard named them; null
  /// when that could not be told.
  ProcessIdentity? _guardIdentity;
  ProcessIdentity? _serverIdentity;

  ProcessIdentity? _identityOf(int id) => switch (_owner.processLookup(id)) {
    ProcessRunning(:final identity) => identity,
    _ => null,
  };

  /// Ends the process with the ID [id] that this session started, when it
  /// can be shown to be that process still: the process that has the ID now
  /// is the one [recorded] when the guard named it, by its start and its
  /// program. An ID alone is no proof: the system gives an ended process's
  /// ID to a new one.
  ///
  /// - Nothing has the ID: it has ended, nothing to do.
  /// - Another process has it: this session's has ended, nothing to do.
  /// - It was never recorded and something has the ID, or who has the ID
  ///   can't be told: nothing is ended, and the owner notes it as left
  ///   ([AnalysisServer.leftProcesses]), once.
  void _endById(int id, ProcessIdentity? recorded) {
    switch (_owner.processLookup(id)) {
      case ProcessGone():
        return;
      case ProcessUnknown():
        _owner._leave(id, recorded, shown: false);
      case ProcessRunning(identity: final now) when recorded == null:
        _owner._leave(id, now, shown: false);
      case ProcessRunning(identity: final now) when now == recorded:
        Process.killPid(id, ProcessSignal.sigkill);
        // Looked at again by the next question: a kill may not take.
        _owner._leave(id, now, shown: true);
      case ProcessRunning():
        // Another process has the ID now.
        return;
    }
  }

  /// After the guard has exited: ends the server when the guard did not
  /// end in order, which means the guard was killed and left its server
  /// running. The process ID is the one the guard named for the server it
  /// started, and the process is ended only when it is shown to be that
  /// server still ([_endById]). A guard that ended in order has a server
  /// that has ended, and then nothing is looked at.
  late final Future<void> _orphanEnded = () async {
    // The guard's last words may arrive after its exit.
    await _saidAll.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    if (_guardEndedInOrder) return;
    if (processes case (guard: _, :final server)) {
      _endById(server, _serverIdentity);
    }
  }();

  Future<void> _endOrphan() => _orphanEnded;

  /// [text] as part of a reason: one line, without a closing full stop.
  static String _plain(String text) => text
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(RegExp(r'\.$'), '');

  void _fail(CodeAnalysisException failure) {
    _failure ??= failure;
    for (final waiter in [..._pending.values, ..._waiting]) {
      if (!waiter.isCompleted) waiter.completeError(_failure!);
    }
    _pending.clear();
    _waiting.clear();
  }

  /// Ends the server and the guard, and returns once both have ended. The
  /// guard deletes what the kill left half-written in the server's cache
  /// before it ends ([runAnalysisGuard]), so it is done when this returns.
  ///
  /// - **The server is killed.** Closing the guard's input makes the guard
  ///   kill the server at once, and end once the server has ended. The
  ///   server is not asked to stop first: in 60 of 60 stops measured in
  ///   review, it had not answered
  ///   `server.shutdown` within 250 ms, and it took about 4 s to end by
  ///   itself, so the request only made every stop slower. When both are
  ///   still there [analysisStopWait] later, they are killed: the process this session
  ///   holds directly, and the guard and the server by their IDs when each
  ///   is shown to be the one it started ([_endById]).
  /// - **What a kill leaves.** The server writes each cache entry to a file
  ///   named after the entry, `-temp-` and its own process ID, then renames
  ///   it into place. A kill in between leaves that file in the cache the
  ///   whole machine shares: 3 to 16 a run on Windows (ticket 11 of slice
  ///   1d.2), 61,696 of them on the development machine since the slice
  ///   began. The kill also ends the server before it has saved all it
  ///   worked out, so a later server starts less warm; that is known and
  ///   kept (the owner, 2026-10-15).
  /// - **Who cleans up.** The guard does, not this process, which may be the
  ///   one that was killed: once the server has ended and nothing runs
  ///   under its ID any more, the guard deletes the files of that ID from
  ///   the server's cache folder ([runAnalysisGuard],
  ///   [removeHalfWrittenFiles]), and only then ends. So the wait for the
  ///   guard's end above is the wait for the clean-up, and a terminal run
  ///   that returns after its stop has left none. Listing a cache folder
  ///   that holds many files takes a while (0.2 to 1 s for 64,000). The
  ///   guard ends within [analysisGuardEndBudget], which is below
  ///   [analysisStopWait], so the kill after that wait never catches a
  ///   guard at work. When the guard is killed before it has cleaned up,
  ///   or its server is not shown to be gone, the files stay.
  ///
  /// Every end of a server comes here: a terminal run's, `appstein mcp`'s
  /// idle stop and close, a server replaced after a settings change, and
  /// one found dead.
  Future<void> stop() async {
    _stopping = true;
    _fail(const CodeAnalysisException('it was stopped'));
    try {
      await _opened;
    } on Object {
      // It failed to start, or was stopped while starting.
    }
    final process = _process;
    if (process == null) return;
    Future<bool> ended() => process.exitCode
        .then((_) => true)
        .timeout(analysisStopWait, onTimeout: () => false);

    process.stdin.close().ignore();
    {
      if (!await ended()) {
        process.kill(ProcessSignal.sigkill);
        if (processes case (:final guard, :final server)) {
          _endById(guard, _guardIdentity);
          _endById(server, _serverIdentity);
        }
        await ended();
      }
    }
    process.stdin.close().ignore();
    await _endOrphan();
    for (final subscription in _listening) {
      await subscription.cancel();
    }
  }
}
