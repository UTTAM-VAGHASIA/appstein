import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../host/host_environment.dart';
import 'flutter_sdk_locator.dart';
import 'flutter_sdk_reader.dart';
import 'language_version.dart';

/// What Appstein knows about a project's Flutter SDK: facts when detection
/// worked, or a problem with a fix when it didn't.
final class SdkDetection {
  /// Detection worked.
  const SdkDetection.found(SdkInfo this.info, SdkLocation this.location)
    : problem = null,
      fixHint = null;

  /// Detection failed. [location] is set when the SDK was found but unusable.
  const SdkDetection.failed(
    String this.problem,
    String this.fixHint, {
    this.location,
  }) : info = null;

  /// The SDK facts, when detection worked.
  final SdkInfo? info;

  /// Where the SDK is, when it was found.
  final SdkLocation? location;

  /// Why detection failed.
  final String? problem;

  /// What the user should do about it.
  final String? fixHint;
}

/// Detects the Flutter SDK a project uses and reads its versions.
final class SdkDetector {
  /// Creates a detector for [environment].
  const SdkDetector(this.environment);

  /// The machine to look on.
  final HostEnvironment environment;

  /// Detects the SDK for [projectRoot], or without a project when it is null.
  SdkDetection detect({String? projectRoot}) {
    final lookup = FlutterSdkLocator(
      environment,
    ).locate(projectRoot: projectRoot);
    final location = lookup.location;
    if (location == null) {
      return SdkDetection.failed(lookup.problem!, lookup.fixHint!);
    }
    final FlutterSdkVersions versions;
    try {
      versions = readSdkVersions(location.root);
    } on SdkNotSetUpException catch (error) {
      return SdkDetection.failed(
        error.toString(),
        location.source == SdkSource.fvm
            ? 'Run `fvm flutter --version` once in the project so Flutter '
                  'downloads its tools.'
            : 'Run `flutter --version` once so Flutter downloads its tools.',
        location: location,
      );
    } on FormatException catch (error) {
      return SdkDetection.failed(
        'Could not read the Flutter version: ${error.message}',
        'Reinstall this Flutter version.',
        location: location,
      );
    }
    String? languageVersion;
    if (projectRoot != null) {
      final pubspec = File(p.join(projectRoot, 'pubspec.yaml'));
      try {
        languageVersion = languageVersionFromPubspec(
          pubspec.readAsStringSync(),
        );
      } on FileSystemException {
        // A missing or unreadable pubspec means an unknown language version.
      }
    }
    return SdkDetection.found(
      SdkInfo(
        flutterVersion: versions.flutter,
        dartVersion: versions.dart,
        channel: versions.channel,
        languageVersion: languageVersion,
        fvmVersion: location.fvmVersion,
      ),
      location,
    );
  }
}
