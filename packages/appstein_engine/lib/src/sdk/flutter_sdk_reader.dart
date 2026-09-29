import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Thrown when an SDK folder exists but Flutter hasn't run in it yet, so its
/// version files aren't there. FVM lists such versions as "Need setup".
final class SdkNotSetUpException implements Exception {
  /// Creates the exception for [sdkRoot].
  const SdkNotSetUpException(this.sdkRoot);

  /// The SDK folder.
  final String sdkRoot;

  @override
  String toString() => 'The Flutter SDK at $sdkRoot has not been set up yet.';
}

/// The versions an installed Flutter SDK reports.
final class FlutterSdkVersions {
  /// Creates the versions.
  const FlutterSdkVersions({
    required this.flutter,
    required this.dart,
    required this.channel,
  });

  /// The Flutter version, such as `3.47.5`.
  final String flutter;

  /// The bundled Dart version, such as `3.13.4`.
  final String dart;

  /// The channel, such as `stable`.
  final String channel;
}

/// Reads the versions from `bin/cache/flutter.version.json` in [sdkRoot].
///
/// This is the file `flutter --version --machine` prints, so reading it is
/// equivalent and takes milliseconds instead of seconds.
/// Throws [SdkNotSetUpException] when the file is missing, and a
/// [FormatException] when its contents are unexpected.
FlutterSdkVersions readSdkVersions(String sdkRoot) {
  final file = File(p.join(sdkRoot, 'bin', 'cache', 'flutter.version.json'));
  if (!file.existsSync()) throw SdkNotSetUpException(sdkRoot);
  final Object? data;
  try {
    final text = file.readAsStringSync();
    // Strip a byte order mark, which `jsonDecode` rejects.
    data = jsonDecode(text.startsWith('﻿') ? text.substring(1) : text);
  } on FileSystemException catch (error) {
    throw FormatException(
      'Could not read ${file.path}: ${error.osError?.message ?? error.message}',
    );
  } on FormatException catch (error) {
    throw FormatException('${file.path} is not valid JSON: ${error.message}');
  }
  if (data is! Map<String, Object?>) {
    throw FormatException('Unexpected contents in ${file.path}.');
  }
  final flutter = data['frameworkVersion'] ?? data['flutterVersion'];
  final dart = data['dartSdkVersion'];
  final channel = data['channel'] ?? 'unknown';
  if (flutter is! String || dart is! String || channel is! String) {
    throw FormatException('Unexpected contents in ${file.path}.');
  }
  // Beta and dev builds read like "3.14.0 (build 3.14.0-150.0.dev)".
  return FlutterSdkVersions(
    flutter: flutter,
    dart: dart.split(' ').first,
    channel: channel,
  );
}
