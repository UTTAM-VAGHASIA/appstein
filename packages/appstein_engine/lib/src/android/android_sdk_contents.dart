import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A version read from an Android SDK folder name the way Flutter's own
/// `Version.parse` reads it (`flutter_tools/lib/src/base/version.dart`,
/// Flutter 3.47).
///
/// Only the numbers at the start of the name count: `37.0.0-rc2` is 37.0.0,
/// `36` is 36.0.0 and `36.1` is 36.1.0. The whole name is kept in [text],
/// for display. Comparing looks at major, minor and patch only, so a preview
/// such as `37.0.0-rc2` ties with the release `37.0.0`.
final class LenientVersion implements Comparable<LenientVersion> {
  /// Creates a version from its parts and the [text] it was read from.
  const LenientVersion(this.major, this.minor, this.patch, this.text);

  /// Reads [text], or returns null when it doesn't start with a number.
  static LenientVersion? tryParse(String text) {
    final match = _leadingNumbers.firstMatch(text);
    if (match == null) return null;
    final major = int.tryParse(match[1]!);
    final minor = int.tryParse(match[3] ?? '0');
    final patch = int.tryParse(match[5] ?? '0');
    if (major == null || minor == null || patch == null) return null;
    return LenientVersion(major, minor, patch, text);
  }

  static final _leadingNumbers = RegExp(r'^(\d+)(\.(\d+)(\.(\d+))?)?');

  /// The major version.
  final int major;

  /// The minor version, 0 when the name has none.
  final int minor;

  /// The patch version, 0 when the name has none.
  final int patch;

  /// The name it was read from, such as `37.0.0-rc2`.
  final String text;

  @override
  int compareTo(LenientVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  String toString() => text;
}

/// A folder in an Android SDK's `platforms` folder, and the API level
/// Flutter reads for it.
typedef AndroidPlatform = ({String name, int level});

/// What Flutter reads from an Android SDK's `build-tools` and `platforms`
/// folders, and the pair it reports (`AndroidSdk.reinitialize` in
/// `flutter_tools/lib/src/android/android_sdk.dart`, Flutter 3.47).
final class AndroidSdkContents {
  /// Creates the contents.
  const AndroidSdkContents({
    required this.buildTools,
    required this.platforms,
    required this.ignoredPlatforms,
  });

  /// Every entry in `build-tools` whose name starts with a number, in name
  /// order. Files count too, as in Flutter.
  final List<LenientVersion> buildTools;

  /// Every platform folder with an API level, in name order.
  final List<AndroidPlatform> platforms;

  /// The platform folders Flutter ignores because it finds no API level in
  /// them, in name order.
  final List<String> ignoredPlatforms;

  /// The platform Flutter reports: the highest API level. Among platforms of
  /// one level, the name that sorts last: Flutter sorts a name-ordered
  /// listing by level, keeping ties in order, and takes the last. Null when
  /// there is none.
  AndroidPlatform? get latestPlatform {
    AndroidPlatform? latest;
    for (final platform in platforms) {
      if (latest == null || platform.level >= latest.level) latest = platform;
    }
    return latest;
  }

  /// The build-tools Flutter pairs with [latestPlatform]: the newest whose
  /// major version equals its API level, or else the newest of all. On a
  /// tie, such as `37.0.0` and `37.0.0-rc2`, the name that sorts first wins,
  /// as Flutter keeps the first one it lists. Null when there is no platform
  /// or no build-tools.
  LenientVersion? get buildToolsForLatest {
    final platform = latestPlatform;
    if (platform == null) return null;
    return _newest(buildTools.where((v) => v.major == platform.level)) ??
        _newest(buildTools);
  }

  static LenientVersion? _newest(Iterable<LenientVersion> versions) {
    LenientVersion? newest;
    for (final version in versions) {
      if (newest == null || version.compareTo(newest) > 0) newest = version;
    }
    return newest;
  }
}

/// Reads the `build-tools` and `platforms` folders of the Android SDK at
/// [sdk] as Flutter does. Never throws: a missing or unreadable folder
/// counts as empty.
AndroidSdkContents readAndroidSdkContents(String sdk) {
  final buildTools = <LenientVersion>[];
  for (final entry in _listByName(p.join(sdk, 'build-tools'))) {
    final version = LenientVersion.tryParse(p.basename(entry.path));
    if (version != null) buildTools.add(version);
  }
  final platforms = <AndroidPlatform>[];
  final ignored = <String>[];
  for (final entry in _listByName(p.join(sdk, 'platforms'))) {
    if (entry is! Directory) continue;
    final name = p.basename(entry.path);
    final level = _platformLevel(entry.path, name);
    if (level == null) {
      ignored.add(name);
    } else {
      platforms.add((name: name, level: level));
    }
  }
  return AndroidSdkContents(
    buildTools: buildTools,
    platforms: platforms,
    ignoredPlatforms: ignored,
  );
}

final _numberedPlatform = RegExp(r'^android-([0-9]+)$');
final _sdkVersionLine = RegExp(r'^ro.build.version.sdk=([0-9]+)$');

/// The API level of the platform folder at [path], named [name]: from a
/// name like `android-36`, or else from the first `ro.build.version.sdk=`
/// line of its `build.prop`. Null when neither gives one.
int? _platformLevel(String path, String name) {
  final numbered = _numberedPlatform.firstMatch(name);
  if (numbered != null) return int.tryParse(numbered[1]!);
  final String text;
  try {
    text = File(p.join(path, 'build.prop')).readAsStringSync();
  } on FileSystemException {
    return null;
  }
  for (final line in const LineSplitter().convert(text)) {
    final match = _sdkVersionLine.firstMatch(line);
    if (match != null) return int.tryParse(match[1]!);
  }
  return null;
}

/// The entries of the folder at [path], sorted by name, or none when it
/// can't be listed. Links are followed, as in Flutter's listing. Flutter
/// uses the file system's own order, which is alphabetical on NTFS and
/// APFS; sorting makes the answer the same everywhere.
List<FileSystemEntity> _listByName(String path) {
  final dir = Directory(path);
  try {
    if (!dir.existsSync()) return const [];
    return dir.listSync()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  } on FileSystemException {
    return const [];
  }
}
