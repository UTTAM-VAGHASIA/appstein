import '../json_fields.dart';
import 'code_ref.dart';

/// One feature: a folder under `lib/ui/` with `view_models/` or `widgets/`
/// (spec §6.5).
final class Feature {
  /// Creates a feature. Every list is sorted: references by name, then
  /// file; paths alphabetically.
  const Feature({
    required this.folder,
    required this.viewModels,
    required this.screens,
    required this.repositories,
    required this.services,
    required this.models,
    required this.tests,
    required this.files,
  });

  factory Feature._read(JsonFields fields) {
    List<CodeRef> refs(String key) => [
      for (final ref in fields.objects(key)) CodeRef.read(ref),
    ];
    return Feature(
      folder: fields.string('folder'),
      viewModels: refs('viewModels'),
      screens: refs('screens'),
      repositories: refs('repositories'),
      services: refs('services'),
      models: refs('models'),
      tests: fields.strings('tests'),
      files: fields.strings('files'),
    );
  }

  /// The feature's folder, such as `lib/ui/auth/login`.
  final String folder;

  /// Its view models: the classes in `view_models/` that extend
  /// `ChangeNotifier`.
  final List<CodeRef> viewModels;

  /// Its screens: the widgets in `widgets/` that routes build.
  final List<CodeRef> screens;

  /// The repositories its view models' constructors take.
  final List<CodeRef> repositories;

  /// The services its view models' constructors take.
  final List<CodeRef> services;

  /// The public classes in `domain` files that its files import.
  final List<CodeRef> models;

  /// Its tests under `test/ui/<feature>/`.
  final List<String> tests;

  /// Its files.
  final List<String> files;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'folder': folder,
    'viewModels': [for (final r in viewModels) r.toJson()],
    'screens': [for (final r in screens) r.toJson()],
    'repositories': [for (final r in repositories) r.toJson()],
    'services': [for (final r in services) r.toJson()],
    'models': [for (final r in models) r.toJson()],
    'tests': tests,
    'files': files,
  };
}

/// The contents of `map/features.json`.
final class FeaturesMap {
  /// Creates the map.
  const FeaturesMap({required this.features});

  /// Reads the map from its JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory FeaturesMap.fromJson(Map<String, Object?> json) => FeaturesMap(
    features: {
      for (final MapEntry(:key, :value) in JsonFields(
        'features.json',
        json,
      ).objectMap('features').entries)
        key: Feature._read(value),
    },
  );

  /// The features, by name: the folder's path below `lib/ui/`, such as
  /// `auth/login`.
  final Map<String, Feature> features;

  /// The feature whose files or tests include [path], or null.
  String? featureOf(String path) {
    for (final MapEntry(:key, :value) in features.entries) {
      if (value.files.contains(path) || value.tests.contains(path)) return key;
    }
    return null;
  }

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'features': {
      for (final MapEntry(:key, :value) in features.entries)
        key: value.toJson(),
    },
  };
}
