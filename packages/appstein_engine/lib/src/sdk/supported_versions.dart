import 'package:pub_semver/pub_semver.dart';

/// The oldest Flutter release Appstein supports (spec §22, item 14).
///
/// Flutter 3.44 ships Dart 3.12, which the Dart MCP server requires, and it
/// made Swift Package Manager the default. CI checks this version in slice 1a.
final minSupportedFlutter = Version(3, 44, 0);

/// The newest Flutter minor version this Appstein was built and tested for.
///
/// On a newer SDK, everything generated from the SDK still works, but
/// curated notes may be missing (spec §6.4).
const newestKnownFlutterMinor = '3.47';

/// The oldest Xcode that can upload to the App Store (Xcode 26, required
/// since 2026-04-28). This moves into the curated notes in slice 1b.
const minimumXcodeMajor = 26;
