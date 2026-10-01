/// Where Flutter keeps the files Appstein reads the toolchain matrix from
/// (spec §12), relative to the SDK root, with `/` separators.
abstract final class ToolchainFiles {
  /// The Android template versions, Flutter's minimums, the newest known
  /// versions and the Java compatibility lists.
  static const gradleUtils =
      'packages/flutter_tools/lib/src/android/gradle_utils.dart';

  /// The versions below which Flutter's Gradle plugin warns or fails a
  /// build.
  static const gradlePluginChecks =
      'packages/flutter_tools/gradle/src/main/kotlin/'
      'DependencyVersionChecker.kt';

  /// The iOS app template's Xcode project.
  static const iosTemplate =
      'packages/flutter_tools/templates/app/ios.tmpl/'
      'Runner.xcodeproj/project.pbxproj.tmpl';

  /// The macOS app template's Xcode project.
  static const macosTemplate =
      'packages/flutter_tools/templates/app/macos.tmpl/'
      'Runner.xcodeproj/project.pbxproj.tmpl';

  /// Every file above.
  static const all = [
    gradleUtils,
    gradlePluginChecks,
    iosTemplate,
    macosTemplate,
  ];
}

/// Thrown when a toolchain file in the SDK doesn't have the shape Appstein
/// reads. The toolchain then falls back to the curated notes (spec §12).
final class ToolchainParseException implements Exception {
  /// Creates the exception for [file].
  const ToolchainParseException(this.file, this.message);

  /// The SDK file, as in [ToolchainFiles].
  final String file;

  /// What was wrong.
  final String message;

  @override
  String toString() => '${file.split('/').last}: $message';
}
