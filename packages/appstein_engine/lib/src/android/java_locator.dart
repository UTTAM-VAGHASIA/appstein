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
    this.skipped = const [],
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

  /// Why Flutter passed over Android Studio installs, one line each, newest
  /// install first.
  final List<String> skipped;
}

/// Finds the JDK Flutter uses, in Flutter's own order (`_findJavaHome` in
/// `flutter_tools/lib/src/android/java.dart`, Flutter 3.47):
/// 1. `flutter config --jdk-dir`;
/// 2. the JDK bundled with Android Studio;
/// 3. JAVA_HOME;
/// 4. `java` on PATH.
///
/// Android Studio is chosen as Flutter's `AndroidStudio.latestValid` chooses
/// it:
/// - when the `android-studio-dir` setting is set, only that install counts;
/// - otherwise the installs Flutter knows about are tried newest version
///   first. They are the ones named by Android Studio's install records (the
///   `.home` files it writes), plus `/opt/android-studio` and
///   `~/android-studio` on Linux and `Android Studio.app` in `/Applications`
///   and `~/Applications` on macOS.
///
/// An install counts only if its bundled `java -version`, run with [runner],
/// succeeds. The installs passed over are listed in [JavaLocation.skipped].
/// JetBrains Toolbox installs are not searched.
Future<JavaLocation?> locateFlutterJava(
  HostEnvironment environment,
  Map<String, Object?> settings,
  ProcessRunner runner,
) async {
  final configured = settings['jdk-dir'];
  if (configured is String && configured.isNotEmpty) {
    return JavaLocation(
      javaBinary: _javaIn(configured, environment),
      source: JavaSource.flutterConfig,
      home: configured,
    );
  }
  final skipped = <String>[];
  for (final studio in _studioCandidates(environment, settings)) {
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
      return JavaLocation(
        javaBinary: java,
        source: JavaSource.androidStudio,
        home: home,
        versionOutput: '${result.stderr}\n${result.stdout}',
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
    return JavaLocation(
      javaBinary: _javaIn(javaHome, environment),
      source: JavaSource.javaHome,
      home: javaHome,
      skipped: skipped,
    );
  }
  final onPath = findExecutable('java', environment);
  return onPath == null
      ? null
      : JavaLocation(
          javaBinary: onPath,
          source: JavaSource.path,
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
  const _Studio(this.path, this.version, {this.preview = false});

  /// The install folder as people know it (on macOS, the `.app` bundle).
  final String path;

  /// The version, or null when Flutter can't tell.
  final _Version? version;

  /// Whether the install record names a Preview build.
  final bool preview;
}

/// The Android Studio installs to try, in order.
List<_Studio> _studioCandidates(
  HostEnvironment environment,
  Map<String, Object?> settings,
) {
  final configured = switch (settings['android-studio-dir']) {
    final String dir when dir.isNotEmpty => dir,
    _ => null,
  };
  if (environment.os == HostOs.macos) {
    if (configured != null) return [_macStudio(configured)];
    final home = environment.homeDir;
    return _newestFirst([
      for (final app in [
        '/Applications/Android Studio.app',
        if (home != null) p.join(home, 'Applications', 'Android Studio.app'),
      ])
        if (Directory(app).existsSync()) _macStudio(app),
    ]);
  }
  final studios = _recordedStudios(environment);
  if (configured != null) {
    // Flutter keeps the version of a matching install record, which decides
    // between `jre` and `jbr`.
    final match = studios.where((s) => p.equals(s.path, configured));
    return [_Studio(configured, match.firstOrNull?.version)];
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
  return _newestFirst(studios);
}

/// Orders installs the way `AndroidStudio.latestValid` prefers them: known
/// versions before unknown ones, newest version first. Flutter has no rule
/// for equal versions; here a release comes before a Preview, then the
/// folder that sorts last comes first (Flutter's rule for unknown versions).
List<_Studio> _newestFirst(List<_Studio> studios) =>
    studios.toList()..sort((a, b) {
      final (aVersion, bVersion) = (a.version, b.version);
      if (aVersion != null && bVersion != null) {
        final byVersion = _compareVersions(bVersion, aVersion);
        if (byVersion != 0) return byVersion;
        if (a.preview != b.preview) return a.preview ? 1 : -1;
      } else if (aVersion != null) {
        return -1;
      } else if (bVersion != null) {
        return 1;
      }
      return b.path.compareTo(a.path);
    });

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

/// A macOS install at [path], which may name the `.app` bundle or its
/// `Contents` folder. Its version comes from the bundle's `Info.plist`, as
/// in Flutter's `AndroidStudio.fromMacOSBundle`.
_Studio _macStudio(String path) {
  final bundle = p.basename(path) == 'Contents' ? p.dirname(path) : path;
  _Version? version;
  try {
    final plist = File(
      p.join(bundle, 'Contents', 'Info.plist'),
    ).readAsStringSync();
    final match = RegExp(
      r'<key>CFBundleShortVersionString</key>\s*<string>([^<]*)</string>',
    ).firstMatch(plist);
    if (match != null) version = _parseVersion(match[1]!.trim());
  } on FileSystemException {
    // No readable Info.plist: the version is unknown, as in Flutter.
  } on FormatException {
    // A binary Info.plist: the version is unknown here.
  }
  return _Studio(bundle, version);
}

/// Android Studio's settings folders: `AndroidStudio2025.3` or
/// `.AndroidStudio3.5`, with the app name and the version as groups
/// (`_dotHomeStudioVersionMatcher` in `android_studio.dart`).
final _settingsFolder = RegExp(r'^\.?(AndroidStudio[^\d]*)([\d.]+)');

/// The Android Studio installs named by the `.home` files that Android
/// Studio writes, on Windows and Linux (`_allLinuxOrWindows` in
/// `android_studio.dart`):
/// - `~/.AndroidStudio*` and `~/.cache/Google/AndroidStudio*`;
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
        if (install != null) {
          add(
            _Studio(install, version, preview: match[1]!.contains('Preview')),
          );
        }
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
          add(
            _Studio(
              install,
              _parseVersion(name.substring(id.length)),
              preview: id == 'AndroidStudioPreview',
            ),
          );
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

/// The folders directly inside [parent]; empty when it can't be listed.
List<String> _foldersIn(String parent) {
  try {
    final dir = Directory(parent);
    if (!dir.existsSync()) return const [];
    return [
      for (final entry in dir.listSync(followLinks: false))
        if (entry is Directory) entry.path,
    ];
  } on FileSystemException {
    return const [];
  }
}
