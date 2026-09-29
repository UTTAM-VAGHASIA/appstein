import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../../android/android_sdk_locator.dart';
import '../../android/flutter_settings.dart';
import '../../host/host_environment.dart';
import '../doctor_check.dart';

/// Checks the Android SDK: build-tools, including `zipalign` for the 16 KB
/// page-size check, and `platform-tools`.
final class AndroidSdkCheck implements DoctorCheck {
  /// Creates the check.
  const AndroidSdkCheck();

  @override
  String get id => 'doctor.android_sdk';

  @override
  String get title => 'Android SDK';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final environment = context.environment;
    final sdk = locateAndroidSdk(environment, readFlutterSettings(environment));
    if (sdk == null) {
      return const CheckResult.error(
        'No Android SDK found.',
        fixHint:
            'Install Android Studio or the command-line tools, then '
            'run `flutter config --android-sdk "<path>"` or set ANDROID_HOME.',
      );
    }
    final details = ['Path: $sdk'];
    final buildTools = _newestBuildTools(sdk);
    if (buildTools == null) {
      return CheckResult.error(
        'The Android SDK has no build-tools.',
        details: details,
        fixHint:
            'Install the latest build-tools in Android Studio '
            '(SDK Manager, SDK Tools tab).',
      );
    }
    final problems = <String>[];
    final zipalign = environment.os == HostOs.windows
        ? 'zipalign.exe'
        : 'zipalign';
    if (!File(p.join(buildTools.path, zipalign)).existsSync()) {
      problems.add(
        'build-tools ${buildTools.version} has no zipalign, so the '
        '16 KB page-size check will be skipped.',
      );
    }
    if (!Directory(p.join(sdk, 'platform-tools')).existsSync()) {
      problems.add(
        "platform-tools (adb) is missing, so apps can't be "
        'installed on devices.',
      );
    }
    if (problems.isNotEmpty) {
      return CheckResult.warning(
        'Android SDK with build-tools ${buildTools.version}, but with gaps',
        details: [...details, ...problems],
        fixHint:
            'Install the missing parts in Android Studio '
            '(SDK Manager, SDK Tools tab).',
      );
    }
    return CheckResult.ok(
      'Android SDK with build-tools ${buildTools.version}',
      details: details,
    );
  }

  /// The newest stable build-tools, or the newest preview when there is no
  /// stable one.
  ({Version version, String path})? _newestBuildTools(String sdk) {
    final dir = Directory(p.join(sdk, 'build-tools'));
    if (!dir.existsSync()) return null;
    final all = <({Version version, String path})>[];
    for (final entry in dir.listSync().whereType<Directory>()) {
      try {
        all.add((
          version: Version.parse(p.basename(entry.path)),
          path: entry.path,
        ));
      } on FormatException {
        continue;
      }
    }
    if (all.isEmpty) return null;
    all.sort((a, b) => a.version.compareTo(b.version));
    final stable = all.where((b) => !b.version.isPreRelease);
    return stable.isNotEmpty ? stable.last : all.last;
  }
}
