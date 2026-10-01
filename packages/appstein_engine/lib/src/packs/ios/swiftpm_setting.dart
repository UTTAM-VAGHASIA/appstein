import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import '../../host/host_environment.dart';
import '../../native/native_files.dart';

/// Flutter's name for the SwiftPM setting, in `pubspec.yaml`'s
/// `flutter: config:` and in `flutter config`.
const swiftPackageManagerSetting = 'enable-swift-package-manager';

/// The environment variable that sets SwiftPM.
const swiftPackageManagerVariable = 'FLUTTER_SWIFT_PACKAGE_MANAGER';

/// The environment variable [name] as Flutter reads it: an empty value
/// counts (decision D11), and on Windows names ignore case.
String? rawVariable(HostEnvironment environment, String name) {
  final exact = environment.variables[name];
  if (exact != null || environment.os != HostOs.windows) return exact;
  final wanted = name.toLowerCase();
  for (final MapEntry(:key, :value) in environment.variables.entries) {
    if (key.toLowerCase() == wanted) return value;
  }
  return null;
}

/// Whether SwiftPM is on for the project, decided as Flutter decides it
/// (`FlutterFeaturesConfig.isEnabled` in flutter_tools 3.47.5): first
/// `pubspec.yaml`'s `flutter: config:`, then the global settings [global]
/// that `flutter config` writes, then the environment [variable], then the
/// version's default (decision D4). A value Flutter would stop on (not a
/// boolean) is `unknown`.
NativeValue swiftPackageManagerEnabled({
  required YamlMap? pubspec,
  required Object? global,
  required String? variable,
  required String flutterVersion,
  required String channel,
}) {
  final flutter = pubspec?.nodes['flutter'];
  if (flutter is YamlMap) {
    final config = flutter.nodes['config'];
    if (config != null && config.value != null) {
      if (config is! YamlMap) {
        return NativeValue.unknown(
          '`flutter: config:` in pubspec.yaml must be a map; Flutter stops '
          'with an error',
          at: 'pubspec.yaml:${yamlLine(config)}',
        );
      }
      final setting = config.nodes[swiftPackageManagerSetting];
      if (setting != null && setting.value != null) {
        final at = 'pubspec.yaml:${yamlLine(setting)}';
        return switch (setting.value) {
          final bool enabled => NativeValue.found(
            enabled,
            at: at,
            resolvedFrom: 'pubspec.yaml',
          ),
          _ => NativeValue.unknown(
            '`$swiftPackageManagerSetting` in pubspec.yaml must be true or '
            'false; Flutter stops with an error',
            at: at,
          ),
        };
      }
    }
  }
  if (global != null) {
    return switch (global) {
      final bool enabled => NativeValue.found(
        enabled,
        resolvedFrom: 'flutter config (global)',
      ),
      _ => const NativeValue.unknown(
        '`$swiftPackageManagerSetting` in the global flutter config must be '
        'true or false; Flutter stops with an error',
      ),
    };
  }
  if (variable != null) {
    return NativeValue.found(
      variable.toLowerCase() == 'true',
      resolvedFrom: swiftPackageManagerVariable,
      note:
          'from the environment `appstein sync` ran in; a build started '
          'elsewhere may not have it',
    );
  }
  final Version version;
  try {
    version = Version.parse(flutterVersion);
  } on FormatException {
    return NativeValue.unknown(
      "Flutter $flutterVersion's default isn't known to Appstein",
    );
  }
  if (version >= Version(3, 44, 0)) {
    return const NativeValue.found(
      true,
      resolvedFrom: 'default',
      note: 'on by default since Flutter 3.44',
    );
  }
  if (channel == 'stable') {
    return const NativeValue.found(
      false,
      resolvedFrom: 'default',
      note: 'off by default before Flutter 3.44',
    );
  }
  return NativeValue.unknown(
    "the $channel channel's default before Flutter 3.44 isn't known to "
    'Appstein',
  );
}
