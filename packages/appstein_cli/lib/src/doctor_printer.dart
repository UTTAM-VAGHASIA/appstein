import 'package:appstein_engine/appstein_engine.dart';

/// Formats a doctor report as plain text.
///
/// Status labels are ASCII, so the output reads correctly in any Windows
/// console code page.
String formatDoctorReport(DoctorReport report, {String? projectRoot}) {
  const indent = '        ';
  final buffer = StringBuffer()
    ..writeln('Appstein doctor')
    ..writeln(
      projectRoot == null
          ? 'Project: none found here; project checks are skipped.'
          : 'Project: $projectRoot',
    )
    ..writeln();
  var errors = 0;
  var warnings = 0;
  for (final entry in report.entries) {
    final result = entry.result;
    if (result.status == CheckStatus.error) errors++;
    if (result.status == CheckStatus.warning) warnings++;
    buffer.writeln(
      '${_label(result.status).padRight(8)}${entry.check.title}: ${result.summary}',
    );
    for (final detail in result.details) {
      buffer.writeln('$indent$detail');
    }
    final fix = result.fixHint;
    if (fix != null &&
        (result.status == CheckStatus.error ||
            result.status == CheckStatus.warning)) {
      buffer.writeln('${indent}Fix: $fix');
    }
  }
  buffer
    ..writeln()
    ..writeln(
      errors == 0 && warnings == 0
          ? 'No problems found.'
          : 'Summary: ${_count(errors, 'error')}, ${_count(warnings, 'warning')}.',
    );
  return buffer.toString();
}

String _label(CheckStatus status) => switch (status) {
  CheckStatus.ok => '[ok]',
  CheckStatus.info => '[info]',
  CheckStatus.warning => '[warn]',
  CheckStatus.error => '[error]',
  CheckStatus.skipped => '[skip]',
};

String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
