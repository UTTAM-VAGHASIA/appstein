import 'dart:convert';
import 'dart:io';

import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../host/host_environment.dart';
import '../host/process_runner.dart';
import '../knowledge/generated_file.dart';
import '../knowledge/input_hash.dart';
import '../packs/pack.dart';
import 'dependencies.dart';
import 'layers.dart';
import 'project_analysis.dart';
import 'project_packages.dart';
import 'symbols.dart';

/// What was done about the project's packages before the map was built.
enum PackagesAction {
  /// They were fresh, so nothing was run.
  upToDate,

  /// `flutter pub get` ran and worked.
  fetched,

  /// `flutter pub get` ran and failed, so the map was skipped.
  fetchFailed,
}

/// What the project-map part of a sync did.
final class MapReport {
  /// Creates the report.
  const MapReport({
    required this.packages,
    required this.packagesReason,
    this.skipped,
  });

  /// What was done about the packages.
  final PackagesAction packages;

  /// Why: the packages' status (words that follow "because"), or, after a
  /// failed fetch, what went wrong, with the end of Flutter's output.
  final String packagesReason;

  /// Why the map wasn't written; null when it was.
  final String? skipped;
}

/// The project map, built but not yet written.
final class MapBuild {
  /// Creates the build.
  const MapBuild({required this.files, required this.report});

  /// The map files; empty when the map was skipped.
  final List<GeneratedFile> files;

  /// What happened.
  final MapReport report;
}

/// Builds the project map (spec §6.5).
///
/// First it makes sure the packages are fetched, the way Flutter does. Then
/// it resolves the project, runs the packs' extractors (official_mvvm's
/// features and routes), and builds the generic files: symbols, layers and
/// deps.
final class MapSync {
  /// Creates the sync. [runner] runs `flutter pub get` (a real process by
  /// default).
  MapSync({
    required this.environment,
    required this.appsteinVersion,
    required this.packs,
    ProcessRunner? runner,
  }) : runner = runner ?? const SystemProcessRunner();

  /// The machine.
  final HostEnvironment environment;

  /// The version of the running Appstein; part of every input hash.
  final String appsteinVersion;

  /// The packs whose extractors and layer rules apply.
  final List<Pack> packs;

  /// Runs `flutter pub get`.
  final ProcessRunner runner;

  /// Builds the map of the project at [projectRoot], for Flutter
  /// [flutterVersion] at [flutterRoot]. `dart:` libraries are read from
  /// [dartSdkPath], by default the Flutter SDK's `bin/cache/dart-sdk`.
  ///
  /// It never throws for the project's own problems: a failed fetch, an
  /// incomplete SDK, a damaged `pubspec.lock` or `pubspec.yaml`, or an
  /// unreadable project file is reported in [MapBuild.report], with no
  /// files.
  Future<MapBuild> build(
    String projectRoot, {
    required String flutterVersion,
    required String flutterRoot,
    String? dartSdkPath,
  }) async {
    var status = checkPackages(projectRoot, flutterVersion: flutterVersion);
    final reason = status.reason;
    var action = PackagesAction.upToDate;
    if (!status.fresh) {
      final failure = await fetchPackages(
        projectRoot,
        flutterRoot: flutterRoot,
        os: environment.os,
        runner: runner,
      );
      if (failure != null) {
        return MapBuild(
          files: const [],
          report: MapReport(
            packages: PackagesAction.fetchFailed,
            packagesReason: failure,
            skipped: 'the packages could not be fetched',
          ),
        );
      }
      action = PackagesAction.fetched;
      // A first fetch may have created the workspace reference.
      status = checkPackages(projectRoot, flutterVersion: flutterVersion);
    }

    final ProjectAnalysis analysis;
    try {
      analysis = await ProjectAnalysis.analyze(
        projectRoot,
        dartSdkPath:
            dartSdkPath ?? p.join(flutterRoot, 'bin', 'cache', 'dart-sdk'),
      );
    } on ProjectAnalysisException catch (error) {
      return MapBuild(
        files: const [],
        report: MapReport(
          packages: action,
          packagesReason: reason,
          skipped: error.message,
        ),
      );
    }
    try {
      final bodies = <String, Map<String, Object?>>{};
      for (final pack in packs) {
        for (final extractor in pack.extractors) {
          bodies.addAll(extractor.extract(analysis));
        }
      }
      final featuresBody = bodies[MapFiles.features];
      final features = featuresBody == null
          ? null
          : FeaturesMap.fromJson(featuresBody);
      String? featureOf(String file) => features?.featureOf(file);
      final rules = packs
          .where((pack) => pack.kind == PackKind.stack)
          .firstOrNull
          ?.layerRules;
      final matcher = rules == null ? null : LayerMatcher(rules);
      final lockFile = p.join(status.workspaceRoot, 'pubspec.lock');
      bodies[MapFiles.symbols] = buildSymbols(
        analysis,
        layerOf: (file) => matcher?.tagFor(file),
        featureOf: featureOf,
      ).toJson();
      bodies[MapFiles.layers] = buildLayers(
        analysis,
        rules: rules,
        featureOf: featureOf,
      ).toJson();
      bodies[MapFiles.deps] = buildDeps(analysis, lockFile: lockFile).toJson();

      final hash = _inputHash(
        projectRoot,
        lockFile: lockFile,
        flutterVersion: flutterVersion,
      );
      final paths = bodies.keys.toList()..sort();
      return MapBuild(
        files: [
          for (final path in paths)
            GeneratedFile(path: path, body: bodies[path]!, inputHash: hash),
        ],
        report: MapReport(packages: action, packagesReason: reason),
      );
    } on DependenciesException catch (error) {
      return MapBuild(
        files: const [],
        report: MapReport(
          packages: action,
          packagesReason: reason,
          skipped: '${error.message}; run `flutter pub get`',
        ),
      );
    } on FileSystemException catch (error) {
      return MapBuild(
        files: const [],
        report: MapReport(
          packages: action,
          packagesReason: reason,
          skipped:
              'the project files could not be read '
              '(${fileErrorReason(error)})',
        ),
      );
    } finally {
      await analysis.dispose();
    }
  }

  /// One hash for every map file (P9): every `.dart` file under
  /// [ProjectAnalysis.folders], `pubspec.yaml`, the lock file, the project's
  /// `analysis_options.yaml`, the Flutter version, and the packs' ids and
  /// versions.
  String _inputHash(
    String projectRoot, {
    required String lockFile,
    required String flutterVersion,
  }) {
    final inputs = <String, List<int>?>{
      'pubspec.yaml': _bytes(p.join(projectRoot, 'pubspec.yaml')),
      'pubspec.lock': _bytes(lockFile),
      // Its `exclude:` changes which files the map covers.
      'analysis_options.yaml': _bytes(
        p.join(projectRoot, 'analysis_options.yaml'),
      ),
      'flutter': utf8.encode(flutterVersion),
      'packs': utf8.encode(
        [for (final pack in packs) '${pack.id}@${pack.version}'].join(','),
      ),
    };
    for (final folder in ProjectAnalysis.folders) {
      final directory = Directory(p.join(projectRoot, folder));
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && entity.path.endsWith('.dart')) {
          final relative = p.split(p.relative(entity.path, from: projectRoot));
          inputs['project:${relative.join('/')}'] = _bytes(entity.path);
        }
      }
    }
    return inputHash(
      inputs,
      appsteinVersion: appsteinVersion,
      formatVersion: knowledgeFormatVersion,
    );
  }

  static List<int>? _bytes(String path) {
    try {
      return File(path).readAsBytesSync();
    } on FileSystemException {
      return null;
    }
  }
}
