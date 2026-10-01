import '../json_fields.dart';
import 'curated_note.dart';

const _file = 'toolchain.json';

/// Where a part of the toolchain matrix came from (spec §12).
enum ToolchainSource {
  /// Read from the installed Flutter SDK's own files.
  sdk,

  /// From Appstein's curated notes, because the SDK's files couldn't be
  /// read.
  notes,
}

/// A part of the toolchain matrix and where it came from.
final class Sourced<T> {
  /// Pairs [value] with its [source].
  const Sourced(this.value, this.source);

  /// The part.
  final T value;

  /// Where it came from.
  final ToolchainSource source;
}

/// The versions below which Flutter warns, and below which it fails.
final class VersionThreshold {
  /// Creates the threshold.
  const VersionThreshold({required this.warnBelow, required this.errorBelow});

  /// Reads the JSON form.
  factory VersionThreshold.fromJson(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    return VersionThreshold(
      warnBelow: fields.string('warnBelow'),
      errorBelow: fields.string('errorBelow'),
    );
  }

  /// Flutter warns below this version.
  final String warnBelow;

  /// Flutter fails below this version.
  final String errorBelow;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'warnBelow': warnBelow,
    'errorBelow': errorBelow,
  };
}

/// One row of Flutter's Java↔Gradle compatibility list: Java versions from
/// [javaMin] up to (not including) [javaMax] need at least [gradleMin], and
/// at most [gradleMax] when it is set.
final class JavaGradleCompat {
  /// Creates the row.
  const JavaGradleCompat({
    required this.javaMin,
    required this.javaMax,
    required this.gradleMin,
    this.gradleMax,
  });

  /// Reads the JSON form.
  factory JavaGradleCompat.fromJson(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    return JavaGradleCompat(
      javaMin: fields.string('javaMin'),
      javaMax: fields.string('javaMax'),
      gradleMin: fields.string('gradleMin'),
      gradleMax: fields.optionalString('gradleMax'),
    );
  }

  /// The lowest Java version of the row.
  final String javaMin;

  /// The Java version the row stops before.
  final String javaMax;

  /// The lowest Gradle version for these Java versions.
  final String gradleMin;

  /// The highest Gradle version for these Java versions, or null for no
  /// limit.
  final String? gradleMax;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'javaMin': javaMin,
    'javaMax': javaMax,
    'gradleMin': gradleMin,
    'gradleMax': gradleMax,
  };
}

/// One row of Flutter's AGP↔Java compatibility list: AGP versions from
/// [agpMin] to [agpMax] (both included) need at least Java [javaMin].
final class JavaAgpCompat {
  /// Creates the row.
  const JavaAgpCompat({
    required this.javaMin,
    required this.javaDefault,
    required this.agpMin,
    required this.agpMax,
  });

  /// Reads the JSON form.
  factory JavaAgpCompat.fromJson(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    return JavaAgpCompat(
      javaMin: fields.string('javaMin'),
      javaDefault: fields.string('javaDefault'),
      agpMin: fields.string('agpMin'),
      agpMax: fields.string('agpMax'),
    );
  }

  /// The lowest Java version these AGP versions accept.
  final String javaMin;

  /// The Java version these AGP versions use by default.
  final String javaDefault;

  /// The lowest AGP version of the row.
  final String agpMin;

  /// The highest AGP version of the row.
  final String agpMax;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'javaMin': javaMin,
    'javaDefault': javaDefault,
    'agpMin': agpMin,
    'agpMax': agpMax,
  };
}

/// The versions `flutter create` writes into a new Android project.
final class AndroidTemplate {
  /// Creates the template versions.
  const AndroidTemplate({
    required this.gradle,
    required this.agp,
    required this.kgp,
    required this.ndk,
    required this.compileSdk,
    required this.targetSdk,
    required this.minSdk,
  });

  /// Reads the JSON form.
  factory AndroidTemplate.fromJson(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    return AndroidTemplate(
      gradle: fields.string('gradle'),
      agp: fields.string('agp'),
      kgp: fields.string('kgp'),
      ndk: fields.string('ndk'),
      compileSdk: fields.integer('compileSdk'),
      targetSdk: fields.integer('targetSdk'),
      minSdk: fields.integer('minSdk'),
    );
  }

  /// The Gradle version.
  final String gradle;

  /// The Android Gradle Plugin version.
  final String agp;

  /// The Kotlin Gradle Plugin version.
  final String kgp;

  /// The NDK version.
  final String ndk;

  /// The compile SDK API level (`flutter.compileSdkVersion`).
  final int compileSdk;

  /// The target SDK API level (`flutter.targetSdkVersion`).
  final int targetSdk;

  /// The minimum SDK API level (`flutter.minSdkVersion`).
  final int minSdk;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'gradle': gradle,
    'agp': agp,
    'kgp': kgp,
    'ndk': ndk,
    'compileSdk': compileSdk,
    'targetSdk': targetSdk,
    'minSdk': minSdk,
  };
}

/// What `flutter doctor` requires of the machine's Android setup.
final class AndroidMinimums {
  /// Creates the minimums.
  const AndroidMinimums({
    required this.compileSdk,
    required this.buildTools,
    required this.java,
  });

  /// Reads the JSON form.
  factory AndroidMinimums.fromJson(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    return AndroidMinimums(
      compileSdk: fields.integer('compileSdk'),
      buildTools: fields.string('buildTools'),
      java: VersionThreshold.fromJson(fields.object('java').json),
    );
  }

  /// The lowest API level the newest installed platform may have.
  final int compileSdk;

  /// The lowest build-tools version.
  final String buildTools;

  /// The Java versions below which `flutter doctor` warns and fails.
  final VersionThreshold java;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'compileSdk': compileSdk,
    'buildTools': buildTools,
    'java': java.toJson(),
  };
}

/// The versions below which Flutter's Gradle plugin warns or fails a build.
final class AndroidBuildChecks {
  /// Creates the checks.
  const AndroidBuildChecks({
    required this.gradle,
    required this.agp,
    required this.kgp,
    required this.java,
    required this.minSdk,
  });

  /// Reads the JSON form.
  factory AndroidBuildChecks.fromJson(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    VersionThreshold read(String key) =>
        VersionThreshold.fromJson(fields.object(key).json);
    return AndroidBuildChecks(
      gradle: read('gradle'),
      agp: read('agp'),
      kgp: read('kgp'),
      java: read('java'),
      minSdk: read('minSdk'),
    );
  }

  /// Gradle.
  final VersionThreshold gradle;

  /// The Android Gradle Plugin.
  final VersionThreshold agp;

  /// The Kotlin Gradle Plugin.
  final VersionThreshold kgp;

  /// Java.
  final VersionThreshold java;

  /// The app's minimum SDK API level.
  final VersionThreshold minSdk;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'gradle': gradle.toJson(),
    'agp': agp.toJson(),
    'kgp': kgp.toJson(),
    'java': java.toJson(),
    'minSdk': minSdk.toJson(),
  };
}

/// The newest versions Flutter's tools know about.
final class AndroidMaxKnown {
  /// Creates the versions.
  const AndroidMaxKnown({
    required this.gradle,
    required this.kgp,
    required this.agp,
    required this.agpWithFullKotlinSupport,
  });

  /// Reads the JSON form.
  factory AndroidMaxKnown.fromJson(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    return AndroidMaxKnown(
      gradle: fields.string('gradle'),
      kgp: fields.string('kgp'),
      agp: fields.string('agp'),
      agpWithFullKotlinSupport: fields.string('agpWithFullKotlinSupport'),
    );
  }

  /// The newest Gradle version Flutter tests.
  final String gradle;

  /// The newest Kotlin Gradle Plugin version Flutter knows.
  final String kgp;

  /// The newest Android Gradle Plugin version Flutter knows.
  final String agp;

  /// The newest AGP version with full Kotlin support in Flutter.
  final String agpWithFullKotlinSupport;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'gradle': gradle,
    'kgp': kgp,
    'agp': agp,
    'agpWithFullKotlinSupport': agpWithFullKotlinSupport,
  };
}

/// The Android part of the toolchain matrix (spec §12).
final class AndroidToolchain {
  /// Creates the Android matrix.
  const AndroidToolchain({
    required this.template,
    required this.flutterMinimums,
    required this.buildChecks,
    required this.maxKnown,
    required this.javaGradle,
    required this.javaAgp,
  });

  /// Reads the JSON form. Other keys, such as `source`, are ignored.
  factory AndroidToolchain.fromJson(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    return AndroidToolchain(
      template: AndroidTemplate.fromJson(fields.object('template').json),
      flutterMinimums: AndroidMinimums.fromJson(
        fields.object('flutterMinimums').json,
      ),
      buildChecks: AndroidBuildChecks.fromJson(
        fields.object('buildChecks').json,
      ),
      maxKnown: AndroidMaxKnown.fromJson(fields.object('maxKnown').json),
      javaGradle: [
        for (final row in fields.objects('javaGradle'))
          JavaGradleCompat.fromJson(row.json),
      ],
      javaAgp: [
        for (final row in fields.objects('javaAgp'))
          JavaAgpCompat.fromJson(row.json),
      ],
    );
  }

  /// The versions in new projects.
  final AndroidTemplate template;

  /// What `flutter doctor` requires.
  final AndroidMinimums flutterMinimums;

  /// What Flutter's Gradle plugin checks during a build.
  final AndroidBuildChecks buildChecks;

  /// The newest versions Flutter knows.
  final AndroidMaxKnown maxKnown;

  /// Java↔Gradle compatibility, in Flutter's order (newest Java first).
  final List<JavaGradleCompat> javaGradle;

  /// AGP↔Java compatibility, in Flutter's order (newest AGP first).
  final List<JavaAgpCompat> javaAgp;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'template': template.toJson(),
    'flutterMinimums': flutterMinimums.toJson(),
    'buildChecks': buildChecks.toJson(),
    'maxKnown': maxKnown.toJson(),
    'javaGradle': [for (final row in javaGradle) row.toJson()],
    'javaAgp': [for (final row in javaAgp) row.toJson()],
  };
}

/// The iOS or macOS part of the toolchain matrix.
final class AppleToolchain {
  /// Creates the Apple matrix.
  const AppleToolchain({required this.deploymentTarget});

  /// Reads the JSON form. Other keys, such as `source`, are ignored.
  factory AppleToolchain.fromJson(Map<String, Object?> json) => AppleToolchain(
    deploymentTarget: JsonFields(_file, json).string('deploymentTarget'),
  );

  /// The deployment target in new projects, such as `15.0`.
  final String deploymentTarget;

  /// The JSON form.
  Map<String, Object?> toJson() => {'deploymentTarget': deploymentTarget};
}

/// A store's build minimum from a date on (spec §12), from
/// `notes/stores.yaml`.
final class StoreRequirement {
  /// Creates the requirement.
  const StoreRequirement({
    this.value,
    required this.since,
    this.formFactor,
    required this.summary,
    required this.source,
  });

  /// Reads the JSON form.
  factory StoreRequirement.fromJson(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    return StoreRequirement(
      value: fields.optionalString('value'),
      since: fields.string('since'),
      formFactor: fields.optionalString('formFactor'),
      summary: fields.string('summary'),
      source: fields.string('source'),
    );
  }

  /// The required value, such as `36` for a target API level, or null when
  /// the requirement has none (such as 16 KB page support).
  final String? value;

  /// The date it applies from: `YYYY-MM-DD`, or `YYYY-MM` when the store
  /// named only the month.
  final String since;

  /// The kind of device it applies to (such as `wear` or `tv`), or null for
  /// phones and tablets.
  final String? formFactor;

  /// What it requires, in one sentence.
  final String summary;

  /// A URL to the store's own page that states it.
  final String source;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'value': value,
    'since': since,
    'formFactor': formFactor,
    'summary': summary,
    'source': source,
  };
}

/// The stores' dated build minimums, by store and by kind (such as
/// `targetSdk` or `xcode`), each list oldest first.
final class StoreRequirements {
  /// Creates the requirements.
  const StoreRequirements({required this.play, required this.appStore});

  /// Reads the JSON form.
  factory StoreRequirements.fromJson(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    Map<String, List<StoreRequirement>> read(String store) {
      final byKind = fields.object(store);
      return {
        for (final kind in byKind.json.keys)
          kind: [
            for (final row in byKind.objects(kind))
              StoreRequirement.fromJson(row.json),
          ],
      };
    }

    return StoreRequirements(play: read('play'), appStore: read('appStore'));
  }

  /// Google Play's requirements.
  final Map<String, List<StoreRequirement>> play;

  /// Apple's App Store requirements.
  final Map<String, List<StoreRequirement>> appStore;

  /// The JSON form.
  Map<String, Object?> toJson() {
    Map<String, Object?> write(Map<String, List<StoreRequirement>> store) => {
      for (final entry in store.entries)
        entry.key: [for (final row in entry.value) row.toJson()],
    };
    return {'play': write(play), 'appStore': write(appStore)};
  }
}

/// The contents of `.appstein/platform/toolchain.json` (spec §12): the
/// native versions that work with the installed Flutter, where each part
/// came from, the stores' build minimums, and the curated notes about
/// Android and iOS builds.
final class Toolchain {
  /// Creates the matrix.
  const Toolchain({
    this.android,
    this.ios,
    this.macos,
    required this.fallbacks,
    required this.stores,
    required this.notes,
  });

  /// Reads the JSON form.
  ///
  /// Throws a [FormatException] when a field is missing or has the wrong
  /// type, or a source is unknown.
  factory Toolchain.fromJson(Map<String, Object?> json) {
    final fields = JsonFields(_file, json);
    Sourced<T>? read<T>(
      String key,
      T Function(Map<String, Object?> json) parse,
    ) {
      final part = fields.optionalObject(key);
      if (part == null) return null;
      final source = ToolchainSource.values.asNameMap()[part.string('source')];
      if (source == null) {
        throw FormatException('$_file: "$key.source" must be sdk or notes.');
      }
      return Sourced(parse(part.json), source);
    }

    final fallbacks = json['fallbacks'];
    if (fallbacks is! List<Object?> || fallbacks.any((f) => f is! String)) {
      throw const FormatException(
        '$_file: "fallbacks" must be a list of strings.',
      );
    }
    return Toolchain(
      android: read('android', AndroidToolchain.fromJson),
      ios: read('ios', AppleToolchain.fromJson),
      macos: read('macos', AppleToolchain.fromJson),
      fallbacks: fallbacks.cast<String>(),
      stores: StoreRequirements.fromJson(fields.object('stores').json),
      notes: [
        for (final note in fields.objects('notes'))
          CuratedNote.fromJson(note.json),
      ],
    );
  }

  /// The Android matrix, or null when neither the SDK nor the notes give
  /// one.
  final Sourced<AndroidToolchain>? android;

  /// The iOS minimums, or null when neither the SDK nor the notes give them.
  final Sourced<AppleToolchain>? ios;

  /// The macOS minimums, or null when neither the SDK nor the notes give
  /// them.
  final Sourced<AppleToolchain>? macos;

  /// Why a part came from the notes or is missing, one sentence each
  /// (`toolchain.fallback`, spec §12). Empty when everything came from the
  /// SDK.
  final List<String> fallbacks;

  /// The stores' dated build minimums.
  final StoreRequirements stores;

  /// The curated notes about Android, iOS and tooling that apply to this
  /// SDK.
  final List<CuratedNote> notes;

  /// The JSON form.
  Map<String, Object?> toJson() {
    Map<String, Object?>? write<T>(
      Sourced<T>? part,
      Map<String, Object?> Function(T value) toJson,
    ) => part == null
        ? null
        : {...toJson(part.value), 'source': part.source.name};

    return {
      'android': write(android, (a) => a.toJson()),
      'ios': write(ios, (a) => a.toJson()),
      'macos': write(macos, (a) => a.toJson()),
      'fallbacks': fallbacks,
      'stores': stores.toJson(),
      'notes': [for (final note in notes) note.toJson()],
    };
  }
}
