import 'package:path/path.dart' as p;

import '../../host/executable_finder.dart';
import '../../sdk/fvm_pin.dart';
import '../doctor_check.dart';

/// Checks FVM when the project pins a Flutter version with it.
final class FvmCheck implements DoctorCheck {
  /// Creates the check.
  const FvmCheck();

  @override
  String get id => 'doctor.fvm';

  @override
  String get title => 'FVM';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final fvm = findExecutable('fvm', context.environment);
    final root = context.projectRoot;
    FvmPin? pin;
    if (root != null) {
      try {
        pin = readFvmPin(root);
      } on FormatException catch (error) {
        return CheckResult.error(
          error.message,
          fixHint: 'Run `fvm use <version>` to rewrite the pin.',
        );
      }
    }
    if (pin == null) {
      return fvm == null
          ? const CheckResult.skipped('Not used by this project.')
          : CheckResult.info(
              'FVM is installed; this project does not pin a Flutter version.',
              details: ['fvm: $fvm'],
            );
    }
    if (fvm == null) {
      return CheckResult.warning(
        'The project pins Flutter ${pin.version} with FVM, but `fvm` is not '
        'on PATH.',
        fixHint:
            'Install FVM (https://fvm.app) so `fvm flutter` and '
            '`fvm dart` work.',
      );
    }
    return CheckResult.ok(
      'Project pins Flutter ${pin.version} (${p.basename(pin.configPath)})',
      details: ['fvm: $fvm'],
    );
  }
}
