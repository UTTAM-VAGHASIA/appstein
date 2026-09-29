import '../../host/host_environment.dart';
import '../check_helpers.dart';
import '../doctor_check.dart';

/// Checks CocoaPods on macOS. Swift Package Manager is the default now, but
/// plugins without SwiftPM support still need CocoaPods.
final class CocoaPodsCheck implements DoctorCheck {
  /// Creates the check.
  const CocoaPodsCheck();

  @override
  String get id => 'doctor.cocoapods';

  @override
  String get title => 'CocoaPods';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    if (context.environment.os != HostOs.macos) {
      return const CheckResult.skipped('Only used for iOS builds on macOS.');
    }
    final result = await context.runner.run('pod', ['--version']);
    if (!result.ok) {
      return const CheckResult.warning(
        'CocoaPods not found. Plugins without Swift Package Manager support '
        'still need it (CocoaPods trunk becomes read-only on 2026-12-02).',
        fixHint: 'brew install cocoapods',
      );
    }
    return CheckResult.ok('CocoaPods ${firstLine(result.stdout)}');
  }
}
