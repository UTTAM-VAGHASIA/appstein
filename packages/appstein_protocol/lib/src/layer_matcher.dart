import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'layer_rules.dart';

/// Gives files their layer tag using the globs in [LayerRules].
///
/// The `layer_imports` lint and `appstein sync` (for `layers.json`) both
/// use it, so a file gets the same tag in the editor and in the map. Paths
/// are relative to the folder whose rules apply (the `analysis_options.yaml`
/// folder for the lint, the project folder for sync), with `/` on every OS.
final class LayerMatcher {
  /// Creates a matcher for [rules]. Throws a [FormatException] for an
  /// invalid glob.
  LayerMatcher(this.rules)
    : _globs = {
        for (final MapEntry(key: tag, value: patterns) in rules.layers.entries)
          tag: [for (final g in patterns) Glob(g, context: p.posix)],
      };

  /// The rules being matched.
  final LayerRules rules;

  final Map<String, List<Glob>> _globs;

  /// The first tag, in declaration order, whose globs match
  /// [relativePosixPath]. Null when none match.
  String? tagFor(String relativePosixPath) {
    for (final MapEntry(key: tag, value: globs) in _globs.entries) {
      if (globs.any((glob) => glob.matches(relativePosixPath))) return tag;
    }
    return null;
  }
}
