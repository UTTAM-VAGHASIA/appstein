import 'package:analyzer/file_system/file_system.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:yaml/yaml.dart';

/// The layer rules that apply to a file, and where they came from.
final class LayerConfig {
  /// Creates a config.
  const LayerConfig({
    required this.optionsPath,
    required this.rootPath,
    this.rules,
    this.matcher,
    this.error,
  });

  /// The `analysis_options.yaml` that declares the rules.
  final String optionsPath;

  /// Its folder. Globs are relative to it.
  final String rootPath;

  /// The rules, or null when the section is invalid.
  final LayerRules? rules;

  /// Gives files their layer tag. Built once with the config, not per file.
  /// Null exactly when [rules] is.
  final LayerMatcher? matcher;

  /// Why the section is invalid, when it is.
  final String? error;
}

/// Finds the layer rules for a file: the nearest `analysis_options.yaml`,
/// at or above the file's folder, that has a top-level `appstein_lints:`
/// section.
///
/// It reads through the analyzer's file system, so it sees unsaved editor
/// changes and works in tests. Parsed files are cached until they change.
final class LayerConfigFinder {
  final Map<String, (int, ({LayerConfig? config, bool unusable}))> _cache = {};

  /// The rules for [file], or null when no options file declares any.
  LayerConfig? find(File file) {
    var folder = file.parent;
    while (true) {
      final options = folder.getFile('analysis_options.yaml');
      if (options.exists) {
        final result = _read(options);
        // A broken options file stops the walk: falling through to a parent
        // config would apply rules the nearer file may have meant to replace.
        if (result.unusable) return null;
        if (result.config != null) return result.config;
      }
      if (folder.isRoot) return null;
      folder = folder.parent;
    }
  }

  ({LayerConfig? config, bool unusable}) _read(File options) {
    final int stamp;
    final String text;
    try {
      stamp = options.modificationStamp;
      text = options.readAsStringSync();
    } on FileSystemException {
      // Gone or locked between `exists` and the read.
      return (config: null, unusable: true);
    }
    final cached = _cache[options.path];
    if (cached != null && cached.$1 == stamp) return cached.$2;
    LayerConfig? config;
    var unusable = false;
    try {
      final doc = loadYaml(text);
      if (doc is Map<Object?, Object?> && doc.containsKey('appstein_lints')) {
        try {
          final rules = LayerRules.fromJson(doc['appstein_lints']);
          config = LayerConfig(
            optionsPath: options.path,
            rootPath: options.parent.path,
            rules: rules,
            // An invalid glob throws a FormatException here.
            matcher: LayerMatcher(rules),
          );
        } on FormatException catch (error) {
          config = LayerConfig(
            optionsPath: options.path,
            rootPath: options.parent.path,
            error: error.message,
          );
        }
      }
    } on YamlException {
      // The analyzer already reports a broken analysis_options.yaml.
      unusable = true;
    }
    final result = (config: config, unusable: unusable);
    _cache[options.path] = (stamp, result);
    return result;
  }
}
