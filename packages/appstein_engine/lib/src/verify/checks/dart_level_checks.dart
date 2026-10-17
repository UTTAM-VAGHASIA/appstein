import 'package:appstein_protocol/appstein_protocol.dart';

import '../deprecation_ignores.dart';
import '../verify_check.dart';

/// `dart.warning`: each analyzer warning, as a warning (slice 1d.2, spec
/// §9.1). A full run reports every one in the project; a fast run only those
/// on the unverified files ([VerifyContext.unverified]), so an agent isn't
/// shown old warnings in files it never touched.
///
/// A diagnostic of an analyzer plugin is reported the same way, by its
/// level, until slice 1d.3 gives the rules their own IDs. The use of a
/// deprecated API is left to `dart.deprecated` (`isDeprecatedUseCode`),
/// whatever its level.
final class DartWarningCheck extends _DartLevelCheck {
  /// Creates the check.
  const DartWarningCheck()
    : super('dart.warning', DiagnosticLevel.warning, Severity.warning);
}

/// `dart.lint`: each info-level diagnostic of the analyzer (most lints, and
/// hints), as an info finding (slice 1d.2, spec §9.1). A full run reports
/// every one in the project; a fast run only those on the unverified files
/// ([VerifyContext.unverified]).
///
/// A diagnostic of an analyzer plugin is reported the same way, by its
/// level. The use of a deprecated API is left to `dart.deprecated`, and a
/// `TODO` the analyzer notes is not in the reading (`CodeReading`).
final class DartLintCheck extends _DartLevelCheck {
  /// Creates the check.
  const DartLintCheck()
    : super('dart.lint', DiagnosticLevel.info, Severity.info);
}

/// The analyzer's diagnostics of one [level], each a finding [id] of
/// [severity] with the file, the line, the analyzer's message and its code,
/// and what the analyzer suggests as the fix hint.
abstract base class _DartLevelCheck implements GatheringCheck {
  const _DartLevelCheck(this.id, this.level, this.severity);

  final String id;
  final DiagnosticLevel level;
  final Severity severity;

  @override
  List<String> get ids => [id];

  // In both modes; the fast mode narrows it to the unverified files.
  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  bool get needsMap => false;

  @override
  Future<void> gather(VerifyGathering gathering) => gathering.code();

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    final everywhere = context.mode == VerifyMode.full;
    return [
      for (final diagnostic in context.code.diagnostics)
        if (diagnostic.level == level &&
            !isDeprecatedUseCode(diagnostic.code) &&
            (everywhere || context.unverified.contains(diagnostic.file)))
          Finding(
            id: id,
            severity: severity,
            file: diagnostic.file,
            line: diagnostic.line,
            message: '${diagnostic.message} (`${diagnostic.code}`)',
            fixHint: diagnostic.correction,
          ),
    ];
  }
}
