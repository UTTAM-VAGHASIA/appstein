import 'dart:io';

import 'package:path/path.dart' as p;

import '../../android/android_sdk_contents.dart';
import '../../android/android_sdk_locator.dart';
import '../../android/flutter_settings.dart';
import '../../host/host_environment.dart';
import '../doctor_check.dart';

/// Checks the Android SDK as Flutter reads it: the newest platform, the
/// build-tools Flutter pairs with it, `zipalign` in those build-tools for
/// the 16 KB page-size check, and `platform-tools`.
///
/// The summary names the platform and build-tools in the words
/// `flutter doctor -v` uses, so the two can be compared.
final class AndroidSdkCheck implements DoctorCheck {
  /// Creates the check.
  const AndroidSdkCheck();

  @override
  String get id => 'doctor.android_sdk';

  @override
  String get title => 'Android SDK';

  static const _pairing =
      'Flutter pairs the newest platform with the newest build-tools of the '
      'same major version, previews included, or else with the newest '
      'build-tools.';

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
    final contents = readAndroidSdkContents(sdk);
    final details = [
      'Path: $sdk',
      if (contents.ignoredPlatforms.isNotEmpty)
        'Flutter ignores these platform folders, because it finds no API '
            'level in them: ${contents.ignoredPlatforms.join(', ')}.',
    ];
    if (contents.buildTools.isEmpty) {
      return CheckResult.error(
        'The Android SDK has no build-tools.',
        details: details,
        fixHint:
            'Install build-tools with `sdkmanager "build-tools;<version>"`, '
            'or in Android Studio (SDK Manager, SDK Tools tab).',
      );
    }
    final platform = contents.latestPlatform;
    final buildTools = contents.buildToolsForLatest;
    if (platform == null || buildTools == null) {
      return CheckResult.error(
        "The Android SDK has no platforms, so Flutter can't build for "
        'Android.',
        details: details,
        fixHint:
            'Install a platform with '
            '`sdkmanager "platforms;android-<API level>"`, or in Android '
            'Studio (SDK Manager, SDK Platforms tab).',
      );
    }
    details.add(_pairing);
    final pair = 'platform ${platform.name}, build-tools ${buildTools.text}';
    final problems = <String>[];
    final toolsDir = p.join(sdk, 'build-tools', buildTools.text);
    final zipalign = environment.os == HostOs.windows
        ? 'zipalign.exe'
        : 'zipalign';
    if (!Directory(toolsDir).existsSync()) {
      problems.add(
        'build-tools/${buildTools.text} is not a folder, but Flutter still '
        'picks it. Remove it, or reinstall build-tools ${buildTools.text}.',
      );
    } else if (!File(p.join(toolsDir, zipalign)).existsSync()) {
      problems.add(
        'build-tools ${buildTools.text} has no zipalign, so the '
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
        '$pair, but with gaps',
        details: [...details, ...problems],
        fixHint:
            'Install the missing parts in Android Studio '
            '(SDK Manager, SDK Tools tab).',
      );
    }
    return CheckResult.ok(pair, details: details);
  }
}
