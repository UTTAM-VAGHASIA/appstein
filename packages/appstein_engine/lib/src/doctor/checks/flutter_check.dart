import 'package:pub_semver/pub_semver.dart';

import '../../sdk/supported_versions.dart';
import '../doctor_check.dart';

/// Checks that the project's Flutter SDK is found and supported.
final class FlutterCheck implements DoctorCheck {
  /// Creates the check.
  const FlutterCheck();

  @override
  String get id => 'doctor.flutter';

  @override
  String get title => 'Flutter SDK';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final sdk = context.sdk;
    final info = sdk.info;
    final location = sdk.location;
    if (info == null || location == null) {
      return CheckResult.error(sdk.problem!, fixHint: sdk.fixHint);
    }
    final details = [
      'Found through ${location.source.label}: ${location.root}',
      if (location.unmetFvmPin case final pin?)
        'The project pins $pin with FVM; FVM does not have it, so this '
            'matching Flutter is used.',
    ];
    final label = 'Flutter ${info.flutterVersion} (${info.channel})';
    final Version version;
    try {
      version = Version.parse(info.flutterVersion);
    } on FormatException {
      return CheckResult.warning(
        '$label: this version number is unreadable.',
        details: details,
        fixHint: 'Use a stable Flutter release.',
      );
    }
    if (version < minSupportedFlutter) {
      return CheckResult.error(
        'Flutter ${info.flutterVersion} is older than $minSupportedFlutter, '
        'the oldest version Appstein supports.',
        details: details,
        fixHint:
            'Upgrade Flutter. With FVM: `fvm install <version>` then '
            '`fvm use <version>`.',
      );
    }
    final newest = Version.parse('$newestKnownFlutterMinor.0');
    if (version.major > newest.major ||
        (version.major == newest.major && version.minor > newest.minor)) {
      return CheckResult.info(
        label,
        details: [
          ...details,
          'Newer than $newestKnownFlutterMinor, the newest version this '
              'Appstein was built for. Version notes may be incomplete.',
        ],
      );
    }
    if (info.channel != 'stable') {
      return CheckResult.warning(
        label,
        details: details,
        fixHint:
            'Appstein targets the stable channel. Pin a stable version '
            'with FVM or run `flutter channel stable`.',
      );
    }
    return CheckResult.ok(label, details: details);
  }
}
