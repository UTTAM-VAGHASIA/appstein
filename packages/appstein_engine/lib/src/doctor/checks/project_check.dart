import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../../config/config_loader.dart';
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
    final language = pubspec.existsSync()
        ? languageVersionFromPubspec(pubspec.readAsStringSync())
        : null;
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
        fixHint:
            'Fix appstein.yaml at the position shown. Every key and '
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
