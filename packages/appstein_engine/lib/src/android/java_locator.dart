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
/// Flutter finds Android Studio through its install records. This checks the
/// `android-studio-dir` setting and the default install folders, which covers
/// standard installs.
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
    ..._defaultStudioDirs(environment),
  ];
  for (final studio in studioDirs) {
    final homes = environment.os == HostOs.macos
        ? [
            p.join(studio, 'Contents', 'jbr', 'Contents', 'Home'),
            p.join(studio, 'jbr', 'Contents', 'Home'),
          ]
        : [p.join(studio, 'jbr'), p.join(studio, 'jre')];
    for (final home in homes) {
      if (File(_javaIn(home, environment)).existsSync()) return home;
    }
  }
  return null;
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
    HostOs.macos => ['/Applications/Android Studio.app'],
    HostOs.linux => [
      '/opt/android-studio',
      if (home != null) p.join(home, 'android-studio'),
    ],
  };
}
