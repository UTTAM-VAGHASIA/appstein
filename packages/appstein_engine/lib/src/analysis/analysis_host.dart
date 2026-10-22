import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../host/host_environment.dart';
import 'analysis_host_lock.dart';
import 'analysis_server.dart';
import 'code_analysis.dart';
import 'kept_analysis_server.dart';

/// The environment variable that moves the folder of the analysis hosts'
/// address files ([analysisHostFolder]), as `analysisCacheVariable` moves the
/// analysis server's cache. Tests set it, so their hosts never meet the
/// hosts of the developer's own sessions.
const analysisHostFolderVariable = 'APPSTEIN_ANALYSIS_HOST_FOLDER';

/// How long an analysis host may go without a question before it ends
/// itself, with its analysis server (decision record 0002). The time is
/// counted from the end of the last question, and never runs while one is
/// answered, so a question is never cut off. A connection that asks nothing
/// for this long is closed too, so a client that stays connected doesn't
/// keep the host. A test shortens it.
const analysisHostIdleStop = analysisIdleStop;

/// The folder of the analysis hosts' address files on the machine
/// [environment], outside every project and readable by its user only:
/// - [analysisHostFolderVariable], when it is set and not empty (tests, the
///   measurement tool);
/// - on Windows, `appstein` in `%LOCALAPPDATA%`, the user's own;
/// - on Linux, a folder chosen from facts that every process of the user
///   shares, not from variables (`HOME`, `XDG_RUNTIME_DIR` and
///   `XDG_CACHE_HOME` are not read: the processes of one user, a shell and an
///   agent's, differ in them, and would start a host each):
///   1. `appstein` in `/run/user/<uid>`, when that folder is there and the
///      user's own, and the group and the world can't write to it (the
///      system makes it for each login of the user, and removes it when the
///      last one ends: a host that was in it then moves, see
///      [runAnalysisHost]);
///   2. else `appstein/hosts/<machine folder name>` in the `.cache` folder of
///      the user's home as the user database has it
///      (`HostEnvironment.userHome`), **when the folders it is made in can be
///      trusted** ([cacheFoldersProblem], the look this function makes at the
///      disk);
///   3. else `appstein-<uid>` in `/tmp` (the literal folder, not `$TMPDIR`, so
///      every environment agrees). It is shared by every user, so another user
///      can make `appstein-<uid>` first. Nothing leaks then: a client refuses
///      it at once when other users can write to it, and otherwise the host
///      it starts can't give it mode 700, writes nothing there, and the client
///      says why. The client is still answered, by an analysis server of its
///      own and with a notice that says why no host could be used
///      ([analysisHostCodeAnalysis]). The folder is used where there is no
///      usable home (a service whose home is `/` or `/nonexistent`, a home or
///      cache folder that others can write to or that belongs to another
///      user, as `sudo` that kept the user's `HOME` leaves one, a user the
///      database doesn't know). Where the user ID can't be read,
///      `appstein-<user name>`;
/// - on macOS, `appstein` in `$XDG_RUNTIME_DIR` when it is set, else
///   `appstein-<uid>` in the system's temporary folder (`$TMPDIR`, the user's
///   own).
///
/// The machine folder name keeps two machines that share a home over the
/// network from reading each other's address files: `<clean name>-<12 hex>`.
/// The clean name is only for a person to read: lower case, each run of
/// characters other than letters, digits, `.`, `_` and `-`, and each run of
/// two or more dots, becomes one `_`, a first dot becomes `_` (so never `..` or
/// a hidden folder), an empty name is `unknown`, at most 60 characters. The 12
/// hex characters are the start of the SHA-256 of the machine ID
/// (`HostEnvironment.machineId`) when there is one, else of the raw name. So a
/// machine that is renamed keeps its hex, two machines of the same name that
/// share a home (different machine IDs) get folders of their own, and, with no
/// machine ID, so do names that clean up to the same text (`a b` and `a_b`),
/// names that differ only in letter case (a home that ignores it), and names
/// that are the same up to the cut.
///
/// [trustedCache] is the look at the disk: given the folders from the base
/// down (see [cacheFoldersProblem]), it says what is wrong with them, or
/// null; with `mustExist` the first must be there. Tests replace it. The look
/// is one process, `stat`, for the folders that exist, and where
/// `/run/user/<uid>` is there nothing else is started. The same environment on
/// the same disk gives the same folder to every client, the host and the
/// measurement tool (and the client passes its folder to the host it starts,
/// `--address-folder`, so they never disagree). The host makes the folders
/// that are missing, each one appearing with mode 700 only ([_userFolder]), so
/// a `umask` of 002 can't leave one at 775, which would send the next client
/// to `/tmp`. A client refuses a folder that is a link, or that other users
/// can write to, and checks for mode 700 and the user's own whenever there is
/// an address to read ([untrustedAddress]); only the folder itself is checked
/// there, so a link above it is fine.
String analysisHostFolder(
  HostEnvironment environment, {
  CacheFolderCheck? trustedCache,
}) => chooseAnalysisHostFolder(environment, trustedCache: trustedCache).folder;

/// What the check of the folders on the way says: what is wrong with the
/// [chain] of folders from the base down, or null when they can be trusted;
/// with [mustExist] the base must be there.
typedef CacheFolderCheck =
    String? Function(List<String> chain, {bool mustExist});

/// The folder [analysisHostFolder] chooses, and, when it is `/tmp` only
/// because the other folders could not be used on Linux, why: `cacheNote` is
/// a sentence a client adds to the error or the notice it gives when that
/// folder is refused, so the user knows what to fix; null when there is
/// nothing to say.
typedef AnalysisHostFolderChoice = ({String folder, String? cacheNote});

/// Chooses the folder as [analysisHostFolder] says, and says why the user's
/// own folders were not used when they were not.
AnalysisHostFolderChoice chooseAnalysisHostFolder(
  HostEnvironment environment, {
  CacheFolderCheck? trustedCache,
}) {
  AnalysisHostFolderChoice chosen(String folder, [String? note]) =>
      (folder: folder, cacheNote: note);
  if (environment.variable(analysisHostFolderVariable) case final folder?) {
    return chosen(p.normalize(p.absolute(folder)));
  }
  switch (environment.os) {
    case HostOs.windows:
      return chosen(
        p.join(
          environment.variable('LOCALAPPDATA') ?? Directory.systemTemp.path,
          'appstein',
        ),
      );
    case HostOs.macos:
      if (environment.variable('XDG_RUNTIME_DIR') case final runtime?) {
        return chosen(p.join(runtime, 'appstein'));
      }
      return chosen(
        p.join(Directory.systemTemp.path, 'appstein-${_userName(environment)}'),
      );
    case HostOs.linux:
      break;
  }
  final user = environment.userId;
  final privateGroup = environment.privateGroupId;
  final check =
      trustedCache ??
      (List<String> chain, {bool mustExist = false}) => cacheFoldersProblem(
        chain,
        userId: user,
        privateGroup: privateGroup,
        mustExist: mustExist,
      );
  String? note;
  if (user != null) {
    final run = p.join(environment.runUserRoot, '$user');
    if (check([run], mustExist: true) == null) {
      return chosen(p.join(run, 'appstein'));
    }
  }
  if (user == null) {
    note = "the user's ID can't be read, so no folder of the user's is known";
  } else {
    String? home = environment.userHomeWithoutProcess;
    // A user that only `getent` knows: one process asks for the home and
    // looks at the folders on the way together.
    List<CacheFolderFacts?>? together;
    if (home == null &&
        trustedCache == null &&
        environment.userHomeNeedsProcess) {
      final both = homeAndFoldersOfUser(user);
      home = both?.home;
      together = both?.facts;
    } else {
      home ??= environment.userHome;
    }
    if (home == null) {
      note = 'no home folder is known for the user';
    } else {
      final hosts = p.join(home, '.cache', 'appstein', 'hosts');
      final folder = p.join(hosts, _machineFolderName(environment));
      final chain = [home, p.join(home, '.cache'), p.dirname(hosts), hosts];
      final problem = together == null
          ? check(chain)
          : cacheFoldersProblem(
              chain,
              userId: user,
              privateGroup: privateGroup,
              look: (paths) => paths.length == chain.length
                  ? together!
                  : _lookAtFolders(paths),
            );
      if (problem == null) return chosen(folder);
      note = 'the folder $folder was not used: $problem';
    }
  }
  return chosen(p.join('/tmp', 'appstein-${_userName(environment)}'), note);
}

/// A place where the host of this machine's user may be found other than the
/// folder the choice gives: the `folder` and what is wrong with it (`problem`,
/// null when it can be used; it may start the one `stat` of the look, so it
/// is asked only for a folder that has an address file).
typedef AnalysisHostPlace = ({String folder, String? Function() problem});

/// The other places the rule could have given [environment]'s Linux user,
/// besides [chosen]: `/run/user/<uid>/appstein`; the machine's folder in the
/// cache folder, and the other folders in its `hosts` that end in the same 12
/// hex characters (this machine under its old name); and `/tmp/appstein-<uid>`.
/// A client that finds no host in its own folder looks for an address file in
/// each before it starts a host (a machine renamed, or `/run/user/<uid>`
/// appearing after a host was started elsewhere: the host moves in its next
/// round, and the client must not start a second one meanwhile). Only file
/// existence is asked here; the trust checks are the places' `problem`. Empty
/// off Linux and for a folder the variable gave.
List<AnalysisHostPlace> otherAnalysisHostPlaces(
  HostEnvironment environment, {
  required String chosen,
  CacheFolderCheck? trustedCache,
}) {
  if (environment.os != HostOs.linux ||
      environment.variable(analysisHostFolderVariable) != null) {
    return const [];
  }
  final user = environment.userId;
  if (user == null) return const [];
  final privateGroup = environment.privateGroupId;
  final check =
      trustedCache ??
      (List<String> chain, {bool mustExist = false}) => cacheFoldersProblem(
        chain,
        userId: user,
        privateGroup: privateGroup,
        mustExist: mustExist,
      );
  final places = <AnalysisHostPlace>[];
  void add(String folder, String? Function() problem) {
    if (!p.equals(folder, chosen) && !places.any((it) => it.folder == folder)) {
      places.add((folder: folder, problem: problem));
    }
  }

  final run = p.join(environment.runUserRoot, '$user');
  add(p.join(run, 'appstein'), () => check([run], mustExist: true));
  final home = environment.userHome;
  if (home != null) {
    final hosts = p.join(home, '.cache', 'appstein', 'hosts');
    final chain = [home, p.join(home, '.cache'), p.dirname(hosts), hosts];
    String? problem() => check(chain);
    add(p.join(hosts, _machineFolderName(environment)), problem);
    // This machine under another name: the same hex.
    final hex = _machineHex(environment);
    try {
      for (final entry in Directory(hosts).listSync(followLinks: false)) {
        if (entry is Directory && p.basename(entry.path).endsWith('-$hex')) {
          add(entry.path, problem);
        }
      }
    } on FileSystemException {
      // No such folder.
    }
  }
  add(p.join('/tmp', 'appstein-${_userName(environment)}'), () => null);
  return places;
}

/// What [cacheFoldersProblem] looks at in a folder: whether it is a folder
/// (a link is followed), the ID of the user it belongs to, the ID of its
/// group, and its permission bits (as `stat` gives them, so the sticky bit is
/// among them).
typedef CacheFolderFacts = ({bool isFolder, int owner, int group, int mode});

/// What is wrong with the folders [chain], the ones the host's folder is
/// made in, from the base (the user's home, or `/run/user/<uid>`) down to
/// `<home>/.cache/appstein/hosts`; null when they can be trusted.
///
/// Every folder of the chain that exists must be a folder of the user [userId]
/// that the world can't write to, and the group can't either, **unless the
/// group is the user's private group** ([privateGroup]: Ubuntu makes the
/// user's files with a `umask` of 002 and a group for each user, so `~/.cache`
/// at 775 is common; the group has no other member, so the user is the only
/// one who can write). A folder others can write to lets them rename or
/// replace the folder below it between two looks of a client, and a folder of
/// another user (a home of `/`, one of `/nonexistent`, `/tmp`, or one `sudo`
/// made as root) is theirs to change. When the base itself is not there, the
/// deepest folder above it that is (`/` for a home that is `/nonexistent`) is
/// the only one looked at, unless [mustExist]. The folders above the base are
/// not looked at: the system's own folders are trusted, as ssh trusts those
/// above a home. A link is followed, so `~/.cache` kept on another disk is
/// fine when that is the user's own folder. The last folder, the host's, is
/// left to the rules of [untrustedAddress].
///
/// Untrusted too: anything that is not a folder, a link that leads nowhere,
/// and what can't be looked at (no `stat` in a minimal image, a folder that
/// vanished meanwhile, no user ID). [look] says what the disk has for each
/// path of a list (null for nothing there); tests give it. The real look is
/// one `stat -L -c '%u %g %a'` for every folder that exists.
String? cacheFoldersProblem(
  List<String> chain, {
  required int? userId,
  int? privateGroup,
  bool mustExist = false,
  List<CacheFolderFacts?> Function(List<String> paths) look = _lookAtFolders,
}) {
  try {
    if (userId == null) return "the user's ID can't be read";
    String? problemWith(String path, CacheFolderFacts facts) {
      if (!facts.isFolder) return '$path is not a folder';
      if (facts.owner != userId) return '$path belongs to another user';
      if (facts.mode & 0x2 != 0) {
        return '$path has mode ${facts.mode.toRadixString(8)}, so other '
            'users can write to it';
      }
      if (facts.mode & 0x10 != 0 && facts.group != privateGroup) {
        return '$path has mode ${facts.mode.toRadixString(8)}, so others in '
            'its group can write to it';
      }
      return null;
    }

    final facts = look(chain);
    if (facts.length != chain.length) return "the folders can't be looked at";
    if (facts.first != null) {
      for (var i = 0; i < chain.length; i++) {
        if (facts[i] case final found?) {
          if (problemWith(chain[i], found) case final problem?) return problem;
        }
      }
      return null;
    }
    if (mustExist) return '${chain.first} is not there';
    // The base is not there: the deepest folder above it that is.
    for (var path = p.dirname(chain.first); ; path = p.dirname(path)) {
      if (look([path]).single case final found?) {
        return problemWith(path, found);
      }
      if (p.dirname(path) == path) return 'nothing of $path exists';
    }
  } on Object catch (error) {
    return "the folders can't be looked at ($error)";
  }
}

/// The facts of each of [paths] as the disk has them, one `stat` for all that
/// exist: null where there is nothing. A link is followed. Throws when `stat`
/// fails or says something that can't be read.
List<CacheFolderFacts?> _lookAtFolders(List<String> paths) {
  final facts = _kindsOf(paths);
  final folders = [
    for (var i = 0; i < paths.length; i++)
      if (facts[i] == _isFolder) i,
  ];
  if (folders.isEmpty) return facts.map(_noFacts).toList();
  final result = Process.runSync('stat', [
    '-L',
    '-c',
    '%u %g %a %n',
    for (final i in folders) paths[i],
  ]);
  if (result.exitCode != 0) {
    throw ProcessException('stat', const [], '${result.stderr}'.trim());
  }
  return _factsFromStat(paths, facts, '${result.stdout}');
}

/// What each path is, without a process: a folder, something else in the way,
/// or nothing.
const _isFolder = 'folder';
const _inTheWay = 'in the way';
List<String?> _kindsOf(List<String> paths) => [
  for (final path in paths)
    switch (FileSystemEntity.typeSync(path)) {
      FileSystemEntityType.directory => _isFolder,
      FileSystemEntityType.notFound =>
        FileSystemEntity.isLinkSync(path) ? _inTheWay : null,
      _ => _inTheWay,
    },
];

CacheFolderFacts? _noFacts(String? kind) =>
    kind == null ? null : (isFolder: false, owner: -1, group: -1, mode: 0);

/// The facts of [paths] from the lines of `stat -c '%u %g %a %n'` in
/// [output], for the paths that [kinds] says are folders.
List<CacheFolderFacts?> _factsFromStat(
  List<String> paths,
  List<String?> kinds,
  String output,
) {
  // `stat` prints each name as it was given (`/home/u//.cache` for a home
  // that ends in `/`), so names are compared in their normal spelling.
  final said = <String, CacheFolderFacts>{};
  for (final line in const LineSplitter().convert(output)) {
    final match = RegExp(r'^(\d+) (\d+) ([0-7]+) (.*)$').firstMatch(line);
    if (match == null) throw FormatException('stat said "$line"');
    said[p.normalize(match[4]!)] = (
      isFolder: true,
      owner: int.parse(match[1]!),
      group: int.parse(match[2]!),
      mode: int.parse(match[3]!, radix: 8),
    );
  }
  return [
    for (var i = 0; i < paths.length; i++)
      if (kinds[i] == _isFolder)
        said[p.normalize(paths[i])] ??
            (throw FormatException('stat did not answer for ${paths[i]}'))
      else
        _noFacts(kinds[i]),
  ];
}

/// For a user that only `getent` knows (LDAP, NIS): the home `getent` gives
/// for [user] and the facts of the folders on the way (the home, `.cache`,
/// `appstein` and `hosts`, as `chooseAnalysisHostFolder` looks at them), in
/// **one** process (a
/// shell that runs `getent` and then `stat` on the folders of the home it
/// found). Null when `getent` says nothing, there is no `sh`, or the home is
/// not an absolute path. The home is given in its normal spelling (a home
/// that ends in `/` without it). [run] replaces the process, for tests.
({String home, List<CacheFolderFacts?> facts})? homeAndFoldersOfUser(
  int user, {
  ProcessResult Function(String executable, List<String> arguments) run =
      Process.runSync,
}) {
  final ProcessResult result;
  try {
    result = run('sh', [
      '-c',
      r'h=$(getent passwd "$1" | cut -d: -f6); printf "home %s\n" "$h"; '
          r'case "$h" in /*) stat -L -c "%u %g %a %n" "$h" "$h/.cache" '
          r'"$h/.cache/appstein" "$h/.cache/appstein/hosts" 2>/dev/null;; esac',
      'sh',
      '$user',
    ]);
  } on ProcessException {
    return null;
  }
  final lines = const LineSplitter().convert('${result.stdout}');
  if (lines.isEmpty || !lines.first.startsWith('home ')) return null;
  final given = lines.first.substring(5);
  if (!p.posix.isAbsolute(given)) return null;
  final home = p.normalize(given);
  final hosts = p.join(home, '.cache', 'appstein', 'hosts');
  final chain = [home, p.join(home, '.cache'), p.dirname(hosts), hosts];
  try {
    final kinds = _kindsOf(chain);
    // Every folder that is there must have been answered for, so a `stat`
    // that failed is never taken for "nothing there".
    final facts = _factsFromStat(chain, kinds, lines.skip(1).join('\n'));
    return (home: home, facts: facts);
  } on FormatException {
    return (
      home: home,
      facts: [
        for (final _ in chain) (isFolder: false, owner: -1, group: -1, mode: 0),
      ],
    );
  }
}

/// The name of the folder of this machine in `hosts/`: the machine's name made
/// one plain folder name, then `-` and 12 hex characters ([_machineHex]).
String _machineFolderName(HostEnvironment environment) {
  var plain = environment.machineName
      .toLowerCase()
      .replaceAll(RegExp(r'(?:[^a-z0-9._-]|\.{2,})+'), '_')
      .replaceFirst(RegExp(r'^\.'), '_');
  if (plain.isEmpty) plain = 'unknown';
  if (plain.length > 60) plain = plain.substring(0, 60);
  return '$plain-${_machineHex(environment)}';
}

/// The first 12 hex characters of the SHA-256 of the machine ID when there is
/// one, else of the machine's raw name.
String _machineHex(HostEnvironment environment) {
  final id = environment.machineId;
  return sha256
      .convert(utf8.encode(id.isNotEmpty ? id : environment.machineName))
      .toString()
      .substring(0, 12);
}

/// The user's ID; the user's name when it can't be read.
String _userName(HostEnvironment environment) =>
    environment.userId?.toString() ?? environment.variable('USER') ?? 'unknown';

/// The address file, in [folder], of the analysis host of the project at
/// [projectRoot]: named by a hash of the project's full path, so a path with
/// spaces or any length gives a short plain name. On Windows ([os]), where a
/// path's letter case doesn't matter, the path is hashed in lower case, so
/// two spellings of one folder share one host.
String analysisHostAddressFile(
  String folder,
  String projectRoot, {
  HostOs? os,
}) {
  var path = p.normalize(p.absolute(projectRoot));
  if ((os ?? HostOs.current) == HostOs.windows) path = path.toLowerCase();
  final hash = sha256.convert(utf8.encode(path)).toString().substring(0, 32);
  return p.join(folder, 'host-$hash.json');
}

/// The file beside the address file [addressFile] where a host that could
/// not start leaves why, for the client that started it
/// ([analysisHostAddressFile] with `.failed` for `.json`).
String analysisHostFailureFile(String addressFile) =>
    '${p.withoutExtension(addressFile)}.failed';

/// Deletes the address file [addressFile] when it still holds the address
/// with [secret], under the lock ([withAnalysisHostLock]), and says whether
/// it did. A client calls it for a host it found dead, and a host for its
/// own address as it ends: an address another starter has written meanwhile
/// is left. Returns false when the lock can't be had.
Future<bool> removeAnalysisHostAddress(
  String addressFile,
  String secret, {
  bool Function()? cancelled,
}) async {
  if (!await Directory(p.dirname(addressFile)).exists()) return false;
  try {
    return await withAnalysisHostLock(
      addressFile,
      cancelled: cancelled,
      () async {
        if (readAnalysisHostAddress(addressFile)?.secret != secret) {
          return false;
        }
        try {
          await File(addressFile).delete();
          return true;
        } on FileSystemException {
          return false;
        }
      },
    );
  } on FileSystemException {
    return false;
  }
}

/// Writes [address] to the file [path], whole or not at all: to a new file
/// beside it first, which then takes its place (a rename), so a client never
/// reads half an address. The rename replaces a file that is there: the
/// host calls this under the address file's lock, after it has found none
/// ([withAnalysisHostLock]). Off Windows ([os]) the folder is given mode 700
/// and the file mode 600 before the address is in it, so only the user can
/// read the secret; `chmod` fails on a folder that isn't the user's, so a
/// folder another user made is never written to. On Windows the folder is
/// the user's own (`%LOCALAPPDATA%`). Off Windows a folder path that is a
/// link is refused before anything is made or changed: a link planted where
/// the folder goes (`/tmp/appstein-<uid>`) would otherwise make the host
/// `chmod` one of the user's own folders and write the secret there.
///
/// Throws a [FileSystemException] when it can't be written.
Future<void> writeAnalysisHostAddress(
  String path,
  AnalysisHostAddress address, {
  HostOs? os,
}) => _writeUserOnly(path, jsonEncode(address.toJson()), os ?? HostOs.current);

/// Writes [text] to [path] as [writeAnalysisHostAddress] says.
Future<void> _writeUserOnly(String path, String text, HostOs os) async {
  await _userFolder(path, os);
  final beside = File('$path.$pid.tmp');
  try {
    await beside.writeAsString('');
    await _userOnly('600', beside.path, os);
    await beside.writeAsString(text, flush: true);
    await beside.rename(path);
  } on Object {
    try {
      await beside.delete();
    } on FileSystemException {
      // Never made, or gone already.
    }
    rethrow;
  }
}

/// Makes the folder of the file [path], user-only, as
/// [writeAnalysisHostAddress] says, and each folder above it that is
/// missing, each appearing with mode 700 only ([_makeUserFolder]).
Future<void> _userFolder(String path, HostOs os) async {
  final folder = Directory(p.dirname(path));
  if (os != HostOs.windows && await FileSystemEntity.isLink(folder.path)) {
    throw FileSystemException(
      'the folder of the address file is a link, not a plain folder',
      folder.path,
    );
  }
  // Each folder that is missing on the way is made from the top, and appears
  // at 700: made with the default mode, a `umask` of 002 would leave it at
  // 775 for a moment, and a client that looked then would send its user to
  // `/tmp`. A folder that is there is left, except the last, which is given
  // mode 700 (a folder a killed host left at 755).
  final missing = <Directory>[];
  for (
    var made = folder;
    !await made.exists() && made.parent.path != made.path;
    made = made.parent
  ) {
    missing.add(made);
  }
  // What a host that died while it made one of these folders left beside it.
  for (var level = folder, i = 0; i < _makingLevels; i++) {
    if (level.parent.path == level.path) break;
    await clearMakingLeftovers(level.parent.path);
    level = level.parent;
  }
  for (final made in missing.reversed) {
    await _makeUserFolder(made, os);
  }
  await _userOnly('700', folder.path, os);
}

final _unique = Random();

/// How many folders above the address folder a host may make (`hosts/<name>`,
/// `hosts`, `appstein` and `.cache` under the home), and so in how many
/// parents it looks for what an earlier one left ([clearMakingLeftovers]).
const _makingLevels = 4;

/// How old a folder that a host was making must be before it counts as left
/// behind: a host makes, chmods and renames one within milliseconds.
const analysisHostMakingAge = Duration(hours: 1);

/// Removes from [parent] the folders a host left while it made a folder there
/// ([_makeUserFolder]: `.<name>.<pid>.<n>.making`) and died before it renamed
/// or deleted it: the ones last modified more than [olderThan] ago. Such a
/// folder is always empty, so each is removed as an empty folder only, which
/// never follows a link, never removes anything in it, and fails on another
/// user's folder in a shared folder such as `/tmp`; whatever can't be
/// removed is left. Returns the paths it removed.
Future<List<String>> clearMakingLeftovers(
  String parent, {
  Duration olderThan = analysisHostMakingAge,
}) async {
  final removed = <String>[];
  final cutoff = DateTime.now().subtract(olderThan);
  try {
    await for (final entry in Directory(parent).list(followLinks: false)) {
      if (entry is! Directory ||
          !RegExp(
            r'^\..+\.\d+\.\d+\.making$',
          ).hasMatch(p.basename(entry.path))) {
        continue;
      }
      try {
        if ((await FileStat.stat(entry.path)).modified.isAfter(cutoff)) {
          continue;
        }
        await entry.delete();
        removed.add(entry.path);
      } on FileSystemException {
        // Not empty, another user's, or gone: left.
      }
    }
  } on FileSystemException {
    // A parent that can't be read: nothing to clear.
  }
  return removed;
}

/// Makes the folder [folder] so that it is there only with mode 700: it is
/// made beside under a name of its own, given the mode, and renamed into
/// place. When the rename fails because the folder is there now (another
/// starter made it first), the one made here is deleted and the folder that
/// is there is used, when it passes the check of a client
/// ([untrustedAddressFolder]).
Future<void> _makeUserFolder(Directory folder, HostOs os) async {
  final beside = Directory(
    p.join(
      folder.parent.path,
      '.${p.basename(folder.path)}.$pid.${_unique.nextInt(1 << 32)}.making',
    ),
  );
  await beside.create();
  try {
    await _userOnly('700', beside.path, os);
    try {
      await beside.rename(folder.path);
      return;
    } on FileSystemException {
      if (!await folder.exists()) rethrow;
    }
    if (await untrustedAddressFolder(folder.path, os: os) case final why?) {
      throw FileSystemException(why, folder.path);
    }
  } finally {
    try {
      if (await beside.exists()) await beside.delete(recursive: true);
    } on FileSystemException {
      // Left: the next host that makes a folder here clears it once it is
      // old ([clearMakingLeftovers]).
    }
  }
}

/// Gives [path] the permissions [mode] off Windows ([setFileMode]), and does
/// nothing on Windows. Throws a [FileSystemException] when that fails.
Future<void> _userOnly(String mode, String path, HostOs os) async {
  if (os == HostOs.windows) return;
  if (!await setFileMode(mode, path)) {
    throw FileSystemException(
      'its permissions could not be set to $mode (is it the user\'s own?)',
      path,
    );
  }
}

/// Why the address file [path] must not be trusted; null when it may be
/// read. On Windows ([os]) the folder is the user's own (`%LOCALAPPDATA%`),
/// so nothing is checked. Elsewhere, when the folder exists:
/// - it must be a folder, not a link, and other users must not be able to
///   write to it (no world-write bit);
/// - when the address file is there, or [strict] is true, the folder must
///   also pass [untrustedAddressFolder]: mode 700 and the user's own;
/// - when the address file is there, it must be a file, not a link, with
///   mode 600, and the user's own.
///
/// A client looks before it reads an address, and **once it has read one,
/// looks again with [strict]**: a file another user renamed into the folder
/// between the two moments is then refused, even if it has gone again. With
/// no address file and [strict] false, a folder of the user's own at 755 or
/// 775 (as a host killed between making it and its `chmod` leaves it) is
/// not refused: the host that is started next gives it mode 700 before it
/// writes its address there, and in a folder another user owns that `chmod`
/// fails, so the host writes nothing there ([writeAnalysisHostAddress]).
///
/// Every local program can reach a loopback port, so a client that took
/// another user's address file would send that user's host its questions,
/// and that host could answer anything.
Future<String?> untrustedAddress(
  String path, {
  HostOs? os,
  bool strict = false,
  int? userId,
}) async {
  final system = os ?? HostOs.current;
  if (system == HostOs.windows) return null;
  final folder = p.dirname(path);
  final folderType = await FileSystemEntity.type(folder, followLinks: false);
  if (folderType == FileSystemEntityType.notFound) return null;
  if (folderType != FileSystemEntityType.directory) {
    return _notPlainFolder(folder);
  }
  final fileType = await FileSystemEntity.type(path, followLinks: false);
  if (fileType == FileSystemEntityType.notFound && !strict) {
    final mode = (await FileStat.stat(folder)).mode & 0x1FF;
    if (mode & 0x2 != 0) {
      return 'the folder $folder has mode ${mode.toRadixString(8)}, so '
          'other users can write to it';
    }
    return null;
  }
  if (_notMode('the folder', folder, 0x1C0) case final why?) return why;
  if (fileType != FileSystemEntityType.notFound) {
    if (fileType != FileSystemEntityType.file) {
      return 'the address file $path is not a plain file';
    }
    if (_notMode('the address file', path, 0x180) case final why?) return why;
  }
  // Who owns them: one `stat`, for the folder and the file together.
  return _notOwnedByUser(
    [
      ('the folder', folder),
      if (fileType != FileSystemEntityType.notFound) ('the address file', path),
    ],
    system,
    userId,
  );
}

/// Why the address-file folder [folder] is not one only the user can use;
/// null when it is, or doesn't exist. On Windows ([os]) nothing is checked.
/// Elsewhere it must be a folder, not a link, with mode 700, and the user's
/// own ([userId], the effective user ID of this process unless a test gives
/// one: its owner, told by one `stat`).
///
/// A client checks it before it trusts anything read from the folder: an
/// address ([untrustedAddress] with `strict`), and the reason a host that
/// could not start left there ([analysisHostFailureFile]).
Future<String?> untrustedAddressFolder(
  String folder, {
  HostOs? os,
  int? userId,
}) async {
  final system = os ?? HostOs.current;
  if (system == HostOs.windows) return null;
  final type = await FileSystemEntity.type(folder, followLinks: false);
  if (type == FileSystemEntityType.notFound) return null;
  if (type != FileSystemEntityType.directory) return _notPlainFolder(folder);
  if (_notMode('the folder', folder, 0x1C0) case final why?) return why;
  return _notOwnedByUser([('the folder', folder)], system, userId);
}

String _notPlainFolder(String folder) =>
    'the folder $folder is not a plain folder';

/// Why [target] ([what]) doesn't have the permissions [mode]; null when it
/// has them.
String? _notMode(String what, String target, int mode) {
  final actual = FileStat.statSync(target).mode & 0x1FF;
  if (actual == mode) return null;
  return '$what $target has mode ${actual.toRadixString(8)}, not '
      '${mode.toRadixString(8)}';
}

/// Why one of [targets] (a description and a path each, none a link) is not
/// the user's own; null when all are. One `stat` that does not follow links
/// tells the owners (GNU's `-c %u`, macOS's `-f %u`), and each is compared
/// with the effective user ID: a `chmod` to the same mode, which only the
/// owner can do, is no proof under root, who can do it on anything.
Future<String?> _notOwnedByUser(
  List<(String, String)> targets,
  HostOs os,
  int? userId,
) async {
  final user = userId ?? MachineFacts.system.userId;
  final owners = <int>[];
  try {
    final (executable, format) = ownerStatCommand(os);
    final result = await Process.run(executable, [
      ...format,
      for (final (_, path) in targets) path,
    ]);
    if (result.exitCode == 0) {
      for (final line in const LineSplitter().convert('${result.stdout}')) {
        owners.add(int.parse(line.trim()));
      }
    }
  } on Object {
    // No `stat`, or it said something else: the owners are not known.
  }
  for (var i = 0; i < targets.length; i++) {
    final (what, path) = targets[i];
    if (user == null || owners.length != targets.length) {
      return "$what $path's owner can't be told";
    }
    if (owners[i] != user) return '$what $path is not the user\'s own';
  }
  return null;
}

/// The `stat` that tells the owner of a path without following a link on
/// [os], and the arguments that make it print the owner's ID alone. On macOS
/// it is the system's own, `/usr/bin/stat -f %u`, by its full path: a GNU
/// `stat` that Homebrew puts first on the PATH reads `-f` as "the file
/// system" and fails, which would make every owner unknown. On Linux it is
/// the `stat` on the PATH (GNU's or BusyBox's; NixOS has no `/usr/bin`),
/// `stat -c %u`.
(String, List<String>) ownerStatCommand(HostOs os) => os == HostOs.macos
    ? ('/usr/bin/stat', const ['-f', '%u'])
    : ('stat', const ['-c', '%u']);

/// The address in the file [path]; null when there is none, or it can't be
/// read as one.
AnalysisHostAddress? readAnalysisHostAddress(String path) {
  try {
    final json = jsonDecode(File(path).readAsStringSync());
    if (json is! Map<String, Object?>) return null;
    return AnalysisHostAddress.fromJson(json);
  } on Object {
    return null;
  }
}

/// How long a new connection may take to send its hello before the host
/// closes it.
const _helloLimit = Duration(seconds: 10);

/// Runs the **analysis host** of the project at [projectRoot] (decision
/// record 0002), and returns when it has ended. It is what the hidden
/// `appstein analysis-host` mode runs.
///
/// - **It owns [analysis]**, the project's analysis server behind its
///   guard, with all its rules (`AnalysisServer`), and keeps it between
///   questions (`KeptAnalysisServer`). Nothing is started until a client
///   asks.
/// - **It listens on loopback TCP only**: `127.0.0.1`, on a port the system
///   picks. It then writes its address file ([analysisHostAddressFile] in
///   [addressFolder]): the port, a random secret, its process ID and
///   [appsteinVersion]. When it can't (the folder can't be made or isn't the
///   user's, the port can't be bound, the file can't be written), it leaves
///   why in [analysisHostFailureFile] for the client that started it, and
///   throws.
/// - **Taking the project is exclusive**: the address is written under the
///   address file's lock ([withAnalysisHostLock]), and only when no other
///   host's address is there. A host that finds one has lost a race with
///   another starter: it returns at once, having started nothing, and its
///   client connects to the winner. An address a dead host left is deleted
///   by the client that finds it dead, before it starts a host.
/// - **A client of a newer Appstein version asks it to stop**
///   (`AnalysisHostStop`): it deletes its address file and closes its port
///   at once, so that client can start a host of its own version, then
///   closes that connection, answers the questions it already has (being
///   answered or waiting in its queue), and ends. It takes no new question:
///   one that comes on a connection still open is answered with an
///   `AnalysisHostEnding` and the connection is closed, so its client asks
///   the host that took the project, and an `--apply` sent then never
///   writes.
/// - **A connection must send the secret first** (an `AnalysisHostHello`):
///   every local program can reach a loopback port, so one whose first line
///   isn't the hello with the secret, or that sends none within 10 s, is
///   closed.
/// - **Each question is one use of the server**: questions are answered one
///   at a time, in the order they arrive, from every connection, and a
///   connection holds the server only while its question is answered. A
///   question that changes the server's state for a while (the pending-fix
///   passes and the rewrite of `--apply`, whose overlays no other client may
///   see) is one question, so no other client's question comes in between.
/// - **A question's turn is told** (`AnalysisHostTurn`) when it leaves the
///   queue, so a client counts its time limit from there, not from the wait
///   behind other clients' questions.
/// - **A question whose client has gone is never begun**: one whose
///   connection closed while it waited is dropped. A rewrite
///   (`applyFixesAndFormat`) whose client goes away while the server works
///   writes nothing: [analysis] is made with an [AnalysisHostWrites], whose
///   `replaceText` looks once, at the first write, whether the client is
///   still there (as `AnalysisServer` gives up a rewrite whose caller stopped
///   waiting).
/// - **It ends itself after [idleStop] with no question**, never while one
///   is answered: it closes its port and its connections, deletes its
///   address file (when it is still its own) and stops the server and its
///   guard. A connection that asks nothing for [idleStop] is closed. A host
///   that is killed instead takes its guard and server with it: the guard
///   ends the server when the host's end closes its input.
/// - **It follows its folder when the client chose it from the machine's
///   facts** ([folderNow] is not null; only a Linux client says so): every
///   [maintenanceEvery] it checks, without starting a process, that the
///   folder chosen now ([analysisHostFolderNow]) is still its folder and that
///   its address file still holds its secret. When either fails (the machine
///   was renamed, the system removed `/run/user/<uid>`, a sweep deleted the
///   file) the folder is chosen again from a new look at the disk, and the
///   host writes its address there, made and checked as at the start, under
///   that folder's lock and only when no other host's address is there, and
///   then deletes the old file if it is still its own. When another host's
///   address is there, it gives its own up, answers the questions it has and
///   ends, as a host asked to stop does, so a rewrite under way is never cut
///   off. Every [heartbeatEvery] the look is a new one in any case, so a home
///   that became unsafe is noticed. The next client finds the same host, and
///   no second host and server are started. A folder that vanished while the
///   host started is made again, once.
/// - **It keeps its address file young and sweeps old folders**: every
///   [heartbeatEvery] it sets the file's modified time to now (when the file
///   holds its secret), and, when it follows its folder and the folder is one
///   machine's in `appstein/hosts`, it sweeps the other folders in `hosts`
///   that nothing has touched for [sweepAge] when it starts
///   ([sweepStaleHostFolders]). All of it is done by the host, in the
///   background: no client waits for it.
/// - **It ends at once when its port fails**: Dart closes a server socket on
///   any error, so a host that kept its address file would accept nothing.
///   It gives the address up and ends as it does after [idleStop].
Future<void> runAnalysisHost({
  required String projectRoot,
  required StoppableCodeAnalysis Function(AnalysisHostWrites writes) analysis,
  required String addressFolder,
  required String appsteinVersion,
  Duration idleStop = analysisHostIdleStop,
  HostOs? os,
  String Function({bool fresh})? folderNow,
  Duration maintenanceEvery = analysisHostMaintenanceEvery,
  Duration heartbeatEvery = analysisHostHeartbeatEvery,
  Duration sweepAge = analysisHostSweepAge,
}) async {
  final system = os ?? HostOs.current;
  final writes = AnalysisHostWrites._();
  final kept = KeptAnalysisServer(analysis(writes), idleStop: idleStop * 2);
  var addressFile = analysisHostAddressFile(
    addressFolder,
    projectRoot,
    os: system,
  );
  final failureFile = analysisHostFailureFile(addressFile);
  final random = Random.secure();
  final secret = [
    for (var i = 0; i < 32; i++) random.nextInt(256).toRadixString(16),
  ].map((byte) => byte.padLeft(2, '0')).join();
  final ServerSocket listening;
  try {
    listening = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final bool claimed;
    try {
      await _userFolder(addressFile, system);
      // Exclusive: only when no other host's address is there. A dead
      // host's was deleted by the client that found it dead.
      claimed = await withAnalysisHostLock(addressFile, () async {
        if (readAnalysisHostAddress(addressFile) != null) return false;
        await writeAnalysisHostAddress(
          addressFile,
          AnalysisHostAddress(
            port: listening.port,
            secret: secret,
            processId: pid,
            appsteinVersion: appsteinVersion,
          ),
          os: system,
        );
        return true;
      });
    } on Object {
      await listening.close();
      rethrow;
    }
    if (!claimed) {
      // Another host took the project first: its clients, the one that
      // started this one too, use that one.
      await listening.close();
      await kept.close();
      return;
    }
  } on Object catch (error) {
    await kept.close();
    try {
      await _writeUserOnly(
        failureFile,
        'the analysis host could not start: ${_plain(error)}',
        system,
      );
    } on Object {
      // Not even that: the client says the host ended as it started.
    }
    rethrow;
  }
  try {
    await File(failureFile).delete();
  } on FileSystemException {
    // None was left.
  }

  final ended = Completer<void>();
  final connections = <Socket>{};
  var asking = 0;
  var ending = false;
  var askedToStop = false;
  Timer? idle;
  Timer? maintenance;
  Future<void>? gaveUp;

  // Gives the project up: the port is closed and the address file deleted,
  // when it is still its own (another host may have written it since).
  Future<void> giveUp() => gaveUp ??= () async {
    await listening.close();
    await removeAnalysisHostAddress(addressFile, secret);
  }();

  Future<void> end() async {
    if (ending) return;
    ending = true;
    idle?.cancel();
    maintenance?.cancel();
    await giveUp();
    // An answer written a moment ago still reaches its client.
    await Future.wait([...connections].map(_closeWritten));
    await kept.close();
    if (!ended.isCompleted) ended.complete();
  }

  void countIdle() {
    idle?.cancel();
    idle = Timer(idleStop, () {
      if (asking == 0) unawaited(end());
    });
  }

  // When no question is being answered: a host asked to stop ends, any
  // other counts its idle time again.
  void afterQuestions() {
    if (asking > 0 || ending) return;
    if (askedToStop) {
      unawaited(end());
    } else {
      countIdle();
    }
  }

  // Asked by a client of a newer version: the project is given up at once,
  // so that client can start a host of its own, and this one ends when the
  // questions it already has are answered. It takes no new one.
  Future<void> stop() async {
    if (askedToStop) return;
    askedToStop = true;
    idle?.cancel();
    maintenance?.cancel();
    await giveUp();
    afterQuestions();
  }

  // The address as written, for the folder the host moves to.
  final address = AnalysisHostAddress(
    port: listening.port,
    secret: secret,
    processId: pid,
    appsteinVersion: appsteinVersion,
  );
  var lastBeat = DateTime.now();
  var maintaining = false;

  // Writes the address into [folder] (made and checked as at the start),
  // under that folder's lock and only when no other host's address is there,
  // and gives up the old file when it is still its own. Returns whether
  // another host's address is there.
  Future<bool> settleIn(String folder) async {
    final target = analysisHostAddressFile(folder, projectRoot, os: system);
    final old = addressFile;
    await _userFolder(target, system);
    final taken = await withAnalysisHostLock(target, () async {
      final found = readAnalysisHostAddress(target);
      if (found != null) return found.secret != secret;
      await writeAnalysisHostAddress(target, address, os: system);
      return false;
    }, cancelled: () => ending || askedToStop);
    if (taken) return true;
    addressFile = target;
    lastBeat = DateTime.now();
    if (old != target) await removeAnalysisHostAddress(old, secret);
    return false;
  }

  // One round of the host's housekeeping: no process is started unless the
  // folder has to be chosen again. Every heartbeat the look is new, so a home
  // that became unsafe is noticed.
  Future<void> maintain() async {
    if (ending || askedToStop || maintaining) return;
    maintaining = true;
    try {
      final mine = readAnalysisHostAddress(addressFile)?.secret == secret;
      final beat = DateTime.now().difference(lastBeat) >= heartbeatEvery;
      if (mine && beat) {
        lastBeat = DateTime.now();
        File(addressFile).setLastModifiedSync(lastBeat);
      }
      if (folderNow == null) return;
      final here = p.dirname(addressFile);
      if (!beat && folderNow() == here && mine) return;
      // The folder chosen now, from a new look at the disk: the one the cheap
      // answer names may be gone.
      final folder = folderNow(fresh: true);
      if (folder == here && mine) return;
      if (await settleIn(folder)) {
        // Another host has the project there: this one gives its own up,
        // answers what it has and ends, as the stop of a newer client makes
        // it do, so a rewrite under way is never cut off.
        unawaited(stop());
      }
    } on Object {
      // Not now (the folder can't be made, a lock is held): the next round.
    } finally {
      maintaining = false;
    }
  }

  maintenance = Timer.periodic(maintenanceEvery, (_) => unawaited(maintain()));
  if (folderNow != null) {
    unawaited(_sweepOtherMachines(addressFolder, sweepAge));
    // A folder that vanished while the host started: made again, once.
    if (!File(addressFile).existsSync()) {
      unawaited(
        settleIn(
          p.dirname(addressFile),
        ).then<void>((_) {}, onError: (Object _) {}),
      );
    }
  }
  countIdle();
  listening.listen((socket) async {
    connections.add(socket);
    // Read apart from the answering, so a client that goes away is seen
    // while its question waits or is answered.
    var open = true;
    final incoming = StreamController<String>();
    utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .listen(
          incoming.add,
          onDone: () {
            open = false;
            unawaited(incoming.close());
          },
          onError: (Object _) {
            open = false;
            unawaited(incoming.close());
          },
        );
    final lines = StreamIterator(incoming.stream);
    // A write to a client that has gone away fails here, not in the host.
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
    try {
      if (!await _helloWith(lines, secret)) return;
      socket.writeln(
        jsonEncode(
          AnalysisHostWelcome(
            appsteinVersion: appsteinVersion,
            processId: pid,
          ).toJson(),
        ),
      );
      // A connection that asks nothing for the idle time is closed.
      while (await lines.moveNext().timeout(idleStop)) {
        final json = jsonDecode(lines.current);
        if (json is! Map<String, Object?>) return;
        if (AnalysisHostStop.isStop(json)) {
          // Its address file is gone before the connection closes.
          await stop();
          return;
        }
        final question = AnalysisHostQuestion.fromJson(json);
        if (askedToStop || ending) {
          // A question that came after the stop, or while the host ends
          // (its server is being closed), is not taken, so the old
          // host and server don't run on beside the new ones: its client
          // asks the host that took the project.
          socket.writeln(jsonEncode(AnalysisHostEnding(question.id).toJson()));
          return;
        }
        asking++;
        idle?.cancel();
        final AnalysisHostAnswer? answer;
        try {
          answer = await kept.use((analysis) async {
            // Its client went away while it waited: it is not begun.
            if (!open) return null;
            socket.writeln(jsonEncode(AnalysisHostTurn(question.id).toJson()));
            writes._current = _Asked(() => open);
            try {
              return await _answer(question, analysis);
            } finally {
              writes._current = null;
            }
          });
        } on CodeAnalysisException catch (error) {
          // The host is ending: the server is closed.
          socket.writeln(
            jsonEncode(
              AnalysisHostAnswer.failed(question.id, error.reason).toJson(),
            ),
          );
          return;
        } finally {
          asking--;
          afterQuestions();
        }
        if (answer == null) return;
        socket.writeln(jsonEncode(answer.toJson()));
      }
    } on Object {
      // A client that broke its connection, sent what is no question, or
      // asked nothing for the idle time: the connection is closed below.
    } finally {
      connections.remove(socket);
      // The last line written (an answer, an ending) still reaches it.
      await _closeWritten(socket);
      await lines.cancel();
    }
  }, onError: (Object _) => unawaited(end()));
  await ended.future;
}

/// Closes [socket] once what was written to it has gone out, or after 1 s
/// when its client doesn't take it: `destroy` alone drops what is still
/// waiting to be sent.
Future<void> _closeWritten(Socket socket) async {
  try {
    await socket.flush().timeout(const Duration(seconds: 1));
  } on Object {
    // Gone already, or not taking what was written: closed below anyway.
  }
  socket.destroy();
}

/// How the analysis host's server writes the files of a rewrite
/// (`applyFixesAndFormat`): the host gives it to the code analysis it owns
/// ([runAnalysisHost]), which passes [replaceText] to `AnalysisServer` as
/// its `replaceText`.
///
/// At the first write of a question it looks whether the client that asked
/// is still connected. When it isn't, that write and every other of the
/// question fail, so nothing is written: the client has already been told
/// the question failed, and a rewrite must only ever fail before anything
/// is written. Once the first write is made, the others follow, as in
/// `AnalysisServer`.
final class AnalysisHostWrites {
  AnalysisHostWrites._();

  /// The question being answered; null between questions.
  _Asked? _current;

  /// Writes [text] to [path] as `replaceFileText` does, unless the client
  /// whose question this is has gone away (above).
  ///
  /// Throws a [FileSystemException] for a write that is not made.
  Future<void> replaceText(String path, String text) =>
      gate(replaceFileText)(path, text);

  /// [write], under the rule above: [replaceText] is `gate(replaceFileText)`.
  /// A test's stand-in for the server passes its own [write].
  Future<void> Function(String path, String text) gate(
    Future<void> Function(String path, String text) write,
  ) => (path, text) async {
    final asked = _current;
    if (asked != null && !asked.began) {
      asked
        ..began = true
        ..abandoned = !asked.wanted();
    }
    if (asked != null && asked.abandoned) {
      throw FileSystemException(
        'the client that asked for the rewrite has gone away, so nothing is '
        'written',
        path,
      );
    }
    await write(path, text);
  };
}

/// One question as [AnalysisHostWrites] sees it.
final class _Asked {
  _Asked(this.wanted);

  /// Whether its client is still connected.
  final bool Function() wanted;

  /// Whether its first write was looked at.
  var began = false;

  /// Whether its writes are not made.
  var abandoned = false;
}

/// [error] in one line, without Dart's class name in front.
String _plain(Object error) => switch (error) {
  FileSystemException(:final message, :final path, :final osError) =>
    '$message${path == null ? '' : ' ($path)'}'
        '${osError == null ? '' : ': ${osError.message}'}',
  SocketException(:final message, :final osError) =>
    '$message${osError == null ? '' : ': ${osError.message}'}',
  _ => '$error',
}.replaceAll(RegExp(r'\s*\n\s*'), ' ');

/// Whether the first line of [lines] is a hello with [secret], sent within
/// [_helloLimit].
Future<bool> _helloWith(StreamIterator<String> lines, String secret) async {
  try {
    if (!await lines.moveNext().timeout(_helloLimit)) return false;
    final json = jsonDecode(lines.current);
    if (json is! Map<String, Object?>) return false;
    final hello = AnalysisHostHello.fromJson(json);
    return _same(hello.secret, secret);
  } on Object {
    return false;
  }
}

/// Whether [a] and [b] are the same text, in a time that doesn't tell how
/// much of them agrees.
bool _same(String a, String b) {
  if (a.length != b.length) return false;
  var differ = 0;
  for (var i = 0; i < a.length; i++) {
    differ |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return differ == 0;
}

/// [analysis]'s answer to [question].
Future<AnalysisHostAnswer> _answer(
  AnalysisHostQuestion question,
  CodeAnalysis analysis,
) async {
  final id = question.id;
  final within = question.within ?? Duration.zero;
  try {
    return AnalysisHostAnswer.answered(id, switch (question.kind) {
      AnalysisHostQuestionKind.read => (await analysis.read()).toJson(),
      AnalysisHostQuestionKind.canDartFix => await analysis.canDartFix(
        question.diagnostic!,
        within: within,
      ),
      AnalysisHostQuestionKind.formatChanges => (await analysis.formatChanges(
        question.files,
        within: within,
      )).toJson(),
      AnalysisHostQuestionKind.pendingFixes => (await analysis.pendingFixes(
        within: within,
      )).toJson(),
      AnalysisHostQuestionKind.applyFixesAndFormat =>
        (await analysis.applyFixesAndFormat(
          leaveUnformatted: (file) async =>
              question.leaveUnformatted.contains(file),
          within: within,
        )).toJson(),
    });
  } on TimeoutException {
    return AnalysisHostAnswer.timedOut(id);
  } on CodeAnalysisException catch (error) {
    return AnalysisHostAnswer.failed(
      id,
      error.reason,
      refusalCode: error.refusalCode,
    );
  } on Object catch (error) {
    return AnalysisHostAnswer.failed(id, 'the analysis host failed: $error');
  }
}

/// How often an analysis host looks after its address ([runAnalysisHost]).
const analysisHostMaintenanceEvery = Duration(seconds: 60);

/// How often an analysis host sets its address file's modified time to now.
const analysisHostHeartbeatEvery = Duration(minutes: 10);

/// How long a folder in `appstein/hosts` that nothing has touched is kept
/// ([sweepStaleHostFolders]).
const analysisHostSweepAge = Duration(days: 7);

/// A function that gives, each time, the folder [analysisHostFolder] chooses
/// now for [environment], without starting a process unless something changed:
/// the answer is kept while the facts the choice is made from (the machine's
/// name and ID, the user, the home, and whether `/run/user/<uid>` is there)
/// are the same, and chosen again from a new look at the disk when they
/// change, or when it is asked to (`fresh`). Every fact is read once for the
/// process, so a round that finds nothing changed reads no file and starts no
/// process. It is what an analysis host that
/// follows its folder is given (`runAnalysisHost`'s `folderNow`).
String Function({bool fresh}) analysisHostFolderNow(
  HostEnvironment environment, {
  CacheFolderCheck? trustedCache,
}) {
  String? key;
  late String folder;
  return ({bool fresh = false}) {
    final user = environment.userId;
    final now =
        '${environment.machineName}|${environment.machineId}|$user|'
        '${environment.userHome}|'
        '${user != null && Directory(p.join(environment.runUserRoot, '$user')).existsSync()}';
    if (fresh || now != key) {
      folder = analysisHostFolder(environment, trustedCache: trustedCache);
      key = now;
    }
    return folder;
  };
}

/// Sweeps the folders of other machines in the `hosts` folder that holds
/// [folder], when [folder] is one of them (`<cache>/appstein/hosts/<name>`).
Future<void> _sweepOtherMachines(String folder, Duration age) async {
  final hosts = p.dirname(folder);
  if (p.basename(hosts) != 'hosts' ||
      p.basename(p.dirname(hosts)) != 'appstein') {
    return;
  }
  await sweepStaleHostFolders(hosts, keep: folder, olderThan: age);
}

/// Removes the folders in [hosts] (`<cache>/appstein/hosts`) that nothing has
/// touched for [olderThan]: every entry in them, and the folder itself, was
/// last modified before that. They are what a machine whose name changes each
/// run (a container on a home kept on a volume) leaves, or a host that was
/// killed. A live host sets its file's modified time every ten minutes, so
/// its folder is never old. Returns the folders it removed.
///
/// What it is not sure of it leaves: [keep] (the caller's own folder), a
/// folder that does not pass the same check as the address folder of a client
/// (a folder of the user's own at mode 700, [untrustedAddressFolder]), a
/// folder with anything newer in it, anything that can't be read, and every
/// link: a link is never followed, in [hosts] or in a folder, and a folder
/// with a link in it is left. A folder is renamed to a name of the sweep's own
/// before it is deleted (atomic: nobody uses it meanwhile) and looked at again
/// under it; one that was written to meanwhile is renamed back. [afterRename]
/// is called with the new name, between the rename and the second look: a test
/// writes there.
Future<List<String>> sweepStaleHostFolders(
  String hosts, {
  required String keep,
  required Duration olderThan,
  Future<void> Function(String moved)? afterRename,
}) async {
  final removed = <String>[];
  try {
    final cutoff = DateTime.now().subtract(olderThan);
    final entries = await Directory(hosts).list(followLinks: false).toList();
    for (final entry in entries) {
      if (entry is! Directory || p.equals(entry.path, keep)) continue;
      try {
        if (!await _untouchedSince(entry, cutoff)) continue;
        if (await untrustedAddressFolder(entry.path) != null) continue;
        // Renamed to a name of this sweep's own first (atomic): nobody uses
        // the folder while it is looked at again and deleted. When something
        // in it is new after all (its host wrote again meanwhile), it is
        // renamed back.
        final moved = Directory(
          p.join(hosts, '.${p.basename(entry.path)}.$pid.sweeping'),
        );
        await entry.rename(moved.path);
        await afterRename?.call(moved.path);
        if (!await _untouchedSince(moved, cutoff)) {
          try {
            await moved.rename(entry.path);
          } on FileSystemException {
            // The name was taken meanwhile: the folder is left under its new
            // one, and a later sweep takes it when it is old.
          }
          continue;
        }
        await moved.delete(recursive: true);
        removed.add(entry.path);
      } on Object {
        // Left as it is.
      }
    }
  } on Object {
    // Nothing to sweep, or it can't be read.
  }
  return removed;
}

/// Whether [folder] and everything in it was last modified before [cutoff],
/// and holds no link.
Future<bool> _untouchedSince(Directory folder, DateTime cutoff) async {
  if ((await FileStat.stat(folder.path)).modified.isAfter(cutoff)) {
    return false;
  }
  await for (final entry in folder.list(recursive: true, followLinks: false)) {
    if (entry is Link) return false;
    if ((await FileStat.stat(entry.path)).modified.isAfter(cutoff)) {
      return false;
    }
  }
  return true;
}
