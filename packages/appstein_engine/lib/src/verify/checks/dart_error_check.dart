import 'package:appstein_protocol/appstein_protocol.dart';

import '../deprecation_ignores.dart';
import '../verify_check.dart';

/// `dart.error`: every analyzer error of the project, wherever it is, in a
/// fast run too (slice 1d.2). An error in a file nobody edited is reported
/// like any other: a change to one file can break another.
///
/// One kind of error is left to another check: the use of a deprecated API
/// that `analysis_options.yaml` raised to an error (`isDeprecatedUseCode`)
/// is a `dart.deprecated` finding, and is not reported here as well.
///
/// It reports what `dart analyze` shows as an error, so also an error in a
/// file the analyzer reads that isn't Dart, such as `analysis_options.yaml`
/// or `pubspec.yaml`.
///
/// Each finding carries the analyzer's message and its code, such as
/// `undefined_method`, and what the analyzer suggests as the fix hint.
final class DartErrorCheck implements GatheringCheck {
  /// Creates the check.
  const DartErrorCheck();

  @override
  List<String> get ids => const ['dart.error'];

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  bool get needsMap => false;

  @override
  Future<void> gather(VerifyGathering gathering) => gathering.code();

  @override
  Future<List<Finding>> run(VerifyContext context) async => [
    for (final diagnostic in context.code.diagnostics)
      // A deprecated use the project raised to an error is reported once,
      // by `dart.deprecated`.
      if (diagnostic.level == DiagnosticLevel.error &&
          !isDeprecatedUseCode(diagnostic.code))
        Finding(
          id: 'dart.error',
          severity: Severity.error,
          file: diagnostic.file,
          line: diagnostic.line,
          message: '${diagnostic.message} (`${diagnostic.code}`)',
          fixHint: diagnostic.correction,
        ),
  ];
}
