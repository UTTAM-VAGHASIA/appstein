import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/host_environment.dart';

/// The environment variable that moves a Dart analysis server's disk cache
/// (its "state location") to another folder. The server reads it on every
/// system, and the guard passes it on, since the server inherits the guard's
/// environment.
const analysisCacheVariable = 'ANALYZER_STATE_LOCATION_OVERRIDE';

/// The folder of the cache under which an analysis server writes its
/// analysis results, and the files it leaves half-written there when it is
/// killed.
const analysisDriverFolder = '.analysis-driver';

/// The cache folder (the "state location") of a Dart analysis server whose
/// environment is [environment], by the SDK's own rule
/// (`_getStandardStateLocation` in the analyzer's `physical_file_system.dart`,
/// the code of the pinned SDK, Dart 3.13.4):
/// - **[analysisCacheVariable], when it is set**, also when it is empty.
///   Here an empty value gives null: the server would then write under the
///   folder it runs in, which Appstein does not guess at;
/// - otherwise `.dartServer` in `LOCALAPPDATA` on Windows and in `HOME`
///   elsewhere, when that folder exists;
/// - otherwise null: the server keeps no cache on disk.
///
/// A relative value is taken from the current folder, which the guard and
/// the server inherit. On Windows a variable's name is matched in any case,
/// as Windows matches it.
String? analysisCacheFolder(HostEnvironment environment) {
  final windows = environment.os == HostOs.windows;
  String? read(String name) {
    final exact = environment.variables[name];
    if (exact != null || !windows) return exact;
    final wanted = name.toLowerCase();
    for (final MapEntry(:key, :value) in environment.variables.entries) {
      if (key.toLowerCase() == wanted) return value;
    }
    return null;
  }

  final override = read(analysisCacheVariable);
  if (override != null) {
    return override.isEmpty ? null : p.normalize(p.absolute(override));
  }
  final home = read(windows ? 'LOCALAPPDATA' : 'HOME');
  if (home == null || home.isEmpty || !Directory(home).existsSync()) {
    return null;
  }
  return p.join(home, '.dartServer');
}

/// What an analysis server Appstein starts on the machine [host] is given
/// besides Appstein's own environment (`AnalysisServer.environment`):
/// [analysisCacheVariable] as [host] sets it, when it does. On the real
/// machine that is what the server inherits anyway; a test's machine names
/// a cache folder of its own, so its servers leave nothing in the cache the
/// machine shares.
Map<String, String> analysisServerEnvironment(HostEnvironment host) => {
  analysisCacheVariable: ?host.variable(analysisCacheVariable),
};

/// The clean-ups of stopped servers that have not ended yet, in this
/// isolate ([trackCleanUp]).
final _cleanUps = <Future<void>>{};

/// Notes [cleanUp], the deletion of a stopped server's half-written files,
/// which runs after the stop returned, so [analysisCleanUpsDone] can wait
/// for it. It never fails.
void trackCleanUp(Future<void> cleanUp) {
  final tracked = cleanUp.catchError((Object _) {});
  _cleanUps.add(tracked);
  unawaited(tracked.whenComplete(() => _cleanUps.remove(tracked)));
}

/// Completes once every clean-up a stop started in this isolate has ended,
/// those started meanwhile included. A stop returns before its clean-up
/// has ended, so a terminal run prints its result first; `runAppstein`
/// waits for this before it returns, and so before the process ends.
Future<void> analysisCleanUpsDone() async {
  while (_cleanUps.isNotEmpty) {
    await Future.wait([..._cleanUps]);
  }
}

/// The name of a half-written cache file: the name of the entry, `-temp-`
/// and the ID of the process that was writing it (the analyzer's
/// `FileByteStore`, which writes each entry to such a file beside the
/// shards and then renames it into its shard).
final _halfWritten = RegExp(r'^.+-temp-(\d+)$');

/// Deletes the files that the analysis server with the process ID
/// [serverId] left half-written in the cache folder [cacheFolder], and
/// returns how many it deleted.
///
/// **Only** the files directly in its [analysisDriverFolder] whose name ends
/// in `-temp-<serverId>` exactly are deleted: no other process's, no complete
/// entry, nothing in a folder below it. A link is never followed and never
/// deleted, also one with such a name, and a [analysisDriverFolder] that is
/// itself a link is left alone.
///
/// **The caller makes sure the server has ended**: a running server is still
/// writing such files. The cache is shared by every analysis server of the
/// user (the IDE's, `dart analyze`'s, other Appsteins'), which is why the
/// process ID must match.
///
/// It never throws: a missing folder, a file already gone or one that can't
/// be deleted (another process holds it) is skipped.
Future<int> removeHalfWrittenFiles(String cacheFolder, int serverId) async {
  final folder = p.join(cacheFolder, analysisDriverFolder);
  var removed = 0;
  try {
    final type = await FileSystemEntity.type(folder, followLinks: false);
    if (type != FileSystemEntityType.directory) return 0;
    final wanted = '$serverId';
    await for (final entry in Directory(folder).list(followLinks: false)) {
      if (entry is! File) continue;
      final match = _halfWritten.firstMatch(p.basename(entry.path));
      if (match == null || match[1] != wanted) continue;
      try {
        await entry.delete();
        removed++;
      } on FileSystemException {
        // Gone already, or held: left as it is.
      }
    }
  } on FileSystemException {
    // The folder went away, or can't be read: nothing more to do.
  }
  return removed;
}
