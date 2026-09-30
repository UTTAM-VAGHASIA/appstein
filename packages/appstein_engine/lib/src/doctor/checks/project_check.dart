import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../../config/config_loader.dart';
import '../../host/file_errors.dart';
import '../../sdk/language_version.dart';
import '../doctor_check.dart';

/// Checks the project: its `appstein.yaml` and Dart language version.
final class ProjectCheck implements DoctorCheck {
  /// Creates the check.
  const ProjectCheck();

  @override
  String get id => 'doctor.project';

  @override
  String get title => 'Project';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final root = context.projectRoot;
    if (root == null) {
      return const CheckResult.skipped('Not inside a Dart or Flutter project.');
    }
    final pubspec = File(p.join(root, 'pubspec.yaml'));
    String? language;
    if (pubspec.existsSync()) {
      try {
        language = languageVersionFromPubspec(pubspec.readAsStringSync());
      } on FileSystemException catch (error) {
        return CheckResult.error(
          'Could not read pubspec.yaml: ${fileErrorReason(error)}',
          details: [pubspec.path],
          fixHint: 'Make sure pubspec.yaml is a readable UTF-8 text file.',
        );
      }
    }
    final languageLine = language == null
        ? 'Dart language version: unknown (pubspec.yaml has no SDK lower bound)'
        : 'Dart language version: $language (from the SDK constraint in '
              'pubspec.yaml)';
    final AppsteinConfig? config;
    try {
      config = loadConfig(root);
    } on ConfigException catch (error) {
      return CheckResult.error(
        'appstein.yaml is invalid: $error',
        details: [root],
        // Without a line, the file couldn't be read at all.
        fixHint: error.line == null
            ? 'Make sure appstein.yaml is a readable UTF-8 text file.'
            : 'Fix appstein.yaml at the position shown. Every key and '
                  'its default are listed in section 7 of the Appstein spec.',
      );
    }
    if (config == null) {
      return CheckResult.info(
        'No appstein.yaml: this project is not set up with Appstein yet.',
        details: [root, languageLine],
      );
    }
    return CheckResult.ok(
      'appstein.yaml is valid',
      details: [
        root,
        'Stack: ${config.packs.stack}; platforms: '
            '${config.packs.platforms.join(', ')}',
        languageLine,
      ],
    );
  }
}
