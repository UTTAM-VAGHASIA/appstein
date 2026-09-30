import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/executable_finder.dart';
import '../host/host_environment.dart';
import '../host/process_runner.dart';

/// Where the JDK that Flutter uses was found.
enum JavaSource {
  /// Set with `flutter config --jdk-dir`.
  flutterConfig('`flutter config --jdk-dir`'),

  /// Bundled with Android Studio.
  androidStudio("Android Studio's bundled JDK"),

  /// The JAVA_HOME environment variable.
  javaHome('JAVA_HOME'),

  /// The `java` command on PATH.
  path('`java` on PATH');

  const JavaSource(this.label);

  /// How the source is shown to people.
  final String label;
}

/// The JDK Flutter would use.
final class JavaLocation {
  /// Creates a location.
  const JavaLocation({
    required this.javaBinary,
    required this.source,
    this.home,
    this.versionOutput,
  });

  /// The `java` executable.
  final String javaBinary;

  /// Where it came from.
  final JavaSource source;

  /// The JDK folder, when known.
  final String? home;

  /// What `java -version` printed, when the lookup already ran it, so callers
  /// need not run it again. Null when the lookup did not run it.
  final String? versionOutput;
}

/// The result of looking for the JDK Flutter uses: the JDK, when there is
/// one, and the Android Studio installs passed over on the way.
final class JavaLookup {
  /// Creates a result.
  const JavaLookup({this.location, this.skipped = const []});

  /// The JDK Flutter would use, or null when it finds none.
  final JavaLocation? location;

  /// Why Flutter passed over Android Studio installs, one line each, in the
  /// order they were tried. It is filled whether or not a JDK was found, so
  /// a missing JDK can be explained too.
  final List<String> skipped;
}

/// Finds the JDK Flutter uses, in Flutter's own order (`_findJavaHome` in
/// `flutter_tools/lib/src/android/java.dart`, Flutter 3.47):
/// 1. `flutter config --jdk-dir`, whenever it is text, even empty text, as
///    in Flutter (an empty home gives a relative `bin/java` that won't run);
/// 2. the JDK bundled with Android Studio;
/// 3. JAVA_HOME;
/// 4. `java` on PATH.
///
/// A `jdk-dir` that is JSON null counts as unset. Any other non-text value
/// is skipped here too; `JavaCheck` reports it, because Flutter stops with
/// an error on it.
///
/// Android Studio is chosen as Flutter's `AndroidStudio.latestValid` chooses
/// it:
/// - when the `android-studio-dir` setting is set, only that install counts
///   (on macOS, unless it is a JetBrains Toolbox launcher, which Flutter
///   drops);
/// - otherwise the installs Flutter knows about are tried newest version
///   first, equal versions in the order they were found. On Windows and
///   Linux they are the ones named by Android Studio's install records (the
///   `.home` files it writes), plus `/opt/android-studio` and
///   `~/android-studio` on Linux. On macOS (`_allMacOS`) they are every
///   `Android Studio*.app` in [macAppFolders], at any depth (by default
///   `/Applications` and `~/Applications`), then the bundles Spotlight's
///   `mdfind` finds by Android Studio's bundle ID, without Toolbox
///   launchers.
///
/// An install counts only if its bundled `java -version`, run with [runner],
/// succeeds. The installs passed over are listed in [JavaLookup.skipped].
Future<JavaLookup> locateFlutterJava(
  HostEnvironment environment,
  Map<String, Object?> settings,
  ProcessRunner runner, {
  List<String>? macAppFolders,
}) async {
  final configured = settings['jdk-dir'];
  if (configured is String) {
    return JavaLookup(
      location: JavaLocation(
        javaBinary: _javaIn(configured, environment),
        source: JavaSource.flutterConfig,
        home: configured,
      ),
    );
  }
  final candidates = await _studioCandidates(
    environment,
    settings,
    runner,
    macAppFolders,
  );
  final skipped = [...candidates.notes];
  for (final studio in candidates.studios) {
    if (!Directory(studio.path).existsSync()) {
      skipped.add(
        '`android-studio-dir` points to ${studio.path}, which does not exist.',
      );
      continue;
    }
    final home = _studioJdkHome(studio, environment);
    final java = _javaIn(home, environment);
    if (!File(java).existsSync()) {
      skipped.add(
        'Android Studio at ${studio.path} has no bundled JDK; '
        'Flutter skips it.',
      );
      continue;
    }
    final result = await runner.run(java, ['-version']);
    if (result.ok) {
      return JavaLookup(
        location: JavaLocation(
          javaBinary: java,
          source: JavaSource.androidStudio,
          home: home,
          versionOutput: '${result.stderr}\n${result.stdout}',
        ),
        skipped: skipped,
      );
    }
    skipped.add(
      'Android Studio at ${studio.path} has a JDK that does not run; '
      'Flutter skips it.',
    );
  }
  final javaHome = environment.variable('JAVA_HOME');
  if (javaHome != null) {
    return JavaLookup(
      location: JavaLocation(
        javaBinary: _javaIn(javaHome, environment),
        source: JavaSource.javaHome,
        home: javaHome,
      ),
      skipped: skipped,
    );
  }
  final onPath = findExecutable('java', environment);
  return JavaLookup(
    location: onPath == null
        ? null
        : JavaLocation(javaBinary: onPath, source: JavaSource.path),
    skipped: skipped,
  );
}

/// The major Java version in `java -version` output: 21 for "21.0.2", and 8
/// for the old "1.8.0_202" style. Null when there is no version.
int? parseJavaMajor(String versionOutput) {
  final quoted = RegExp(
    r'version "(\d+)(?:\.(\d+))?',
  ).firstMatch(versionOutput);
  if (quoted != null) {
    final first = int.parse(quoted.group(1)!);
    final second = quoted.group(2);
    return first == 1 && second != null ? int.parse(second) : first;
  }
  final plain = RegExp(r'(?:openjdk|java) (\d+)').firstMatch(versionOutput);
  return plain == null ? null : int.parse(plain.group(1)!);
}

String _javaIn(String home, HostEnvironment environment) =>
    p.join(home, 'bin', environment.os == HostOs.windows ? 'java.exe' : 'java');

/// An Android Studio version, as Flutter's `Version` reads it: major, minor
/// and patch, with missing parts as 0.
typedef _Version = (int, int, int);

/// One Android Studio install that Flutter would consider.
final class _Studio {
  const _Studio(this.path, this.version);

  /// The install folder as people know it (on macOS, the `.app` bundle).
  final String path;

  /// The version, or null when Flutter can't tell.
  final _Version? version;
}

/// The installs to try, in order, and notes about installs left out before
/// trying them (Toolbox launchers).
typedef _Candidates = ({List<_Studio> studios, List<String> notes});

/// The Android Studio installs to try, in order.
Future<_Candidates> _studioCandidates(
  HostEnvironment environment,
  Map<String, Object?> settings,
  ProcessRunner runner,
  List<String>? macAppFolders,
) async {
  final configured = switch (settings['android-studio-dir']) {
    final String dir when dir.isNotEmpty => dir,
    _ => null,
  };
  if (environment.os == HostOs.macos) {
    final home = environment.homeDir;
    return _macStudioCandidates(
      configured,
      runner,
      macAppFolders ??
          ['/Applications', if (home != null) p.join(home, 'Applications')],
    );
  }
  final studios = _recordedStudios(environment);
  if (configured != null) {
    // Flutter keeps the version of a matching install record, which decides
    // between `jre` and `jbr`.
    final match = studios.where((s) => p.equals(s.path, configured));
    return (
      studios: [_Studio(configured, match.firstOrNull?.version)],
      notes: const <String>[],
    );
  }
  if (environment.os == HostOs.linux) {
    final home = environment.homeDir;
    for (final dir in [
      '/opt/android-studio',
      if (home != null) p.join(home, 'android-studio'),
    ]) {
      if (Directory(dir).existsSync() &&
          !studios.any((s) => p.equals(s.path, dir))) {
        studios.add(_Studio(dir, null));
      }
    }
  }
  return (studios: _newestFirst(studios), notes: const <String>[]);
}

/// Spotlight's query for Android Studio bundles, Preview (`-EAP`) included.
const _spotlightQuery =
    'kMDItemCFBundleIdentifier="com.google.android.studio*"';

/// The macOS installs to try, as Flutter's `_allMacOS` finds them: every
/// `Android Studio*.app` in [appFolders], then Spotlight's results. When
/// [configured] is set and isn't a Toolbox launcher, only it counts.
Future<_Candidates> _macStudioCandidates(
  String? configured,
  ProcessRunner runner,
  List<String> appFolders,
) async {
  final notes = <String>[];
  String? configuredBundle;
  if (configured != null) {
    final bundle = p.basename(configured) == 'Contents'
        ? p.dirname(configured)
        : configured;
    if (!Directory(bundle).existsSync()) {
      // locateFlutterJava reports it as a folder that does not exist.
      return (studios: [_Studio(bundle, null)], notes: notes);
    }
    final studio = await _macStudio(bundle, runner, notes);
    if (studio != null) return (studios: [studio], notes: notes);
    // A Toolbox launcher: Flutter drops it and chooses as if nothing were
    // configured.
    configuredBundle = bundle;
  }
  final bundles = <String>[];
  for (final folder in appFolders) {
    _findStudioBundles(folder, bundles);
  }
  final spotlight = await runner.run('mdfind', [_spotlightQuery]);
  if (spotlight.ok) {
    for (final line in LineSplitter.split(spotlight.stdout)) {
      // Flutter adds a result unless the scan found that exact text. A
      // bundle Spotlight still lists after it was deleted is invalid in
      // Flutter, so it is left out here.
      if (line.isEmpty ||
          bundles.contains(line) ||
          !Directory(line).existsSync()) {
        continue;
      }
      bundles.add(line);
    }
  }
  final studios = <_Studio>[];
  for (final bundle in bundles) {
    if (configuredBundle != null && p.equals(bundle, configuredBundle)) {
      continue;
    }
    final studio = await _macStudio(bundle, runner, notes);
    if (studio != null) studios.add(studio);
  }
  return (studios: _newestFirst(studios), notes: notes);
}

/// Adds to [found] every `Android Studio*.app` folder in [folder], at any
/// depth, as Flutter's `checkForStudio` does: it never looks inside an
/// `.app` bundle and doesn't follow links to folders. Names are matched
/// case-sensitively. Entries are read in name order, so "found first" is
/// the same on every file system.
void _findStudioBundles(String folder, List<String> found) {
  final List<FileSystemEntity> entries;
  try {
    final dir = Directory(folder);
    if (!dir.existsSync()) return;
    entries = dir.listSync(followLinks: false)
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  } on FileSystemException {
    return;
  }
  for (final entry in entries) {
    if (entry is! Directory) continue;
    final name = p.basename(entry.path);
    if (name.startsWith('Android Studio') && name.endsWith('.app')) {
      found.add(entry.path);
    } else if (!name.endsWith('.app')) {
      _findStudioBundles(entry.path, found);
    }
  }
}

/// The macOS install in the app [bundle], as Flutter's
/// `AndroidStudio.fromMacOSBundle` reads it, or null for a JetBrains Toolbox
/// launcher, which gets a line in [notes]. The version is the plist's
/// `CFBundleShortVersionString`.
Future<_Studio?> _macStudio(
  String bundle,
  ProcessRunner runner,
  List<String> notes,
) async {
  final plist = await _readInfoPlist(
    p.join(bundle, 'Contents', 'Info.plist'),
    runner,
  );
  if (plist != null && plist.contains('<key>JetBrainsToolboxApp</key>')) {
    notes.add(
      'Android Studio at $bundle is a JetBrains Toolbox launcher. Flutter '
      'skips it, and finds Toolbox installs only through Spotlight.',
    );
    return null;
  }
  final match = plist == null
      ? null
      : RegExp(
          r'<key>CFBundleShortVersionString</key>\s*<string>([^<]*)</string>',
        ).firstMatch(plist);
  return _Studio(
    bundle,
    match == null ? null : _parseStudioVersion(match[1]!.trim()),
  );
}

/// The Info.plist at [path] as XML, from `/usr/bin/plutil`, which reads the
/// binary plists most apps ship. When plutil can't run (on Windows and
/// Linux, in tests), the file is read as text. Null when there is no
/// readable plist: the version is then unknown, as in Flutter.
Future<String?> _readInfoPlist(String path, ProcessRunner runner) async {
  if (!File(path).existsSync()) return null;
  final xml = await runner.run('/usr/bin/plutil', [
    '-convert',
    'xml1',
    '-o',
    '-',
    path,
  ]);
  if (xml.ok) return xml.stdout;
  try {
    return File(path).readAsStringSync();
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// Orders installs the way `AndroidStudio.latestValid` prefers them: known
/// versions before unknown ones, newest version first. Equal versions keep
/// the order they were found in, because Flutter replaces its choice only
/// with a strictly newer one. Among unknown versions, the folder that sorts
/// last comes first (Flutter's rule for them).
List<_Studio> _newestFirst(List<_Studio> studios) {
  final order = [for (var i = 0; i < studios.length; i++) i];
  order.sort((i, j) {
    final (a, b) = (studios[i].version, studios[j].version);
    if (a != null && b != null) {
      final byVersion = _compareVersions(b, a);
      return byVersion != 0 ? byVersion : i.compareTo(j);
    }
    if (a != null) return -1;
    if (b != null) return 1;
    return studios[j].path.compareTo(studios[i].path);
  });
  return [for (final i in order) studios[i]];
}

int _compareVersions(_Version a, _Version b) {
  if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
  if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
  return a.$3.compareTo(b.$3);
}

/// Reads a version the way Flutter's `Version.parse` does: digits at the
/// start of [text], such as `2025.3.4`. Null when [text] doesn't start with
/// one, as in `Preview2024.2`.
_Version? _parseVersion(String text) {
  final match = RegExp(r'^(\d+)(?:\.(\d+)(?:\.(\d+))?)?').firstMatch(text);
  if (match == null) return null;
  final major = int.tryParse(match[1]!);
  final minor = int.tryParse(match[2] ?? '0');
  final patch = int.tryParse(match[3] ?? '0');
  if (major == null || minor == null || patch == null) return null;
  return (major, minor, patch);
}

/// Reads a macOS Info.plist version as Flutter's
/// `AndroidStudio._parseVersion` does. A Preview's
/// `EAP AI-242.21829.142.2422.12358220` becomes 2024.2.2, from the four
/// digits `2422`; any other count of digits there gives null. Other text is
/// read like [_parseVersion].
_Version? _parseStudioVersion(String text) {
  final eap = RegExp(
    r'EAP\s+[A-Z]{2}-\d+\.\d+\.\d+\.(\d+)\.\d+',
  ).firstMatch(text);
  if (eap == null) return _parseVersion(text);
  final digits = eap[1]!;
  if (digits.length != 4) return null;
  return (
    int.parse('20${digits.substring(0, 2)}'),
    int.parse(digits[2]),
    int.parse(digits[3]),
  );
}

/// The bundled JDK folder Flutter uses in [studio]
/// (`AndroidStudio._initAndValidate` in `android_studio.dart`): `jre` before
/// Android Studio 2022, `jbr` from then on and when the version is unknown.
String _studioJdkHome(_Studio studio, HostEnvironment environment) {
  final major = studio.version?.$1;
  if (environment.os != HostOs.macos) {
    return p.join(studio.path, major != null && major < 2022 ? 'jre' : 'jbr');
  }
  final contents = p.join(studio.path, 'Contents');
  if (major != null && major < 2020) {
    return p.join(contents, 'jre', 'jdk', 'Contents', 'Home');
  }
  if (major != null && major < 2022) {
    return p.join(contents, 'jre', 'Contents', 'Home');
  }
  return p.join(contents, 'jbr', 'Contents', 'Home');
}

/// Android Studio's settings folders: `AndroidStudio2025.3` or
/// `.AndroidStudio3.5`, with the app name and the version as groups
/// (`_dotHomeStudioVersionMatcher` in `android_studio.dart`).
final _settingsFolder = RegExp(r'^\.?(AndroidStudio[^\d]*)([\d.]+)');

/// The Android Studio installs named by the `.home` files that Android
/// Studio writes, on Windows and Linux (`_allLinuxOrWindows` in
/// `android_studio.dart`), in the order Flutter finds them:
/// - `~/.AndroidStudio*`, then `~/.cache/Google/AndroidStudio*`;
/// - `%LOCALAPPDATA%\Google\AndroidStudio*` on Windows.
///
/// When several records name one install, it keeps the newest version, as
/// Flutter does. Never throws: unreadable files and missing folders are
/// skipped.
List<_Studio> _recordedStudios(HostEnvironment environment) {
  final studios = <_Studio>[];
  void add(_Studio studio) {
    final version = studio.version;
    final alreadyFound = studios.any(
      (other) =>
          p.equals(other.path, studio.path) &&
          (version == null ||
              (other.version != null &&
                  _compareVersions(other.version!, version) >= 0)),
    );
    if (alreadyFound) return;
    studios
      ..removeWhere((other) => p.equals(other.path, studio.path))
      ..add(studio);
  }

  final home = environment.homeDir;
  if (home != null) {
    for (final parent in [home, p.join(home, '.cache', 'Google')]) {
      for (final folder in _foldersIn(parent)) {
        final match = _settingsFolder.firstMatch(p.basename(folder));
        final version = match == null ? null : _parseVersion(match[2]!);
        if (match == null || version == null) continue;
        // Android Studio 4.1 moved the record out of `system`.
        final record = version.$1 >= 4 && version.$2 >= 1
            ? p.join(folder, '.home')
            : p.join(folder, 'system', '.home');
        final install = _readInstallRecord(record);
        if (install != null) add(_Studio(install, version));
      }
    }
  }
  final localAppData = environment.variable('LOCALAPPDATA');
  if (environment.os == HostOs.windows && localAppData != null) {
    for (final folder in _foldersIn(p.join(localAppData, 'Google'))) {
      final name = p.basename(folder);
      for (final id in const ['AndroidStudio', 'AndroidStudioPreview']) {
        if (!name.startsWith(id)) continue;
        final install = _readInstallRecord(p.join(folder, '.home'));
        if (install != null) {
          add(_Studio(install, _parseVersion(name.substring(id.length))));
        }
      }
    }
  }
  return studios;
}

/// The install folder a `.home` record names, or null when the record or
/// the folder is missing or unreadable.
String? _readInstallRecord(String file) {
  try {
    final install = File(file).readAsStringSync().trim();
    return install.isNotEmpty && Directory(install).existsSync()
        ? install
        : null;
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// The folders directly inside [parent], in name order (Flutter uses the
/// file system's order, which is alphabetical on NTFS and APFS); empty when
/// it can't be listed.
List<String> _foldersIn(String parent) {
  try {
    final dir = Directory(parent);
    if (!dir.existsSync()) return const [];
    return [
      for (final entry in dir.listSync(followLinks: false))
        if (entry is Directory) entry.path,
    ]..sort((a, b) => p.basename(a).compareTo(p.basename(b)));
  } on FileSystemException {
    return const [];
  }
}
