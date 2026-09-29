import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// Gives files their layer tag using the globs in [LayerRules].
///
/// Paths are relative to the folder of the `analysis_options.yaml` that
/// declares the rules, and use `/` on every OS.
final class LayerMatcher {
  /// Creates a matcher for [rules].
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
