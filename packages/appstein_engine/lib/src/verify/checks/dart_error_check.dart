import 'package:appstein_protocol/appstein_protocol.dart';

import '../../analysis/code_analysis.dart';
import '../verify_check.dart';

/// `dart.error`: every analyzer error of the project, wherever it is, in a
/// fast run too (slice 1d.2). An error in a file nobody edited is reported
/// like any other: a change to one file can break another.
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
      if (diagnostic.level == DiagnosticLevel.error)
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
