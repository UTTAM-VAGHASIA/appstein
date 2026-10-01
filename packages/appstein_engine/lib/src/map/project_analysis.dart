import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// One analyzed Dart library of the project, with its parts.
final class AnalyzedLibrary {
  /// Creates the entry.
  const AnalyzedLibrary(this.path, this.result);

  /// The library's file, relative to the project, with `/`.
  final String path;

  /// The analyzer's resolved library: its element and every unit's AST.
  final ResolvedLibraryResult result;
}

/// An import or export of another file of the project.
final class ProjectImport {
  /// Creates the entry.
  const ProjectImport({
    required this.file,
    required this.line,
    required this.library,
  });

  /// The imported file, relative to the project, with `/`.
  final String file;

  /// The 1-based line of the directive's URI.
  final int line;

  /// The imported library.
  final LibraryElement library;
}

/// Thrown when the project can't be analyzed at all, for example because
/// the Dart SDK is incomplete.
final class ProjectAnalysisException implements Exception {
  /// Creates the exception.
  const ProjectAnalysisException(this.message);

  /// What is wrong, for the person running `appstein sync`.
  final String message;

  @override
  String toString() => message;
}

/// The resolved Dart code of a project (spec §6.5): every library under
/// [folders], resolved by `package:analyzer` against the project's packages.
///
/// The project's `.dart_tool/package_config.json` must exist, so check the
/// packages first (`checkPackages`). Code with errors still resolves as far
/// as it can. Call [dispose] when done.
final class ProjectAnalysis {
  ProjectAnalysis._(
    this.projectRoot,
    this.packageName,
    this.libraries,
    this._collection,
  );

  /// The folders whose Dart files are analyzed.
  static const folders = ['lib', 'test', 'testing'];

  /// Analyzes the project at [projectRoot], reading `dart:` libraries from
  /// the Dart SDK at [dartSdkPath] (inside a Flutter SDK, that is
  /// `bin/cache/dart-sdk`).
  ///
  /// Throws a [ProjectAnalysisException] when that SDK has no
  /// `lib/core/core.dart`, or when a Dart file of the project can't be
  /// resolved as a library (only part files are skipped).
  static Future<ProjectAnalysis> analyze(
    String projectRoot, {
    required String dartSdkPath,
  }) async {
    // The analyzer accepts only absolute, normalized paths.
    final root = p.normalize(p.absolute(projectRoot));
    final sdk = p.normalize(p.absolute(dartSdkPath));
    if (!File(p.join(sdk, 'lib', 'core', 'core.dart')).existsSync()) {
      throw ProjectAnalysisException(
        'The Dart SDK at $sdk is incomplete: it has no lib/core/core.dart.',
      );
    }
    final included = [
      for (final folder in folders)
        if (Directory(p.join(root, folder)).existsSync()) p.join(root, folder),
    ];
    final name = _packageName(root);
    if (included.isEmpty) return ProjectAnalysis._(root, name, const [], null);
    final collection = AnalysisContextCollection(
      includedPaths: included,
      sdkPath: sdk,
    );
    final libraries = <String, AnalyzedLibrary>{};
    try {
      for (final context in collection.contexts) {
        final files =
            context.contextRoot
                .analyzedFiles()
                .where((file) => file.endsWith('.dart'))
                .toList()
              ..sort();
        for (final file in files) {
          final result = await context.currentSession.getResolvedLibrary(file);
          // A part file isn't a library: its library lists it in `units`.
          if (result is NotLibraryButPartResult) continue;
          final path = _relative(root, file);
          if (result is! ResolvedLibraryResult || path == null) {
            // Never drop a file silently: a map with a hole in it would look
            // complete.
            final why = path == null
                ? 'it is outside the project'
                : 'the result was a ${result.runtimeType}';
            throw ProjectAnalysisException(
              'The analyzer could not resolve ${path ?? p.normalize(file)} '
              '($why).',
            );
          }
          libraries[path] = AnalyzedLibrary(path, result);
        }
      }
    } catch (_) {
      await collection.dispose();
      rethrow;
    }
    final sorted = libraries.keys.toList()..sort();
    return ProjectAnalysis._(root, name, [
      for (final path in sorted) libraries[path]!,
    ], collection);
  }

  /// The project folder, absolute and normalized.
  final String projectRoot;

  /// The package's `name:` from `pubspec.yaml`, or null.
  final String? packageName;

  /// The analyzed libraries, sorted by path.
  final List<AnalyzedLibrary> libraries;

  final AnalysisContextCollection? _collection;

  /// [absolutePath] relative to the project, with `/`, or null when it is
  /// outside the project (the SDK, the pub cache).
  String? relativePath(String absolutePath) =>
      _relative(projectRoot, absolutePath);

  /// Where [fragment]'s name is: its file, relative to the project, and the
  /// 1-based line. Null when it is outside the project or has no name.
  ({String file, int line})? locationOf(Fragment fragment) {
    final library = fragment.libraryFragment;
    final offset = fragment.nameOffset;
    if (library == null || offset == null) return null;
    final file = relativePath(library.source.fullName);
    if (file == null) return null;
    return (file: file, line: library.lineInfo.getLocation(offset).lineNumber);
  }

  /// The imports and exports in [unit] that resolve to a file of the
  /// project, in source order. A conditional import counts by its main
  /// URI, as in the `layer_imports` lint.
  List<ProjectImport> importsOf(ResolvedUnitResult unit) => [
    for (final directive in unit.unit.directives)
      if (_imported(directive) case final library?)
        if (relativePath(library.firstFragment.source.fullName)
            case final file?)
          ProjectImport(
            file: file,
            line: unit.lineInfo
                .getLocation((directive as UriBasedDirective).uri.offset)
                .lineNumber,
            library: library,
          ),
  ];

  /// Releases the analyzer.
  Future<void> dispose() async => _collection?.dispose();

  static LibraryElement? _imported(Directive directive) => switch (directive) {
    ImportDirective(:final libraryImport) => libraryImport?.importedLibrary,
    ExportDirective(:final libraryExport) => libraryExport?.exportedLibrary,
    _ => null,
  };

  static String? _relative(String root, String path) {
    final normalized = p.normalize(path);
    if (!p.isWithin(root, normalized)) return null;
    return p.split(p.relative(normalized, from: root)).join('/');
  }

  static String? _packageName(String root) {
    try {
      final pubspec = loadYaml(
        File(p.join(root, 'pubspec.yaml')).readAsStringSync(),
      );
      return pubspec is Map && pubspec['name'] is String
          ? pubspec['name'] as String
          : null;
    } on FileSystemException {
      return null;
    } on YamlException {
      return null;
    }
  }
}
