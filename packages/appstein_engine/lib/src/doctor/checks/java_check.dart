import 'dart:io';

import 'package:path/path.dart' as p;

import '../../android/flutter_settings.dart';
import '../../android/java_locator.dart';
import '../../host/host_environment.dart';
import '../check_helpers.dart';
import '../doctor_check.dart';

/// Checks the JDK Flutter actually uses for Android builds, and whether
/// JAVA_HOME names a JDK of another version.
final class JavaCheck implements DoctorCheck {
  /// Creates the check.
  const JavaCheck();

  /// The oldest JDK that current Android Gradle Plugin versions accept.
  static const minimumMajor = 17;

  /// The fix for a `jdk-dir` setting Flutter can't use.
  static const _fixJdkDir =
      'Run `flutter config --jdk-dir="<path to a JDK $minimumMajor+>"`, or '
      '`flutter config --jdk-dir=""` to remove the setting.';

  @override
  String get id => 'doctor.java';

  @override
  String get title => 'JDK used by Flutter';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final environment = context.environment;
    final settings = readFlutterSettings(environment);
    // Flutter stops with a tool error when this setting names a missing
    // folder (`AndroidStudio._configuredDir`), whatever JDK it would use.
    final studioDir = settings['android-studio-dir'];
    if (studioDir is String &&
        studioDir.isNotEmpty &&
        !Directory(studioDir).existsSync()) {
      return CheckResult.error(
        'Flutter stops: `android-studio-dir` points to $studioDir, which '
        'does not exist.',
        fixHint:
            'Fix the path with `flutter config --android-studio-dir '
            '"<path>"`, or clear it with '
            '`flutter config --android-studio-dir ""`.',
      );
    }
    // Flutter uses any text in jdk-dir as the JDK folder, and stops with an
    // error on anything else (`_findJavaHome` in `java.dart`).
    final jdkDir = settings['jdk-dir'];
    if (jdkDir != null && jdkDir is! String) {
      return CheckResult.error(
        'jdk-dir in ${flutterSettingsPath(environment)} is not text.',
        details: const [
          'Flutter stops with an error when it reads this setting.',
        ],
        fixHint: _fixJdkDir,
      );
    }
    if (jdkDir == '') {
      return const CheckResult.error(
        "Flutter's jdk-dir setting is empty, so Flutter can't find a JDK.",
        details: [
          'Flutter treats the empty value as a JDK folder, and looks for '
              'bin/java relative to the folder it runs in.',
        ],
        fixHint: _fixJdkDir,
      );
    }
    final lookup = await locateFlutterJava(
      environment,
      settings,
      context.runner,
    );
    final java = lookup.location;
    const pointFlutter =
        'Point Flutter at a working JDK $minimumMajor or '
        'newer: `flutter config --jdk-dir "<path to the JDK>"`.';
    if (java == null) {
      return CheckResult.error(
        'No JDK found. Android builds need JDK $minimumMajor or newer.',
        details: lookup.skipped,
        fixHint:
            'Install JDK $minimumMajor or newer, then set JAVA_HOME or '
            'run `flutter config --jdk-dir "<path>"`.',
      );
    }
    final where = '${java.source.label} (${java.home ?? java.javaBinary})';
    final found = ['Path: ${java.home ?? java.javaBinary}', ...lookup.skipped];
    final details = [
      ...found,
      'Flutter checks, in order: `flutter config --jdk-dir`, the newest '
          'Android Studio whose JDK runs, JAVA_HOME, then `java` on PATH.',
    ];
    var versionOutput = java.versionOutput;
    if (versionOutput == null) {
      final result = await context.runner.run(java.javaBinary, ['-version']);
      if (!result.ok) {
        final reason = firstLine(result.stderr);
        return CheckResult.error(
          'Flutter uses $where, but it does not run: '
          '${reason.isEmpty ? 'exit code ${result.exitCode}' : reason}',
          details: details,
          fixHint: pointFlutter,
        );
      }
      versionOutput = '${result.stderr}\n${result.stdout}';
    }
    final major = parseJavaMajor(versionOutput);
    if (major == null) {
      return CheckResult.warning(
        'Could not read the version of $where.',
        details: details,
        fixHint: pointFlutter,
      );
    }
    if (major < minimumMajor) {
      return CheckResult.error(
        'Flutter uses JDK $major from $where; Android builds need '
        '$minimumMajor or newer.',
        details: details,
        fixHint: pointFlutter,
      );
    }
    final javaHome = environment.variable('JAVA_HOME');
    final home = java.home;
    if (java.source != JavaSource.javaHome &&
        javaHome != null &&
        (home == null || !p.equals(javaHome, home))) {
      final javaHomeMajor = await _majorOf(javaHome, context);
      if (javaHomeMajor == major) {
        return CheckResult.info(
          'JDK $major from ${java.source.label}; JAVA_HOME points to another '
          'JDK $major ($javaHome).',
          details: found,
        );
      }
      final javaHomeJdk = javaHomeMajor == null
          ? javaHome
          : 'JDK $javaHomeMajor ($javaHome)';
      return CheckResult.warning(
        'Flutter uses JDK $major from $where, but JAVA_HOME points to '
        '$javaHomeJdk.',
        details: details,
        fixHint:
            'Gradle run outside Flutter (such as ./gradlew) uses '
            'JAVA_HOME, so builds can behave differently. Point both at one '
            'JDK: `flutter config --jdk-dir "$javaHome"`, or change JAVA_HOME.',
      );
    }
    return CheckResult.ok(
      'JDK $major from ${java.source.label}',
      details: found,
    );
  }

  /// The major version of the JDK in [jdkHome], or null when it doesn't run
  /// or prints no version.
  static Future<int?> _majorOf(String jdkHome, DoctorContext context) async {
    final java = p.join(
      jdkHome,
      'bin',
      context.environment.os == HostOs.windows ? 'java.exe' : 'java',
    );
    final result = await context.runner.run(java, ['-version']);
    return result.ok
        ? parseJavaMajor('${result.stderr}\n${result.stdout}')
        : null;
  }
}
