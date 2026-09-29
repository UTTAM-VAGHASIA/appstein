import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/executable_finder.dart';
import '../host/host_environment.dart';

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
  });

  /// The `java` executable.
  final String javaBinary;

  /// Where it came from.
  final JavaSource source;

  /// The JDK folder, when known.
  final String? home;
}

/// Finds the JDK Flutter uses, in Flutter's own order (`_findJavaHome` in
/// `flutter_tools/lib/src/android/java.dart`, Flutter 3.47):
/// 1. `flutter config --jdk-dir`;
/// 2. Android Studio's bundled JDK;
/// 3. JAVA_HOME;
/// 4. `java` on PATH.
///
/// Android Studio is looked for, in order, in the `android-studio-dir`
/// setting, in Flutter's install records (the `.home` files Android Studio
/// writes), and in the default install folders. JetBrains Toolbox installs
/// are not searched.
JavaLocation? locateFlutterJava(
  HostEnvironment environment,
  Map<String, Object?> settings,
) {
  final configured = settings['jdk-dir'];
  if (configured is String && configured.isNotEmpty) {
    return JavaLocation(
      javaBinary: _javaIn(configured, environment),
      source: JavaSource.flutterConfig,
      home: configured,
    );
  }
  final studioJdk = _androidStudioJdk(environment, settings);
  if (studioJdk != null) {
    return JavaLocation(
      javaBinary: _javaIn(studioJdk, environment),
      source: JavaSource.androidStudio,
      home: studioJdk,
    );
  }
  final javaHome = environment.variable('JAVA_HOME');
  if (javaHome != null) {
    return JavaLocation(
      javaBinary: _javaIn(javaHome, environment),
      source: JavaSource.javaHome,
      home: javaHome,
    );
  }
  final onPath = findExecutable('java', environment);
  return onPath == null
      ? null
      : JavaLocation(javaBinary: onPath, source: JavaSource.path);
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

String? _androidStudioJdk(
  HostEnvironment environment,
  Map<String, Object?> settings,
) {
  final studioDirs = <String>[
    if (settings['android-studio-dir'] case final String dir) dir,
    ..._recordedStudioDirs(environment),
    ..._defaultStudioDirs(environment),
  ];
  for (final studio in studioDirs) {
    for (final home in _jdkHomesIn(studio, environment)) {
      if (File(_javaIn(home, environment)).existsSync()) return home;
    }
  }
  return null;
}

/// The JDK folders Flutter looks at inside an Android Studio install
/// (`AndroidStudio._initAndValidate` in `android_studio.dart`), newest first.
List<String> _jdkHomesIn(String studio, HostEnvironment environment) {
  if (environment.os != HostOs.macos) {
    return [p.join(studio, 'jbr'), p.join(studio, 'jre')];
  }
  // Flutter works inside `Contents`; accept the `.app` folder or `Contents`.
  final contents = p.basename(studio) == 'Contents'
      ? studio
      : p.join(studio, 'Contents');
  return [
    p.join(contents, 'jbr', 'Contents', 'Home'),
    p.join(contents, 'jre', 'Contents', 'Home'),
    p.join(contents, 'jre', 'jdk', 'Contents', 'Home'),
  ];
}

/// Android Studio install folders named by the `.home` files that Android
/// Studio writes (`_allLinuxOrWindows` in `android_studio.dart`):
/// - `~/.cache/Google/AndroidStudio*/.home` and
///   `~/.AndroidStudio*/system/.home` on Windows and Linux;
/// - `%LOCALAPPDATA%\Google\AndroidStudio*\.home` on Windows.
///
/// Never throws: unreadable files and missing folders are skipped.
List<String> _recordedStudioDirs(HostEnvironment environment) {
  if (environment.os == HostOs.macos) return const [];
  final homeFiles = <String>[];
  final home = environment.homeDir;
  if (home != null) {
    for (final dir in _studioFoldersIn(home)) {
      homeFiles.add(p.join(dir, 'system', '.home'));
    }
    for (final dir in _studioFoldersIn(p.join(home, '.cache', 'Google'))) {
      homeFiles.add(p.join(dir, '.home'));
    }
  }
  final localAppData = environment.variable('LOCALAPPDATA');
  if (environment.os == HostOs.windows && localAppData != null) {
    for (final dir in _studioFoldersIn(p.join(localAppData, 'Google'))) {
      homeFiles.add(p.join(dir, '.home'));
    }
  }
  final result = <String>[];
  for (final file in homeFiles) {
    try {
      final install = File(file).readAsStringSync().trim();
      if (install.isNotEmpty && Directory(install).existsSync()) {
        result.add(install);
      }
    } on FileSystemException {
      continue;
    } on FormatException {
      continue;
    }
  }
  return result;
}

/// Folders in [parent] named like Android Studio's settings folders
/// (`AndroidStudio*` or `.AndroidStudio*`), newest name first.
List<String> _studioFoldersIn(String parent) {
  try {
    final dir = Directory(parent);
    if (!dir.existsSync()) return const [];
    final names =
        dir
            .listSync(followLinks: false)
            .whereType<Directory>()
            .map((d) => d.path)
            .where(
              (path) => RegExp(r'^\.?AndroidStudio').hasMatch(p.basename(path)),
            )
            .toList()
          ..sort((a, b) => p.basename(b).compareTo(p.basename(a)));
    return names;
  } on FileSystemException {
    return const [];
  }
}

List<String> _defaultStudioDirs(HostEnvironment environment) {
  final home = environment.homeDir;
  return switch (environment.os) {
    HostOs.windows => [
      p.join(
        environment.variable('ProgramFiles') ?? r'C:\Program Files',
        'Android',
        'Android Studio',
      ),
    ],
    HostOs.macos => [
      '/Applications/Android Studio.app',
      if (home != null) p.join(home, 'Applications', 'Android Studio.app'),
    ],
    HostOs.linux => [
      '/opt/android-studio',
      if (home != null) p.join(home, 'android-studio'),
    ],
  };
}
