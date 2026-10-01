import 'package:appstein_protocol/appstein_protocol.dart';

import 'interface_library.dart';
import 'project_analysis.dart';

/// Builds `layers.json` (spec §6.5, §9.6). It lists every analyzed file
/// (libraries and their parts) with its layer tag from [rules], its feature
/// from [featureOf], and the project files it imports or exports.
/// Violations are the imports [rules] forbid: exactly what the
/// `layer_imports` lint reports, because both use [LayerMatcher] and the
/// same interface rule.
LayersMap buildLayers(
  ProjectAnalysis analysis, {
  required LayerRules? rules,
  required String? Function(String file) featureOf,
}) {
  final matcher = rules == null ? null : LayerMatcher(rules);
  final files = <String, MapFileEntry>{};
  final violations = <LayerViolation>[];
  for (final library in analysis.libraries) {
    for (final unit in library.result.units) {
      final file = analysis.relativePath(unit.path);
      if (file == null) continue;
      final from = matcher?.tagFor(file);
      final imports = <String>{};
      for (final import in analysis.importsOf(unit)) {
        imports.add(import.file);
        final to = matcher?.tagFor(import.file);
        if (rules == null || from == null || to == null) continue;
        if (rules.mayImport(
          from,
          to,
          interfaceOnly: isInterfaceLibrary(import.library),
        )) {
          continue;
        }
        violations.add(
          LayerViolation(
            file: file,
            line: import.line,
            import: import.file,
            from: from,
            to: to,
          ),
        );
      }
      files[file] = MapFileEntry(
        layer: from,
        feature: featureOf(file),
        imports: imports.toList()..sort(),
      );
    }
  }
  violations.sort((a, b) {
    final byFile = a.file.compareTo(b.file);
    if (byFile != 0) return byFile;
    final byLine = a.line.compareTo(b.line);
    return byLine != 0 ? byLine : a.import.compareTo(b.import);
  });
  final paths = files.keys.toList()..sort();
  return LayersMap(
    files: {for (final path in paths) path: files[path]!},
    violations: violations,
  );
}
