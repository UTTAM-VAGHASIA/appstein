import 'package:appstein_protocol/appstein_protocol.dart';

import '../host/host_environment.dart';

/// What a native extractor may use (spec §6.5). There is no Dart analysis
/// here on purpose: `native.json` is built even when the map is skipped.
final class NativeContext {
  /// Creates the context.
  const NativeContext({
    required this.projectRoot,
    required this.flutterVersion,
    required this.channel,
    required this.environment,
    this.android,
  });

  /// The project's root folder.
  final String projectRoot;

  /// The Flutter version, such as `3.47.5`.
  final String flutterVersion;

  /// The Flutter channel, such as `stable`.
  final String channel;

  /// The machine: environment variables and the OS, for settings Flutter
  /// reads from outside the project.
  final HostEnvironment environment;

  /// Flutter's Android values for this SDK (what `flutter.minSdkVersion`
  /// and the others resolve to), as `toolchain.json` read them; null when
  /// neither the SDK nor the curated notes give them.
  final Sourced<AndroidToolchain>? android;
}

/// One section of `native.json` and everything it was built from.
final class NativeSection {
  /// Pairs the section's [node] with its [inputs].
  const NativeSection(this.node, this.inputs);

  /// The section: a group of values, or one value when the whole section
  /// is absent (such as no `ios/` folder).
  final NativeNode node;

  /// Every input it read, by a stable name (`file:android/gradle.properties`,
  /// `env:FLUTTER_SWIFT_PACKAGE_MANAGER`), to its bytes or null when
  /// missing. They go into the file's input hash.
  final Map<String, List<int>?> inputs;
}

/// Builds one section of `map/native.json` from a project's native files
/// (spec §6.5, §10). Platform packs provide one.
abstract interface class NativeExtractor {
  /// The section it writes, such as `android`.
  String get section;

  /// Reads the project's native files. It never throws for the project's
  /// own problems: a missing or damaged file becomes `absent` or `unknown`
  /// values.
  NativeSection extract(NativeContext context);
}
