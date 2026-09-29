import 'package:path/path.dart' as p;

import '../../host/executable_finder.dart';
import '../../host/file_links.dart';
import '../../sdk/flutter_sdk_locator.dart';
import '../doctor_check.dart';

/// Reports the Dart SDK bundled with Flutter, and warns when the `dart` on
/// PATH belongs to a different SDK.
final class DartCheck implements DoctorCheck {
  /// Creates the check.
  const DartCheck();

  @override
  String get id => 'doctor.dart';

  @override
  String get title => 'Dart SDK';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final info = context.sdk.info;
    final location = context.sdk.location;
    if (info == null || location == null) {
      return const CheckResult.skipped('Needs a Flutter SDK (see above).');
    }
    final summary = 'Dart ${info.dartVersion} (bundled with Flutter)';
    final pathDart = findExecutable('dart', context.environment);
    if (pathDart != null) {
      final root = resolveLinks(location.root);
      final dart = resolveLinks(pathDart);
      if (!p.isWithin(root, dart)) {
        final yourCommand = location.source == SdkSource.fvm
            ? '`fvm dart`'
            : 'the `dart` inside ${location.root}';
        return CheckResult.info(
          summary,
          details: [
            '`dart` on PATH is $pathDart, from a different SDK. Appstein always '
                'uses the project\'s SDK; when you run Dart yourself, use '
                '$yourCommand.',
          ],
        );
      }
    }
    return CheckResult.ok(summary);
  }
}
