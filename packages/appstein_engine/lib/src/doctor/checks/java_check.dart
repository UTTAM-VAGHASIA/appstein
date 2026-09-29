import 'package:path/path.dart' as p;

import '../../android/flutter_settings.dart';
import '../../android/java_locator.dart';
import '../check_helpers.dart';
import '../doctor_check.dart';

/// Checks the JDK Flutter actually uses for Android builds.
final class JavaCheck implements DoctorCheck {
  /// Creates the check.
  const JavaCheck();

  /// The oldest JDK that current Android Gradle Plugin versions accept.
  static const minimumMajor = 17;

  @override
  String get id => 'doctor.java';

  @override
  String get title => 'JDK used by Flutter';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final environment = context.environment;
    final java = locateFlutterJava(
      environment,
      readFlutterSettings(environment),
    );
    const pointFlutter =
        'Point Flutter at a working JDK $minimumMajor or '
        'newer: `flutter config --jdk-dir "<path to the JDK>"`.';
    if (java == null) {
      return const CheckResult.error(
        'No JDK found. Android builds need JDK $minimumMajor or newer.',
        fixHint:
            'Install JDK $minimumMajor or newer, then set JAVA_HOME or '
            'run `flutter config --jdk-dir "<path>"`.',
      );
    }
    final where = '${java.source.label} (${java.home ?? java.javaBinary})';
    final details = [
      'Flutter checks, in order: `flutter config --jdk-dir`, '
          "Android Studio's JDK, JAVA_HOME, then `java` on PATH.",
    ];
    final result = await context.runner.run(java.javaBinary, ['-version']);
    if (!result.ok) {
      final reason = firstLine(result.stderr);
      return CheckResult.error(
        'Flutter uses $where, but it does not run: '
        '${reason.isEmpty ? 'exit code ${result.exitCode}' : reason}',
        details: details,
        fixHint: java.source == JavaSource.androidStudio
            ? 'Repair or reinstall Android Studio, or: $pointFlutter'
            : pointFlutter,
      );
    }
    final major = parseJavaMajor('${result.stderr}\n${result.stdout}');
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
      return CheckResult.warning(
        'Flutter uses JDK $major from $where, but JAVA_HOME points to '
        '$javaHome.',
        details: details,
        fixHint:
            'Gradle run outside Flutter (such as ./gradlew) uses '
            'JAVA_HOME, so builds can behave differently. Point both at one '
            'JDK: `flutter config --jdk-dir "$javaHome"`, or change JAVA_HOME.',
      );
    }
    return CheckResult.ok(
      'JDK $major from ${java.source.label}',
      details: ['Path: ${java.home ?? java.javaBinary}'],
    );
  }
}
