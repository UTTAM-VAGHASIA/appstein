import '../../host/host_environment.dart';
import '../../sdk/supported_versions.dart';
import '../check_helpers.dart';
import '../doctor_check.dart';

/// Checks Xcode on macOS. App Store uploads need Xcode 26 or newer.
final class XcodeCheck implements DoctorCheck {
  /// Creates the check.
  const XcodeCheck();

  @override
  String get id => 'doctor.xcode';

  @override
  String get title => 'Xcode';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    if (context.environment.os != HostOs.macos) {
      return const CheckResult.skipped(
        'iOS builds need macOS. On this '
        'machine iOS checks are static; CI builds iOS on macOS.',
      );
    }
    final result = await context.runner.run('xcodebuild', ['-version']);
    if (!result.ok) {
      return const CheckResult.error(
        'Xcode not found.',
        fixHint:
            'Install Xcode $minimumXcodeMajor or newer from the App '
            'Store, then run `sudo xcode-select -s /Applications/Xcode.app`.',
      );
    }
    final match = RegExp(r'Xcode (\d+)(?:\.\d+)*').firstMatch(result.stdout);
    if (match == null) {
      return CheckResult.warning(
        'Could not read the Xcode version.',
        details: [firstLine(result.stdout)],
      );
    }
    final version = match.group(0)!;
    if (int.parse(match.group(1)!) < minimumXcodeMajor) {
      return CheckResult.error(
        '$version is too old: App Store uploads need Xcode '
        '$minimumXcodeMajor or newer (since 2026-04-28).',
        fixHint: 'Update Xcode from the App Store.',
      );
    }
    return CheckResult.ok(version);
  }
}
