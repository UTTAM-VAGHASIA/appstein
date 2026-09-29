/// Facts about the Flutter SDK a project uses.
///
/// This is the content of `.appstein/platform/sdk.json` (spec §6.2). Slice 1a
/// detects these facts; slice 1b writes them to disk and adds notes coverage.
final class SdkInfo {
  /// Creates SDK facts.
  const SdkInfo({
    required this.flutterVersion,
    required this.dartVersion,
    required this.channel,
    this.languageVersion,
    this.fvmVersion,
  });

  /// Reads SDK facts from their JSON form.
  ///
  /// Throws a [FormatException] when a required field is missing or has the
  /// wrong type.
  factory SdkInfo.fromJson(Map<String, Object?> json) {
    String readString(String key) {
      final value = json[key];
      if (value is String) return value;
      throw FormatException('sdk.json: "$key" must be a string.');
    }

    String? readOptional(String key) {
      final value = json[key];
      if (value == null || value is String) return value as String?;
      throw FormatException('sdk.json: "$key" must be a string or null.');
    }

    return SdkInfo(
      flutterVersion: readString('flutter'),
      dartVersion: readString('dart'),
      channel: readString('channel'),
      languageVersion: readOptional('languageVersion'),
      fvmVersion: readOptional('fvm'),
    );
  }

  /// The Flutter framework version, such as `3.47.5`.
  final String flutterVersion;

  /// The Dart SDK version bundled with Flutter, such as `3.13.4`.
  final String dartVersion;

  /// The Flutter channel, such as `stable`.
  final String channel;

  /// The project's Dart language version, such as `3.9`.
  ///
  /// It is the lower bound of the `sdk` constraint in `pubspec.yaml`. New
  /// syntax is gated by this, not by the installed SDK. Null when unknown.
  final String? languageVersion;

  /// The Flutter version the project pins with FVM, or null without FVM.
  final String? fvmVersion;

  /// The JSON form, with the key names used in `sdk.json`.
  Map<String, Object?> toJson() => {
    'flutter': flutterVersion,
    'dart': dartVersion,
    'channel': channel,
    'languageVersion': languageVersion,
    'fvm': fvmVersion,
  };

  @override
  bool operator ==(Object other) =>
      other is SdkInfo &&
      other.flutterVersion == flutterVersion &&
      other.dartVersion == dartVersion &&
      other.channel == channel &&
      other.languageVersion == languageVersion &&
      other.fvmVersion == fvmVersion;

  @override
  int get hashCode => Object.hash(
    flutterVersion,
    dartVersion,
    channel,
    languageVersion,
    fvmVersion,
  );
}
