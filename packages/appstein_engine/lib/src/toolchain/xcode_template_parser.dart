import 'toolchain_files.dart';

/// Reads a deployment target from the text of one of Flutter's Xcode
/// project templates (spec §12): the value of [setting]
/// (`IPHONEOS_DEPLOYMENT_TARGET` or `MACOSX_DEPLOYMENT_TARGET`), which
/// every build configuration in the template sets.
///
/// [file] names the template in errors. Throws [ToolchainParseException]
/// when the setting is missing or the configurations disagree.
String parseDeploymentTarget(
  String text, {
  required String setting,
  required String file,
}) {
  final values = {
    for (final match in RegExp(
      '\\b$setting\\s*=\\s*"?([0-9][0-9.]*)"?\\s*;',
    ).allMatches(text))
      match[1]!,
  };
  if (values.isEmpty) throw ToolchainParseException(file, 'no $setting');
  if (values.length > 1) {
    throw ToolchainParseException(
      file,
      'its build configurations disagree on $setting: '
      '${(values.toList()..sort()).join(', ')}',
    );
  }
  return values.single;
}
