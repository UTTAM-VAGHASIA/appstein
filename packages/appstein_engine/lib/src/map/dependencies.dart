import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'project_analysis.dart';

/// Builds `deps.json` (spec §6.5). It lists every package in [lockFile]
/// (the project's `pubspec.lock`, or its pub workspace's), with:
/// - the constraint `pubspec.yaml` gives it (an override wins);
/// - the resolved version, dependency kind and source the lock file
///   records;
/// - the project files that import or export it.
///
/// A missing or unreadable lock file gives no packages.
DepsMap buildDeps(ProjectAnalysis analysis, {required String lockFile}) {
  final constraints = <String, String?>{};
  final pubspec = _readYaml(p.join(analysis.projectRoot, 'pubspec.yaml'));
  for (final section in const [
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  ]) {
    if (pubspec?[section] case final Map<Object?, Object?> entries) {
      for (final MapEntry(:key, :value) in entries.entries) {
        if (key is String) constraints[key] = _constraint(value);
      }
    }
  }

  final usages = <String, Set<String>>{};
  for (final library in analysis.libraries) {
    for (final unit in library.result.units) {
      final file = analysis.relativePath(unit.path);
      if (file == null) continue;
      for (final directive
          in unit.unit.directives.whereType<NamespaceDirective>()) {
        final uri = directive.uri.stringValue;
        if (uri == null || !uri.startsWith('package:')) continue;
        final slash = uri.indexOf('/');
        if (slash < 0) continue;
        final package = uri.substring('package:'.length, slash);
        if (package == analysis.packageName) continue;
        (usages[package] ??= {}).add(file);
      }
    }
  }

  final packages = <String, PackageDependency>{};
  if (_readYaml(lockFile)?['packages']
      case final Map<Object?, Object?> locked) {
    for (final name in locked.keys.whereType<String>().toList()..sort()) {
      if (locked[name] case {
        'dependency': final String dependency,
        'source': final String source,
        'version': final String version,
      }) {
        packages[name] = PackageDependency(
          constraint: constraints[name],
          version: version,
          dependency: dependency,
          source: source,
          usages: (usages[name]?.toList() ?? [])..sort(),
        );
      }
    }
  }
  return DepsMap(packages: packages);
}

String? _constraint(Object? value) => switch (value) {
  final String text => text,
  {'version': final String version} => version,
  _ => null,
};

Map<Object?, Object?>? _readYaml(String path) {
  try {
    final yaml = loadYaml(File(path).readAsStringSync());
    return yaml is Map<Object?, Object?> ? yaml : null;
  } on FileSystemException {
    return null;
  } on YamlException {
    return null;
  }
}
